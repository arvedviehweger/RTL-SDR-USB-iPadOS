//
//  SpectrumAnalyzer.swift
//  RTL-SDR Host
//
//  The spectrum of the IQ stream for the radio's waterfall: 1024-point FFTs
//  (Blackman window) averaged into 25 frames per second, in dB relative to
//  a full-scale carrier, from the lowest to the highest frequency.
//
//  Runs on the demodulator's queue; not thread-safe.
//

import Accelerate
import Foundation

nonisolated final class SpectrumAnalyzer {

    static let size = 1024
    private static let framesPerSecond = 25

    private let rate: Int
    // 1024-point complex transforms are always supported.
    private let dft = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward,
                                                         transformType: .complexComplex,
                                                         ofType: Float.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .blackman,
                                     count: size, isHalfWindow: false)
    /// A full-scale carrier comes out of the FFT with this power.
    private let reference: Float

    private var pendingI: [Float] = []
    private var pendingQ: [Float] = []
    private var windowedI = [Float](repeating: 0, count: size)
    private var windowedQ = [Float](repeating: 0, count: size)
    private var outI = [Float](repeating: 0, count: size)
    private var outQ = [Float](repeating: 0, count: size)
    private var power = [Float](repeating: 0, count: size)
    private var sum = [Float](repeating: 0, count: size)
    private var blocks = 0
    private var samplesInFrame = 0

    init(rate: Int) {
        self.rate = rate
        let gain = vDSP.sum(window)
        reference = gain * gain
    }

    func reset() {
        pendingI.removeAll()
        pendingQ.removeAll()
        sum = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        blocks = 0
        samplesInFrame = 0
    }

    /// Adds IQ samples; returns a frame of levels when one is complete.
    func process(_ i: [Float], _ q: [Float]) -> [Float]? {
        let n = SpectrumAnalyzer.size
        pendingI.append(contentsOf: i)
        pendingQ.append(contentsOf: q)

        var frame: [Float]?
        var offset = 0
        while pendingI.count - offset >= n {
            vDSP.multiply(pendingI[offset..<offset + n], window, result: &windowedI)
            vDSP.multiply(pendingQ[offset..<offset + n], window, result: &windowedQ)
            dft.transform(inputReal: windowedI, inputImaginary: windowedQ,
                          outputReal: &outI, outputImaginary: &outQ)
            vDSP_vmma(outI, 1, outI, 1, outQ, 1, outQ, 1, &power, 1, vDSP_Length(n))
            vDSP.add(sum, power, result: &sum)
            blocks += 1
            offset += n

            samplesInFrame += n
            if samplesInFrame >= rate / SpectrumAnalyzer.framesPerSecond {
                frame = finishFrame()
            }
        }
        pendingI.removeFirst(offset)
        pendingQ.removeFirst(offset)
        return frame
    }

    private func finishFrame() -> [Float] {
        let n = SpectrumAnalyzer.size
        vDSP.multiply(1 / Float(blocks), sum, result: &power)
        vDSP.add(1e-20, power, result: &power)          // no log of zero
        var levels = [Float](repeating: 0, count: n)
        vDSP.convert(power: power, toDecibels: &levels, zeroReference: reference)
        sum = [Float](repeating: 0, count: n)
        blocks = 0
        samplesInFrame = 0
        // The FFT puts 0 Hz first; the display wants it in the middle.
        return Array(levels[n / 2..<n] + levels[0..<n / 2])
    }
}
