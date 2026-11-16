//
//  DABTables.swift
//  RTL-SDR Host
//
//  Constants and tables of the DAB transmission system, EN 300 401
//  (transmission mode I only, the one used in Band III):
//
//    - frame timing at 2.048 MS/s
//    - the phase reference symbol (clause 14.3.2, tables 43/44)
//    - frequency interleaving (clause 14.6)
//    - puncturing vectors PI 1 … 24 and the tail vector (clause 11.1.2)
//    - EEP and UEP protection profiles (clause 11.3, table 8)
//    - the energy dispersal sequence (clause 10)
//    - the Band III channel raster
//

import Foundation

nonisolated enum DAB {

    static let sampleRate = 2_048_000

    // Mode I, in samples at 2.048 MS/s.
    static let fftSize = 2048
    static let guardLength = 504
    static let symbolLength = 2552
    static let nullLength = 2656
    static let symbolsPerFrame = 76                 // PRS + 3 FIC + 72 MSC
    static let frameLength = nullLength + symbolsPerFrame * symbolLength   // 196 608, 96 ms
    static let carriers = 1536
    static let bitsPerSymbol = 2 * carriers         // 3072

    static let ficSymbols = 3
    static let cifsPerFrame = 4
    static let cuBits = 64
    static let cusPerCIF = 864
    static let cifBits = cusPerCIF * cuBits         // 55 296
    /// Punctured FIC bits per CIF: 3 FIBs, 768 bits before coding.
    static let ficBlockBits = 2304

    // MARK: - Phase reference symbol

    private static let h: [[UInt8]] = [
        [0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1, 0, 2, 0, 0, 0, 0, 1, 1, 2, 0, 0, 0, 2, 2, 1, 1],
        [0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0, 0, 3, 2, 3, 0, 1, 3, 0, 2, 1, 2, 3, 2, 3, 3, 0],
        [0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3, 0, 0, 0, 2, 0, 2, 1, 3, 2, 2, 0, 2, 2, 0, 1, 3],
        [0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2, 0, 1, 2, 1, 0, 3, 3, 2, 2, 3, 2, 1, 2, 1, 3, 2],
    ]

    /// (i, n) for each block of 32 carriers, from k = -768 upwards; k' is
    /// the first carrier of the block.
    private static let prsBlocks: [(i: Int, n: Int)] = [
        (0, 1), (1, 2), (2, 0), (3, 1), (0, 3), (1, 2), (2, 2), (3, 3),
        (0, 2), (1, 1), (2, 2), (3, 3), (0, 1), (1, 2), (2, 3), (3, 3),
        (0, 2), (1, 2), (2, 2), (3, 1), (0, 1), (1, 3), (2, 1), (3, 2),
        (0, 3), (3, 1), (2, 1), (1, 1), (0, 2), (3, 2), (2, 1), (1, 0),
        (0, 2), (3, 2), (2, 3), (1, 3), (0, 0), (3, 2), (2, 1), (1, 3),
        (0, 3), (3, 3), (2, 3), (1, 0), (0, 3), (3, 0), (2, 1), (1, 1),
    ]

    /// Phase of carrier k in units of π/2, for k = -768 … 768 (k = 0 unused).
    static func prsPhase(_ k: Int) -> Int {
        precondition(k != 0 && abs(k) <= 768)
        let block = k < 0 ? (k + 768) / 32 : 24 + (k - 1) / 32
        let first = k < 0 ? -768 + 32 * block : 1 + 32 * (block - 24)
        let (i, n) = prsBlocks[block]
        return (Int(h[i][k - first]) + n) & 3
    }

    // MARK: - Frequency interleaving

    /// carrier[n] is the carrier k (−768 … 768) that carries QPSK symbol n.
    static let interleavedCarrier: [Int] = {
        var result: [Int] = []
        result.reserveCapacity(carriers)
        var pi = 0
        for _ in 0..<fftSize {
            if pi >= 256 && pi <= 1792 && pi != 1024 { result.append(pi - 1024) }
            pi = (13 * pi + 511) % fftSize
        }
        return result
    }()

    // MARK: - Puncturing

    /// PI_n keeps 8 + n of every 32 mother-code bits.
    static let puncturing: [[Bool]] = {
        // Each vector as 8 groups of 4 bits.
        let groups: [[UInt8]] = [
            [0xC, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8],
            [0xC, 0x8, 0x8, 0x8, 0xC, 0x8, 0x8, 0x8],
            [0xC, 0x8, 0xC, 0x8, 0xC, 0x8, 0x8, 0x8],
            [0xC, 0x8, 0xC, 0x8, 0xC, 0x8, 0xC, 0x8],
            [0xC, 0xC, 0xC, 0x8, 0xC, 0x8, 0xC, 0x8],
            [0xC, 0xC, 0xC, 0x8, 0xC, 0xC, 0xC, 0x8],
            [0xC, 0xC, 0xC, 0xC, 0xC, 0xC, 0xC, 0x8],
            [0xC, 0xC, 0xC, 0xC, 0xC, 0xC, 0xC, 0xC],
            [0xE, 0xC, 0xC, 0xC, 0xC, 0xC, 0xC, 0xC],
            [0xE, 0xC, 0xC, 0xC, 0xE, 0xC, 0xC, 0xC],
            [0xE, 0xC, 0xE, 0xC, 0xE, 0xC, 0xC, 0xC],
            [0xE, 0xC, 0xE, 0xC, 0xE, 0xC, 0xE, 0xC],
            [0xE, 0xE, 0xE, 0xC, 0xE, 0xC, 0xE, 0xC],
            [0xE, 0xE, 0xE, 0xC, 0xE, 0xE, 0xE, 0xC],
            [0xE, 0xE, 0xE, 0xE, 0xE, 0xE, 0xE, 0xC],
            [0xE, 0xE, 0xE, 0xE, 0xE, 0xE, 0xE, 0xE],
            [0xF, 0xE, 0xE, 0xE, 0xE, 0xE, 0xE, 0xE],
            [0xF, 0xE, 0xE, 0xE, 0xF, 0xE, 0xE, 0xE],
            [0xF, 0xE, 0xF, 0xE, 0xF, 0xE, 0xE, 0xE],
            [0xF, 0xE, 0xF, 0xE, 0xF, 0xE, 0xF, 0xE],
            [0xF, 0xF, 0xF, 0xE, 0xF, 0xE, 0xF, 0xE],
            [0xF, 0xF, 0xF, 0xE, 0xF, 0xF, 0xF, 0xE],
            [0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xE],
            [0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF, 0xF],
        ]
        return groups.map { vector in vector.flatMap { g in (0..<4).map { g & (8 >> $0) != 0 } } }
    }()

    /// Applied to the 24 code bits of the 6 tail bits.
    static let tailPuncturing: [Bool] = (0..<24).map { $0 % 4 < 2 }

    /// A run of `blocks` × 128 mother-code bits punctured with PI_`index`.
    struct PunctureRun {
        let blocks: Int
        let index: Int
    }

    /// A subchannel's code: the punctured runs, then the tail; 4 × 32 bits of
    /// mother code per 32 information bits.
    struct Protection: Equatable, Sendable {
        let runs: [Int]          // blocks per run (one block = 32 information bits)
        let vectors: [Int]       // PI index per run
        let size: Int            // CUs
        var informationBits: Int { runs.reduce(0, +) * 32 }
        /// Punctured bits of the runs and the tail; at most size × 64.
        var codedBits: Int {
            zip(runs, vectors).reduce(12) { $0 + $1.0 * 4 * (8 + $1.1) }
        }
    }

    /// FIC: 3 FIBs (768 bits) per CIF, 21 blocks with PI16, 3 with PI15.
    static let ficProtection = Protection(runs: [21, 3], vectors: [16, 15], size: 36)

    /// EEP, option A (`b == false`) or B, protection level 1 … 4.
    static func eep(bitrate: Int, level: Int, b: Bool) -> Protection? {
        guard (1...4).contains(level) else { return nil }
        if !b {
            guard bitrate % 8 == 0, bitrate >= 8 else { return nil }
            let n = bitrate / 8
            switch level {
            case 1 where n == 1: return Protection(runs: [3, 3], vectors: [24, 23], size: 12)
            case 1: return Protection(runs: [6 * n - 3, 3], vectors: [24, 23], size: 12 * n)
            case 2 where n == 1: return Protection(runs: [5, 1], vectors: [13, 12], size: 8)
            case 2: return Protection(runs: [2 * n - 3, 4 * n + 3], vectors: [14, 13], size: 8 * n)
            case 3: return Protection(runs: [6 * n - 3, 3], vectors: [8, 7], size: 6 * n)
            default: return Protection(runs: [4 * n - 3, 2 * n + 3], vectors: [3, 2], size: 4 * n)
            }
        }
        guard bitrate % 32 == 0, bitrate >= 32 else { return nil }
        let n = bitrate / 32
        let (vectors, size): ([Int], Int) = switch level {
        case 1: ([10, 9], 27 * n)
        case 2: ([6, 5], 21 * n)
        case 3: ([4, 3], 18 * n)
        default: ([2, 1], 15 * n)
        }
        return Protection(runs: [24 * n - 3, 3], vectors: vectors, size: size)
    }

    /// UEP for MPEG audio (classic DAB), by table index 0 … 63: bitrate,
    /// protection level, size, L1 … L4, PI1 … PI4.
    static let uep: [(bitrate: Int, level: Int, protection: Protection)] = {
        let rows: [(Int, Int, Int, [Int], [Int])] = [
            (32, 5, 16, [3, 4, 17, 0], [5, 3, 2, 0]),
            (32, 4, 21, [3, 3, 18, 0], [11, 6, 5, 0]),
            (32, 3, 24, [3, 4, 14, 3], [15, 9, 6, 8]),
            (32, 2, 29, [3, 4, 14, 3], [22, 13, 8, 13]),
            (32, 1, 35, [3, 5, 13, 3], [24, 17, 12, 17]),
            (48, 5, 24, [4, 3, 26, 3], [5, 4, 2, 3]),
            (48, 4, 29, [3, 4, 26, 3], [9, 6, 4, 6]),
            (48, 3, 35, [3, 4, 26, 3], [15, 10, 6, 9]),
            (48, 2, 42, [3, 4, 26, 3], [24, 14, 8, 15]),
            (48, 1, 52, [3, 5, 25, 3], [24, 18, 13, 18]),
            (56, 5, 29, [6, 10, 23, 3], [5, 4, 2, 3]),
            (56, 4, 35, [6, 10, 23, 3], [9, 6, 4, 5]),
            (56, 3, 42, [6, 12, 21, 3], [16, 7, 6, 9]),
            (56, 2, 52, [6, 10, 23, 3], [23, 13, 8, 13]),
            (64, 5, 32, [6, 9, 31, 2], [5, 3, 2, 3]),
            (64, 4, 42, [6, 9, 33, 0], [11, 6, 5, 0]),
            (64, 3, 48, [6, 12, 27, 3], [16, 8, 6, 9]),
            (64, 2, 58, [6, 10, 29, 3], [23, 13, 8, 13]),
            (64, 1, 70, [6, 11, 28, 3], [24, 18, 12, 18]),
            (80, 5, 40, [6, 10, 41, 3], [6, 3, 2, 3]),
            (80, 4, 52, [6, 10, 41, 3], [11, 6, 5, 6]),
            (80, 3, 58, [6, 11, 40, 3], [16, 8, 6, 7]),
            (80, 2, 70, [6, 10, 41, 3], [23, 13, 8, 13]),
            (80, 1, 84, [6, 10, 41, 3], [24, 17, 12, 18]),
            (96, 5, 48, [7, 9, 53, 3], [5, 4, 2, 4]),
            (96, 4, 58, [7, 10, 52, 3], [9, 6, 4, 6]),
            (96, 3, 70, [6, 12, 51, 3], [16, 9, 6, 10]),
            (96, 2, 84, [6, 10, 53, 3], [22, 12, 9, 12]),
            (96, 1, 104, [6, 13, 50, 3], [24, 18, 13, 19]),
            (112, 5, 58, [14, 17, 50, 3], [5, 4, 2, 5]),
            (112, 4, 70, [11, 21, 49, 3], [9, 6, 4, 8]),
            (112, 3, 84, [11, 23, 47, 3], [16, 8, 6, 9]),
            (112, 2, 104, [11, 21, 49, 3], [23, 12, 9, 14]),
            (128, 5, 64, [12, 19, 62, 3], [5, 3, 2, 4]),
            (128, 4, 84, [11, 21, 61, 3], [11, 6, 5, 7]),
            (128, 3, 96, [11, 22, 60, 3], [16, 9, 6, 10]),
            (128, 2, 116, [11, 21, 61, 3], [22, 12, 9, 14]),
            (128, 1, 140, [11, 20, 62, 3], [24, 17, 13, 19]),
            (160, 5, 80, [11, 19, 87, 3], [5, 4, 2, 4]),
            (160, 4, 104, [11, 23, 83, 3], [11, 6, 5, 9]),
            (160, 3, 116, [11, 24, 82, 3], [16, 8, 6, 11]),
            (160, 2, 140, [11, 21, 85, 3], [22, 11, 9, 13]),
            (160, 1, 168, [11, 22, 84, 3], [24, 18, 12, 19]),
            (192, 5, 96, [11, 20, 110, 3], [6, 4, 2, 5]),
            (192, 4, 116, [11, 22, 108, 3], [10, 6, 4, 9]),
            (192, 3, 140, [11, 24, 106, 3], [16, 10, 6, 11]),
            (192, 2, 168, [11, 20, 110, 3], [22, 13, 9, 13]),
            (192, 1, 208, [11, 21, 109, 3], [24, 20, 13, 24]),
            (224, 5, 116, [12, 22, 131, 3], [8, 6, 2, 6]),
            (224, 4, 140, [12, 26, 127, 3], [12, 8, 4, 11]),
            (224, 3, 168, [11, 20, 134, 3], [16, 10, 7, 9]),
            (224, 2, 208, [11, 22, 132, 3], [24, 16, 10, 15]),
            (224, 1, 232, [11, 24, 130, 3], [24, 20, 12, 20]),
            (256, 5, 128, [11, 24, 154, 3], [6, 5, 2, 5]),
            (256, 4, 168, [11, 24, 154, 3], [12, 9, 5, 10]),
            (256, 3, 192, [11, 27, 151, 3], [16, 10, 7, 10]),
            (256, 2, 232, [11, 22, 156, 3], [24, 14, 10, 13]),
            (256, 1, 280, [11, 26, 152, 3], [24, 19, 14, 18]),
            (320, 5, 160, [11, 26, 200, 3], [8, 5, 2, 6]),
            (320, 4, 208, [11, 25, 201, 3], [13, 9, 5, 10]),
            (320, 2, 280, [11, 26, 200, 3], [24, 17, 9, 17]),
            (384, 5, 192, [11, 27, 247, 3], [8, 6, 2, 7]),
            (384, 3, 280, [11, 24, 250, 3], [16, 9, 7, 10]),
            (384, 1, 416, [12, 28, 245, 3], [24, 20, 14, 23]),
        ]
        return rows.map { bitrate, level, size, l, pi in
            let used = zip(l, pi).filter { $0.0 > 0 }
            return (bitrate, level, Protection(runs: used.map(\.0), vectors: used.map(\.1), size: size))
        }
    }()

    // MARK: - Energy dispersal

    /// The PRBS x^9 + x^5 + 1, all ones at the start, one bit per element.
    static func energyDispersal(_ count: Int) -> [UInt8] {
        var register: UInt16 = 0x1FF
        return (0..<count).map { _ in
            let bit = UInt8(((register >> 8) ^ (register >> 4)) & 1)
            register = ((register << 1) | UInt16(bit)) & 0x1FF
            return bit
        }
    }

    // MARK: - Band III

    /// Channel 5A … 13F with its center frequency in Hz.
    static let channels: [(name: String, frequency: UInt32)] = [
        ("5A", 174_928_000), ("5B", 176_640_000), ("5C", 178_352_000), ("5D", 180_064_000),
        ("6A", 181_936_000), ("6B", 183_648_000), ("6C", 185_360_000), ("6D", 187_072_000),
        ("7A", 188_928_000), ("7B", 190_640_000), ("7C", 192_352_000), ("7D", 194_064_000),
        ("8A", 195_936_000), ("8B", 197_648_000), ("8C", 199_360_000), ("8D", 201_072_000),
        ("9A", 202_928_000), ("9B", 204_640_000), ("9C", 206_352_000), ("9D", 208_064_000),
        ("10A", 209_936_000), ("10N", 210_096_000), ("10B", 211_648_000), ("10C", 213_360_000), ("10D", 215_072_000),
        ("11A", 216_928_000), ("11N", 217_088_000), ("11B", 218_640_000), ("11C", 220_352_000), ("11D", 222_064_000),
        ("12A", 223_936_000), ("12N", 224_096_000), ("12B", 225_648_000), ("12C", 227_360_000), ("12D", 229_072_000),
        ("13A", 230_784_000), ("13B", 232_496_000), ("13C", 234_208_000), ("13D", 235_776_000),
        ("13E", 237_488_000), ("13F", 239_200_000),
    ]
}
