// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// Adapted from Ardia's ArdiaProtectedVideoMedia.mm (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios: Boxes, Walk, InitKeyID, FairPlayKeyIDs, FairPlayPssh, SinfKeyIDs, InitTimescale,
// FragmentDecodeTime, CodecsOf), which is Copyright 2026 Mantra Patel, licensed under the Apache License, Version 2.0;
// modified by The Airc Authors (Swift).

import Foundation

/// The few ISO BMFF (fMP4) facts the FairPlay video bridge needs (docs/design/fairplay-bridge.md, step 2): key IDs from
/// init segments, `pssh` and `sinf` init data, timescales and fragment decode times. Bounds-checked: input is the page's.
public enum FairPlayMP4 {
    /// FairPlay's system ID in a `pssh` box.
    static let fairPlaySystem: [UInt8] = [0x94, 0xce, 0x86, 0xfb, 0x07, 0xff, 0x4f, 0x43, 0xad, 0xb8, 0x93, 0xd2, 0xfa, 0x96, 0x8c, 0xa2]

    struct Box { let type: String; let start: Int; let body: Int; let end: Int }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var at = start
        while at + 8 <= end {
            var size = UInt64(u32(b, at))
            var header = 8
            if size == 1 {
                if at + 16 > end { break }
                size = UInt64(u32(b, at + 8)) << 32 | UInt64(u32(b, at + 12))
                header = 16
            } else if size == 0 {
                size = UInt64(end - at)
            }
            if size < UInt64(header) || size > UInt64(end - at) { break }
            let type = String(bytes: b[(at + 4)..<(at + 8)], encoding: .isoLatin1) ?? ""
            out.append(Box(type: type, start: at, body: at + header, end: at + Int(size)))
            at += Int(size)
        }
        return out
    }

    static func childrenOffset(_ type: String) -> Int {
        switch type {
        case "stsd": return 8
        case "encv", "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe": return 78
        case "enca", "mp4a", "ec-3", "ac-3": return 28
        default: return 0
        }
    }

    static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "stsd", "encv", "enca", "sinf", "schi", "fpsd", "fpsk"]

    /// Visits boxes depth first; `visit` says whether to go into a box.
    static func walk(_ b: [UInt8], _ start: Int, _ end: Int, _ visit: (Box) -> Bool) {
        for box in boxes(b, start, end) where visit(box) {
            let children = box.body + childrenOffset(box.type)
            if children < box.end { walk(b, children, box.end, visit) }
        }
    }

    /// The default key ID of an init segment (its `tenc`), or nil when it isn't encrypted.
    public static func initKeyID(_ data: Data) -> Data? {
        let b = [UInt8](data)
        var found: Data?
        walk(b, 0, b.count) { box in
            if found == nil, box.type == "tenc", box.end - box.start >= 32 { found = Data(b[(box.start + 16)..<(box.start + 32)]) }
            return containers.contains(box.type)
        }
        return found
    }

    /// FairPlay key IDs in `pssh` boxes (version 1 KIDs and `fkri` boxes).
    public static func fairPlayKeyIDs(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var ids: [Data] = []
        func add(_ d: Data) { if !ids.contains(d) { ids.append(d) } }
        for box in boxes(b, 0, b.count) where box.type == "pssh" && box.end - box.start >= 32 && Array(b[(box.start + 12)..<(box.start + 28)]) == fairPlaySystem {
            var at = box.start + 28
            if b[box.start + 8] > 0 {
                if at + 4 > box.end { continue }
                let count = u32(b, at)
                at += 4
                var i: UInt32 = 0
                while i < count && at + 16 <= box.end { add(Data(b[at..<(at + 16)])); at += 16; i += 1 }
            }
            if at + 4 > box.end { continue }
            at += 4
            walk(b, at, box.end) { inner in
                if inner.type == "fkri", inner.end - inner.start >= 28 { add(Data(b[(inner.start + 12)..<(inner.start + 28)])) }
                return containers.contains(inner.type)
            }
        }
        return ids
    }

    /// The FairPlay `pssh` box in `cenc` init data.
    public static func fairPlayPssh(_ data: Data) -> Data? {
        let b = [UInt8](data)
        for box in boxes(b, 0, b.count) where box.type == "pssh" && box.end - box.start >= 32 && Array(b[(box.start + 12)..<(box.start + 28)]) == fairPlaySystem {
            return Data(b[box.start..<box.end])
        }
        return nil
    }

    /// Key IDs of `sinf` init data: JSON `{"sinf": [base64, …]}`, as WebKit and FairPlay players use it.
    public static func sinfKeyIDs(_ json: Data) -> [Data] {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any], let sinfs = o["sinf"] as? [Any] else { return [] }
        var ids: [Data] = []
        for case let s as String in sinfs {
            if let sinf = Data(base64Encoded: s), let kid = initKeyID(sinf), !ids.contains(kid) { ids.append(kid) }
        }
        return ids
    }

    /// The first track's media timescale.
    public static func initTimescale(_ data: Data) -> UInt32 {
        let b = [UInt8](data)
        var found: UInt32 = 0
        walk(b, 0, b.count) { box in
            if found == 0, box.type == "mdhd", box.end - box.body >= 24 { found = u32(b, box.body + (b[box.body] == 1 ? 20 : 12)) }
            return box.type == "moov" || box.type == "trak" || box.type == "mdia"
        }
        return found
    }

    /// A fragment's first `tfdt` base media decode time, or -1.
    public static func fragmentDecodeTime(_ data: Data) -> Int64 {
        let b = [UInt8](data)
        var found: Int64 = -1
        walk(b, 0, b.count) { box in
            if found < 0, box.type == "tfdt", box.end - box.body >= 8 {
                if b[box.body] != 1 { found = Int64(u32(b, box.body + 4)) }
                else if box.end - box.body >= 12 { found = Int64(bitPattern: UInt64(u32(b, box.body + 4)) << 32 | UInt64(u32(b, box.body + 8))) }
            }
            return box.type == "moof" || box.type == "traf"
        }
        return found
    }

    /// "a1b2…" (32 hex digits) → 16 bytes.
    public static func unhex(_ text: String) -> Data? {
        let chars = Array(text.lowercased())
        guard chars.count == 32 else { return nil }
        var out = Data()
        for i in stride(from: 0, to: 32, by: 2) {
            guard let v = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    /// The key ID in an `skd://` URI: "skd://<32 hex>" or "skd://<uuid with dashes>[:IV]".
    public static func keyID(fromSkd uri: String) -> Data? {
        guard uri.lowercased().hasPrefix("skd://") else { return nil }
        var rest = String(uri.dropFirst(6))
        if let colon = rest.firstIndex(of: ":") { rest = String(rest[..<colon]) }
        return unhex(rest.replacingOccurrences(of: "-", with: ""))
    }
}
