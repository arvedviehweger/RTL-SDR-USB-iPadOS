//
//  FICDecoder.swift
//  RTL-SDR Host
//
//  The Fast Information Channel (EN 300 401 clauses 5.2, 6 and 8): per
//  frame 3 OFDM symbols → 4 blocks of 2304 punctured bits → Viterbi and
//  energy dispersal → 3 FIBs of 32 bytes each → CRC → FIGs. The FIGs that
//  matter for listening build up the ensemble:
//
//    0/0   ensemble id          1/0  ensemble label
//    0/1   subchannels          1/1  programme service labels
//    0/2   services → components (audio stream, subchannel)
//    0/13  user applications (MOT slideshow in X-PAD)
//

import Foundation

nonisolated struct DABEnsemble: Equatable, Sendable {

    struct Subchannel: Equatable, Sendable {
        var id: Int
        var start: Int                  // CU
        var size: Int                   // CUs
        var bitrate: Int                // kbit/s
        var protection: DAB.Protection
        var isUEP: Bool
        /// "EEP 3-A", "UEP 3"
        var protectionName: String
    }

    struct Component: Equatable, Sendable {
        var subchannel: Int
        var isDABPlus: Bool             // ASCTy 63, else MPEG audio layer II
        var isPrimary: Bool
    }

    struct Service: Equatable, Sendable, Identifiable {
        var id: UInt32
        var label: String?
        var shortLabel: String?
        var audio: Component?
        var hasSlideshow = false
    }

    var id: UInt16?
    var label: String?
    var shortLabel: String?
    var subchannels: [Int: Subchannel] = [:]
    var services: [UInt32: Service] = [:]

    /// Services with audio in a known subchannel, sorted by label.
    var audioServices: [Service] {
        services.values
            .filter { s in s.audio.map { subchannels[$0.subchannel] != nil } ?? false }
            .sorted { ($0.label ?? "") < ($1.label ?? "") }
    }

    /// Enough to list the ensemble: its label and every audio service named.
    var isComplete: Bool {
        label != nil && !audioServices.isEmpty && audioServices.allSatisfy { $0.label != nil }
    }
}

nonisolated final class FICDecoder {

    private(set) var ensemble = DABEnsemble()
    /// FIBs received and how many failed the CRC.
    private(set) var fibs = 0
    private(set) var fibErrors = 0

    private let decoder = ConvolutionalDecoder(protection: DAB.ficProtection)

    func reset() {
        ensemble = DABEnsemble()
        fibs = 0
        fibErrors = 0
    }

    /// One frame's 3 FIC symbols of soft bits.
    func process(_ soft: [Int8]) {
        soft.withUnsafeBufferPointer { s in
            for block in 0..<DAB.cifsPerFrame {
                let part = UnsafeBufferPointer(rebasing: s[(block * DAB.ficBlockBits)..<((block + 1) * DAB.ficBlockBits)])
                let bytes = decoder.decode(part)
                for f in 0..<3 {
                    let fib = bytes[(f * 32)..<(f * 32 + 32)]
                    fibs += 1
                    guard CRC16.check(fib) else {
                        fibErrors += 1
                        continue
                    }
                    parseFIB(Array(fib.prefix(30)))
                }
            }
        }
    }

    // MARK: - FIGs

    private func parseFIB(_ fib: [UInt8]) {
        var i = 0
        while i < fib.count {
            let header = fib[i]
            if header == 0xFF { return }
            let type = Int(header >> 5), length = Int(header & 0x1F)
            guard length > 0, i + 1 + length <= fib.count else { return }
            let body = Array(fib[(i + 1)...(i + length)])
            switch type {
            case 0: parseFIG0(body)
            case 1: parseFIG1(body)
            default: break
            }
            i += 1 + length
        }
    }

    private func parseFIG0(_ d: [UInt8]) {
        let pd = d[0] & 0x20 != 0
        let ext = Int(d[0] & 0x1F)
        let data = Array(d.dropFirst())
        switch ext {
        case 0 where data.count >= 2:
            ensemble.id = UInt16(data[0]) << 8 | UInt16(data[1])
        case 1:
            parseSubchannels(data)
        case 2:
            parseServices(data, pd: pd)
        case 13:
            parseUserApplications(data, pd: pd)
        default:
            break
        }
    }

    private func parseSubchannels(_ d: [UInt8]) {
        var i = 0
        while i + 3 <= d.count {
            let id = Int(d[i] >> 2)
            let start = Int(d[i] & 3) << 8 | Int(d[i + 1])
            if d[i + 2] & 0x80 == 0 {
                let index = Int(d[i + 2] & 0x3F)
                if index < DAB.uep.count {
                    let e = DAB.uep[index]
                    ensemble.subchannels[id] = .init(id: id, start: start, size: e.protection.size, bitrate: e.bitrate,
                                                     protection: e.protection, isUEP: true,
                                                     protectionName: "UEP \(e.level)")
                }
                i += 3
            } else {
                guard i + 4 <= d.count else { return }
                let option = Int(d[i + 2] >> 4) & 7
                let level = Int(d[i + 2] >> 2) & 3 + 1
                let size = Int(d[i + 2] & 3) << 8 | Int(d[i + 3])
                let b = option == 1
                let factor = b ? [27, 21, 18, 15][level - 1] : [12, 8, 6, 4][level - 1]
                if option <= 1, size % factor == 0, size > 0 {
                    let bitrate = size / factor * (b ? 32 : 8)
                    if let p = DAB.eep(bitrate: bitrate, level: level, b: b), p.size == size {
                        ensemble.subchannels[id] = .init(id: id, start: start, size: size, bitrate: bitrate,
                                                         protection: p, isUEP: false,
                                                         protectionName: "EEP \(level)-\(b ? "B" : "A")")
                    }
                }
                i += 4
            }
        }
    }

    private func parseServices(_ d: [UInt8], pd: Bool) {
        var i = 0
        let idLength = pd ? 4 : 2
        while i + idLength + 1 <= d.count {
            let sid = d[i..<(i + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            i += idLength
            let count = Int(d[i] & 0x0F)
            i += 1
            var service = ensemble.services[sid] ?? .init(id: sid)
            for _ in 0..<count {
                guard i + 2 <= d.count else { return }
                let tmid = d[i] >> 6
                let primary = d[i + 1] & 0x02 != 0
                if tmid == 0 {
                    let ascty = Int(d[i] & 0x3F)
                    let subch = Int(d[i + 1] >> 2)
                    if ascty == 63 || ascty == 0, primary || service.audio == nil {
                        service.audio = .init(subchannel: subch, isDABPlus: ascty == 63, isPrimary: primary)
                    }
                }
                i += 2
            }
            ensemble.services[sid] = service
        }
    }

    private func parseUserApplications(_ d: [UInt8], pd: Bool) {
        var i = 0
        let idLength = pd ? 4 : 2
        while i + idLength + 1 <= d.count {
            let sid = d[i..<(i + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            i += idLength
            let count = Int(d[i] & 0x0F)
            i += 1
            for _ in 0..<count {
                guard i + 2 <= d.count else { return }
                let type = Int(d[i]) << 3 | Int(d[i + 1] >> 5)
                let length = Int(d[i + 1] & 0x1F)
                if type == 0x002 {                       // MOT slideshow
                    var service = ensemble.services[sid] ?? .init(id: sid)
                    service.hasSlideshow = true
                    ensemble.services[sid] = service
                }
                i += 2 + length
            }
        }
    }

    private func parseFIG1(_ d: [UInt8]) {
        guard d.count >= 1 else { return }
        let charset = Int(d[0] >> 4)
        let ext = Int(d[0] & 7)
        let data = Array(d.dropFirst())
        let idLength: Int
        switch ext {
        case 0, 1: idLength = 2
        case 5: idLength = 4
        default: return
        }
        guard data.count >= idLength + 18 else { return }
        let label = data[idLength..<(idLength + 16)]
        let flags = UInt16(data[idLength + 16]) << 8 | UInt16(data[idLength + 17])
        let text = DABText.label(label, charset: charset)
        let short = DABText.label(label.enumerated().filter { flags & (0x8000 >> $0.offset) != 0 }.map(\.element),
                                  charset: charset)
        switch ext {
        case 0:
            ensemble.label = text
            ensemble.shortLabel = short
        default:
            let sid = data.prefix(idLength).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var service = ensemble.services[sid] ?? .init(id: sid)
            service.label = text
            service.shortLabel = short
            ensemble.services[sid] = service
        }
    }
}
