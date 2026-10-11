//
//  FMDemodulator.swift
//  RTL-SDR Host
//
//  Turns the RTL-SDR's 8-bit IQ stream into FM broadcast audio:
//
//    IQ 960 kS/s, station at -240 kHz (the tuner sits fs/4 above it, so the
//    DC spike and the IQ image stay out of the channel)
//      → shift by +fs/4, channel filter, ÷4          → 240 kS/s complex
//      → FM discriminator, ±75 kHz deviation = ±1     → 240 kS/s multiplex
//      → L−R: × 38 kHz subcarrier from the pilot PLL
//      → variable-ratio resampler (clock drift, see FMReceiver)
//      → 16 kHz low-pass (removes pilot, subcarriers and RDS), ÷5 → 48 kHz
//      → L = (L+R) + (L−R), R = (L+R) − (L−R); blends to mono as the
//        reception gets weak, where stereo turns hissy
//      → de-emphasis (50 or 75 µs), DC blocker        → audio
//
//  Shifting by fs/4 multiplies sample n by j^n. Since the channel filter
//  then keeps every 4th output, the shift folds into the filter: taps
//  h[p]·j^p on the unshifted signal. Everything at 960 kS/s is then a plain
//  vDSP filter, which matters in debug builds, where Swift loops are slow.
//
//  It estimates the reception quality from the channel before the
//  discriminator: an FM signal has a constant envelope, so whatever makes
//  the envelope fluctuate is noise or interference. The second and fourth
//  moments of the power give the carrier-to-noise ratio (M2M4 estimator),
//  whatever the station broadcasts.
//
//  Runs on one queue; not thread-safe.
//

import Accelerate
import Foundation

nonisolated final class FMDemodulator {

    static let inputRate = 960_000
    static let mpxRate   = 240_000
    static let audioRate = 48_000
    /// How far above the station the tuner is set.
    static let tuningOffset = inputRate / 4

    private static let deviation = 75_000.0

    // The channel filter h[p]·j^p as real and imaginary taps.
    private static let channelTaps: (re: [Float], im: [Float]) = {
        let h = FilterDesign.lowpass(cutoff: 110_000, rate: 960_000, count: 128)
        let re = h.enumerated().map { p, v in p % 4 == 0 ? v : p % 4 == 2 ? -v : 0 }
        let im = h.enumerated().map { p, v in p % 4 == 1 ? v : p % 4 == 3 ? -v : 0 }
        return (re, im)
    }()
    private static let audioTaps = FilterDesign.lowpass(cutoff: 16_000, rate: 240_000, count: 255)
    /// The discriminator averages the frequency over one sample interval,
    /// a sinc response that takes 4 % off the 38 kHz subcarrier. Without
    /// this the separation stops at about 33 dB.
    private static let differenceGain: Float = {
        let x = Double.pi * 38_000 / 240_000
        return Float(x / sin(x))
    }()

    // (I + jQ) · (re + j·im) = (I·re − Q·im) + j(Q·re + I·im)
    private let iRe = FIRDecimator(taps: channelTaps.re, factor: 4)
    private let qIm = FIRDecimator(taps: channelTaps.im, factor: 4)
    private let qRe = FIRDecimator(taps: channelTaps.re, factor: 4)
    private let iIm = FIRDecimator(taps: channelTaps.im, factor: 4)
    private let sumFilter = FIRDecimator(taps: audioTaps, factor: 5)
    private let differenceFilter = FIRDecimator(taps: audioTaps, factor: 5)
    private let resampler = Resampler()
    private let pilot = PilotPLL()

    /// False plays mono even when the station sends stereo.
    var stereoEnabled = true

    // Block buffers, reused between calls.
    private var i960: [Float] = []
    private var q960: [Float] = []
    private var partA: [Float] = []
    private var partB: [Float] = []
    private var i240: [Float] = []
    private var q240: [Float] = []
    private var lastI240: [Float] = []
    private var lastQ240: [Float] = []
    private var re: [Float] = []
    private var im: [Float] = []
    private var mpx: [Float] = []
    private var subcarrier: [Float] = []
    private var difference: [Float] = []
    private var power: [Float] = []
    private var resampledSum: [Float] = []
    private var resampledDifference: [Float] = []
    private var sum48: [Float] = []
    private var difference48: [Float] = []

    // State carried from block to block.
    private var oddByte: [UInt8] = []
    private var lastI: Float = 0
    private var lastQ: Float = 0
    private var separation: Float = 0       // 0 = mono … 1 = full stereo
    private var deemphasisAlpha: Float = 0
    private var left = OutputFilter()
    private var right = OutputFilter()

    /// E|x|² and E|x|⁴ of the channel, smoothed over about half a second.
    private var moments: (m2: Double, m4: Double)?

    init(deemphasis: Double = 50e-6) {
        setDeemphasis(deemphasis)
    }

    /// Time constant in seconds: 50 µs in most of the world, 75 µs in the
    /// Americas and South Korea.
    func setDeemphasis(_ tau: Double) {
        deemphasisAlpha = Float(1 - exp(-1 / (Double(FMDemodulator.audioRate) * tau)))
    }

    func reset() {
        [iRe, qIm, qRe, iIm, sumFilter, differenceFilter].forEach { $0.reset() }
        resampler.reset()
        oddByte = []
        lastI = 0
        lastQ = 0
        left = OutputFilter()
        right = OutputFilter()
        stationChanged()
    }

    /// Forgets what belonged to the previous station: pilot and quality.
    func stationChanged() {
        pilot.reset()
        separation = 0
        moments = nil
    }

    /// Estimated carrier-to-noise ratio in the channel, in dB. For a
    /// constant envelope C in complex Gaussian noise N, M2 = C + N and
    /// M4 = C² + 4CN + 2N², so C = √(2·M2² − M4).
    var cnr: Double {
        guard let m = moments else { return 0 }
        let carrier = (max(2 * m.m2 * m.m2 - m.m4, 0)).squareRoot()
        let noise = m.m2 - carrier
        guard carrier > 0 else { return 0 }
        guard noise > 0 else { return 60 }
        return min(10 * log10(carrier / noise), 60)
    }

    /// Reception quality from 0 (noise) to 1 (excellent): 10 dB CNR, where
    /// FM breaks up, up to 45 dB.
    var quality: Double {
        min(max((cnr - 10) / 35, 0), 1)
    }

    /// True while the audio is (mostly) stereo.
    var isStereo: Bool { separation > 0.5 }

    /// Demodulates a block of interleaved 8-bit IQ bytes and appends the
    /// audio as interleaved left / right samples to `audio`. `ratio`
    /// stretches the output slightly (output / input samples, close to 1)
    /// to follow the audio clock.
    func process(_ iq: UnsafeRawBufferPointer, ratio: Double, into audio: inout [Float]) {
        convert(iq)
        guard !i960.isEmpty else { return }
        selectChannel()
        guard !i240.isEmpty else { return }
        discriminate()
        estimateNoise()

        // L−R: the subcarrier is double-sideband around 38 kHz.
        let n = mpx.count
        FMDemodulator.resize(&subcarrier, to: n)
        FMDemodulator.resize(&difference, to: n)
        mpx.withUnsafeBufferPointer { m in
            subcarrier.withUnsafeMutableBufferPointer { pilot.process(m, subcarrier: $0) }
        }
        vDSP.multiply(mpx, subcarrier, result: &difference)
        var gain = FMDemodulator.differenceGain
        difference.withUnsafeMutableBufferPointer { x in
            vDSP_vsmul(x.baseAddress!, 1, &gain, x.baseAddress!, 1, vDSP_Length(n))
        }

        resampledSum.removeAll(keepingCapacity: true)
        resampledDifference.removeAll(keepingCapacity: true)
        mpx.withUnsafeBufferPointer { m in
            difference.withUnsafeBufferPointer { d in
                resampler.process(m, d, ratio: ratio, into: &resampledSum, &resampledDifference)
            }
        }
        sum48.removeAll(keepingCapacity: true)
        difference48.removeAll(keepingCapacity: true)
        resampledSum.withUnsafeBufferPointer { sumFilter.process($0, into: &sum48) }
        resampledDifference.withUnsafeBufferPointer { differenceFilter.process($0, into: &difference48) }

        matrix(into: &audio)
    }

    // MARK: - Stages

    /// 8-bit IQ → I and Q floats in [-1, 1]. A block may end in the middle
    /// of a pair; that byte waits for the next block.
    private func convert(_ iq: UnsafeRawBufferPointer) {
        let bytes = iq.assumingMemoryBound(to: UInt8.self)
        if oddByte.isEmpty {
            convertPairs(bytes)
        } else {
            var joined = oddByte
            joined.append(contentsOf: bytes)
            oddByte = []
            joined.withUnsafeBufferPointer { convertPairs($0) }
        }
    }

    private func convertPairs(_ bytes: UnsafeBufferPointer<UInt8>) {
        let n = bytes.count / 2
        if bytes.count % 2 == 1 { oddByte = [bytes[bytes.count - 1]] }
        FMDemodulator.resize(&i960, to: n)
        FMDemodulator.resize(&q960, to: n)
        guard n > 0, let src = bytes.baseAddress else { return }
        var scale: Float = 1 / 127.5
        var offset: Float = -1
        vDSP_vfltu8(src, 2, &i960, 1, vDSP_Length(n))
        vDSP_vfltu8(src + 1, 2, &q960, 1, vDSP_Length(n))
        for buffer in [\FMDemodulator.i960, \FMDemodulator.q960] {
            self[keyPath: buffer].withUnsafeMutableBufferPointer { x in
                vDSP_vsmsa(x.baseAddress!, 1, &scale, &offset, x.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }

    /// Shift by +fs/4, channel filter and ÷4 in one complex FIR.
    private func selectChannel() {
        partA.removeAll(keepingCapacity: true)
        partB.removeAll(keepingCapacity: true)
        i960.withUnsafeBufferPointer { iRe.process($0, into: &partA) }
        q960.withUnsafeBufferPointer { qIm.process($0, into: &partB) }
        FMDemodulator.resize(&i240, to: partA.count)
        vDSP.subtract(partA, partB, result: &i240)

        partA.removeAll(keepingCapacity: true)
        partB.removeAll(keepingCapacity: true)
        q960.withUnsafeBufferPointer { qRe.process($0, into: &partA) }
        i960.withUnsafeBufferPointer { iIm.process($0, into: &partB) }
        FMDemodulator.resize(&q240, to: partA.count)
        vDSP.add(partA, partB, result: &q240)
    }

    /// Phase difference between consecutive samples, scaled so that the
    /// full ±75 kHz deviation maps to ±1.
    private func discriminate() {
        let n = i240.count
        // x[k-1], continuing from the previous block.
        FMDemodulator.resize(&lastI240, to: n)
        FMDemodulator.resize(&lastQ240, to: n)
        lastI240[0] = lastI
        lastQ240[0] = lastQ
        memcpy(&lastI240[1], i240, (n - 1) * MemoryLayout<Float>.size)
        memcpy(&lastQ240[1], q240, (n - 1) * MemoryLayout<Float>.size)
        lastI = i240[n - 1]
        lastQ = q240[n - 1]

        // x[k] · conj(x[k-1])
        FMDemodulator.resize(&re, to: n)
        FMDemodulator.resize(&im, to: n)
        vDSP_vmma(i240, 1, lastI240, 1, q240, 1, lastQ240, 1, &re, 1, vDSP_Length(n))
        vDSP_vmmsb(q240, 1, lastI240, 1, i240, 1, lastQ240, 1, &im, 1, vDSP_Length(n))

        FMDemodulator.resize(&mpx, to: n)
        var count = Int32(n)
        vvatan2f(&mpx, im, re, &count)
        var scale = Float(Double(FMDemodulator.mpxRate) / (2 * .pi * FMDemodulator.deviation))
        mpx.withUnsafeMutableBufferPointer { x in
            vDSP_vsmul(x.baseAddress!, 1, &scale, x.baseAddress!, 1, vDSP_Length(n))
        }
    }

    private func estimateNoise() {
        let n = i240.count
        FMDemodulator.resize(&power, to: n)
        vDSP_vmma(i240, 1, i240, 1, q240, 1, q240, 1, &power, 1, vDSP_Length(n))
        let m2 = Double(vDSP.mean(power))
        let m4 = Double(vDSP.meanSquare(power))
        let alpha = 1 - exp(-Double(n) / (0.5 * Double(FMDemodulator.mpxRate)))
        moments = moments.map { ($0.m2 + alpha * (m2 - $0.m2), $0.m4 + alpha * (m4 - $0.m4)) } ?? (m2, m4)
    }

    /// Left and right from sum and difference, then de-emphasis. The stereo
    /// separation follows the reception and glides across the block.
    private func matrix(into audio: inout [Float]) {
        let n = min(sum48.count, difference48.count)
        guard n > 0 else { return }

        // Stereo noise is about 20 dB above mono: full stereo from 28 dB CNR,
        // blending to mono at 18 dB.
        let target: Float = stereoEnabled && pilot.isLocked
            ? Float(min(max((cnr - 18) / 10, 0), 1)) : 0
        let alpha = Float(1 - exp(-Double(n) / (0.3 * Double(FMDemodulator.audioRate))))
        let from = separation
        separation += alpha * (target - separation)
        let step = (separation - from) / Float(n)

        let start = audio.count
        audio.appendZeros(2 * n)
        let a = deemphasisAlpha
        var l = left, r = right
        sum48.withUnsafeBufferPointer { m in
            difference48.withUnsafeBufferPointer { d in
                audio.withUnsafeMutableBufferPointer { out in
                    var sep = from
                    for k in 0..<n {
                        sep += step
                        let diff = d[k] * sep
                        out[start + 2 * k] = l.process(m[k] + diff, alpha: a)
                        out[start + 2 * k + 1] = r.process(m[k] - diff, alpha: a)
                    }
                }
            }
        }
        left = l
        right = r
    }

    /// Sets the length, reusing the array's storage.
    private static func resize(_ array: inout [Float], to count: Int) {
        guard array.count != count else { return }
        if array.count > count {
            array.removeLast(array.count - count)
        } else {
            array.appendZeros(count - array.count)
        }
    }
}

/// De-emphasis and DC blocker for one channel.
private nonisolated struct OutputFilter {
    var emphasis: Float = 0
    var lastIn: Float = 0
    var lastOut: Float = 0

    mutating func process(_ x: Float, alpha: Float) -> Float {
        emphasis += alpha * (x - emphasis)
        // A tuning error shows up as a constant offset.
        let y = emphasis - lastIn + 0.999 * lastOut
        lastIn = emphasis
        lastOut = y
        return y
    }
}

/// Locks to the 19 kHz stereo pilot and supplies the 38 kHz subcarrier.
/// The standard puts their zero crossings together: with the pilot at
/// sin(φ), the subcarrier is sin(2φ).
///
/// The oscillator is a rotating phasor; the phase detector is averaged over
/// blocks of 64 samples, and the loop corrects phase and frequency once
/// per block.
nonisolated final class PilotPLL {

    private static let rate = 240_000.0
    private static let block = 64
    private static let nominal = 2 * Double.pi * 19_000 / rate
    // Second-order loop, ωn = 2π · 10 Hz, ζ = 0.7.
    private static let loopTime = 2 * Double.pi * 10 * Double(block) / rate
    private static let loopP = 2 * 0.7 * loopTime
    private static let loopI = loopTime * loopTime / Double(block)
    private static let maxOffset = 2 * Double.pi * 20 / rate

    private var c: Float = 1
    private var s: Float = 0
    private var offset = 0.0                // rad per sample
    private var stepC = Float(cos(nominal))
    private var stepS = Float(sin(nominal))
    private var sumI: Float = 0
    private var sumQ: Float = 0
    private var count = 0
    private var level: Float = 0
    private var quadrature: Float = 0
    private var score = 0
    private(set) var isLocked = false

    func reset() {
        c = 1
        s = 0
        offset = 0
        setStep()
        sumI = 0
        sumQ = 0
        count = 0
        level = 0
        quadrature = 0
        score = 0
        isLocked = false
    }

    /// Writes 2·sin(2φ) for every sample of the multiplex.
    func process(_ mpx: UnsafeBufferPointer<Float>, subcarrier: UnsafeMutableBufferPointer<Float>) {
        guard let x = mpx.baseAddress, let out = subcarrier.baseAddress else { return }
        var n = 0
        while n < mpx.count {
            // Up to the end of the loop's block, on local copies: in debug
            // builds every property access in this loop would cost a call.
            let length = min(PilotPLL.block - count, mpx.count - n)
            var c = self.c, s = self.s, sumI = self.sumI, sumQ = self.sumQ
            let stepC = self.stepC, stepS = self.stepS
            for k in n..<n + length {
                let v = x[k]
                sumI += v * s
                sumQ += v * c
                out[k] = 4 * s * c
                let nc = c * stepC - s * stepS
                s = s * stepC + c * stepS
                c = nc
            }
            self.c = c
            self.s = s
            self.sumI = sumI
            self.sumQ = sumQ
            count += length
            n += length
            if count == PilotPLL.block { updateLoop() }
        }
    }

    private func updateLoop() {
        // The pilot is A·sin(φ + δ): i ≈ A·cos δ, q ≈ A·sin δ.
        let i = 2 * sumI / Float(count)
        let q = 2 * sumQ / Float(count)
        sumI = 0
        sumQ = 0
        count = 0

        // The pilot is 8 to 10 % of the deviation, 0.08 … 0.1 here.
        level += 0.02 * (i - level)
        quadrature += 0.02 * (q - quadrature)
        let inLock = level > 0.04 && abs(quadrature) < 0.5 * level
        score = inLock ? min(score + 1, 400) : max(score - 2, 0)
        if score >= 300 { isLocked = true } else if score < 100 { isLocked = false }

        let error = i * i + q * q > 1e-4 ? Double(atan2(q, i)) : 0
        let correction = PilotPLL.loopP * error
        let cc = Float(cos(correction)), cs = Float(sin(correction))
        (c, s) = (c * cc - s * cs, s * cc + c * cs)
        let norm = 1 / (c * c + s * s).squareRoot()
        c *= norm
        s *= norm
        offset = min(max(offset + PilotPLL.loopI * error, -PilotPLL.maxOffset), PilotPLL.maxOffset)
        setStep()
    }

    private func setStep() {
        stepC = Float(cos(PilotPLL.nominal + offset))
        stepS = Float(sin(PilotPLL.nominal + offset))
    }
}

// MARK: - Building blocks

/// FIR filter that keeps every `factor`-th output sample. Keeps the input
/// history between blocks, so the blocks may have any length.
nonisolated final class FIRDecimator {

    private let taps: [Float]
    private let factor: Int
    private var buffer: [Float]

    init(taps: [Float], factor: Int) {
        self.taps = taps
        self.factor = factor
        buffer = [Float](repeating: 0, count: taps.count - 1)
    }

    func reset() {
        buffer = [Float](repeating: 0, count: taps.count - 1)
    }

    func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        buffer.append(contentsOf: input)
        let p = taps.count
        guard buffer.count >= p else { return }
        let n = (buffer.count - p) / factor + 1
        let start = output.count
        output.appendZeros(n)
        buffer.withUnsafeBufferPointer { a in
            taps.withUnsafeBufferPointer { f in
                output.withUnsafeMutableBufferPointer { c in
                    vDSP_desamp(a.baseAddress!, vDSP_Stride(factor), f.baseAddress!,
                                c.baseAddress! + start, vDSP_Length(n), vDSP_Length(p))
                }
            }
        }
        buffer.removeFirst(n * factor)
    }
}

/// Resamples two channels by a ratio close to 1 with cubic (Catmull-Rom)
/// interpolation. It runs on the 240 kS/s multiplex, where audio
/// frequencies are so far below the sample rate that the interpolation is
/// practically flat.
nonisolated final class Resampler {

    private var workA: [Float] = [0, 0, 0]
    private var workB: [Float] = [0, 0, 0]
    private var position = 1.0          // read position in the work buffers

    func reset() {
        workA = [0, 0, 0]
        workB = [0, 0, 0]
        position = 1
    }

    func process(_ a: UnsafeBufferPointer<Float>, _ b: UnsafeBufferPointer<Float>, ratio: Double,
                 into outA: inout [Float], _ outB: inout [Float]) {
        workA.append(contentsOf: a)
        workB.append(contentsOf: b)
        let step = 1 / ratio
        let end = Double(workA.count - 2)
        var t = position
        let start = outA.count
        let room = Int((end - t) / step) + 2
        outA.appendZeros(room)
        outB.appendZeros(room)
        var produced = 0
        workA.withUnsafeBufferPointer { xa in
            workB.withUnsafeBufferPointer { xb in
                outA.withUnsafeMutableBufferPointer { ya in
                    outB.withUnsafeMutableBufferPointer { yb in
                        while t < end {
                            let i = Int(t)
                            let f = Float(t - Double(i))
                            ya[start + produced] = Resampler.cubic(xa, i, f)
                            yb[start + produced] = Resampler.cubic(xb, i, f)
                            produced += 1
                            t += step
                        }
                    }
                }
            }
        }
        outA.removeLast(room - produced)
        outB.removeLast(room - produced)
        // Keep the last three samples for the next block's interpolation.
        let consumed = workA.count - 3
        position = t - Double(consumed)
        workA.removeFirst(consumed)
        workB.removeFirst(consumed)
    }

    @inline(__always)
    private static func cubic(_ x: UnsafeBufferPointer<Float>, _ i: Int, _ f: Float) -> Float {
        let xm1 = x[i - 1], x0 = x[i], x1 = x[i + 1], x2 = x[i + 2]
        let c1 = 0.5 * (x1 - xm1)
        let c2 = xm1 - 2.5 * x0 + 2 * x1 - 0.5 * x2
        let c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1)
        return ((c3 * f + c2) * f + c1) * f + x0
    }
}

extension Array where Element == Float {

    /// Appends `count` zeros. Unlike `append(contentsOf: repeatElement(…))`,
    /// which debug builds run element by element through generic code, this
    /// stays a memory clear even unoptimised.
    nonisolated mutating func appendZeros(_ count: Int) {
        guard count > 0 else { return }
        append(contentsOf: [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            vDSP_vclr(buffer.baseAddress!, 1, vDSP_Length(count))
            initialized = count
        })
    }
}

/// Windowed-sinc (Blackman) filter design.
nonisolated enum FilterDesign {

    static func lowpass(cutoff: Double, rate: Double, count: Int) -> [Float] {
        let taps = sinc(cutoff: cutoff, rate: rate, count: count)
        let sum = taps.reduce(0, +)
        return taps.map { Float($0 / sum) }
    }

    static func bandpass(low: Double, high: Double, rate: Double, count: Int) -> [Float] {
        let h = sinc(cutoff: high, rate: rate, count: count)
        let l = sinc(cutoff: low, rate: rate, count: count)
        return zip(h, l).map { Float($0 - $1) }
    }

    private static func sinc(cutoff: Double, rate: Double, count: Int) -> [Double] {
        let fc = cutoff / rate
        let m = Double(count - 1)
        return (0..<count).map { n in
            let x = Double(n) - m / 2
            let s = x == 0 ? 2 * fc : sin(2 * .pi * fc * x) / (.pi * x)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(n) / m) + 0.08 * cos(4 * .pi * Double(n) / m)
            return s * w
        }
    }
}
