// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Easels on disk: one folder per Easel in the data folder's `Easels/`:
///
///     Easels/<id>/easel.json        the document (versioned JSON, EaselDocument)
///     Easels/<id>/easel.json.bak    the version before the last save
///     Easels/<id>/history.json      the last session's undo and redo (EaselHistory)
///     Easels/<id>/assets/<sha256>.<ext>   its pictures, named by their bytes
///     Easels/<id>/easel.json.damaged-<time>   a file that didn't read, kept as it was
///
/// Saves are atomic: the new JSON goes to a temporary file in the folder, the current file becomes the `.bak`, then the
/// temporary file takes its name (rename(2) both times), so a crash leaves either version whole. Reading falls back
/// from a damaged file to the `.bak`, and from there to whatever blocks still decode; nothing that didn't read is
/// overwritten or deleted.
public struct EaselFiles: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let documentName = "easel.json"
    public static let backupName = "easel.json.bak"
    public static let historyName = "history.json"
    public static let assetsName = "assets"

    /// Ids this build makes and accepts as folder names: nothing that climbs out of `root`.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Asset names this build writes and reads: hex and a picture extension.
    public static func isValidAsset(_ name: String) -> Bool {
        name.range(of: #"^[0-9a-f]{16,128}\.(png|jpg|gif|heic|webp)$"#, options: .regularExpression) != nil
    }

    public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    public func documentURL(_ id: String) -> URL { folder(id).appendingPathComponent(Self.documentName) }
    public func backupURL(_ id: String) -> URL { folder(id).appendingPathComponent(Self.backupName) }
    public func historyURL(_ id: String) -> URL { folder(id).appendingPathComponent(Self.historyName) }
    public func assetsFolder(_ id: String) -> URL { folder(id).appendingPathComponent(Self.assetsName, isDirectory: true) }

    public func assetURL(_ id: String, _ asset: String) -> URL? {
        Self.isValidAsset(asset) && Self.isValidID(id) ? assetsFolder(id).appendingPathComponent(asset) : nil
    }

    public func exists(_ id: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: documentURL(id).path) || fm.fileExists(atPath: backupURL(id).path)
    }

    // MARK: Encoding

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        // Seconds since 2001 (Foundation's own reference) as a JSON number: exact both ways (ISO 8601 drops fractions of
        // a second, and moving the epoch to 1970 rounds the last bits).
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    public static func encode(_ d: EaselDocument) throws -> Data { try encoder().encode(d) }

    // MARK: Saving

    public enum SaveError: Error, Equatable { case invalidID, rename(Int32) }

    /// Writes `doc` atomically, the version it replaces kept as the `.bak`.
    public func save(_ doc: EaselDocument) throws {
        try save(Self.encode(doc), id: doc.id)
    }

    public func save(_ data: Data, id: String) throws {
        guard Self.isValidID(id) else { throw SaveError.invalidID }
        let fm = FileManager.default
        try fm.createDirectory(at: folder(id), withIntermediateDirectories: true)
        let tmp = folder(id).appendingPathComponent(".easel.json.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        let current = documentURL(id)
        if fm.fileExists(atPath: current.path), rename(current.path, backupURL(id).path) != 0 {
            let e = errno
            try? fm.removeItem(at: tmp)
            throw SaveError.rename(e)
        }
        if rename(tmp.path, current.path) != 0 {
            let e = errno
            try? fm.removeItem(at: tmp)
            throw SaveError.rename(e)
        }
    }

    public func saveHistory(_ h: EaselHistory, id: String) throws {
        guard Self.isValidID(id) else { throw SaveError.invalidID }
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
        try Self.encoder().encode(h).write(to: historyURL(id), options: .atomic)
    }

    /// The saved undo history, if it belongs to `doc` as it was read (same revision).
    public func loadHistory(for doc: EaselDocument) -> EaselHistory? {
        guard let data = try? Data(contentsOf: historyURL(doc.id)),
              let h = try? Self.decoder().decode(EaselHistory.self, from: data), h.revision == doc.revision, !doc.revision.isEmpty else { return nil }
        return h
    }

    // MARK: Reading, with recovery

    public struct Issue: Hashable, Sendable {
        /// The block's place in the file and its id when it had one.
        public var index: Int
        public var blockID: String?
        public var reason: String
    }

    public enum Source: Hashable, Sendable {
        /// easel.json read whole.
        case document
        /// easel.json read, some blocks left out (`issues`).
        case partialDocument
        /// easel.json didn't read; its `.bak` did (`partial`: some of its blocks left out).
        case backup(partial: Bool)
        /// Neither read: an empty Easel (the damaged files are kept).
        case unreadable
        /// No file at all (a new Easel, or one whose folder is gone).
        case missing
    }

    public struct LoadResult: Sendable {
        public var document: EaselDocument
        public var source: Source
        public var issues: [Issue]
        /// Where the file that didn't read was kept.
        public var keptDamaged: URL?

        /// What to tell the person, or nil when it read whole.
        public var message: String? {
            switch source {
            case .document, .missing: return nil
            case .partialDocument:
                return "Some of this Easel couldn't be read: \(issues.count) item\(issues.count == 1 ? "" : "s") left out. The original file is kept."
            case .backup(let partial):
                return "This Easel's file was damaged, so its previous version was opened" + (partial ? ", without \(issues.count) item\(issues.count == 1 ? "" : "s") that couldn't be read." : ".")
            case .unreadable:
                return "This Easel couldn't be read. Its file is kept in the Easels folder."
            }
        }
    }

    enum Attempt {
        case whole(EaselDocument)
        case partial(EaselDocument, [Issue])
        case failed
    }

    /// Reads `data` whole, else leniently (the blocks that decode).
    static func attempt(_ data: Data) -> Attempt {
        let dec = decoder()
        if let d = try? dec.decode(EaselDocument.self, from: data) { return .whole(d) }
        var issues: [Issue] = []
        let box = LenientBox()
        dec.userInfo[LenientBox.key] = box
        guard let w = try? dec.decode(LenientDocument.self, from: data) else { return .failed }
        issues = box.issues
        return .partial(w.document, issues)
    }

    /// Reads Easel `id`: its file, else its `.bak`, else the blocks that still decode, else an empty Easel. A file that
    /// didn't read whole is copied aside first (`easel.json.damaged-<time>`), so a later save never loses it.
    public func load(_ id: String) -> LoadResult {
        let fm = FileManager.default
        let doc = documentURL(id), bak = backupURL(id)
        let primary = try? Data(contentsOf: doc)
        if primary == nil && !fm.fileExists(atPath: bak.path) {
            return LoadResult(document: EaselDocument(id: id), source: .missing, issues: [])
        }
        var kept: URL?
        func keepDamaged(_ url: URL) {
            guard kept == nil, fm.fileExists(atPath: url.path) else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let to = folder(id).appendingPathComponent("easel.json.damaged-\(stamp)")
            if (try? fm.copyItem(at: url, to: to)) != nil { kept = to }
        }
        func fixed(_ d: EaselDocument) -> EaselDocument {
            var d = d
            d.id = id
            return d
        }
        var primaryPartial: (EaselDocument, [Issue])?
        if let primary {
            switch Self.attempt(primary) {
            case .whole(let d): return LoadResult(document: fixed(d), source: .document, issues: [])
            case .partial(let d, let issues): primaryPartial = (d, issues)
            case .failed: break
            }
            keepDamaged(doc)
        }
        // The file didn't read whole: the previous version, if it's whole, has everything but the last save; a file
        // that still reads in part keeps its newer blocks, so it wins over a backup that only reads in part.
        if let b = try? Data(contentsOf: bak) {
            switch Self.attempt(b) {
            case .whole(let d):
                if let p = primaryPartial, p.0.blocks.count > d.blocks.count {
                    return LoadResult(document: fixed(p.0), source: .partialDocument, issues: p.1, keptDamaged: kept)
                }
                return LoadResult(document: fixed(d), source: .backup(partial: false), issues: [], keptDamaged: kept)
            case .partial(let d, let issues) where primaryPartial == nil:
                return LoadResult(document: fixed(d), source: .backup(partial: true), issues: issues, keptDamaged: kept)
            default: break
            }
        }
        if let p = primaryPartial { return LoadResult(document: fixed(p.0), source: .partialDocument, issues: p.1, keptDamaged: kept) }
        keepDamaged(bak)
        return LoadResult(document: EaselDocument(id: id), source: .unreadable, issues: [], keptDamaged: kept)
    }

    // MARK: Assets

    /// Keeps picture bytes in `id`'s assets (named by their bytes, so the same picture is kept once). The name.
    public func addAsset(_ data: Data, ext: String, to id: String) throws -> String {
        var ext = ext.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "\(hex).\(ext)"
        guard let url = assetURL(id, name) else { throw SaveError.invalidID }
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: assetsFolder(id), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    /// Pasting between Easels: `assets` of Easel `from` copied into `to`'s (those it doesn't have yet).
    public func copyAssets(_ assets: Set<String>, from: String, to: String) {
        guard from != to else { return }
        let fm = FileManager.default
        for a in assets {
            guard let src = assetURL(from, a), let dst = assetURL(to, a), !fm.fileExists(atPath: dst.path), fm.fileExists(atPath: src.path) else { continue }
            try? fm.createDirectory(at: assetsFolder(to), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: Copies (a row duplicated)

    /// The app's Easels folder, for the store's row copies (`SpacesStore.copiedAddress`); set at launch. nil (tests that
    /// don't set it): a copied row shares its Easel, as before P19b.
    nonisolated(unsafe) public static var shared: EaselFiles?

    /// A new Easel with `id`'s blocks, title and pictures (not its undo history), under a new id. The new id, or nil
    /// when `id` has nothing to copy or the copy couldn't be written (then nothing is left half-made).
    public func duplicate(_ id: String, now: Date = Date()) -> String? {
        guard Self.isValidID(id), exists(id) else { return nil }
        let r = load(id)
        if case .missing = r.source { return nil }
        let copyID = AircKit.newID()
        var d = r.document
        d.id = copyID
        d.revision = AircKit.newID()
        d.createdAt = now
        d.updatedAt = now
        let fm = FileManager.default
        do {
            for a in d.assets {
                guard let src = assetURL(id, a), let dst = assetURL(copyID, a), fm.fileExists(atPath: src.path) else { continue }
                try fm.createDirectory(at: assetsFolder(copyID), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: dst)
            }
            try save(d)
        } catch {
            try? fm.removeItem(at: folder(copyID))
            return nil
        }
        return copyID
    }

    // MARK: Listing (Library › Easels)

    public struct Summary: Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var updatedAt: Date
        public var blockCount: Int
        public var text: String
        /// The picture that stands for it: its frontmost image or Capture.
        public var thumbnail: String?
        public var displayTitle: String {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? EaselURL.untitled : t
        }
    }

    /// Every Easel in the folder, newest first. Reads each document; call it off the main thread for many.
    public func list() -> [Summary] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [Summary] = []
        for id in names where Self.isValidID(id) && exists(id) {
            let r = load(id)
            if case .missing = r.source { continue }
            let d = r.document
            let thumb = d.stacked.reversed().lazy.compactMap { b -> String? in
                switch b.content {
                case .image(let i): i.asset
                case .capture(let c): c.asset
                default: nil
                }
            }.first
            out.append(Summary(id: id, title: d.title, updatedAt: d.updatedAt, blockCount: d.blocks.count, text: d.plainText, thumbnail: thumb))
        }
        return out.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}

// MARK: - Lenient decoding

/// Collects the blocks a lenient read left out.
final class LenientBox: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "org.airc.easel.lenient")!
    var issues: [EaselFiles.Issue] = []
}

struct LenientDocument: Decodable {
    var document: EaselDocument

    init(from decoder: Decoder) throws {
        let box = decoder.userInfo[LenientBox.key] as? LenientBox
        document = try EaselDocument(from: decoder, lenient: true) { index, id, reason in
            box?.issues.append(EaselFiles.Issue(index: index, blockID: id, reason: reason))
        }
    }
}
