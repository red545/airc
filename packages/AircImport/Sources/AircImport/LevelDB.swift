// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A read-only LevelDB reader, enough for Chromium's Local Storage database (P22b): the MANIFEST's live tables, their
/// blocks (uncompressed or Snappy), and the write-ahead logs newer than the last flush, merged by sequence number so the
/// newest write of each key wins and deletions hide older values. Every log record and block is checked against its
/// CRC32C; a log's torn tail (Arc writing) ends that log, a damaged table fails the read. Never writes.
enum LevelDB {
    struct Problem: Error, Equatable {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The live key/value pairs of the database in `directory` (a private copy: see `SiteStorageCopy`).
    static func read(_ directory: URL) throws -> [Data: Data] {
        let fm = FileManager.default
        let current = (try? String(contentsOf: directory.appendingPathComponent("CURRENT"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard current.hasPrefix("MANIFEST-"), !current.contains("/"),
              let manifest = try? Data(contentsOf: directory.appendingPathComponent(current)) else { throw Problem("no MANIFEST") }
        let version = try Self.manifest(manifest)
        var newest: [Data: (sequence: UInt64, value: Data?)] = [:]
        func put(_ key: Data, _ sequence: UInt64, _ value: Data?) {
            if let old = newest[key], old.sequence > sequence { return }
            newest[key] = (sequence, value)
        }
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        let present = Set(names.compactMap { name -> UInt64? in
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, parts[1] == "ldb" || parts[1] == "sst" else { return nil }
            return UInt64(parts[0])
        })
        guard version.tables.isSubset(of: present) else { throw Problem("missing live table") }
        for name in names {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let number = UInt64(parts[0]) else { continue }
            let url = directory.appendingPathComponent(name)
            if (parts[1] == "ldb" || parts[1] == "sst") && version.tables.contains(number) {
                for e in try table(try Data(contentsOf: url)) { put(e.key, e.sequence, e.value) }
            } else if parts[1] == "log" && number >= version.logNumber {
                for record in records(try Data(contentsOf: url)) {
                    for e in try batch(record) { put(e.key, e.sequence, e.value) }
                }
            }
        }
        var out: [Data: Data] = [:]
        for (key, entry) in newest { if let value = entry.value { out[key] = value } }
        return out
    }

    // MARK: Format

    struct Entry { var key: Data; var sequence: UInt64; var value: Data? }

    /// The MANIFEST's live table numbers and the oldest log still needed.
    static func manifest(_ data: Data) throws -> (tables: Set<UInt64>, logNumber: UInt64) {
        var tables = Set<UInt64>(), log: UInt64 = 0
        for r in records(data) {
            var c = Cursor(r)
            while !c.atEnd {
                switch try c.varint() {
                case 1: _ = try c.bytes(try c.length())                         // comparator
                case 2: log = try c.varint()                                         // log number
                case 3, 4, 9: _ = try c.varint()                                     // next file, last sequence, prev log
                case 5: _ = try c.varint(); _ = try c.bytes(try c.length())     // compact pointer
                case 6: _ = try c.varint(); tables.remove(try c.varint())            // deleted file
                case 7:                                                              // new file
                    _ = try c.varint(); let n = try c.varint(); _ = try c.varint()
                    _ = try c.bytes(try c.length()); _ = try c.bytes(try c.length())
                    tables.insert(n)
                default: throw Problem("unknown MANIFEST record")
                }
            }
        }
        return (tables, log)
    }

    /// A log's records: 32 KiB blocks of fragments (full, first, middle, last). Stops at the first torn or damaged one.
    static func records(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var out: [Data] = [], pending: [UInt8]? = nil, i = 0
        while i + 7 <= b.count {
            let left = 32768 - i % 32768
            if left < 7 { i += left; continue }
            let crc = le32(b, i), length = Int(b[i + 4]) | Int(b[i + 5]) << 8, type = b[i + 6]
            if type == 0 && length == 0 { i += left; continue }   // preallocated zeros
            guard i + 7 + length <= b.count, unmask(crc) == crc32c([type] + b[(i + 7)..<(i + 7 + length)]) else { break }
            let body = Array(b[(i + 7)..<(i + 7 + length)])
            i += 7 + length
            switch type {
            case 1: out.append(Data(body)); pending = nil
            case 2: pending = body
            case 3: pending? += body
            case 4: if let p = pending { out.append(Data(p + body)) }; pending = nil
            default: return out
            }
        }
        return out
    }

    /// A write batch: its first sequence number, then puts (1) and deletions (0).
    static func batch(_ record: Data) throws -> [Entry] {
        var c = Cursor(record)
        let sequence = try c.fixed64(), count = try c.fixed32()
        guard sequence <= UInt64.max >> 8, UInt64(count) <= (UInt64.max >> 8) - sequence else {
            throw Problem("sequence out of range")
        }
        var out: [Entry] = []
        for n in 0..<UInt64(count) {
            let type = try c.byte()
            let key = try c.bytes(try c.length())
            switch type {
            case 1: out.append(Entry(key: key, sequence: sequence + n, value: try c.bytes(try c.length())))
            case 0: out.append(Entry(key: key, sequence: sequence + n, value: nil))
            default: throw Problem("unknown log entry")
            }
        }
        return out
    }

    /// A table's entries: the footer's index block names each data block.
    static func table(_ data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        guard b.count >= 48, le64(b, b.count - 8) == 0xdb47_7524_8b80_fb57 else { throw Problem("not a LevelDB table") }
        var footer = Cursor(Data(b[(b.count - 48)...]))
        _ = try footer.varint(); _ = try footer.varint()   // metaindex
        let index = try block(b, try footer.length(), try footer.length())
        var out: [Entry] = []
        for (_, handle) in index {
            var h = Cursor(handle)
            for (internalKey, value) in try block(b, try h.length(), try h.length()) {
                guard internalKey.count >= 8 else { throw Problem("damaged table key") }
                let tag = le64([UInt8](internalKey.suffix(8)), 0)
                let type = tag & 0xff
                guard type <= 1 else { throw Problem("unknown table entry") }
                out.append(Entry(key: Data(internalKey.dropLast(8)), sequence: tag >> 8, value: type == 1 ? value : nil))
            }
        }
        return out
    }

    /// One block's key/value pairs (keys share prefixes with the one before).
    static func block(_ b: [UInt8], _ offset: Int, _ size: Int) throws -> [(Data, Data)] {
        guard offset >= 0, size >= 0, offset <= b.count, b.count - offset >= 5, size <= b.count - offset - 5 else { throw Problem("block out of range") }
        let type = b[offset + size]
        guard unmask(le32(b, offset + size + 1)) == crc32c(Array(b[offset..<(offset + size)]) + [type]) else {
            throw Problem("block checksum")
        }
        let raw: [UInt8]
        switch type {
        case 0: raw = Array(b[offset..<(offset + size)])
        case 1: raw = try snappy(Array(b[offset..<(offset + size)]))
        default: throw Problem("compressed in a way Airc can't read")
        }
        guard raw.count >= 4 else { throw Problem("damaged block") }
        let restarts = Int(le32(raw, raw.count - 4))
        let end = raw.count - 4 - 4 * restarts
        guard end >= 0 else { throw Problem("damaged block") }
        var c = Cursor(Data(raw[..<end])), key: [UInt8] = [], out: [(Data, Data)] = []
        while !c.atEnd {
            let shared = try c.length(), unshared = try c.length(), length = try c.length()
            guard shared <= key.count else { throw Problem("damaged block") }
            key = Array(key[..<shared]) + [UInt8](try c.bytes(unshared))
            out.append((Data(key), try c.bytes(length)))
        }
        return out
    }

    /// Snappy's raw format: the length, then literals and back-references (which may overlap what they copy).
    static func snappy(_ b: [UInt8]) throws -> [UInt8] {
        var c = Cursor(Data(b))
        let length = try c.length()
        guard length <= 64 << 20 else { throw Problem("block too large") }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while !c.atEnd {
            let tag = try c.byte()
            var count: Int, offset: Int
            switch tag & 3 {
            case 0:
                count = Int(tag >> 2)
                if count >= 60 {
                    let n = count - 59
                    count = 0
                    for k in 0..<n { count |= Int(try c.byte()) << (8 * k) }
                }
                guard count < length - out.count else { throw Problem("damaged Snappy literal") }
                out += [UInt8](try c.bytes(count + 1))
                continue
            case 1: count = 4 + Int((tag >> 2) & 7); offset = Int(tag >> 5) << 8 | Int(try c.byte())
            case 2: count = Int(tag >> 2) + 1; offset = Int(try c.byte()) | Int(try c.byte()) << 8
            default: count = Int(tag >> 2) + 1; offset = Int(try c.fixed32())
            }
            guard offset > 0, offset <= out.count, out.count + count <= length else { throw Problem("damaged Snappy block") }
            for _ in 0..<count { out.append(out[out.count - offset]) }
        }
        guard out.count == length else { throw Problem("damaged Snappy block") }
        return out
    }

    // MARK: Bytes

    struct Cursor {
        let b: [UInt8]
        var i = 0
        init(_ data: Data) { b = [UInt8](data) }
        var atEnd: Bool { i >= b.count }
        mutating func byte() throws -> UInt8 {
            guard i < b.count else { throw Problem("truncated") }
            defer { i += 1 }
            return b[i]
        }
        mutating func varint() throws -> UInt64 {
            var r: UInt64 = 0, shift: UInt64 = 0
            while true {
                let c = try byte()
                guard shift < 64, shift != 63 || c <= 1 else { throw Problem("bad varint") }
                r |= UInt64(c & 0x7f) << shift
                if c < 0x80 { return r }
                shift += 7
            }
        }
        mutating func length() throws -> Int {
            guard let n = Int(exactly: try varint()) else { throw Problem("length out of range") }
            return n
        }
        mutating func bytes(_ n: Int) throws -> Data {
            guard n >= 0, n <= b.count - i else { throw Problem("truncated") }
            defer { i += n }
            return Data(b[i..<(i + n)])
        }
        mutating func fixed32() throws -> UInt32 { let d = [UInt8](try bytes(4)); return LevelDB.le32(d, 0) }
        mutating func fixed64() throws -> UInt64 { let d = [UInt8](try bytes(8)); return LevelDB.le64(d, 0) }
    }

    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0x82f6_3b78 : c >> 1 }
        return c
    }
    static func crc32c<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for x in bytes { crc = crcTable[Int((crc ^ UInt32(x)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
    static func unmask(_ c: UInt32) -> UInt32 {
        let r = c &- 0xa282_ead8
        return (r >> 17) | (r << 15)
    }
}

/// Writes a fresh LevelDB holding `entries` (nil values are deletions) as LevelDB itself lays one out before its first
/// flush: CURRENT, a MANIFEST and one log of write batches, every record with its CRC32C. For synthetic fixtures only
/// (tests and the app's acceptance check), never on real data.
public enum LevelDBFixture {
    public static func write(_ entries: [(key: Data, value: Data?)], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            while v >= 0x80 { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
            return out + [UInt8(v)]
        }
        func fixed(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        func log(_ payloads: [[UInt8]]) -> Data {
            var out: [UInt8] = []
            for p in payloads {
                var rest = p[...], first = true
                repeat {
                    var left = 32768 - out.count % 32768
                    if left < 7 { out += [UInt8](repeating: 0, count: left); left = 32768 }
                    let n = min(rest.count, left - 7)
                    let last = n == rest.count
                    let type: UInt8 = first && last ? 1 : first ? 2 : last ? 4 : 3
                    let body = Array(rest.prefix(n))
                    let crc = LevelDB.crc32c([type] + body)
                    let masked = ((crc >> 15) | (crc << 17)) &+ 0xa282_ead8
                    out += fixed(UInt64(masked), 4)
                    out += fixed(UInt64(n), 2)
                    out.append(type)
                    out += body
                    rest = rest.dropFirst(n)
                    first = false
                } while !rest.isEmpty
            }
            return Data(out)
        }
        var batch: [UInt8] = fixed(1, 8)
        batch += fixed(UInt64(entries.count), 4)
        for e in entries {
            batch.append(e.value == nil ? 0 : 1)
            batch += varint(UInt64(e.key.count))
            batch += [UInt8](e.key)
            if let v = e.value {
                batch += varint(UInt64(v.count))
                batch += [UInt8](v)
            }
        }
        let comparator = [UInt8]("leveldb.BytewiseComparator".utf8)
        var edit: [UInt8] = [1]
        edit += varint(UInt64(comparator.count))
        edit += comparator
        edit += [2] + varint(3)       // log number
        edit += [3] + varint(4)       // next file
        edit += [4] + varint(UInt64(entries.count))   // last sequence
        try log([edit]).write(to: directory.appendingPathComponent("MANIFEST-000002"))
        try log([batch]).write(to: directory.appendingPathComponent("000003.log"))
        try Data("MANIFEST-000002\n".utf8).write(to: directory.appendingPathComponent("CURRENT"))
    }
}
