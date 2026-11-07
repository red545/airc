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

    private struct Snapshot: Codable, Equatable, Sendable {
        var fields: [SyncField: SyncValue]
        var order: Double
    }

    public init(includeToday: Bool = false) { self.includeToday = includeToday }

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

    private mutating func captureImpl(_ state: StoreState, into replica: inout SyncReplica, now: Int64) throws -> [SyncOperation] {
        let start = Set(replica.operations.keys)
        let spaces = state.spaces.filter { !$0.value.isBlankWindow }
        // Preserve one identity through Today -> pinned/Favorite -> Today, unload, archive and undo.
        for tab in state.tabs.values.sorted(by: { $0.id < $1.id }) {
            if let item = tab.itemID {
                let id = aliases["item:" + item] ?? aliases["tab:" + tab.id] ?? "item:" + item
                aliases["item:" + item] = id; aliases["tab:" + tab.id] = id
            } else if aliases["tab:" + tab.id] == nil { aliases["tab:" + tab.id] = "tab:" + tab.id }
        }
        var current: [SyncRecordID: Snapshot] = [:]
        for space in spaces.values {
            current[SyncRecordID(.space, space.id)] = Snapshot(fields: [
                .name: .text(space.name), .icon: space.icon.map(SyncValue.icon) ?? .null,
                .theme: .theme(space.theme), .profile: .text(space.profileID)
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
            let id = aliases["item:" + item.id] ?? "item:" + item.id
            aliases["item:" + item.id] = id
            let location: SyncLocation
            switch item.container {
            case .pinned(let space): location = .pinned(space: space)
            case .favorites(let profile): location = .favorites(profile: profile)
            }
            let parent = item.parentID.map { aliases["item:" + $0] ?? "item:" + $0 }
            current[SyncRecordID(.row, id)] = Snapshot(fields: [
                .kind: .text(item.kind.rawValue), .location: .location(location),
                .parent: parent.map(SyncValue.text) ?? .null,
                .url: item.savedURL.map(SyncValue.text) ?? .null,
                .title: item.title.map(SyncValue.text) ?? .null,
                .icon: item.icon.map(SyncValue.text) ?? .null
            ], order: item.order)
        }
        let today = state.tabs.values.filter { $0.isToday && $0.spaceID.map { spaces[$0] != nil } == true }
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
        // Even with Today export off, an archive concurrent with pinning must target the same record.
        let archived = Set(state.archive.values.map { $0.tab.id })
        var archivedRecords = Set<SyncRecordID>()
        for tabID in previousToday.intersection(archived).sorted() where state.tabs[tabID] == nil {
            let id = SyncRecordID(.row, aliases["tab:" + tabID] ?? "tab:" + tabID)
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
            let old = previous[id]
            var fields = row.fields.filter { old?.fields[$0.key] != $0.value }
            if old == nil { fields[.deleted] = .flag(false) }
            let moved = old?.order != row.order || old?.fields[.location] != row.fields[.location]
                || old?.fields[.parent] != row.fields[.parent]
            if moved {
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
        return replica.log.filter { !start.contains($0.id) }
    }

    private static func less(_ a: SyncRecordID, _ b: SyncRecordID) -> Bool {
        (a.kind.rawValue, a.id) < (b.kind.rawValue, b.id)
    }
}
