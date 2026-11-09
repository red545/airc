// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Feed successive ordinary SpacesStore states after successful actions (or its existing observe callback).
/// Persist this value alongside SyncReplica. No private/Little Arc store may be supplied here.
/// There is deliberately no generic entity serialization, profile payload, archive payload or Boost export.
public struct SyncStoreAdapter: Codable, Sendable {
    public let includeToday: Bool
    private var aliases: [String: String] = [:]
    private var previous: [SyncRecordID: Snapshot] = [:]
    private var previousToday: Set<String> = []
    /// Local profile ID → the group's ID it syncs as (outbound: one per local profile). Profile IDs are per
    /// installation; every record carries the group's ID, and only unmapped local profiles describe themselves.
    public private(set) var groupProfiles: [String: String] = [:]
    /// The group's profile ID → the local profile its Spaces and Favorites use (inbound: several group profiles may
    /// share one local profile; the first mapped is the one the local profile syncs as).
    public private(set) var inboundProfiles: [String: String] = [:]
    /// Rows excluded at the last capture (their item is local-only: its saved URL is too long, or it's a note). An explicit state:
    /// while excluded a row sends nothing and remote changes leave its item alone; when it fits again it's re-created
    /// under the same record (with its Space and folders, if another Mac deleted them meanwhile).
    public private(set) var excludedRows: Set<String> = []

    /// Longer saved URLs (data: URLs) stay on this Mac; longer names and titles sync cut. So every operation, and with
    /// it every batch, stays far below CloudKit's 1 MB record limit.
    public static let maxURLBytes = 16 * 1024
    public static let maxTextBytes = 2 * 1024
    /// Local items made for a record that started as another Mac's pinned Today tab (`tab:<id>`) have this ID, so the
    /// same record always lands on the same item, even if a checkpoint was lost after the store changed.
    public static let tabItemPrefix = "synctab-"

    private struct Snapshot: Codable, Equatable, Sendable {
        var fields: [SyncField: SyncValue]
        var order: Double
    }

    public init(includeToday: Bool = false) { self.includeToday = includeToday }

    /// The record a local pinned item or Favorite syncs as (`item:<id>`, or `tab:<id>` for a pinned Today tab).
    public func record(forItem id: String) -> String { aliases["item:" + id] ?? Self.defaultRecord(forItem: id) }

    /// Without an alias: `item:<id>`, or the `tab:` record a `synctab-` item was made for.
    public static func defaultRecord(forItem id: String) -> String {
        id.hasPrefix(tabItemPrefix) ? "tab:" + id.dropFirst(tabItemPrefix.count) : "item:" + id
    }

    /// The stable local item ID for a remote record with no local item yet.
    public static func localItem(forRecord record: String) -> String? {
        if record.hasPrefix("item:") { return String(record.dropFirst(5)) }
        if record.hasPrefix("tab:") { return tabItemPrefix + record.dropFirst(4) }
        return nil
    }

    /// Record ID → the local item that carries it, for items this adapter has seen or bound.
    public var localItems: [String: String] {
        var result: [String: String] = [:]
        for (key, record) in aliases where key.hasPrefix("item:") { result[record] = String(key.dropFirst(5)) }
        return result
    }

    /// A remote record materialized as a new local item keeps the record's identity.
    public mutating func bind(item localID: String, to record: String) { aliases["item:" + localID] = record }

    /// The group's `group` profile is `local` on this Mac. Several group profiles may map to one local profile; the
    /// first one mapped stays the one it syncs as (map the group's default profile first).
    public mutating func mapProfile(local: String, to group: String) {
        guard local != group else { inboundProfiles[group] = nil; return }
        inboundProfiles[group] = local
        groupProfiles = groupProfiles.filter { $0.value != group || $0.key == local }
        if groupProfiles[local] == nil { groupProfiles[local] = group }
    }

    /// The group's profile ID → this Mac's.
    public var localProfiles: [String: String] { inboundProfiles }

    /// The caller must persist adapter + replica + encrypted outbox atomically before upload.
    /// Remote application must rebase this baseline rather than emit the imported edits again.
    @discardableResult
    public mutating func capture(_ state: StoreState, into replica: inout SyncReplica, now: Int64) throws -> [SyncOperation] {
        var next = self
        var merged = replica
        let result = try next.captureImpl(state, into: &merged, now: now)
        self = next; replica = merged
        return result
    }

    /// Remote edits were applied to the store: its state becomes the baseline without emitting them again. Local
    /// edits must be captured before applying remote ones, or this swallows them.
    public mutating func rebase(_ state: StoreState) {
        let (current, today, excluded) = snapshot(state)
        previous = current
        previousToday = Set(today.map(\.id))
        excludedRows = Set(excluded.map(\.id))
    }

    /// The next capture describes this Mac's unmapped profiles again (after Replace took the group's sidebar as is).
    public mutating func forgetProfileDescriptions() { previous = previous.filter { $0.key.kind != .profile } }

    private func canonical(_ profile: String) -> String { groupProfiles[profile] ?? profile }

    private mutating func snapshot(_ state: StoreState) -> ([SyncRecordID: Snapshot], [LiveTab], Set<SyncRecordID>) {
        var excluded = Set<SyncRecordID>()
        let spaces = state.spaces.filter { !$0.value.isBlankWindow }
        // Preserve one identity through Today -> pinned/Favorite -> Today, unload, archive and undo.
        for tab in state.tabs.values.sorted(by: { $0.id < $1.id }) {
            if let item = tab.itemID {
                let id = aliases["item:" + item] ?? aliases["tab:" + tab.id] ?? "item:" + item
                aliases["item:" + item] = id; aliases["tab:" + tab.id] = id
            } else if aliases["tab:" + tab.id] == nil { aliases["tab:" + tab.id] = "tab:" + tab.id }
        }
        var current: [SyncRecordID: Snapshot] = [:]
        for profile in state.profiles.values where groupProfiles[profile.id] == nil {
            current[SyncRecordID(.profile, profile.id)] = Snapshot(fields: [
                .name: .text(Self.cut(profile.name)), .icon: profile.emoji.isEmpty ? .null : .text(Self.cut(profile.emoji)),
                .kind: .text(profile.isDefault ? "default" : "profile")
            ], order: 0)
        }
        for space in spaces.values {
            current[SyncRecordID(.space, space.id)] = Snapshot(fields: [
                .name: .text(Self.cut(space.name)), .icon: space.icon.map(SyncValue.icon) ?? .null,
                .theme: .theme(space.theme), .profile: .text(canonical(space.profileID))
            ], order: space.order)
        }
        // Splits are deferred as a whole, including their children (no partial or lossy flattening).
        func supported(_ item: Item) -> Bool {
            var cursor: Item? = item
            var seen = Set<String>()
            while let row = cursor {
                guard row.kind != .split, seen.insert(row.id).inserted else { return false }
                cursor = row.parentID.flatMap { state.items[$0] }
            }
            if let space = item.spaceID { return spaces[space] != nil }
            return true
        }
        for item in state.items.values where supported(item) {
            let id = aliases["item:" + item.id] ?? Self.defaultRecord(forItem: item.id)
            aliases["item:" + item.id] = id
            // A saved URL past maxURLBytes (a data: URL) keeps its item on this Mac only. Excluded is not deleted: an
            // item that synced before keeps its last synced values (no tombstone, no edit), until its URL fits again.
            if Self.isLocalOnly(item) {
                if let synced = previous[SyncRecordID(.row, id)] { current[SyncRecordID(.row, id)] = synced }
                excluded.insert(SyncRecordID(.row, id))
                continue
            }
            let location: SyncLocation
            switch item.container {
            case .pinned(let space): location = .pinned(space: space)
            case .favorites(let profile): location = .favorites(profile: canonical(profile))
            }
            let parent = item.parentID.map { aliases["item:" + $0] ?? Self.defaultRecord(forItem: $0) }
            current[SyncRecordID(.row, id)] = Snapshot(fields: [
                .kind: .text(item.kind.rawValue), .location: .location(location),
                .parent: parent.map(SyncValue.text) ?? .null,
                .url: item.savedURL.map(SyncValue.text) ?? .null,
                .title: item.title.map { .text(Self.cut($0)) } ?? .null,
                .icon: item.icon.map { .text(Self.cut($0)) } ?? .null
            ], order: item.order)
        }
        // A note's Today tab stays on this Mac like its pinned item (isLocalOnly): never exported, never archived.
        let today = state.tabs.values.filter { $0.isToday && $0.spaceID.map { spaces[$0] != nil } == true && !NoteURL.isNote($0.url) }
        if includeToday {
            for tab in today {
                let id = SyncRecordID(.row, aliases["tab:" + tab.id]!)
                // Navigation updates aren't exported: the append-only log must not become browsing history.
                let initialURL = previous[id]?.fields[.url] ?? .text(tab.url)
                current[id] = Snapshot(fields: [
                    .kind: .text("tab"), .location: .location(.today(space: tab.spaceID!)),
                    .parent: .null, .url: initialURL, .title: .null, .icon: .null
                ], order: tab.order)
            }
        }
        return (current, today, excluded)
    }

    private mutating func captureImpl(_ state: StoreState, into replica: inout SyncReplica, now: Int64) throws -> [SyncOperation] {
        let start = Set(replica.operations.keys)
        let (current, today, excluded) = snapshot(state)
        // Back from exclusion: a re-creation under the same record, every field and a new order key, whatever happened
        // to the record elsewhere meanwhile (a deletion, an unpin).
        var recreate = Set(excludedRows.map { SyncRecordID(.row, $0) }.filter { current[$0] != nil && !excluded.contains($0) })
        // A Space (or folder) another Mac deleted that this Mac kept, for its local-only rows, stays quiet until this Mac
        // edits something synced in it: a new or changed row inside, or the Space itself. That local edit, made after
        // the deletion was seen, re-creates the container under its record (a newer stamp wins), so what's in it syncs.
        // Only a local edit does it: a second deletion elsewhere leaves it quiet again, never a ping-pong.
        let edited = current.keys.filter { id in
            id.kind != .profile && !excluded.contains(id) && (previous[id] == nil || previous[id] != current[id])
        }
        for id in edited where id.kind == .space && replica.records[id]?.isDeleted == true { recreate.insert(id) }
        let containersOf = recreate.union(edited.filter { $0.kind == .row })
        for row in containersOf {
            if case .location(.pinned(let space))? = current[row]?.fields[.location] {
                let id = SyncRecordID(.space, space)
                if current[id] != nil, replica.records[id]?.isDeleted == true { recreate.insert(id) }
            }
            var parent = current[row]?.fields[.parent]
            var seen = Set<String>()
            while case .text(let p)? = parent, seen.insert(p).inserted {
                let id = SyncRecordID(.row, p)
                if current[id] != nil, replica.records[id]?.isDeleted == true { recreate.insert(id) }
                parent = current[id]?.fields[.parent]
            }
        }
        // Even with Today export off, an archive concurrent with pinning must target the same record. A Today tab no
        // other Mac can know about (never pinned, Today export off) gets no marker: one per closed tab would grow the
        // log forever.
        let archived = Set(state.archive.values.map { $0.tab.id })
        var archivedRecords = Set<SyncRecordID>()
        for tabID in previousToday.intersection(archived).sorted() where state.tabs[tabID] == nil {
            let id = SyncRecordID(.row, aliases["tab:" + tabID] ?? "tab:" + tabID)
            guard includeToday || replica.records[id] != nil else { continue }
            try replica.edit(id, [.location: .location(.archived)], now: now)
            archivedRecords.insert(id)
        }
        for id in previous.keys.sorted(by: Self.less) where current[id] == nil && !archivedRecords.contains(id) {
            if id.kind == .row, case .location(.today) = previous[id]?.fields[.location] {
                try replica.edit(id, [.location: .location(.archived)], now: now)
            } else {
                // Unpinning with Today sync disabled retains the identity and hides it via lifecycle.
                let unpinned = today.contains { aliases["tab:" + $0.id] == id.id }
                try replica.edit(id, unpinned ? [.location: .location(.archived)] : [.deleted: .flag(true)], now: now)
            }
        }
        // Generate a key only for rows actually moved/inserted by the store action.
        let sorted = current.keys.sorted {
            current[$0]!.order == current[$1]!.order ? Self.less($0, $1) : current[$0]!.order < current[$1]!.order
        }
        for (index, id) in sorted.enumerated() {
            let row = current[id]!
            let old = recreate.contains(id) ? nil : previous[id]
            var fields = row.fields.filter { old?.fields[$0.key] != $0.value }
            if old == nil { fields[.deleted] = .flag(false) }
            let moved = old?.order != row.order || old?.fields[.location] != row.fields[.location]
                || old?.fields[.parent] != row.fields[.parent]
            if moved && id.kind != .profile {
                func sameGroup(_ other: SyncRecordID) -> Bool {
                    other.kind == id.kind && current[other]?.fields[.location] == row.fields[.location]
                        && current[other]?.fields[.parent] == row.fields[.parent]
                }
                let lower = sorted[..<index].last(where: sameGroup).flatMap { replica.records[$0]?.order }
                let upper = sorted[(index + 1)...].first { other in
                    guard sameGroup(other), let before = previous[other], let after = current[other],
                          before.order == after.order, before.fields[.location] == after.fields[.location],
                          before.fields[.parent] == after.fields[.parent],
                          let key = replica.records[other]?.order else { return false }
                    return lower.map { $0 < key } ?? true
                }.flatMap { replica.records[$0]?.order }
                fields[.order] = .order(try SyncOrder.between(lower, upper))
            }
            if !fields.isEmpty { try replica.edit(id, fields, now: now) }
        }
        previous = current
        previousToday = Set(today.map(\.id))
        excludedRows = Set(excluded.map(\.id))
        return replica.log.filter { !start.contains($0.id) }
    }

    /// Items that stay on this Mac whatever happens elsewhere: their saved URL is too long to sync, or they're a note's
    /// (Notes.swift: notes stay on this Mac for now; what they say is a `note` row, which no record kind carries).
    public static func isLocalOnly(_ item: Item) -> Bool {
        (item.savedURL?.utf8.count ?? 0) > maxURLBytes || NoteURL.isNote(item.savedURL)
    }

    /// At most `maxTextBytes` of UTF-8, cut at a character boundary.
    static func cut(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        var result = "", bytes = 0
        for c in text {
            let n = String(c).utf8.count
            if bytes + n > maxTextBytes { break }
            result.append(c); bytes += n
        }
        return result
    }

    private static func less(_ a: SyncRecordID, _ b: SyncRecordID) -> Bool {
        (a.kind.rawValue, a.id) < (b.kind.rawValue, b.id)
    }
}
