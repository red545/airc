// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

// Notes in iCloud sync (docs/sync.md, "Notes"). A pinned note's row syncs like any pinned tab (its address is
// `airc-note:<id>`); what the note says goes separately, one mutable record per note and Mac, sealed with the group key:
//
// - `SyncNote` `note.<device>.<note id>`: that Mac's latest version of the note (text, title, dates), with a version
//   vector and a hybrid-clock stamp. Each Mac only ever writes its own records, so CloudKit never merges anything.
// - `SyncNoteAsset` `noteasset.<keyed hash>`: one picture, sealed, as a CKAsset. The name is an HMAC of the picture's
//   file name under a key derived from the group key, so iCloud can't tell which picture it is.
//
// Older Airc builds skip both record types (their transport ignores types it doesn't know), and the note rows go in
// batches of envelope version 2, which they keep unread in their quarantine (docs/sync.md, "Older builds").

/// A note version's history: how many versions each Mac has made of it. A version that has every count of another has
/// seen it (it "dominates" it); two versions that each have a count the other lacks were made apart: a conflict.
public struct SyncNoteVector: Codable, Hashable, Sendable {
    /// Device UUID string → versions that device made.
    public private(set) var counts: [String: UInt64]

    public init(_ counts: [String: UInt64] = [:]) { self.counts = counts.filter { $0.value > 0 } }

    public enum Order: Equatable, Sendable { case same, newer, older, concurrent }

    /// How `self` relates to `other`.
    public func compare(_ other: Self) -> Order {
        var ahead = false, behind = false
        for key in Set(counts.keys).union(other.counts.keys) {
            let a = counts[key] ?? 0, b = other.counts[key] ?? 0
            if a > b { ahead = true } else if a < b { behind = true }
        }
        switch (ahead, behind) {
        case (false, false): return .same
        case (true, false): return .newer
        case (false, true): return .older
        case (true, true): return .concurrent
        }
    }

    public func merged(_ other: Self) -> Self {
        var result = counts
        for (key, n) in other.counts { result[key] = max(result[key] ?? 0, n) }
        return Self(result)
    }

    /// One more version by `device`.
    public func incremented(_ device: UUID) -> Self {
        var result = counts
        result[device.uuidString, default: 0] += 1
        return Self(result)
    }

    public var devices: [UUID] { counts.keys.compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString } }
}

/// One version of a note, as sealed in its record. `removed`: the note isn't pinned any more on the Mac that made it (its
/// row was deleted, unpinned or its Space deleted there). A removal carries no text; it never deletes a note anywhere by
/// itself (rows do that), and an edit it didn't see wins over it (docs/sync.md, "Conflicts").
public struct SyncNoteVersion: Codable, Hashable, Sendable {
    public var format = 1
    public var note: String
    public var stamp: SyncStamp
    public var vector: SyncNoteVector
    public var removed: Bool
    public var title: String?
    public var document: NoteDocument?
    public var created: Date?
    public var updated: Date?

    public init(note: String, stamp: SyncStamp, vector: SyncNoteVector, removed: Bool, title: String? = nil,
                document: NoteDocument? = nil, created: Date? = nil, updated: Date? = nil) {
        self.note = note; self.stamp = stamp; self.vector = vector; self.removed = removed
        self.title = removed ? nil : title
        self.document = removed ? nil : document
        self.created = created; self.updated = updated
    }

    /// The digest of the title and the whole document (styles, links, checkboxes, and each picture's file and size): what
    /// a Mac compares to tell an edit from what it last synced.
    public var digest: String? { document.map { SyncNotes.digest(title: title, document: $0) } }
}

/// A sealed note record: what CloudKit stores (`SyncNote`). Only the record's own device writes it.
public struct SyncNoteRecord: Codable, Hashable, Sendable {
    public var group: UUID
    public var device: UUID
    public var note: String
    public var format: Int
    public var sealed: Data

    public init(group: UUID, device: UUID, note: String, format: Int = 1, sealed: Data) {
        self.group = group; self.device = device; self.note = note; self.format = format; self.sealed = sealed
    }

    public var name: String { SyncCloudSchema.noteName(device: device, note: note) }

    private static func authentication(format: Int, group: UUID, device: UUID, note: String) -> Data {
        Data("Airc-note|\(format)|\(group.uuidString)|\(device.uuidString)|\(note)".utf8)
    }

    /// `device` publishes `version` (its own, or in a recovery another Mac's that it holds).
    public static func seal(_ version: SyncNoteVersion, group: UUID, device: UUID, key: SymmetricKey) throws -> Self {
        guard SyncNotes.isValidNoteID(version.note) else { throw SyncError.invalidOperation }
        let plain = try JSONEncoder().encode(version)
        let box = try AES.GCM.seal(plain, using: key,
                                   authenticating: authentication(format: version.format, group: group, device: device, note: version.note))
        guard let combined = box.combined else { throw SyncError.invalidEnvelope }
        return Self(group: group, device: device, note: version.note, format: version.format, sealed: combined)
    }

    public func open(group expected: UUID, key: SymmetricKey) throws -> SyncNoteVersion {
        guard format == 1 else { throw SyncError.unsupportedVersion }
        guard group == expected else { throw SyncError.wrongGroup }
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: key, authenticating: Self.authentication(format: format, group: group, device: device, note: note))
        let version = try JSONDecoder().decode(SyncNoteVersion.self, from: plain)
        guard version.note == note, version.format == format, version.removed || version.document != nil else {
            throw SyncError.invalidEnvelope
        }
        return version
    }
}

/// A picture of a note, sealed (`SyncNoteAsset`). Created once by whichever Mac uploads it first; never changed.
public struct SyncNoteAsset: Hashable, Sendable {
    public var name: String
    public var group: UUID
    public var sealed: Data

    public init(name: String, group: UUID, sealed: Data) { self.name = name; self.group = group; self.sealed = sealed }

    /// The record name for picture file `file` (`<sha256>.<ext>`): keyed, so it says nothing about the picture.
    public static func name(for file: String, key: SymmetricKey) -> String {
        let names = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("Airc note picture names".utf8), outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(file.utf8), using: names)
        return "noteasset." + Data(mac).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    private static func authentication(group: UUID, name: String) -> Data { Data("Airc-note-picture|\(group.uuidString)|\(name)".utf8) }

    public static func seal(_ data: Data, file: String, group: UUID, key: SymmetricKey) throws -> Self {
        let recordName = Self.name(for: file, key: key)
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: authentication(group: group, name: recordName)).combined else {
            throw SyncError.invalidEnvelope
        }
        return Self(name: recordName, group: group, sealed: combined)
    }

    /// The picture's bytes, only if they are file `file`'s: its SHA-256 is the file name.
    public func open(file: String, group expected: UUID, key: SymmetricKey) throws -> Data {
        guard group == expected, name == Self.name(for: file, key: key) else { throw SyncError.wrongGroup }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: Self.authentication(group: group, name: name))
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard NoteImage.isValidFile(file), file.hasPrefix(hex + ".") else { throw SyncError.invalidEnvelope }
        return data
    }
}

// MARK: - Limits and helpers

public enum SyncNotes {
    /// A sealed note version up to this size goes in the record itself; CloudKit allows 1 MB of fields per record.
    public static let inlineBytes = 256 * 1024
    /// Larger ones go in a CKAsset of the record, up to this size. A note whose text is larger still (far past any
    /// real note; pictures don't count) keeps syncing its row, but not its text, and Settings → Sync says so.
    public static let maxNoteBytes = 8 * 1024 * 1024
    /// Pictures larger than this stay on this Mac; other Macs show "Picture not on this Mac" in their place.
    public static let maxPictureBytes = 32 * 1024 * 1024
    /// Pictures fetched in one cycle at most (the rest next cycle).
    public static let picturesPerCycle = 24

    /// Note IDs this build writes and reads in record names (`newID()`: a lowercase UUID).
    public static func isValidNoteID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func digest(title: String?, document: NoteDocument) -> String {
        struct Content: Encodable { var title: String?; var document: NoteDocument }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Content(title: title, document: document))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ note: Note) -> String { digest(title: note.title, document: note.document) }

    /// The notes that sync from this store: note ID → its pinned items that sync (in a listed Space; a pane of a pinned
    /// split too, since splits sync, P14b2).
    /// A note only in Today or the Archive stays on this Mac, like a Today tab.
    public static func pinnedNotes(_ state: StoreState) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for item in state.items.values {
            guard let id = NoteURL.noteID(item.savedURL), isValidNoteID(id), case .pinned(let space) = item.container,
                  let s = state.spaces[space], !s.isBlankWindow else { continue }
            // A split with an Easel pane stays on this Mac as a whole (SyncStoreAdapter.isLocalOnly), a note in it too.
            if SyncStoreAdapter.isLocalOnly(item, in: state) { continue }
            result[id, default: []].append(item.id)
        }
        for key in result.keys { result[key]?.sort() }
        return result
    }
}

/// Where a Mac keeps note pictures (the data folder's Notes/Images): files named by their SHA-256 (NoteImage.file).
public struct SyncNotePictureFolder: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public func has(_ file: String) -> Bool {
        NoteImage.isValidFile(file) && FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }

    public func data(_ file: String) -> Data? {
        guard NoteImage.isValidFile(file) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(file))
    }

    /// Writes a picture another Mac sent (already checked against its name). Never replaces a file that's there.
    public func save(_ data: Data, file: String) throws {
        guard NoteImage.isValidFile(file) else { throw SyncError.invalidEnvelope }
        let target = folder.appendingPathComponent(file)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
}

// MARK: - Record mapping

extension SyncCloudSchema {
    public static let note = "SyncNote"
    public static let noteAsset = "SyncNoteAsset"

    public static func noteName(device: UUID, note: String) -> String { "note." + device.uuidString + "." + note }

    public static func record(_ note: SyncNoteRecord) -> SyncCloudRecord {
        var fields: [String: SyncCloudValue] = [
            "group": .string(note.group.uuidString), "device": .string(note.device.uuidString),
            "note": .string(note.note), "version": .int(Int64(note.format)),
        ]
        // Larger versions go in an asset: a record's fields hold at most 1 MB.
        if note.sealed.count <= SyncNotes.inlineBytes { fields["sealed"] = .bytes(note.sealed) } else { fields["payload"] = .asset(note.sealed) }
        return SyncCloudRecord(name: note.name, type: self.note, fields: fields)
    }

    /// nil for anything malformed or written under another device's name.
    public static func note(_ record: SyncCloudRecord) -> SyncNoteRecord? {
        guard record.type == note, let group = record.string("group").flatMap(UUID.init(uuidString:)),
              let device = record.string("device").flatMap(UUID.init(uuidString:)),
              let id = record.string("note"), SyncNotes.isValidNoteID(id), let format = record.int("version"),
              let sealed = record.bytes("sealed") ?? record.asset("payload") else { return nil }
        let result = SyncNoteRecord(group: group, device: device, note: id, format: Int(format), sealed: sealed)
        return record.name == result.name ? result : nil
    }

    public static func record(_ asset: SyncNoteAsset) -> SyncCloudRecord {
        SyncCloudRecord(name: asset.name, type: noteAsset, fields: [
            "group": .string(asset.group.uuidString), "version": .int(1), "data": .asset(asset.sealed),
        ])
    }

    public static func noteAsset(_ record: SyncCloudRecord) -> SyncNoteAsset? {
        guard record.type == noteAsset, record.name.hasPrefix("noteasset."), record.int("version") == 1,
              let group = record.string("group").flatMap(UUID.init(uuidString:)), let data = record.asset("data") else { return nil }
        return SyncNoteAsset(name: record.name, group: group, sealed: data)
    }
}

// MARK: - The store's side

extension SpacesStore {
    /// Another Mac's version of a note: its text and title here, its rows renamed after it. Not an undo step (as typing
    /// isn't), on disk at once.
    public func applySyncedNote(_ id: String, title: String?, document: NoteDocument, created: Date?, updated: Date?) throws {
        var n = note(id) ?? Note(id: id, createdAt: created ?? now())
        n.document = document
        n.title = Note.cleanTitle(title)
        if let created { n.createdAt = created }
        n.updatedAt = updated ?? now()
        guard note(id) != n else { return }
        try perform(nil, contentOnly: true) {
            put(n)
            renameRows(of: n)
        }
    }

    /// A note kept against a removal elsewhere whose row already went here: pinned again at the bottom of the first
    /// Space's pinned tabs.
    public func repinNote(_ id: String) throws {
        guard let n = note(id), let space = orderedSpaces.first(where: { !$0.isBlankWindow }) else { throw StoreError.notFound }
        let container = ItemContainer.pinned(spaceID: space.id)
        let siblings = children(of: container, parent: nil)
        try perform(nil) {
            put(Item(kind: .tab, container: container, parentID: nil, order: Ordering.insertion(at: siblings.count, in: siblings.map(\.order)),
                     savedURL: n.url, pageTitle: n.displayTitle, createdAt: now()))
        }
    }

    /// A conflict this Mac's version lost (docs/sync.md, "Conflicts"): its text as a note of its own, pinned just below
    /// the note's row (or at the bottom of the first Space's pinned tabs), named "<title> (conflicted copy, <Mac>)".
    @discardableResult
    public func createConflictedCopy(of id: String, title: String?, document: NoteDocument, device: String) throws -> String {
        let name = (Note.cleanTitle(title) ?? (document.title.isEmpty ? NoteURL.untitled : document.title))
        let copy = Note(document: document, title: "\(name) (conflicted copy, \(device))", createdAt: now())
        let url = NoteURL.make(id)
        // A note that is a split's pane: the copy goes below the split, never in it as one more pane.
        let anchor = state.items.values.filter { $0.savedURL == url && $0.spaceID != nil }.sorted { $0.id < $1.id }.first
            .map { splitItem(ofPane: $0.id) ?? $0 }
        let container: ItemContainer, parent: String?, order: Double
        if let anchor, case .pinned = anchor.container {
            let siblings = children(of: anchor.container, parent: anchor.parentID)
            let i = siblings.firstIndex { $0.id == anchor.id } ?? siblings.count - 1
            container = anchor.container; parent = anchor.parentID
            order = Ordering.between(anchor.order, i + 1 < siblings.count ? siblings[i + 1].order : nil)
        } else {
            guard let space = orderedSpaces.first(where: { !$0.isBlankWindow }) else { throw StoreError.notFound }
            container = .pinned(spaceID: space.id); parent = nil
            let siblings = children(of: container, parent: nil)
            order = Ordering.insertion(at: siblings.count, in: siblings.map(\.order))
        }
        try perform(nil) {
            put(copy)
            put(Item(kind: .tab, container: container, parentID: parent, order: order, savedURL: copy.url,
                     pageTitle: copy.displayTitle, createdAt: now()))
        }
        return copy.id
    }
}
