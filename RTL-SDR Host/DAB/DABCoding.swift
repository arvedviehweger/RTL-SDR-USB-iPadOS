//
//  DABCoding.swift
//  RTL-SDR Host
//
//  The convolutional code around Viterbi: depuncturing a protection
//  profile back to the rate 1/4 mother code, decoding, and removing the
//  energy dispersal. Also the CRC-16 of FIBs, AUs and PAD (EN 300 401
//  annex E: CCITT polynomial, register preset to ones, result inverted).
//

import Foundation

nonisolated final class ConvolutionalDecoder {

    let protection: DAB.Protection
    /// Mother-code position of each received (punctured) bit.
    private let positions: [Int32]
    private let motherLength: Int
    private var mother: [Int8]
    private var work: [UInt8]
    private var bits: [UInt8]
    private let dispersal: [UInt8]

    init(protection: DAB.Protection) {
        self.protection = protection
        var positions: [Int32] = []
        var m = 0
        for (blocks, index) in zip(protection.runs, protection.vectors) {
            let vector = DAB.puncturing[index - 1]
            for _ in 0..<(blocks * 4) {
                for keep in vector {
                    if keep { positions.append(Int32(m)) }
                    m += 1
                }
            }
        }
        for keep in DAB.tailPuncturing {
            if keep { positions.append(Int32(m)) }
            m += 1
        }
        self.positions = positions
        motherLength = m
        let info = protection.informationBits
        mother = [Int8](repeating: 0, count: m)
        work = [UInt8](repeating: 0, count: dab_viterbi_work_size(info))
        bits = [UInt8](repeating: 0, count: info)
        dispersal = DAB.energyDispersal(info)
    }

    /// Punctured soft bits in (at least `protection.codedBits` of them,
    /// padding after that is ignored), information bytes out.
    func decode(_ soft: UnsafeBufferPointer<Int8>) -> [UInt8] {
        precondition(soft.count >= positions.count)
        mother.withUnsafeMutableBufferPointer { m in
            m.update(repeating: 0)
            for (i, p) in positions.enumerated() { m[Int(p)] = soft[i] }
        }
        let info = protection.informationBits
        mother.withUnsafeBufferPointer { m in
            work.withUnsafeMutableBytes { w in
                bits.withUnsafeMutableBufferPointer { b in
                    dab_viterbi(m.baseAddress!, info, b.baseAddress!, w.baseAddress!)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: info / 8)
        for i in 0..<info {
            bytes[i >> 3] |= (bits[i] ^ dispersal[i]) << (7 - UInt8(i & 7))
        }
        return bytes
    }
}

nonisolated enum CRC16 {

    private static let table: [UInt16] = (0..<256).map { byte in
        var crc = UInt16(byte) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return crc
    }

    static func compute<C: Collection>(_ data: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for b in data { crc = (crc << 8) ^ table[Int((crc >> 8) ^ UInt16(b))] }
        return ~crc
    }

    /// The last two bytes hold the CRC of the bytes before them.
    static func check<C: BidirectionalCollection>(_ data: C) -> Bool where C.Element == UInt8 {
        guard data.count > 2 else { return false }
        let body = data.dropLast(2)
        let hi = data[data.index(data.endIndex, offsetBy: -2)], lo = data[data.index(before: data.endIndex)]
        return compute(body) == UInt16(hi) << 8 | UInt16(lo)
    }
}
