//
//  MSCDecoder.swift
//  RTL-SDR Host
//
//  One subchannel of the Main Service Channel (EN 300 401 clauses 11 and
//  12): per frame 72 OFDM symbols hold 4 CIFs of 864 CUs; the subchannel
//  is a run of CUs in each CIF.
//
//    CU slice → time deinterleaving (bit i was sent d(i mod 16) CIFs late,
//    d the 4-bit reversal of 0 … 15, so the output is 15 CIFs = 360 ms
//    behind) → depuncturing → Viterbi → energy dispersal → bytes, 24 ms
//    worth (bitrate × 3) per CIF.
//

import Foundation

nonisolated final class MSCDecoder {

    let subchannel: DABEnsemble.Subchannel

    private let decoder: ConvolutionalDecoder
    private let bits: Int                       // soft bits per CIF
    private var history: [[Int8]]               // the last 16 CIFs
    private var newest = -1
    private var filled = 0
    private var output: [Int8]

    private static let delay: [Int] = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]

    init(subchannel: DABEnsemble.Subchannel) {
        self.subchannel = subchannel
        decoder = ConvolutionalDecoder(protection: subchannel.protection)
        bits = subchannel.size * DAB.cuBits
        history = Array(repeating: [Int8](repeating: 0, count: subchannel.size * DAB.cuBits), count: 16)
        output = [Int8](repeating: 0, count: subchannel.size * DAB.cuBits)
    }

    /// One frame's 72 MSC symbols of soft bits; returns up to 4 blocks of
    /// bitrate × 3 bytes, none while the deinterleaver fills.
    func process(_ msc: [Int8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        for cif in 0..<DAB.cifsPerFrame {
            newest = (newest + 1) & 15
            let from = cif * DAB.cifBits + subchannel.start * DAB.cuBits
            history[newest].withUnsafeMutableBufferPointer { h in
                msc.withUnsafeBufferPointer { m in
                    h.baseAddress!.update(from: m.baseAddress! + from, count: bits)
                }
            }
            filled = min(filled + 1, 16)
            guard filled == 16 else { continue }

            for i in 0..<bits {
                let source = (newest - 15 + MSCDecoder.delay[i & 15]) & 15
                output[i] = history[source][i]
            }
            result.append(output.withUnsafeBufferPointer { decoder.decode($0) })
        }
        return result
    }
}
