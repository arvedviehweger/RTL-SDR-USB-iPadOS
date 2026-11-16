//
//  SuperframeDecoder.swift
//  RTL-SDR Host
//
//  DAB+ audio superframes (TS 102 563): 5 consecutive CIFs of a subchannel
//  form one superframe of 120 ms. It is protected by RS(120, 110),
//  interleaved so that codeword j holds bytes j, j + s, j + 2s, … (s =
//  bitrate / 8). The first 110 × s bytes carry:
//
//    header firecode (16), rfa, dac_rate, sbr_flag, aac_channel_mode,
//    ps_flag, mpeg_surround_config (3), au_start[1 …] (12 bits each)
//    → 2, 3, 4 or 6 AUs, each followed by its CRC-16
//
//  The superframe start is found by trying each CIF as the first one until
//  the firecode checks out.
//

import Foundation

nonisolated final class SuperframeDecoder {

    struct AudioFormat: Equatable, Sendable {
        var sampleRate: Int             // output: 32 or 48 kHz
        var sbr: Bool
        var stereo: Bool                // aac_channel_mode
        var ps: Bool
        var description: String {
            "\(ps ? "HE-AAC v2" : sbr ? "HE-AAC" : "AAC-LC") \(sampleRate / 1000) kHz \(stereo ? "stereo" : ps ? "PS" : "mono")"
        }
        /// Samples per AU at the output rate, as broadcast.
        var samplesPerAU: Int { sbr ? 1920 : 960 }
    }

    struct Statistics: Sendable {
        var superframes = 0
        var rsCorrected = 0             // bytes
        var rsFailed = 0                // codewords
        var ausGood = 0
        var ausBad = 0
    }

    private(set) var format: AudioFormat?
    private(set) var stats = Statistics()
    private(set) var isSynced = false

    private let s: Int
    private let cifBytes: Int
    private var cifs: [[UInt8]] = []
    private var misses = 0

    init(bitrate: Int) {
        s = bitrate / 8
        cifBytes = bitrate * 3
    }

    /// One CIF of subchannel bytes; returns the good AUs of a completed
    /// superframe (and nil for each lost one, so the audio keeps its pace).
    func process(_ cif: [UInt8]) -> [[UInt8]?] {
        guard cif.count == cifBytes else { return [] }
        cifs.append(cif)
        guard cifs.count == 5 else { return [] }

        var frame = Array(cifs.joined())
        let corrected = correct(&frame)
        if firecodeOK(frame) {
            cifs.removeAll(keepingCapacity: true)
            isSynced = true
            misses = 0
            stats.superframes += 1
            stats.rsCorrected += corrected.bytes
            stats.rsFailed += corrected.failed
            return accessUnits(frame)
        }
        // Not a superframe start: shift by one CIF.
        cifs.removeFirst()
        if isSynced {
            misses += 1
            if misses >= 5 {
                isSynced = false
            }
            // Keep the pace while synced; a broken superframe is 120 ms of
            // silence.
            if misses % 5 == 0, let format { return Array(repeating: nil, count: format.sbr ? (format.sampleRate == 48000 ? 3 : 2) : (format.sampleRate == 48000 ? 6 : 4)) }
        }
        return []
    }

    func reset() {
        cifs.removeAll()
        isSynced = false
        misses = 0
        format = nil
        stats = Statistics()
    }

    private func correct(_ frame: inout [UInt8]) -> (bytes: Int, failed: Int) {
        var bytes = 0, failed = 0
        var codeword = [UInt8](repeating: 0, count: 120)
        for j in 0..<s {
            for k in 0..<120 { codeword[k] = frame[j + s * k] }
            let n = codeword.withUnsafeMutableBufferPointer { dab_rs_decode($0.baseAddress!) }
            if n < 0 {
                failed += 1
                continue
            }
            if n > 0 {
                bytes += Int(n)
                for k in 0..<110 { frame[j + s * k] = codeword[k] }
            }
        }
        return (bytes, failed)
    }

    /// CRC over header bytes 2 … 10 with g(x) = (x^11 + 1)(x^5 + x^3 + x^2 + x + 1).
    private func firecodeOK(_ f: [UInt8]) -> Bool {
        guard f[0...10].contains(where: { $0 != 0 }) else { return false }
        var crc: UInt16 = 0
        for byte in f[2...10] {
            for bit in stride(from: 7, through: 0, by: -1) {
                let top = (crc >> 15) & 1
                crc <<= 1
                if top ^ UInt16((byte >> UInt8(bit)) & 1) == 1 { crc ^= 0x782F }
            }
        }
        return crc == UInt16(f[0]) << 8 | UInt16(f[1])
    }

    private func accessUnits(_ f: [UInt8]) -> [[UInt8]?] {
        let flags = f[2]
        let format = AudioFormat(sampleRate: flags & 0x40 != 0 ? 48000 : 32000, sbr: flags & 0x20 != 0,
                                 stereo: flags & 0x10 != 0, ps: flags & 0x08 != 0)
        self.format = format
        let count = format.sampleRate == 48000 ? (format.sbr ? 3 : 6) : (format.sbr ? 2 : 4)
        var starts = [[2: 5, 3: 6, 4: 8, 6: 11][count]!]
        for i in 1..<count {
            let bit = 24 + 12 * (i - 1)
            let v = (Int(f[bit / 8]) << 8 | Int(f[bit / 8 + 1])) >> (4 - bit % 8) & 0xFFF
            starts.append(v)
        }
        starts.append(110 * s)

        var result: [[UInt8]?] = []
        for i in 0..<count {
            let a = starts[i], b = starts[i + 1]
            guard a + 2 < b, b <= 110 * s else {
                stats.ausBad += 1
                result.append(nil)
                continue
            }
            let au = f[a..<b]
            if CRC16.check(au) {
                stats.ausGood += 1
                result.append(Array(au.dropLast(2)))
            } else {
                stats.ausBad += 1
                result.append(nil)
            }
        }
        return result
    }
}
