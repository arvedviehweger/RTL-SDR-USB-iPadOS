//
//  DABText.swift
//  RTL-SDR Host
//
//  Character sets of DAB labels and DLS (TS 101 756): the complete EBU
//  Latin based repertoire (charset 0), ISO 8859-1 (4), UCS-2 big endian (6)
//  and UTF-8 (15).
//

import Foundation

nonisolated enum DABText {

    static func decode<C: Collection>(_ bytes: C, charset: Int) -> String where C.Element == UInt8 {
        switch charset {
        case 15:
            return String(decoding: bytes, as: UTF8.self)
        case 6:
            let a = Array(bytes)
            let units = stride(from: 0, to: a.count - 1, by: 2).map { UInt16(a[$0]) << 8 | UInt16(a[$0 + 1]) }
            return String(decoding: units, as: UTF16.self)
        case 4:
            return String(bytes.map { Character(UnicodeScalar($0)) })
        default:
            return String(bytes.compactMap { ebuLatin[Int($0)] })
        }
    }

    /// Labels: decoded and trimmed, nil when empty.
    static func label<C: Collection>(_ bytes: C, charset: Int) -> String? where C.Element == UInt8 {
        let s = decode(bytes, charset: charset).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Complete EBU Latin based repertoire. Control codes 0x0A (preferred
    /// line break) and 0x0B (end of headline) become a space; others drop.
    private static let ebuLatin: [Character?] = {
        var t = [Character?](repeating: nil, count: 256)
        t[0x0A] = " "
        t[0x0B] = " "
        for c in 0x20...0x7D { t[c] = Character(UnicodeScalar(UInt8(c))) }
        t[0x24] = "¤"
        t[0x5E] = "―"
        t[0x60] = "║"
        t[0x7E] = "¯"
        let rows: [(Int, String)] = [
            (0x80, "áàéèíìóòúùÑÇŞß¡Ĳ"),
            (0x90, "âäêëîïôöûüñçşğıĳ"),
            (0xA0, "ªα©‰Ǧěňőπ€£$←↑→↓"),
            (0xB0, "º¹²³±İńűµ¿÷°¼½¾§"),
            (0xC0, "ÁÀÉÈÍÌÓÒÚÙŘČŠŽĐĿ"),
            (0xD0, "ÂÄÊËÎÏÔÖÛÜřčšžđŀ"),
            (0xE0, "ÃÅÆŒŷÝÕØÞŊŔĆŚŹŦð"),
            (0xF0, "ãåæœŵýõøþŋŕćśźŧ"),
        ]
        for (start, chars) in rows {
            for (k, ch) in chars.enumerated() { t[start + k] = ch }
        }
        return t
    }()
}
