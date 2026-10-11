//
//  RDSDecoder.swift
//  RTL-SDR Host
//
//  Decodes RDS (IEC 62106) from the FM multiplex signal: the station name
//  (PS) and the radio text (RT).
//
//  RDS is a 1187.5 bit/s stream on a 57 kHz subcarrier, biphase coded and
//  differentially encoded. The decoder
//    • mixes the 240 kS/s multiplex down from 57 kHz (the carrier repeats
//      every 80 samples, so a table does it) and filters it to ±3 kHz at
//      12 kS/s,
//    • tracks the carrier phase with a Costas loop, which does not need the
//      stereo pilot, so mono stations work too,
//    • correlates with the biphase symbol, finds the bit clock with an
//      early-late gate and decodes the bit from the change of polarity,
//    • synchronises on the 26-bit blocks with their checkwords and offset
//      words, and assembles groups 0A/0B (PS) and 2A/2B (RT).
//
//  Runs on the demodulator's queue; not thread-safe.
//

import Accelerate
import Foundation

nonisolated final class RDSDecoder {

    private static let inputRate = 240_000.0
    private static let decimation = 20
    private static let rate = inputRate / Double(decimation)     // 12 kS/s
    private static let samplesPerBit = rate / 1187.5               // ≈ 10.1

    // 57 kHz at 240 kS/s: 19 cycles in 80 samples. Tiled so that one chunk
    // of up to `chunk` samples can start at any phase.
    private static let period = 80
    private static let chunk = 8_000
    private static let carrier: (cos: [Float], minusSin: [Float]) = {
        let n = chunk + period
        let w = 2 * Double.pi * 19 / Double(period)
        return ((0..<n).map { Float(cos(w * Double($0 % period))) },
                (0..<n).map { Float(-sin(w * Double($0 % period))) })
    }()

    private let filterI = FIRDecimator(taps: FilterDesign.lowpass(cutoff: 3_000, rate: inputRate, count: 481),
                                       factor: decimation)
    private let filterQ = FIRDecimator(taps: FilterDesign.lowpass(cutoff: 3_000, rate: inputRate, count: 481),
                                       factor: decimation)
    private var carrierIndex = 0
    private var mixI: [Float] = []
    private var mixQ: [Float] = []
    private var baseI: [Float] = []
    private var baseQ: [Float] = []

    // Costas loop (12 kS/s; ωn ≈ 2π · 15 Hz, ζ = 0.7)
    private static let costasP = 0.011
    private static let costasI = 6.2e-5
    private static let maxOffset = 2 * Double.pi * 20 / rate
    private var theta = 0.0
    private var omega = 0.0
    private var power: Float = 0

    // Biphase matched filter: +1 over the first half bit, −1 over the second.
    private var window = [Float](repeating: 0, count: 10)
    private var windowIndex = 0
    private var matched = [Float](repeating: 0, count: 16)     // recent outputs
    private var matchedIndex = 0

    // Bit clock
    private var clock = 0.0                 // samples since the last bit
    private var lastSymbol = false
    private var onTimeLevel: Float = 0      // |matched| at the bit instants …
    private var midLevel: Float = 0         // … and half a bit away
    private var decisions = 0

    let parser = RDSParser()

    func reset() {
        filterI.reset()
        filterQ.reset()
        carrierIndex = 0
        theta = 0
        omega = 0
        power = 0
        window = [Float](repeating: 0, count: window.count)
        matched = [Float](repeating: 0, count: matched.count)
        clock = 0
        onTimeLevel = 0
        midLevel = 0
        decisions = 0
        parser.reset()
    }

    func process(_ mpx: UnsafeBufferPointer<Float>) {
        guard let base = mpx.baseAddress, !mpx.isEmpty else { return }
        baseI.removeAll(keepingCapacity: true)
        baseQ.removeAll(keepingCapacity: true)

        var offset = 0
        while offset < mpx.count {
            let n = min(RDSDecoder.chunk, mpx.count - offset)
            mixI.removeAll(keepingCapacity: true)
            mixQ.removeAll(keepingCapacity: true)
            mixI.appendZeros(n)
            mixQ.appendZeros(n)
            RDSDecoder.carrier.cos.withUnsafeBufferPointer { c in
                vDSP_vmul(base + offset, 1, c.baseAddress! + carrierIndex, 1, &mixI, 1, vDSP_Length(n))
            }
            RDSDecoder.carrier.minusSin.withUnsafeBufferPointer { s in
                vDSP_vmul(base + offset, 1, s.baseAddress! + carrierIndex, 1, &mixQ, 1, vDSP_Length(n))
            }
            carrierIndex = (carrierIndex + n) % RDSDecoder.period
            mixI.withUnsafeBufferPointer { filterI.process($0, into: &baseI) }
            mixQ.withUnsafeBufferPointer { filterQ.process($0, into: &baseQ) }
            offset += n
        }

        for k in 0..<baseI.count {
            symbolSample(costas(baseI[k], baseQ[k]))
        }
    }

    /// Rotates the sample onto the real axis and returns the real part.
    private func costas(_ zi: Float, _ zq: Float) -> Float {
        let c = Float(cos(theta)), s = Float(sin(theta))
        let re = zi * c + zq * s
        let im = zq * c - zi * s
        power += 0.002 * (re * re + im * im - power)
        // BPSK: re · im ≈ sin(2·error) / 2, normalised by the power.
        let error = Double(re * im / max(power, 1e-12))
        omega = min(max(omega + RDSDecoder.costasI * error, -RDSDecoder.maxOffset), RDSDecoder.maxOffset)
        theta += omega + RDSDecoder.costasP * error
        if theta > .pi { theta -= 2 * .pi } else if theta < -.pi { theta += 2 * .pi }
        return re
    }

    private func symbolSample(_ x: Float) {
        window[windowIndex] = x
        windowIndex = (windowIndex + 1) % window.count
        // windowIndex now points at the oldest sample.
        var sum: Float = 0
        for k in 0..<window.count {
            let v = window[(windowIndex + k) % window.count]
            sum += k < window.count / 2 ? v : -v
        }
        matched[matchedIndex] = sum
        matchedIndex = (matchedIndex + 1) % matched.count

        clock += 1
        guard clock >= RDSDecoder.samplesPerBit else { return }
        clock -= RDSDecoder.samplesPerBit

        let late = matched[(matchedIndex - 1 + matched.count) % matched.count]
        let onTime = matched[(matchedIndex - 2 + matched.count) % matched.count]
        let early = matched[(matchedIndex - 3 + matched.count) % matched.count]
        let mid = matched[(matchedIndex - 7 + matched.count) % matched.count]

        // Early-late gate: move towards the larger neighbour.
        let error = (abs(late) - abs(early)) / max(abs(onTime), 1e-9)
        clock -= 0.1 * Double(min(max(error, -1), 1))

        // The gate can also settle half a bit off, where |matched| is large
        // only when two equal bits follow each other. The right instants
        // carry more energy than the points between them.
        onTimeLevel += 0.02 * (abs(onTime) - onTimeLevel)
        midLevel += 0.02 * (abs(mid) - midLevel)
        decisions += 1
        if decisions >= 64 {
            decisions = 0
            if midLevel > 1.2 * onTimeLevel {
                clock += RDSDecoder.samplesPerBit / 2
                swap(&onTimeLevel, &midLevel)
            }
        }

        let symbol = onTime > 0
        parser.feed(symbol != lastSymbol)
        lastSymbol = symbol
    }
}

/// Block synchronisation and the groups this app shows: 0A/0B and 2A/2B.
nonisolated final class RDSParser {

    private(set) var stationName: String?
    private(set) var radioText: String?
    private(set) var isSynced = false

    // Offset words for blocks A, B, C, C' and D.
    private static let offsets: [UInt32: Int] = [0x0FC: 0, 0x198: 1, 0x168: 2, 0x350: 2, 0x1B4: 3]
    private static let offsetCPrime: UInt32 = 0x350

    private var register: UInt32 = 0
    private var bitCount = 0
    private var lastFound: (bit: Int, slot: Int)?

    private var bitsInBlock = 0
    private var slot = 0                    // expected slot of the next block
    private var missed = 0
    private var group: [UInt16?] = [nil, nil, nil, nil]
    private var blockCIsPrime = false
    private var pi: UInt16?

    private var ps = [UInt8](repeating: 0x20, count: 8)
    private var psSegments: UInt8 = 0
    private var rt = [UInt8](repeating: 0x20, count: 64)
    private var rtSegments: UInt16 = 0
    private var rtFlag: UInt16?

    func reset() {
        stationName = nil
        radioText = nil
        isSynced = false
        register = 0
        bitCount = 0
        lastFound = nil
        group = [nil, nil, nil, nil]
        pi = nil
        clearStation()
    }

    func feed(_ bit: Bool) {
        register = ((register << 1) | (bit ? 1 : 0)) & 0x3FF_FFFF
        bitCount += 1
        guard bitCount >= 26 else { return }
        isSynced ? nextBit() : acquire()
    }

    // MARK: - Blocks

    /// The checkword is the CRC of the 16 data bits (generator
    /// x¹⁰+x⁸+x⁷+x⁵+x⁴+x³+1) plus the block's offset word.
    private static func checkword(_ info: UInt16) -> UInt32 {
        var v = UInt32(info) << 10
        for b in stride(from: 25, through: 10, by: -1) where v & (1 << b) != 0 {
            v ^= 0x5B9 << (b - 10)
        }
        return v & 0x3FF
    }

    /// Slot (0 = A … 3 = D) and offset word of a valid block, or nil.
    private static func identify(_ block: UInt32) -> (slot: Int, offset: UInt32)? {
        let offset = checkword(UInt16(block >> 10)) ^ (block & 0x3FF)
        return offsets[offset].map { (slot: $0, offset: offset) }
    }

    /// Two valid blocks the right number of bits apart in the right order.
    private func acquire() {
        guard let found = RDSParser.identify(register) else { return }
        if let last = lastFound {
            let blocks = (found.slot - last.slot + 4) % 4
            if bitCount - last.bit == 26 * (blocks == 0 ? 4 : blocks) {
                isSynced = true
                bitsInBlock = 0
                missed = 0
                group = [nil, nil, nil, nil]
                store(found.slot, found.offset)
                slot = (found.slot + 1) % 4
                return
            }
        }
        lastFound = (bitCount, found.slot)
    }

    private func nextBit() {
        bitsInBlock += 1
        guard bitsInBlock == 26 else { return }
        bitsInBlock = 0

        if let found = RDSParser.identify(register), found.slot == slot {
            store(slot, found.offset)
            missed = 0
        } else {
            group[slot] = nil
            missed += 1
        }
        if slot == 3 {
            handleGroup()
            group = [nil, nil, nil, nil]
        }
        slot = (slot + 1) % 4

        if missed >= 10 {
            isSynced = false
            lastFound = nil
        }
    }

    private func store(_ slot: Int, _ offset: UInt32) {
        group[slot] = UInt16(register >> 10)
        if slot == 2 { blockCIsPrime = offset == RDSParser.offsetCPrime }
    }

    // MARK: - Groups

    private func handleGroup() {
        if let a = group[0] {
            if let pi, pi != a { clearStation() }       // another station
            pi = a
        }
        guard let b = group[1] else { return }
        let type = b >> 12
        let versionB = b & 0x0800 != 0

        switch type {
        case 0:
            guard let d = group[3] else { return }
            let address = Int(b & 0x3)
            ps[2 * address] = UInt8(d >> 8)
            ps[2 * address + 1] = UInt8(d & 0xFF)
            psSegments |= 1 << address
            if psSegments == 0xF {
                stationName = RDSParser.text(ps)
                psSegments = 0
            }
        case 2:
            let address = Int(b & 0xF)
            let flag = (b >> 4) & 1
            if flag != rtFlag {                         // new text
                rt = [UInt8](repeating: 0x20, count: 64)
                rtSegments = 0
                rtFlag = flag
            }
            if versionB {
                guard let d = group[3] else { return }
                setText([UInt8(d >> 8), UInt8(d & 0xFF)], segment: address, capacity: 32)
            } else {
                guard let c = group[2], !blockCIsPrime, let d = group[3] else { return }
                setText([UInt8(c >> 8), UInt8(c & 0xFF), UInt8(d >> 8), UInt8(d & 0xFF)],
                        segment: address, capacity: 64)
            }
        default:
            break
        }
    }

    /// Publishes the radio text once every segment up to its end (a
    /// carriage return, or the full length) has arrived.
    private func setText(_ chars: [UInt8], segment: Int, capacity: Int) {
        let width = chars.count
        for (k, c) in chars.enumerated() { rt[segment * width + k] = c }
        rtSegments |= 1 << segment
        let length = rt[0..<capacity].firstIndex(of: 0x0D) ?? capacity
        guard length > 0 else { return }
        let lastSegment = (length - 1) / width
        let needed: UInt16 = lastSegment >= 15 ? 0xFFFF : (1 << (lastSegment + 1)) - 1
        if rtSegments & needed == needed {
            radioText = RDSParser.text(rt[0..<length])
        }
    }

    private func clearStation() {
        stationName = nil
        radioText = nil
        ps = [UInt8](repeating: 0x20, count: 8)
        psSegments = 0
        rt = [UInt8](repeating: 0x20, count: 64)
        rtSegments = 0
        rtFlag = nil
    }

    // MARK: - Characters

    /// RDS's character table (IEC 62106 annex E): ASCII for the printable
    /// range, then the accented letters of Western European languages.
    private static let table: [UInt8: Character] = {
        var t: [UInt8: Character] = [:]
        for c in UInt8(0x20)...UInt8(0x7D) { t[c] = Character(UnicodeScalar(c)) }
        let rows: [(UInt8, String)] = [
            (0x80, "áàéèíìóòúùÑÇŞß¡Ĳ"),
            (0x90, "âäêëîïôöûüñçşğıĳ"),
            (0xC0, "ÁÀÉÈÍÌÓÒÚÙŘČŠŽĐĿ"),
            (0xD0, "ÂÄÊËÎÏÔÖÛÜřčšžđŀ"),
        ]
        for (start, chars) in rows {
            for (k, ch) in chars.enumerated() { t[start + UInt8(k)] = ch }
        }
        return t
    }()

    private static func text<C: Collection>(_ bytes: C) -> String? where C.Element == UInt8 {
        let s = String(bytes.map { table[$0] ?? " " })
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}
