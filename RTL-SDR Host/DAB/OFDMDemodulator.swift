//
//  OFDMDemodulator.swift
//  RTL-SDR Host
//
//  Turns the RTL-SDR's 8-bit IQ at 2.048 MS/s into the soft bits of DAB
//  transmission frames (mode I, EN 300 401 clause 14):
//
//    search: the null symbol is a 1.3 ms gap in the signal power
//      → FFT of the phase reference symbol (PRS) right after it
//      → integer frequency offset: the shift (in 1 kHz carriers) at which
//        the phase steps between neighbouring carriers match the PRS
//      → timing: impulse response of PRS × conj(expected PRS), its peak is
//        where the symbol really starts
//      → fraction of a carrier: phase of the guard interval against the
//        symbol's end, which repeats it
//    each frame: 76 symbols at known positions
//      → mix down by the frequency offset (an NCO on the absolute sample
//        count, so the phase runs on across frames), FFT
//      → DQPSK: carrier × conj(same carrier one symbol earlier)
//      → frequency deinterleaving, soft bits (real part = bit n, imaginary
//        part = bit n + 1536)
//      → tracking: the PRS peak moves with the sample clock error, the
//        guard correlation with the residual frequency offset
//
//  Delivers 3 FIC symbols and 72 MSC symbols, 3072 soft bits each, per
//  frame. Soft bits are > 0 for a likely 0.
//
//  Runs on one queue; not thread-safe.
//

import Accelerate
import Foundation

nonisolated final class OFDMDemodulator {

    struct Frame {
        /// 3 × 3072 soft bits.
        var fic: [Int8]
        /// 72 × 3072 soft bits.
        var msc: [Int8]
    }

    /// Modulation error ratio of the DQPSK constellation, dB. 0 until synced.
    private(set) var mer = 0.0
    private(set) var isSynced = false
    /// Frequency offset of the signal against the tuner, Hz.
    private(set) var frequencyOffset = 0.0
    /// Sample clock error, ppm, from how the frame start moves.
    private(set) var clockError = 0.0
    /// Total frames delivered.
    private(set) var frames = 0

    private let n = DAB.fftSize
    private let backoff = 48                    // FFT window starts this early in the guard
    private let maxIntegerOffset = 40           // carriers (kHz)

    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    // Raw IQ, not yet consumed; `base` is the absolute index of element 0.
    private var re: [Float] = []
    private var im: [Float] = []
    private var base: Int64 = 0

    private var frameStart: Int64 = 0           // absolute index of the null symbol
    private var timingCorrection = 0            // samples, applied to the next frame start
    private var lostFrames = 0

    // Expected PRS per bin (unit phasors), and the carrier ↔ bin mapping.
    private let prsRe: [Float]
    private let prsIm: [Float]
    private let carrierBin: [Int]               // for QPSK symbol n
    private let usedBins: [Int]                 // all 1536 carriers, k = −768 … 768

    // Scratch.
    private var winRe: [Float]
    private var winIm: [Float]
    private var outRe: [Float]
    private var outIm: [Float]
    private var prevRe: [Float]
    private var prevIm: [Float]
    /// Average |re|, |im| per carrier, for the MER.
    private var carrierLevel: [Float] = []
    private var ramp: [Float]
    private var cosTable: [Float]
    private var sinTable: [Float]

    init() {
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(DAB.fftSize), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(DAB.fftSize), .INVERSE)!
        var pre = [Float](repeating: 0, count: DAB.fftSize)
        var pim = pre
        var used: [Int] = []
        for k in -768...768 where k != 0 {
            let bin = (k + DAB.fftSize) % DAB.fftSize
            let phase = Double(DAB.prsPhase(k)) * .pi / 2
            pre[bin] = Float(cos(phase))
            pim[bin] = Float(sin(phase))
            used.append(bin)
        }
        prsRe = pre
        prsIm = pim
        usedBins = used
        carrierBin = DAB.interleavedCarrier.map { ($0 + DAB.fftSize) % DAB.fftSize }
        winRe = [Float](repeating: 0, count: DAB.fftSize)
        winIm = winRe; outRe = winRe; outIm = winRe; prevRe = winRe; prevIm = winRe
        ramp = winRe; cosTable = winRe; sinTable = winRe
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Forgets the signal, e.g. after retuning.
    func reset() {
        re.removeAll(keepingCapacity: true)
        im.removeAll(keepingCapacity: true)
        base = 0
        isSynced = false
        mer = 0
        carrierLevel = []
        frequencyOffset = 0
        clockError = 0
        timingCorrection = 0
        lostFrames = 0
    }

    /// Appends 8-bit IQ and returns the frames now complete.
    func process(_ iq: UnsafeRawBufferPointer) -> [Frame] {
        let count = iq.count / 2
        guard count > 0 else { return [] }
        let old = re.count
        re.append(contentsOf: repeatElement(0, count: count))
        im.append(contentsOf: repeatElement(0, count: count))
        let bytes = iq.bindMemory(to: UInt8.self)
        // Interleaved bytes → floats in [−1, 1).
        var scale: Float = 1 / 128
        var offset: Float = -127.5 / 128
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                vDSP_vfltu8(bytes.baseAddress!, 2, r.baseAddress! + old, 1, vDSP_Length(count))
                vDSP_vfltu8(bytes.baseAddress! + 1, 2, i.baseAddress! + old, 1, vDSP_Length(count))
                vDSP_vsmsa(r.baseAddress! + old, 1, &scale, &offset, r.baseAddress! + old, 1, vDSP_Length(count))
                vDSP_vsmsa(i.baseAddress! + old, 1, &scale, &offset, i.baseAddress! + old, 1, vDSP_Length(count))
            }
        }

        var result: [Frame] = []
        while true {
            if !isSynced {
                guard acquire() else { break }
            }
            guard let frame = demodulateFrame() else { break }
            if let frame { result.append(frame) }
        }
        compact()
        return result
    }

    // MARK: - Acquisition

    /// Looks for a null symbol and locks onto the frame after it. Returns
    /// false when it needs more samples.
    private func acquire() -> Bool {
        let available = re.count
        let block = 64
        // Enough for a whole frame after the null, wherever it is.
        guard available >= DAB.frameLength + 2 * DAB.nullLength else { return false }

        let blocks = available / block
        var power = [Float](repeating: 0, count: blocks)
        re.withUnsafeBufferPointer { r in im.withUnsafeBufferPointer { i in
            for b in 0..<blocks {
                var sr: Float = 0, si: Float = 0
                vDSP_svesq(r.baseAddress! + b * block, 1, &sr, vDSP_Length(block))
                vDSP_svesq(i.baseAddress! + b * block, 1, &si, vDSP_Length(block))
                power[b] = sr + si
            }
        } }
        let mean = power.reduce(0, +) / Float(blocks)
        let needed = (DAB.nullLength - 2 * block) / block
        var run = 0
        var nullEnd: Int?
        for b in 0..<blocks {
            // At 6 dB SNR the null still carries a quarter of the signal's
            // power, as noise.
            if power[b] < 0.5 * mean {
                run += 1
            } else {
                if run >= needed, b * block + DAB.frameLength + block <= available {
                    nullEnd = b * block
                    break
                }
                run = 0
            }
        }
        guard let end = nullEnd else {
            drop(max(0, available - DAB.frameLength - 2 * DAB.nullLength))
            return false
        }

        // The null ends somewhere in the block before `end`.
        let guess = end - block / 2
        guard let lock = lockPRS(nearSymbolStart: guess) else {
            drop(end)               // not a DAB frame: look further on
            return false
        }
        frequencyOffset = lock.offset
        frameStart = base + Int64(lock.symbolStart - DAB.nullLength)
        timingCorrection = 0
        lostFrames = 0
        isSynced = true
        return true
    }

    /// Integer and fractional frequency offset and exact symbol start of the
    /// PRS that starts about at `guess` (buffer index).
    private func lockPRS(nearSymbolStart guess: Int) -> (symbolStart: Int, offset: Double)? {
        let start = guess + DAB.guardLength - backoff
        guard start >= 0, start + n <= re.count else { return nil }
        fft(at: start, offsetHz: 0)

        // Differential correlation with the PRS: insensitive to the timing.
        var best = (shift: 0, value: Float(0))
        var total: Float = 0
        for s in -maxIntegerOffset...maxIntegerOffset {
            var accRe: Float = 0, accIm: Float = 0
            for k in -768..<768 where k != 0 && k != -1 {
                let a = (k + s + n) % n, b = (k + 1 + s + n) % n
                // X_a conj(X_b)
                let xr = outRe[a] * outRe[b] + outIm[a] * outIm[b]
                let xi = outIm[a] * outRe[b] - outRe[a] * outIm[b]
                let ka = (k + n) % n, kb = (k + 1 + n) % n
                let pr = prsRe[ka] * prsRe[kb] + prsIm[ka] * prsIm[kb]
                let pi = prsIm[ka] * prsRe[kb] - prsRe[ka] * prsIm[kb]
                // × conj(P_a conj(P_b))
                accRe += xr * pr + xi * pi
                accIm += xi * pr - xr * pi
            }
            let value = accRe * accRe + accIm * accIm
            total += value
            if value > best.value { best = (s, value) }
        }
        let average = total / Float(2 * maxIntegerOffset + 1)
        guard best.value > 8 * average else { return nil }

        // Coarse offset removed, the impulse response gives the timing.
        let coarse = Double(best.shift) * 1000
        fft(at: start, offsetHz: coarse)
        let peak = impulsePeak()
        let symbolStart = start + peak - DAB.guardLength + backoff
        guard symbolStart >= 0, symbolStart + DAB.symbolLength <= re.count else { return nil }

        // Fraction of a carrier from the guard interval.
        let fraction = guardPhase(at: symbolStart, offsetHz: coarse) / (2 * .pi) * 1000
        return (symbolStart, coarse + fraction)
    }

    // MARK: - Frames

    /// nil: needs more samples. .some(nil): the frame was lost (resync).
    private func demodulateFrame() -> Frame?? {
        let first = Int(frameStart - base) + DAB.nullLength
        let last = first + DAB.symbolsPerFrame * DAB.symbolLength + DAB.nullLength
        guard first >= 0 else { isSynced = false; return .some(nil) }
        guard last <= re.count else { return nil }

        var fic = [Int8](repeating: 0, count: DAB.ficSymbols * DAB.bitsPerSymbol)
        var msc = [Int8](repeating: 0, count: (DAB.symbolsPerFrame - 1 - DAB.ficSymbols) * DAB.bitsPerSymbol)
        var errorPower = 0.0, signalPower = 0.0
        var guardRe = 0.0, guardIm = 0.0

        for l in 0..<DAB.symbolsPerFrame {
            let symbolStart = first + l * DAB.symbolLength
            fft(at: symbolStart + DAB.guardLength - backoff, offsetHz: frequencyOffset)
            let g = guardCorrelation(at: symbolStart, offsetHz: frequencyOffset)
            guardRe += g.re
            guardIm += g.im

            if l == 0 {
                // Timing from the PRS. A peak at index `backoff` is on time.
                let peak = impulsePeak()
                trackTiming(peak - backoff)
            } else {
                let symbol = l - 1
                let e = symbol < DAB.ficSymbols
                    ? demap(into: &fic, at: symbol * DAB.bitsPerSymbol)
                    : demap(into: &msc, at: (symbol - DAB.ficSymbols) * DAB.bitsPerSymbol)
                errorPower += e.error
                signalPower += e.signal
            }
            swap(&prevRe, &outRe)
            swap(&prevIm, &outIm)
        }

        // Residual frequency offset, a fraction of the remaining error.
        let residual = atan2(guardIm, guardRe) / (2 * .pi) * 1000
        frequencyOffset += 0.3 * residual
        let ratio = signalPower / max(errorPower, 1e-12)
        mer = 10 * log10(ratio)

        if !isSynced { return .some(nil) }
        frames += 1
        frameStart += Int64(DAB.frameLength + timingCorrection)
        return .some(Frame(fic: fic, msc: msc))
    }

    private func trackTiming(_ error: Int) {
        // A clock error moves the frame by a few samples per frame at most;
        // a large jump means the sync is lost.
        if abs(error) > DAB.guardLength / 2 {
            lostFrames += 1
            if lostFrames >= 2 { isSynced = false }
            return
        }
        lostFrames = 0
        // Half the error per frame: follows a clock error of a few hundred
        // ppm without reacting to noise in the peak.
        timingCorrection = error / 2
        // In steady state the correction is the drift per frame.
        clockError = 0.95 * clockError + 0.05 * Double(timingCorrection) / Double(DAB.frameLength) * 1e6
    }

    /// DQPSK against the previous symbol (in prevRe/prevIm), deinterleaved
    /// into soft bits.
    private func demap(into bits: inout [Int8], at offset: Int) -> (signal: Double, error: Double) {
        let k = DAB.carriers
        var yRe = [Float](repeating: 0, count: k)
        var yIm = [Float](repeating: 0, count: k)
        var sumAbs: Float = 0
        for q in 0..<k {
            let b = carrierBin[q]
            let r = outRe[b] * prevRe[b] + outIm[b] * prevIm[b]
            let i = outIm[b] * prevRe[b] - outRe[b] * prevIm[b]
            yRe[q] = r
            yIm[q] = i
            sumAbs += abs(r) + abs(i)
        }
        let mean = max(sumAbs / Float(2 * k), 1e-20)
        let gain = 40 / mean
        // MER against each carrier's own level, averaged over the last few
        // symbols: on a real channel the levels differ across the band
        // (multipath, the tuner's filter edges), which is not noise.
        if carrierLevel.count != k { carrierLevel = [Float](repeating: mean, count: k) }
        var signal = 0.0, error = 0.0
        bits.withUnsafeMutableBufferPointer { out in
            for q in 0..<k {
                out[offset + q] = Int8(clamping: Int((yRe[q] * gain).rounded()))
                out[offset + k + q] = Int8(clamping: Int((yIm[q] * gain).rounded()))
                let level = max(carrierLevel[q], 1e-20)
                let r = abs(yRe[q]) / level, i = abs(yIm[q]) / level
                carrierLevel[q] += 0.1 * ((abs(yRe[q]) + abs(yIm[q])) / 2 - carrierLevel[q])
                error += Double((r - 1) * (r - 1) + (i - 1) * (i - 1))
                signal += 2
            }
        }
        return (signal, error)
    }

    // MARK: - Helpers

    /// FFT of n samples from buffer index `start`, mixed down by `offsetHz`,
    /// into outRe/outIm.
    private func fft(at start: Int, offsetHz: Double) {
        mix(from: start, count: n, offsetHz: offsetHz, re: &winRe, im: &winIm)
        vDSP_DFT_Execute(forward, winRe, winIm, &outRe, &outIm)
    }

    /// Samples × exp(−j 2π f t), t from the absolute sample count.
    private func mix(from start: Int, count: Int, offsetHz: Double, re outR: inout [Float], im outI: inout [Float]) {
        let cycles = offsetHz / Double(DAB.sampleRate)
        let phase0 = (cycles * Double(base + Int64(start))).truncatingRemainder(dividingBy: 1)
        var startPhase = Float(-2 * .pi * phase0)
        var step = Float(-2 * .pi * cycles)
        vDSP_vramp(&startPhase, &step, &ramp, 1, vDSP_Length(count))
        var c = Int32(count)
        vvsincosf(&sinTable, &cosTable, ramp, &c)
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in
            cosTable.withUnsafeMutableBufferPointer { c in sinTable.withUnsafeMutableBufferPointer { sn in
                outR.withUnsafeMutableBufferPointer { o in outI.withUnsafeMutableBufferPointer { oi in
                    var x = DSPSplitComplex(realp: r.baseAddress! + start, imagp: i.baseAddress! + start)
                    var w = DSPSplitComplex(realp: c.baseAddress!, imagp: sn.baseAddress!)
                    var y = DSPSplitComplex(realp: o.baseAddress!, imagp: oi.baseAddress!)
                    vDSP_zvmul(&x, 1, &w, 1, &y, 1, vDSP_Length(count), 1)
                } }
            } }
        } }
    }

    /// Peak of the channel impulse response from the PRS in outRe/outIm,
    /// −n/2 … n/2.
    private func impulsePeak() -> Int {
        var hRe = [Float](repeating: 0, count: n)
        var hIm = [Float](repeating: 0, count: n)
        for b in usedBins {
            // X · conj(P)
            hRe[b] = outRe[b] * prsRe[b] + outIm[b] * prsIm[b]
            hIm[b] = outIm[b] * prsRe[b] - outRe[b] * prsIm[b]
        }
        var tRe = [Float](repeating: 0, count: n)
        var tIm = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(inverse, hRe, hIm, &tRe, &tIm)
        var best = 0
        var top: Float = -1
        for t in 0..<n {
            let p = tRe[t] * tRe[t] + tIm[t] * tIm[t]
            if p > top { top = p; best = t }
        }
        return best > n / 2 ? best - n : best
    }

    /// Σ x[t] conj(x[t + n]) over the guard interval, mixed down.
    private func guardCorrelation(at symbolStart: Int, offsetHz: Double) -> (re: Double, im: Double) {
        let g = DAB.guardLength
        var aRe = [Float](repeating: 0, count: g), aIm = aRe, bRe = aRe, bIm = aRe
        mix(from: symbolStart, count: g, offsetHz: offsetHz, re: &aRe, im: &aIm)
        mix(from: symbolStart + n, count: g, offsetHz: offsetHz, re: &bRe, im: &bIm)
        var sr = 0.0, si = 0.0
        for t in 0..<g {
            // the end of the symbol lags its copy by n samples: b · conj(a)
            sr += Double(bRe[t] * aRe[t] + bIm[t] * aIm[t])
            si += Double(bIm[t] * aRe[t] - bRe[t] * aIm[t])
        }
        return (sr, si)
    }

    private func guardPhase(at symbolStart: Int, offsetHz: Double) -> Double {
        let g = guardCorrelation(at: symbolStart, offsetHz: offsetHz)
        return atan2(g.im, g.re)
    }

    private func drop(_ count: Int) {
        guard count > 0 else { return }
        re.removeFirst(min(count, re.count))
        im.removeFirst(min(count, im.count))
        base += Int64(count)
    }

    /// Drops samples before the current frame.
    private func compact() {
        let keep: Int
        if isSynced {
            keep = Int(frameStart - base) - DAB.symbolLength
        } else {
            keep = 0
        }
        if keep > 1 << 16 { drop(keep) }
    }
}
