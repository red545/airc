// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import os

// SpacesStore: the one source of truth for profiles, Spaces, sidebar items, tabs and the archive
// (SET-2). State lives in memory; every change is written to SQLite in one transaction as
// (1) the entity's current value and (2) an operation-log entry with a timestamp and device ID,
// so sync can replay the log later without a migration. Arc's tab rules are in StoreActions.swift.

public enum EntityKind: String, Codable, Sendable, CaseIterable {
    case profile, space, item, tab, archive, split
}

/// Everything the store holds, keyed by ID.
public struct StoreState: Codable, Hashable, Sendable {
    public var profiles: [String: Profile] = [:]
    public var spaces: [String: Space] = [:]
    public var items: [String: Item] = [:]
    public var tabs: [String: LiveTab] = [:]
    public var archive: [String: ArchiveEntry] = [:]
    /// SV-1: Split Views (Splits.swift). Older stores and backups have none.
    public var splits: [String: Split] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case profiles, spaces, items, tabs, archive, splits }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([String: Profile].self, forKey: .profiles)
        spaces = try c.decode([String: Space].self, forKey: .spaces)
        items = try c.decode([String: Item].self, forKey: .items)
        tabs = try c.decode([String: LiveTab].self, forKey: .tabs)
        archive = try c.decode([String: ArchiveEntry].self, forKey: .archive)
        splits = try c.decodeIfPresent([String: Split].self, forKey: .splits) ?? [:]
    }
}

public protocol StoreEntity: Codable, Hashable, Sendable, Identifiable where ID == String {
    static var entityKind: EntityKind { get }
    static var stateKeyPath: WritableKeyPath<StoreState, [String: Self]> { get }
}

extension Profile: StoreEntity {
    public static var entityKind: EntityKind { .profile }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: Profile]> { \.profiles }
}
extension Space: StoreEntity {
    public static var entityKind: EntityKind { .space }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: Space]> { \.spaces }
}
extension Item: StoreEntity {
    public static var entityKind: EntityKind { .item }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: Item]> { \.items }
}
extension LiveTab: StoreEntity {
    public static var entityKind: EntityKind { .tab }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: LiveTab]> { \.tabs }
}
extension ArchiveEntry: StoreEntity {
    public static var entityKind: EntityKind { .archive }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: ArchiveEntry]> { \.archive }
}
extension Split: StoreEntity {
    public static var entityKind: EntityKind { .split }
    public static var stateKeyPath: WritableKeyPath<StoreState, [String: Split]> { \.splits }
}

public struct EntityRef: Hashable, Sendable {
    public var kind: EntityKind
    public var id: String
}

/// A value as it was before a transaction touched it (nil = it didn't exist).
enum EntitySnapshot: Hashable, Sendable {
    case profile(Profile?), space(Space?), item(Item?), tab(LiveTab?), archive(ArchiveEntry?), split(Split?)
}

/// What a transaction changed. Observers use it to refresh only what they show.
public struct StoreChange: Sendable {
    public var refs: Set<EntityRef>
    public var kinds: Set<EntityKind> { Set(refs.map(\.kind)) }
    public var windowStateChanged: Bool
    /// Only what a page showed changed (its URL, title or icon): nothing moved, appeared or went away. The sidebar
    /// refreshes those rows instead of rebuilding (code review M3).
    public var contentOnly = false
    public func touches(_ kind: EntityKind) -> Bool { refs.contains { $0.kind == kind } }
}

/// A row on disk that this build can't use: undecodable (damaged, or written by a newer Airc), or hanging off such
/// a row (a Space whose profile is unreadable, a pinned tab in an unreadable folder). It stays on disk byte for
/// byte and is hidden in memory; nothing here deletes or "repairs" it (code review H4).
public struct UnreadableRow: Hashable, Sendable {
    public var kind: String
    public var id: String
    public var reason: String
}

public enum StoreError: Error, Equatable, Sendable {
    case notFound
    case invalidProfileName
    case profileNameTaken
    case cannotDeleteDefaultProfile
    case profileInUse
    case cannotDeleteLastSpace
    case favoritesFull
    case invalidMove
    /// SV-1: a split already has four panes (Arc's limit).
    case splitFull
}

public final class SpacesStore {
    public static let schemaVersion = 1
    public static let maxFavorites = 12
    public static let maxUndo = 50

    public private(set) var state = StoreState()
    public private(set) var windowState = WindowState()
    public let deviceID: String
    /// Injected for tests.
    public var now: () -> Date = Date.init

    private let db: Database
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    // Transaction bookkeeping.
    private var txDepth = 0
    private var txBefore: [EntityRef: EntitySnapshot] = [:]
    private var txChanged: Set<EntityRef> = []
    private var txLabel: String?
    private var txUndoable = false
    private var txDeferred = true
    private var txWindowChanged = false
    private var txContentOnly = false
    /// Changes waiting for `flush()` (tab title/URL updates are written lazily).
    private var pendingWrites: Set<EntityRef> = []
    /// Called (on the caller's thread) the first time a write fails; the app says so once (code review M4). The
    /// failed changes stay pending and are retried by the next flush.
    public var onWriteFailure: ((Error) -> Void)?
    private var reportedWriteFailure = false
    /// Tests: the next `n` flushes fail as if SQLite did.
    var failNextFlushes = 0
    /// Window state changed with `deferred: true`, written by the next `flush()`.
    private var windowStateDirty = false

    public struct UndoEntry: Sendable {
        public var label: String
        var before: [EntityRef: EntitySnapshot]
    }
    public private(set) var undoStack: [UndoEntry] = []

    private var observers: [Int: (StoreChange) -> Void] = [:]
    private var nextObserver = 0
    private var cachedTabByItem: [String: String]?

    /// Rows kept on disk but hidden in memory (H4). The app tells the user once that some data is waiting for a
    /// newer Airc.
    public private(set) var unreadableRows: [UnreadableRow] = []
    private var hidden: Set<EntityRef> = []
    /// Rows whose body on disk is exactly what this build writes for them, so a write can skip the merge.
    private var cleanOnDisk: Set<EntityRef> = []
    /// The schema the data was last written with, when that's newer than this build's.
    public private(set) var newerSchemaVersion: Int?
    private static let log = Logger(subsystem: "org.airc.Airc", category: "store")

    /// Opens (or creates) the store at `path`. `nil` keeps it in memory, for tests.
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        db = try Database(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS entities(
              kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, ts REAL NOT NULL,
              PRIMARY KEY(kind, id));
            CREATE TABLE IF NOT EXISTS ops(
              seq INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, device TEXT NOT NULL,
              kind TEXT NOT NULL, id TEXT NOT NULL, op TEXT NOT NULL, body TEXT);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        if let d = try db.query("SELECT value FROM meta WHERE key='device'").first?.first as? String {
            deviceID = d
        } else {
            deviceID = newID()
            try db.run("INSERT INTO meta(key, value) VALUES('device', ?)", [.text(deviceID)])
        }
        // An older build never lowers the schema mark, so the newer one still knows its data was opened elsewhere.
        let stored = (try db.query("SELECT value FROM meta WHERE key='schema'").first?.first as? String).flatMap { Int($0) }
        if let stored, stored > Self.schemaVersion {
            newerSchemaVersion = stored
            Self.log.warning("store written by schema \(stored, privacy: .public); this build reads \(Self.schemaVersion, privacy: .public)")
        } else {
            try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('schema', ?)", [.text("\(Self.schemaVersion)")])
        }
        try load()
        try repair()
    }

    // MARK: Loading

    private func load() throws {
        var s = StoreState()
        var unreadable: [UnreadableRow] = []
        for row in try db.query("SELECT kind, id, body FROM entities") {
            guard let kindRaw = row[0] as? String, let id = row[1] as? String else { continue }
            guard let kind = EntityKind(rawValue: kindRaw) else {
                unreadable.append(UnreadableRow(kind: kindRaw, id: id, reason: "unknown kind"))
                continue
            }
            guard let body = (row[2] as? String)?.data(using: .utf8) else {
                unreadable.append(UnreadableRow(kind: kindRaw, id: id, reason: "no body"))
                continue
            }
            do {
                switch kind {
                case .profile: let v = try decoder.decode(Profile.self, from: body); s.profiles[v.id] = v
                case .space: let v = try decoder.decode(Space.self, from: body); s.spaces[v.id] = v
                case .item: let v = try decoder.decode(Item.self, from: body); s.items[v.id] = v
                case .tab: let v = try decoder.decode(LiveTab.self, from: body); s.tabs[v.id] = v
                case .archive: let v = try decoder.decode(ArchiveEntry.self, from: body); s.archive[v.id] = v
                case .split: let v = try decoder.decode(Split.self, from: body); s.splits[v.id] = v
                }
            } catch {
                unreadable.append(UnreadableRow(kind: kindRaw, id: id, reason: Self.describe(error)))
            }
        }
        hideDependents(in: &s, unreadable: &unreadable)
        for r in unreadable {
            Self.log.warning("kept unreadable \(r.kind, privacy: .public) row \(r.id, privacy: .public) on disk: \(r.reason, privacy: .public)")
        }
        unreadableRows = unreadable
        hidden = Set(unreadable.compactMap { r in EntityKind(rawValue: r.kind).map { EntityRef(kind: $0, id: r.id) } })
        state = s
        if let w = try db.query("SELECT value FROM meta WHERE key='window'").first?.first as? String,
           let data = w.data(using: .utf8), let ws = try? decoder.decode(WindowState.self, from: data) {
            windowState = ws
        }
    }

    /// Hides everything that hangs off an unreadable row, so `repair()` doesn't take the missing parent for a deleted
    /// one (and move its Spaces to the default profile, or delete its pinned tabs).
    private func hideDependents(in s: inout StoreState, unreadable: inout [UnreadableRow]) {
        var profiles = Set(unreadable.filter { $0.kind == EntityKind.profile.rawValue }.map(\.id))
        var spaces = Set(unreadable.filter { $0.kind == EntityKind.space.rawValue }.map(\.id))
        var items = Set(unreadable.filter { $0.kind == EntityKind.item.rawValue }.map(\.id))
        guard !(profiles.isEmpty && spaces.isEmpty && items.isEmpty) else { return }
        func hide(_ kind: EntityKind, _ id: String, _ why: String) {
            unreadable.append(UnreadableRow(kind: kind.rawValue, id: id, reason: why))
        }
        for sp in s.spaces.values where profiles.contains(sp.profileID) {
            s.spaces[sp.id] = nil; spaces.insert(sp.id); hide(.space, sp.id, "its profile is unreadable")
        }
        var changed = true
        while changed {
            changed = false
            for item in s.items.values {
                let why: String? = switch item.container {
                case .pinned(let sid) where spaces.contains(sid): "its Space is unreadable"
                case .favorites(let pid) where profiles.contains(pid): "its profile is unreadable"
                default: item.parentID.map { items.contains($0) } == true ? "its folder is unreadable" : nil
                }
                if let why { s.items[item.id] = nil; items.insert(item.id); hide(.item, item.id, why); changed = true }
            }
        }
        for t in s.tabs.values {
            let why: String? = if let i = t.itemID, items.contains(i) { "its sidebar item is unreadable" }
                else if let sid = t.spaceID, spaces.contains(sid) { "its Space is unreadable" }
                else if profiles.contains(t.profileID) { "its profile is unreadable" }
                else { nil }
            if let why { s.tabs[t.id] = nil; hide(.tab, t.id, why) }
        }
        for a in s.archive.values where profiles.contains(a.profileID) {
            s.archive[a.id] = nil; hide(.archive, a.id, "its profile is unreadable")
        }
        for x in s.splits.values where spaces.contains(x.spaceID) {
            s.splits[x.id] = nil; hide(.split, x.id, "its Space is unreadable")
        }
        profiles.removeAll()
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return "\(error)" }
        switch e {
        case .keyNotFound(let k, let c): return "missing \((c.codingPath + [k]).map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
            return "bad value at \(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)"
        @unknown default: return "\(error)"
        }
    }

    /// Makes the invariants true without deleting anything (H4): a default profile, at least one Space, every Space
    /// on an existing profile ("Missing Profile" falls back to Default, as Arc does), every tab on its Space's or
    /// Favorite's profile. Items and tabs whose parent is gone stay on disk and are only hidden.
    private func repair() throws {
        var orphans: [UnreadableRow] = []
        try perform(nil) {
            if !state.profiles.values.contains(where: \.isDefault) {
                if let first = state.profiles.values.sorted(by: { $0.createdAt < $1.createdAt }).first {
                    var p = first; p.isDefault = true; put(p)
                } else {
                    put(Profile(name: "Personal", emoji: "", color: RGBA(hex: "7EB6D5")!, isDefault: true,
                                createdAt: now()))
                }
            }
            let def = defaultProfile
            if state.spaces.isEmpty {
                put(Space(name: "Personal", icon: nil, theme: .neutral, profileID: def.id, order: 0, createdAt: now()))
            }
            for var s in state.spaces.values where state.profiles[s.profileID] == nil {
                s.profileID = def.id
                put(s)
            }
            // Items whose container is gone are hidden with their subtree, never deleted.
            var gone = Set<String>()
            var changed = true
            while changed {
                changed = false
                for item in state.items.values where !gone.contains(item.id) {
                    let missing: Bool = switch item.container {
                    case .pinned(let sid): state.spaces[sid] == nil
                    case .favorites(let pid): state.profiles[pid] == nil
                    }
                    if missing || item.parentID.map(gone.contains) == true {
                        gone.insert(item.id); changed = true
                    }
                }
            }
            for id in gone {
                state.items[id] = nil
                orphans.append(UnreadableRow(kind: EntityKind.item.rawValue, id: id, reason: "its container is missing"))
            }
            for item in state.items.values {
                // SV-2: a split's panes hang off it like a folder's children, in the split's own container.
                if let p = item.parentID, let parent = state.items[p], parent.kind == .split, item.kind == .tab {
                    if item.container != parent.container { var i = item; i.container = parent.container; put(i) }
                } else if let p = item.parentID, state.items[p]?.kind != .folder {
                    var i = item; i.parentID = nil; put(i)
                }
            }
            for tab in state.tabs.values {
                let expected: String?
                if let iid = tab.itemID {
                    guard let item = state.items[iid] else {
                        state.tabs[tab.id] = nil
                        orphans.append(UnreadableRow(kind: EntityKind.tab.rawValue, id: tab.id, reason: "its sidebar item is missing"))
                        continue
                    }
                    switch item.container {
                    case .pinned(let sid): expected = state.spaces[sid]?.profileID
                    case .favorites(let pid): expected = pid
                    }
                } else if let sid = tab.spaceID, let sp = state.spaces[sid] {
                    expected = sp.profileID
                } else {
                    state.tabs[tab.id] = nil
                    orphans.append(UnreadableRow(kind: EntityKind.tab.rawValue, id: tab.id, reason: "its Space is missing"))
                    continue
                }
                if let expected, tab.profileID != expected {
                    var t = tab; t.profileID = expected; put(t)
                }
            }
            // SV-1: a split needs its Space and at least two of its tabs; a tab is in one split at most (the oldest).
            var claimed = Set<String>()
            for x in state.splits.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
                let members = x.tabIDs.filter { state.tabs[$0] != nil && !claimed.contains($0) }
                if state.spaces[x.spaceID] == nil || Set(members).count < 2 {
                    state.splits[x.id] = nil
                    orphans.append(UnreadableRow(kind: EntityKind.split.rawValue, id: x.id,
                                                 reason: state.spaces[x.spaceID] == nil ? "its Space is missing" : "fewer than two of its tabs are left"))
                    continue
                }
                claimed.formUnion(members)
                if members != x.tabIDs || !x.isNormalized { var y = x; y.keep(members); put(y) }
            }
            if windowState.selectedSpaceID.flatMap({ state.spaces[$0] }) == nil {
                windowState.selectedSpaceID = orderedSpaces.first?.id
                txWindowChanged = true
            }
        }
        cachedTabByItem = nil
        for r in orphans {
            Self.log.warning("kept orphaned \(r.kind, privacy: .public) row \(r.id, privacy: .public) on disk: \(r.reason, privacy: .public)")
            if let k = EntityKind(rawValue: r.kind) { hidden.insert(EntityRef(kind: k, id: r.id)) }
        }
        unreadableRows += orphans
    }

    // MARK: Observers

    @discardableResult
    public func observe(_ block: @escaping (StoreChange) -> Void) -> Int {
        nextObserver += 1
        observers[nextObserver] = block
        return nextObserver
    }

    public func removeObserver(_ token: Int) { observers[token] = nil }

    // MARK: Transactions

    /// Runs `body` as one transaction. Nested calls join the outer one. With `undoable`, the
    /// before-images of everything it touched go on the undo stack under `label`.
    /// `deferred` writes wait for `flush()` (for high-frequency engine updates).
    @discardableResult
    public func perform<R>(_ label: String?, undoable: Bool = false, deferred: Bool = false, contentOnly: Bool = false,
                           _ body: () throws -> R) throws -> R {
        if txDepth == 0 {
            txBefore = [:]
            txChanged = []
            txLabel = label
            txUndoable = undoable
            txDeferred = deferred
            txWindowChanged = false
            txContentOnly = contentOnly
        } else {
            if undoable && !txUndoable {
                txUndoable = true
                txLabel = label
            }
            if !contentOnly { txContentOnly = false }
        }
        txDepth += 1
        let result: R
        do {
            result = try body()
        } catch {
            txDepth -= 1
            if txDepth == 0 { rollback() }
            throw error
        }
        txDepth -= 1
        if txDepth == 0 { try commit() }
        return result
    }

    private func rollback() {
        for (ref, snap) in txBefore { apply(snap, id: ref.id) }
        txBefore = [:]
        txChanged = []
        cachedTabByItem = nil
    }

    private func commit() throws {
        let changed = txChanged
        let windowChanged = txWindowChanged
        if txUndoable, let label = txLabel, !txBefore.isEmpty {
            undoStack.append(UndoEntry(label: label, before: txBefore))
            if undoStack.count > Self.maxUndo { undoStack.removeFirst(undoStack.count - Self.maxUndo) }
        }
        if txDeferred {
            pendingWrites.formUnion(changed)
        } else {
            pendingWrites.formUnion(changed)
            try flush()
        }
        if windowChanged { try saveWindowState() }
        txBefore = [:]
        txChanged = []
        guard !changed.isEmpty || windowChanged else { return }
        let change = StoreChange(refs: changed, windowStateChanged: windowChanged, contentOnly: txContentOnly && !windowChanged)
        for o in observers.sorted(by: { $0.key < $1.key }) { o.value(change) }
    }

    /// Writes pending changes and their op-log entries in one SQLite transaction.
    public func flush() throws {
        if windowStateDirty {
            windowStateDirty = false
            try saveWindowState()
        }
        guard !pendingWrites.isEmpty else { return }
        let refs = pendingWrites
        let ts = now().timeIntervalSince1970
        do {
            try writePending(refs, ts: ts)
        } catch {
            // Memory still has the changes; they stay pending, so the next flush retries them.
            if !reportedWriteFailure {
                reportedWriteFailure = true
                Self.log.error("store write failed: \(String(describing: error), privacy: .public)")
                onWriteFailure?(error)
            }
            throw error
        }
        pendingWrites.subtract(refs)
        reportedWriteFailure = false
    }

    private func writePending(_ refs: Set<EntityRef>, ts: Double) throws {
        if failNextFlushes > 0 {
            failNextFlushes -= 1
            throw Database.DBError.step("injected failure")
        }
        try db.transaction {
            for ref in refs.sorted(by: { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }) {
                // A row this build couldn't read is never overwritten or deleted (H4).
                if hidden.contains(ref) { continue }
                if var body = try encodedBody(ref) {
                    body = try preservingUnknownFields(ref, body)
                    try db.run("INSERT OR REPLACE INTO entities(kind, id, body, ts) VALUES(?,?,?,?)",
                               [.text(ref.kind.rawValue), .text(ref.id), .text(body), .real(ts)])
                    try db.run("INSERT INTO ops(ts, device, kind, id, op, body) VALUES(?,?,?,?,'put',?)",
                               [.real(ts), .text(deviceID), .text(ref.kind.rawValue), .text(ref.id), .text(body)])
                } else {
                    try db.run("DELETE FROM entities WHERE kind=? AND id=?", [.text(ref.kind.rawValue), .text(ref.id)])
                    try db.run("INSERT INTO ops(ts, device, kind, id, op, body) VALUES(?,?,?,?,'delete',NULL)",
                               [.real(ts), .text(deviceID), .text(ref.kind.rawValue), .text(ref.id)])
                }
            }
        }
    }

    public var hasPendingWrites: Bool { !pendingWrites.isEmpty || windowStateDirty }

    private func encodedBody(_ ref: EntityRef) throws -> String? {
        let data: Data?
        switch ref.kind {
        case .profile: data = try state.profiles[ref.id].map { try encoder.encode($0) }
        case .space: data = try state.spaces[ref.id].map { try encoder.encode($0) }
        case .item: data = try state.items[ref.id].map { try encoder.encode($0) }
        case .tab: data = try state.tabs[ref.id].map { try encoder.encode($0) }
        case .archive: data = try state.archive[ref.id].map { try encoder.encode($0) }
        case .split: data = try state.splits[ref.id].map { try encoder.encode($0) }
        }
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Fields a newer Airc wrote (an unknown key, an enum case this build reads as its default) survive a write from
    /// this build: every field this build didn't change since it read the row keeps its stored value (H4).
    private func preservingUnknownFields(_ ref: EntityRef, _ body: String) throws -> String {
        if cleanOnDisk.contains(ref) { return body }
        guard let raw = try db.query("SELECT body FROM entities WHERE kind=? AND id=?",
                                     [.text(ref.kind.rawValue), .text(ref.id)]).first?.first as? String,
              raw != body, let loaded = reencoded(ref.kind, raw), loaded != raw else {
            cleanOnDisk.insert(ref)
            return body
        }
        let merged = Self.merge(raw: raw, loaded: loaded, current: body)
        if merged == body { cleanOnDisk.insert(ref) }
        return merged
    }

    /// What this build makes of a stored body: decoded, then encoded again.
    private func reencoded(_ kind: EntityKind, _ raw: String) -> String? {
        let data = Data(raw.utf8)
        let out: Data?
        switch kind {
        case .profile: out = try? encoder.encode(decoder.decode(Profile.self, from: data))
        case .space: out = try? encoder.encode(decoder.decode(Space.self, from: data))
        case .item: out = try? encoder.encode(decoder.decode(Item.self, from: data))
        case .tab: out = try? encoder.encode(decoder.decode(LiveTab.self, from: data))
        case .archive: out = try? encoder.encode(decoder.decode(ArchiveEntry.self, from: data))
        case .split: out = try? encoder.encode(decoder.decode(Split.self, from: data))
        }
        return out.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Three-way merge of JSON bodies: `raw` is on disk, `loaded` is what this build read from it, `current` is what
    /// it wants to write. A subtree this build didn't change keeps its stored form; changed values are written.
    static func merge(raw: String, loaded: String, current: String) -> String {
        func obj(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }
        guard let r = obj(raw), let l = obj(loaded), let c = obj(current) else { return current }
        func merge(_ r: Any, _ l: Any?, _ c: Any) -> Any {
            if let l, (l as AnyObject).isEqual(c) { return r }
            guard let rd = r as? [String: Any], let cd = c as? [String: Any],
                  !Set(rd.keys).isDisjoint(with: cd.keys) else { return c }
            let ld = l as? [String: Any] ?? [:]
            var out = rd
            for (k, cv) in cd { out[k] = rd[k].map { merge($0, ld[k], cv) } ?? cv }
            for k in ld.keys where cd[k] == nil { out[k] = nil }
            return out
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merge(r, l, c),
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return current }
        return String(decoding: data, as: UTF8.self)
    }

    private func snapshot(_ ref: EntityRef) -> EntitySnapshot {
        switch ref.kind {
        case .profile: .profile(state.profiles[ref.id])
        case .space: .space(state.spaces[ref.id])
        case .item: .item(state.items[ref.id])
        case .tab: .tab(state.tabs[ref.id])
        case .archive: .archive(state.archive[ref.id])
        case .split: .split(state.splits[ref.id])
        }
    }

    /// Restores raw state; used by rollback (outside a transaction's bookkeeping).
    private func apply(_ snap: EntitySnapshot, id: String) {
        switch snap {
        case .profile(let v): state.profiles[id] = v
        case .space(let v): state.spaces[id] = v
        case .item(let v): state.items[id] = v
        case .tab(let v): state.tabs[id] = v
        case .archive(let v): state.archive[id] = v
        case .split(let v): state.splits[id] = v
        }
    }

    private func touch(_ ref: EntityRef) {
        precondition(txDepth > 0, "SpacesStore writes must happen inside perform(_:)")
        if txBefore[ref] == nil { txBefore[ref] = snapshot(ref) }
        txChanged.insert(ref)
        if ref.kind == .tab || ref.kind == .item { cachedTabByItem = nil }
    }

    /// Inserts or replaces an entity. Only valid inside `perform`.
    public func put<T: StoreEntity>(_ value: T) {
        let ref = EntityRef(kind: T.entityKind, id: value.id)
        // Writing an entity with a hidden row's ID (a backup restore) takes that row over.
        if hidden.remove(ref) != nil { unreadableRows.removeAll { $0.kind == ref.kind.rawValue && $0.id == ref.id } }
        touch(ref)
        state[keyPath: T.stateKeyPath][value.id] = value
    }

    /// Deletes an entity. Only valid inside `perform`.
    public func remove<T: StoreEntity>(_ type: T.Type, _ id: String) {
        guard state[keyPath: T.stateKeyPath][id] != nil else { return }
        touch(EntityRef(kind: T.entityKind, id: id))
        state[keyPath: T.stateKeyPath][id] = nil
        // SV-1: a tab that goes (closed, archived, forgotten) leaves its split in the same transaction, so ⌘Z puts both
        // back; a split left with one pane is gone.
        if T.self == LiveTab.self { leaveSplit(id) }
    }

    // MARK: Undo (SB-23, SB-40, ⌘Z after close and archive)

    public var canUndo: Bool { !undoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }

    /// What ⌘Z did.
    public enum UndoResult: Equatable, Sendable {
        /// Restored. `movedTabs` went to a Space of the profile they were closed in, because their own Space uses
        /// another profile now.
        case restored(label: String, movedTabs: [String])
        /// Nothing changed, because a tab would have come back in a profile it wasn't closed in (code review H3).
        /// Closed Today tabs stay in the Archive.
        case refused(label: String, reason: String)

        public var label: String {
            switch self { case .restored(let l, _), .refused(let l, _): l }
        }
    }

    private struct UndoRefusal: Error { var reason: String }

    /// Restores everything the last undoable action touched. A tab only ever comes back in the profile it was closed in
    /// (H3): if its Space has moved to another profile, it goes to a Space of its own profile, or the undo is refused.
    @discardableResult
    public func undo() throws -> UndoResult? {
        guard let entry = undoStack.popLast() else { return nil }
        var moved: [String] = []
        do {
            try perform(nil) {
                for (ref, snap) in entry.before {
                    switch snap {
                    case .profile(let v): if let v { put(v) } else { remove(Profile.self, ref.id) }
                    case .space(let v): if let v { put(v) } else { remove(Space.self, ref.id) }
                    case .item(let v): if let v { put(v) } else { remove(Item.self, ref.id) }
                    case .tab(let v): if let v { put(v) } else { remove(LiveTab.self, ref.id) }
                    case .archive(let v): if let v { put(v) } else { remove(ArchiveEntry.self, ref.id) }
                    case .split(let v): if let v { put(v) } else { remove(Split.self, ref.id) }
                    }
                }
                moved = try keepRestoredTabsInTheirProfiles(entry.before)
            }
        } catch let r as UndoRefusal {
            return .refused(label: entry.label, reason: r.reason)
        }
        return .restored(label: entry.label, movedTabs: moved)
    }

    /// Inside undo's transaction: every restored tab must load in the profile it was closed in, and that must be its
    /// Space's (or Favorite's) profile. Throws `UndoRefusal` to roll the whole undo back.
    private func keepRestoredTabsInTheirProfiles(_ before: [EntityRef: EntitySnapshot]) throws -> [String] {
        for snap in before.values {
            if case .space(let v?) = snap, profile(v.profileID) == nil {
                throw UndoRefusal(reason: "Can't undo: the profile “\(v.name)” used was deleted")
            }
        }
        var moved: [String] = []
        var restoredAny = false
        for (ref, snap) in before.sorted(by: { $0.key.id < $1.key.id }) {
            guard case .tab(let old?) = snap, let t = tab(ref.id) else {
                if case .tab = snap {} else { restoredAny = true }
                continue
            }
            let target: String? = if let iid = t.itemID {
                switch item(iid)?.container {
                case .pinned(let sid)?: space(sid)?.profileID
                case .favorites(let pid)?: pid
                case nil: nil
                }
            } else {
                space(t.spaceID)?.profileID
            }
            if target == old.profileID { restoredAny = true; continue }
            guard profile(old.profileID) != nil else {
                throw UndoRefusal(reason: "Can't reopen “\(old.displayTitle)”: the profile it was closed in was deleted")
            }
            if t.itemID != nil {
                // A pinned tab's row stays in its Space; the page isn't brought back in the other profile. The row
                // opens fresh in the Space's profile when clicked.
                remove(LiveTab.self, t.id)
                continue
            }
            let home = space(windowState.selectedSpaceID).flatMap { $0.profileID == old.profileID ? $0 : nil }
                ?? spaces(usingProfile: old.profileID).first
            guard let home else {
                let name = profile(old.profileID)?.name ?? "its profile"
                throw UndoRefusal(reason: "Can't reopen “\(old.displayTitle)”: no Space uses \(name) now")
            }
            var m = t
            m.spaceID = home.id
            m.order = Ordering.between(nil, todayTabs(ofSpace: home.id).filter { $0.id != t.id }.first?.order)
            put(m)
            moved.append(t.id)
            restoredAny = true
        }
        guard restoredAny else {
            throw UndoRefusal(reason: "Can't reopen it here: this Space uses another profile now")
        }
        return moved
    }

    // MARK: Window state (device-local, not in the op log)

    public func updateWindowState(deferred: Bool = false, _ change: (inout WindowState) -> Void) {
        var w = windowState
        change(&w)
        guard w != windowState else { return }
        windowState = w
        if deferred {
            windowStateDirty = true
        } else if txDepth > 0 {
            txWindowChanged = true
        } else {
            try? saveWindowState()
            let c = StoreChange(refs: [], windowStateChanged: true)
            for o in observers.sorted(by: { $0.key < $1.key }) { o.value(c) }
        }
    }

    private func saveWindowState() throws {
        let body = String(decoding: try encoder.encode(windowState), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES('window', ?)", [.text(body)])
    }

    // MARK: Device-local values (not in the op log, never synced)

    /// A device-local value, e.g. the engine's spare profile folder (H6).
    public func localValue(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key=?", [.text("local." + key)]))?.first?.first as? String
    }

    public func setLocalValue(_ key: String, _ value: String?) {
        if let value {
            try? db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text("local." + key), .text(value)])
        } else {
            try? db.run("DELETE FROM meta WHERE key=?", [.text("local." + key)])
        }
    }

    /// True when any stored profile row names `directory` as its engine folder, including rows this build can't read
    /// (H4). Before deleting an engine folder, this is the check.
    public func storedProfileUses(engineDirectory directory: String) -> Bool {
        if state.profiles.values.contains(where: { $0.engineDirectory == directory }) { return true }
        let rows = (try? db.query("SELECT body FROM entities WHERE kind='profile'")) ?? []
        return rows.contains { ($0.first as? String)?.contains("\"\(directory)\"") ?? true }
    }

    // MARK: Op log access (for sync later, and tests)

    public struct Operation: Sendable, Equatable {
        public var seq: Int64
        public var timestamp: Date
        public var device: String
        public var kind: EntityKind
        public var id: String
        public var op: String
    }

    public func operations(since seq: Int64 = 0) throws -> [Operation] {
        try db.query("SELECT seq, ts, device, kind, id, op FROM ops WHERE seq > ? ORDER BY seq", [.int(seq)]).compactMap {
            guard let seq = $0[0] as? Int64, let ts = $0[1] as? Double, let dev = $0[2] as? String,
                  let k = ($0[3] as? String).flatMap(EntityKind.init(rawValue:)), let id = $0[4] as? String,
                  let op = $0[5] as? String else { return nil }
            return Operation(seq: seq, timestamp: Date(timeIntervalSince1970: ts), device: dev, kind: k, id: id, op: op)
        }
    }

    /// Archive retention (code review M5): entries older than `age` go, and at most `maxEntries` stay (newest kept).
    /// Returns how many were removed.
    @discardableResult
    public func pruneArchive(olderThan age: TimeInterval = 90 * 86400, maxEntries: Int = 5000) throws -> Int {
        let cutoff = now().addingTimeInterval(-age)
        let sorted = archivedEntries
        let victims = sorted.enumerated().filter { $0.offset >= maxEntries || $0.element.archivedAt < cutoff }.map(\.element.id)
        guard !victims.isEmpty else { return 0 }
        try perform(nil) { for id in victims { remove(ArchiveEntry.self, id) } }
        return victims.count
    }

    /// Drops op-log entries older than `age` that a later entry for the same entity supersedes.
    public func compactOperations(olderThan age: TimeInterval) throws {
        let cutoff = now().timeIntervalSince1970 - age
        try db.run("""
            DELETE FROM ops WHERE ts < ? AND seq NOT IN (SELECT MAX(seq) FROM ops GROUP BY kind, id)
            """, [.real(cutoff)])
    }

    // MARK: Backup (SET-3)

    public struct Backup: Codable, Sendable {
        public var version: Int
        public var exportedAt: Date
        public var device: String
        public var state: StoreState
    }

    public func exportJSON() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(Backup(version: Self.schemaVersion, exportedAt: now(), device: deviceID, state: state))
    }

    /// Writes `airc-backup-YYYY-MM-DD.json` into `directory` unless today's exists. Keeps `keep` files.
    @discardableResult
    public func backupIfNeeded(to directory: URL, keep: Int = 14) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        let url = directory.appendingPathComponent("airc-backup-\(f.string(from: now())).json")
        guard !fm.fileExists(atPath: url.path) else { return nil }
        try exportJSON().write(to: url, options: .atomic)
        let backups = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("airc-backup-") && $0.hasSuffix(".json") }
            .sorted()
        for old in backups.dropLast(keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
        return url
    }

    /// Replaces everything with a backup's contents (as one change in the op log).
    public func restore(fromBackup data: Data) throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let backup = try d.decode(Backup.self, from: data)
        try perform("Restore Backup") {
            for p in state.profiles.keys where backup.state.profiles[p] == nil { remove(Profile.self, p) }
            for s in state.spaces.keys where backup.state.spaces[s] == nil { remove(Space.self, s) }
            for i in state.items.keys where backup.state.items[i] == nil { remove(Item.self, i) }
            for t in state.tabs.keys where backup.state.tabs[t] == nil { remove(LiveTab.self, t) }
            for a in state.archive.keys where backup.state.archive[a] == nil { remove(ArchiveEntry.self, a) }
            for x in state.splits.keys where backup.state.splits[x] == nil { remove(Split.self, x) }
            backup.state.profiles.values.forEach { put($0) }
            backup.state.spaces.values.forEach { put($0) }
            backup.state.items.values.forEach { put($0) }
            backup.state.tabs.values.forEach { put($0) }
            backup.state.archive.values.forEach { put($0) }
            backup.state.splits.values.forEach { put($0) }
        }
        undoStack.removeAll()
        try repair()
    }

    // MARK: Basic queries

    public var defaultProfile: Profile {
        state.profiles.values.first(where: \.isDefault) ?? state.profiles.values.sorted { $0.createdAt < $1.createdAt }[0]
    }

    public var orderedProfiles: [Profile] {
        state.profiles.values.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }

    public var orderedSpaces: [Space] {
        state.spaces.values.sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) }
    }

    public func space(_ id: String?) -> Space? { id.flatMap { state.spaces[$0] } }
    public func profile(_ id: String?) -> Profile? { id.flatMap { state.profiles[$0] } }
    public func item(_ id: String?) -> Item? { id.flatMap { state.items[$0] } }
    public func tab(_ id: String?) -> LiveTab? { id.flatMap { state.tabs[$0] } }

    public var selectedSpace: Space {
        space(windowState.selectedSpaceID) ?? orderedSpaces[0]
    }

    public func profile(ofSpace id: String) -> Profile {
        profile(space(id)?.profileID) ?? defaultProfile
    }

    public func spaces(usingProfile id: String) -> [Space] {
        orderedSpaces.filter { $0.profileID == id }
    }

    /// Sibling items in a container, in display order.
    public func children(of container: ItemContainer, parent: String?) -> [Item] {
        state.items.values
            .filter { $0.container == container && $0.parentID == parent }
            .sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) }
    }

    public func favorites(ofProfile id: String) -> [Item] {
        children(of: .favorites(profileID: id), parent: nil)
    }

    public func pinnedRoots(ofSpace id: String) -> [Item] {
        children(of: .pinned(spaceID: id), parent: nil)
    }

    /// Today tabs of a Space, top first (SB-42).
    public func todayTabs(ofSpace id: String) -> [LiveTab] {
        state.tabs.values
            .filter { $0.itemID == nil && $0.spaceID == id }
            .sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) }
    }

    /// The live tab of a pinned item or Favorite, if it has one.
    public func liveTab(forItem id: String) -> LiveTab? {
        if cachedTabByItem == nil {
            var m: [String: String] = [:]
            for t in state.tabs.values { if let i = t.itemID { m[i] = t.id } }
            cachedTabByItem = m
        }
        return cachedTabByItem?[id].flatMap { state.tabs[$0] }
    }

    func removeItemTree(_ id: String) {
        for child in state.items.values where child.parentID == id { removeItemTree(child.id) }
        if let t = liveTab(forItem: id) { remove(LiveTab.self, t.id) }
        remove(Item.self, id)
    }
}

// MARK: - Fractional ordering

public enum Ordering {
    /// An order value between two neighbours (either may be missing).
    public static func between(_ a: Double?, _ b: Double?) -> Double {
        switch (a, b) {
        case (nil, nil): 0
        case (let a?, nil): a + 1
        case (nil, let b?): b - 1
        case (let a?, let b?): (a + b) / 2
        }
    }

    /// The order for inserting at `index` into `orders` (already sorted ascending).
    public static func insertion(at index: Int, in orders: [Double]) -> Double {
        let i = max(0, min(index, orders.count))
        return between(i > 0 ? orders[i - 1] : nil, i < orders.count ? orders[i] : nil)
    }
}
