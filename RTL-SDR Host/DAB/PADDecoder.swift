//
//  PADDecoder.swift
//  RTL-SDR Host
//
//  Programme Associated Data (EN 300 401 clause 7.4): the text and the
//  pictures that travel with the audio.
//
//    DAB+: a data_stream_element at the start of each AU carries the PAD
//    MP2: the end of each frame, before the scale factor CRCs
//
//  Either way the last two bytes are the F-PAD; the X-PAD sits before it
//  in reverse byte order. The X-PAD starts with a list of contents
//  indicators (length and application type of each subfield), then the
//  subfields:
//
//    type 1       data group length (for the next MOT data group)
//    type 2 / 3   Dynamic Label (DLS): start / continuation
//    type 12 / 13 MOT data group: start / continuation
//
//  DLS (clause 7.4.5.2): up to 8 segments of 16 characters, a toggle bit
//  marks a new label. MOT (EN 301 234): a header and the segments of a body
//  under one transport id; slideshow pictures are JPEG or PNG bodies
//  (TS 101 499).
//
//  Runs on one queue; not thread-safe.
//

import Foundation

nonisolated final class PADDecoder {

    struct Slide: Equatable, Sendable {
        var data: Data
        var isPNG: Bool
        var name: String?
    }

    /// The current label, nil until one is complete.
    private(set) var label: String?
    private(set) var slide: Slide?
    /// Increases on each new label or slide, for cheap change checks.
    private(set) var labelVersion = 0
    private(set) var slideVersion = 0

    struct Statistics: Sendable {
        var dataGroups = 0              // MOT data groups complete
        var dataGroupErrors = 0         // … failing their CRC
        var lengthIndicators = 0
    }
    private(set) var stats = Statistics()

    // X-PAD continuation state.
    private var lastType = 0
    private var lastLength = 0

    // DLS.
    private var dlsGroup: [UInt8] = []
    private var dlsToggle: Int?
    private var dlsSegments: [Int: [UInt8]] = [:]
    private var dlsCharset = 0
    private var dlsLast: Int?

    // MOT.
    private var motLength = 0
    private var motGroup: [UInt8] = []
    private var objects: [Int: MOTObject] = [:]
    private var objectOrder: [Int] = []          // transport ids, oldest first

    private struct MOTObject {
        var header: [UInt8]?
        var body: [Int: [UInt8]] = [:]
        var lastBody: Int?
    }

    func reset() {
        label = nil
        slide = nil
        lastType = 0
        lastLength = 0
        dlsGroup = []
        dlsToggle = nil
        dlsSegments = [:]
        dlsLast = nil
        motLength = 0
        motGroup = []
        objects = [:]
        objectOrder = []
    }

    // MARK: - Input

    /// The PAD of a DAB+ AU, if its first element is a DSE.
    func processAU(_ au: [UInt8]) {
        guard au.count >= 4, au[0] >> 5 == 4 else { return }
        var count = Int(au[1])
        var offset = 2
        if count == 255 {
            count += Int(au[2])
            offset = 3
        }
        guard count >= 2, offset + count <= au.count else { return }
        process(au[offset..<(offset + count - 2)], fpad: (au[offset + count - 2], au[offset + count - 1]))
    }

    /// The PAD at the end of an MP2 frame.
    func processMP2(_ frame: [UInt8]) {
        guard frame.count > 8 else { return }
        let mpeg1 = frame[1] & 0x08 != 0
        let rates = [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384]
        let index = Int(frame[2] >> 4)
        let mono = frame[3] >> 6 == 3
        let perChannel = index < rates.count ? rates[index] / (mono ? 1 : 2) : 0
        let crcBytes = mpeg1 && perChannel < 56 ? 2 : 4
        let end = frame.count - 2 - crcBytes
        guard end > 4 else { return }
        process(frame[4..<end], fpad: (frame[frame.count - 2], frame[frame.count - 1]))
    }

    /// `region`: the bytes before the F-PAD (or before the scale factor
    /// CRCs), X-PAD reversed at its end.
    private func process(_ region: ArraySlice<UInt8>, fpad: (UInt8, UInt8)) {
        guard fpad.0 >> 6 == 0 else { return }            // F-PAD type 00
        let indicator = (fpad.0 >> 4) & 3
        let hasCI = fpad.1 & 0x02 != 0
        guard indicator != 0 else { return }
        // X-PAD byte j in logical order.
        let reversed = region.reversed().map { $0 }
        var subfields: [(type: Int, data: ArraySlice<UInt8>)] = []

        if indicator == 1 {                                 // short X-PAD
            guard reversed.count >= 4 else { return }
            if hasCI {
                subfields.append((Int(reversed[0] & 0x1F), reversed[1..<4]))
            } else {
                subfields.append((continuation(lastType), reversed[0..<4]))
            }
        } else if indicator == 2 {                          // variable size
            var lengths: [(Int, Int)] = []
            var i = 0
            if hasCI {
                let sizes = [4, 6, 8, 12, 16, 24, 32, 48]
                while i < 4, i < reversed.count {
                    let ci = reversed[i]
                    i += 1
                    let type = Int(ci & 0x1F)
                    if type == 0 { break }
                    lengths.append((type, sizes[Int(ci >> 5)]))
                }
            } else if lastLength > 0 {
                // Without CIs the X-PAD continues the last subfield and is as
                // long as the previous X-PAD, CIs included.
                lengths.append((continuation(lastType), lastLength))
            }
            for (type, length) in lengths {
                guard i + length <= reversed.count else { break }
                subfields.append((type, reversed[i..<(i + length)]))
                i += length
            }
            if hasCI { lastLength = i }
        }

        for (type, data) in subfields {
            handle(type: type, data)
            lastType = type
        }
    }

    /// The application type a CI-less X-PAD continues with.
    private func continuation(_ type: Int) -> Int {
        switch type {
        case 2: 3
        case 12: 13
        default: type
        }
    }

    private func handle(type: Int, _ data: ArraySlice<UInt8>) {
        switch type {
        case 1:
            // Data group length indicator: 14 bits, then a CRC.
            if data.count >= 4, CRC16.check(data.prefix(4)) {
                stats.lengthIndicators += 1
                motLength = Int(data[data.startIndex] & 0x3F) << 8 | Int(data[data.startIndex + 1])
            }
        case 2:
            dlsGroup = Array(data)
            completeDLS()
        case 3:
            guard !dlsGroup.isEmpty else { return }
            dlsGroup += data
            completeDLS()
        case 12:
            motGroup = Array(data)
            completeMOT()
        case 13:
            guard !motGroup.isEmpty else { return }
            motGroup += data
            completeMOT()
        default:
            break
        }
    }

    // MARK: - DLS

    private func completeDLS() {
        guard dlsGroup.count >= 2 else { return }
        let b0 = dlsGroup[0]
        let command = b0 & 0x10 != 0
        let field = Int(b0 & 0x0F)
        let length: Int
        if command {
            length = field == 2 ? 2 + (Int(dlsGroup[1]) & 0x0F) + 1 + 2 : 4
        } else {
            length = 2 + field + 1 + 2
        }
        guard dlsGroup.count >= length else { return }
        let group = Array(dlsGroup[0..<length])
        dlsGroup = []
        guard CRC16.check(group) else { return }

        if command {
            if field == 1 {                      // remove label
                dlsSegments = [:]
                dlsLast = nil
            }
            return
        }
        let toggle = Int(b0 >> 7)
        let first = b0 & 0x40 != 0
        let last = b0 & 0x20 != 0
        if toggle != dlsToggle {
            dlsToggle = toggle
            dlsSegments = [:]
            dlsLast = nil
        }
        let segment: Int
        if first {
            segment = 0
            dlsCharset = Int(group[1] >> 4)
        } else {
            segment = Int(group[1] >> 4) & 7
        }
        dlsSegments[segment] = Array(group[2..<(2 + field + 1)])
        if last { dlsLast = segment }
        guard let dlsLast, (0...dlsLast).allSatisfy({ dlsSegments[$0] != nil }) else { return }
        let bytes = (0...dlsLast).flatMap { dlsSegments[$0]! }
        let text = DABText.label(bytes, charset: dlsCharset)
        if text != label {
            label = text
            labelVersion += 1
        }
    }

    // MARK: - MOT

    private func completeMOT() {
        guard motLength > 0, motGroup.count >= motLength else { return }
        let group = Array(motGroup[0..<motLength])
        motGroup = []
        motLength = 0
        parseDataGroup(group)
    }

    /// An MSC data group (EN 300 401 clause 5.3.3) carrying a MOT segment.
    private func parseDataGroup(_ g: [UInt8]) {
        guard g.count >= 4 else { return }
        let hasExtension = g[0] & 0x80 != 0
        let hasCRC = g[0] & 0x40 != 0
        let segmented = g[0] & 0x20 != 0
        let userAccess = g[0] & 0x10 != 0
        let type = Int(g[0] & 0x0F)
        stats.dataGroups += 1
        if hasCRC && !CRC16.check(g) {
            stats.dataGroupErrors += 1
            return
        }
        let end = g.count - (hasCRC ? 2 : 0)
        var i = 2 + (hasExtension ? 2 : 0)

        var last = false
        var segment = 0
        if segmented {
            guard i + 2 <= end else { return }
            last = g[i] & 0x80 != 0
            segment = Int(g[i] & 0x7F) << 8 | Int(g[i + 1])
            i += 2
        }
        var transport: Int?
        if userAccess {
            guard i < end else { return }
            let hasTransport = g[i] & 0x10 != 0
            let length = Int(g[i] & 0x0F)
            if hasTransport, i + 3 <= end { transport = Int(g[i + 1]) << 8 | Int(g[i + 2]) }
            i += 1 + length
        }
        guard let transport, i + 2 <= end else { return }
        // Segmentation header: repetition count (3) and segment size (13).
        let size = Int(g[i] & 0x1F) << 8 | Int(g[i + 1])
        i += 2
        guard i + size <= end else { return }
        let data = Array(g[i..<(i + size)])

        var object = objects[transport] ?? MOTObject()
        switch type {
        case 3:                                  // MOT header (one segment in slideshows)
            object.header = data
        case 4:                                  // MOT body
            object.body[segment] = data
            if last { object.lastBody = segment }
        default:
            return
        }
        objects[transport] = object
        objectOrder.removeAll { $0 == transport }
        objectOrder.append(transport)
        // Keep only the newest few objects of the carousel.
        while objectOrder.count > 4 {
            objects.removeValue(forKey: objectOrder.removeFirst())
        }
        finish(transport)
    }

    private func finish(_ transport: Int) {
        guard let object = objects[transport], let header = object.header, header.count >= 7,
              let last = object.lastBody, (0...last).allSatisfy({ object.body[$0] != nil }) else { return }
        let bodySize = Int(header[0]) << 20 | Int(header[1]) << 12 | Int(header[2]) << 4 | Int(header[3] >> 4)
        let contentType = Int(header[5] >> 1) & 0x3F
        let subType = Int(header[5] & 1) << 8 | Int(header[6])
        let body = (0...last).flatMap { object.body[$0]! }
        objects.removeValue(forKey: transport)
        objectOrder.removeAll { $0 == transport }
        guard body.count == bodySize, contentType == 2, subType == 1 || subType == 3 else { return }
        let new = Slide(data: Data(body), isPNG: subType == 3, name: contentName(header))
        if new != slide {
            slide = new
            slideVersion += 1
        }
    }

    /// ContentName (parameter 12) from the MOT header extension.
    private func contentName(_ h: [UInt8]) -> String? {
        let headerSize = Int(h[3] & 0x0F) << 9 | Int(h[4]) << 1 | Int(h[5] >> 7)
        var i = 7
        let end = min(headerSize, h.count)
        while i < end {
            let pli = h[i] >> 6, id = Int(h[i] & 0x3F)
            i += 1
            var length: Int
            switch pli {
            case 0: length = 0
            case 1: length = 1
            case 2: length = 4
            default:
                guard i < end else { return nil }
                if h[i] & 0x80 != 0 {
                    guard i + 1 < end else { return nil }
                    length = Int(h[i] & 0x7F) << 8 | Int(h[i + 1])
                    i += 2
                } else {
                    length = Int(h[i] & 0x7F)
                    i += 1
                }
            }
            guard i + length <= end else { return nil }
            if id == 12, length > 1 {
                return DABText.label(h[(i + 1)..<(i + length)], charset: Int(h[i] >> 4))
            }
            i += length
        }
        return nil
    }
}
