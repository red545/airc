// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// What applying the synced sidebar did, and what's left for the app.
public struct SyncApplyResult: Equatable, Sendable {
    /// The group's profile IDs that synced Spaces or Favorites use and that have no profile on this Mac: those rows wait.
    public var unresolvedProfiles: Set<String> = []
    /// Spaces whose profile changed on another Mac: the app moves their open pages over (`SpacesStore.setProfile` and
    /// a reload in the engine), the way a local change does.
    public var profileChanges: [ProfileChange] = []
    /// Favorites past the 12 a profile can show stay in the group and out of this sidebar.
    public var withheldFavorites = 0
    public var changed = false

    public struct ProfileChange: Equatable, Sendable {
        public var space: String
        public var profile: String
    }
}

extension SpacesStore {
    /// Applies the synced sidebar (`replica.sidebar`) to the store in one transaction that isn't undoable. Only the
    /// synced kinds are touched: listed Spaces, pinned tabs, folders and Favorites. Never profiles, Today tabs (except
    /// those of a Space deleted elsewhere, which go to the Archive as on a local delete), splits, or anything private.
    /// `replace` also removes this Mac's synced kinds the replica doesn't have (Replace this Mac's sidebar). The caller
    /// captures local edits before and rebases the adapter after, so nothing applied here is sent back.
    @discardableResult
    public func applySync(_ replica: SyncReplica, adapter: inout SyncStoreAdapter, replace: Bool = false) throws -> SyncApplyResult {
        var result = SyncApplyResult()
        let groupToLocal = adapter.localProfiles
        let before = state
        func localProfile(_ group: String) -> String? { groupToLocal[group] ?? (state.profiles[group] != nil ? group : nil) }
        let live = replica.sidebar
        var binder = adapter
        try perform(nil) {
            // Spaces, in the group's order.
            var kept = Set<String>()      // listed Spaces that stay
            var synced: [Space] = []
            for record in live where record.id.kind == .space {
                let id = record.id.id
                guard case .text(let group)? = record[.profile], let profile = localProfile(group) else {
                    if case .text(let group)? = record[.profile] { result.unresolvedProfiles.insert(group) }
                    if state.spaces[id] != nil { kept.insert(id) }
                    continue
                }
                let existing = state.spaces[id]
                if existing?.isBlankWindow == true { continue }
                var space = existing ?? Space(id: id, name: "Space", profileID: profile, createdAt: now())
                if case .text(let name)? = record[.name], !name.isEmpty { space.name = name }
                switch record[.icon] {
                case .icon(let icon)?: space.icon = icon
                case .text(let emoji)?: space.icon = .emoji(emoji)
                case .null?: space.icon = nil
                default: break
                }
                if case .theme(let theme)? = record[.theme] { space.theme = theme }
                if existing != nil, space.profileID != profile {
                    result.profileChanges.append(.init(space: id, profile: profile))
                }
                synced.append(space)
                kept.insert(id)
            }
            if !zip(synced, synced.dropFirst()).allSatisfy({ $0.order < $1.order }) {
                for i in synced.indices { synced[i].order = Double(i + 1) }
            }
            for space in synced where state.spaces[space.id] != space { put(space) }

            // Spaces deleted elsewhere, and on Replace every listed Space iCloud doesn't have. One listed Space stays.
            var doomed = replica.records.values.filter { $0.id.kind == .space && $0.isDeleted }.map(\.id.id)
                .filter { state.spaces[$0].map { !$0.isBlankWindow } == true && !kept.contains($0) }
            if replace {
                doomed += state.spaces.values.filter { !$0.isBlankWindow && !kept.contains($0.id) && !doomed.contains($0.id) }.map(\.id)
            }
            // Never erase local-only data: a Space another Mac deleted stays here while it holds a local-only item or a
            // note's Today tab (its synced rows still go, by their own tombstones).
            doomed.removeAll { space in
                state.items.values.contains { $0.spaceID == space && SyncStoreAdapter.isLocalOnly($0) }
                    || state.tabs.values.contains { $0.isToday && $0.spaceID == space && NoteURL.isNote($0.url) }
            }
            doomed.sort()
            let listed = state.spaces.values.filter { !$0.isBlankWindow }.count
            if doomed.count >= listed { doomed.removeLast(doomed.count - listed + 1) }

            // Rows: decide each record's local item before writing, so parents resolve.
            let rows = live.filter { $0.id.kind == .row }
            let bound = binder.localItems
            var local: [String: String] = [:]          // record → local item ID
            var favorites: [String: Int] = [:]
            var skipped = Set<String>()
            for record in rows {
                guard case .location(let location)? = record[.location] else { continue }
                switch location {
                case .pinned(let space):
                    guard kept.contains(space), !doomed.contains(space), state.spaces[space] != nil else { skipped.insert(record.id.id); continue }
                case .favorites(let group):
                    guard let profile = localProfile(group) else {
                        result.unresolvedProfiles.insert(group); skipped.insert(record.id.id); continue
                    }
                    let shown = favorites[profile, default: 0]
                    guard shown < Self.maxFavorites else { result.withheldFavorites += 1; skipped.insert(record.id.id); continue }
                    favorites[profile] = shown + 1
                case .today, .archived:
                    continue
                }
                // Stable: the same record always lands on the same local item, even after a lost checkpoint.
                var id = bound[record.id.id] ?? SyncStoreAdapter.localItem(forRecord: record.id.id) ?? newID()
                // A local-only item (its URL is too long to sync) is this Mac's: remote edits never touch it.
                if let mine = state.items[id], SyncStoreAdapter.isLocalOnly(mine), binder.record(forItem: id) == record.id.id {
                    skipped.insert(record.id.id); continue
                }
                if let mine = state.items[id], mine.kind == .split || binder.record(forItem: id) != record.id.id { id = newID() }
                local[record.id.id] = id
            }
            // Local items no longer in the synced sidebar: deleted, unpinned or moved out elsewhere.
            var gone: [(String, unpinned: Bool)] = []
            for (recordID, record) in replica.records where record.id.kind == .row && local[recordID.id] == nil && !skipped.contains(recordID.id) {
                guard let id = bound[recordID.id] ?? SyncStoreAdapter.localItem(forRecord: recordID.id),
                      let item = state.items[id], item.kind != .split, !SyncStoreAdapter.isLocalOnly(item),
                      binder.record(forItem: id) == recordID.id else { continue }
                let unpinned: Bool = if case .location(.archived)? = record[.location], !record.isDeleted { true }
                    else if case .location(.today)? = record[.location], !record.isDeleted { true } else { false }
                gone.append((id, unpinned))
            }
            if replace {
                let mine = Set(local.values)
                for item in state.items.values where !mine.contains(item.id) && !gone.contains(where: { $0.0 == item.id })
                    && !insideSplit(item) && !SyncStoreAdapter.isLocalOnly(item)
                    && item.spaceID.map({ state.spaces[$0]?.isBlankWindow != true }) != false {
                    gone.append((item.id, false))
                }
            }

            var written: [Item] = []
            for record in rows {
                guard let id = local[record.id.id], case .location(let location)? = record[.location] else { continue }
                let container: ItemContainer
                switch location {
                case .pinned(let space): container = .pinned(spaceID: space)
                case .favorites(let group): container = .favorites(profileID: localProfile(group)!)
                default: continue
                }
                let old = state.items[id]
                var item = old ?? Item(id: id, kind: .tab, container: container, createdAt: now())
                item.kind = record[.kind] == .text("folder") ? .folder : .tab
                item.container = container
                if case .text(let parent)? = record[.parent], let p = local[parent], case .pinned = container { item.parentID = p }
                else { item.parentID = nil }
                item.savedURL = item.kind == .folder ? nil : record[.url].flatMap { if case .text(let u) = $0 { u } else { nil } }
                item.title = record[.title].flatMap { if case .text(let t) = $0 { t } else { nil } }
                item.icon = record[.icon].flatMap { if case .text(let e) = $0 { e } else { nil } }
                if item.kind == .folder, item.title?.isEmpty != false { item.title = "Folder" }
                if let old, old.container != container, let tab = liveTab(forItem: id) { follow(tab, to: container) }
                written.append(item)
                binder.bind(item: id, to: record.id.id)
            }
            // Order inside each list (a Space's pinned root or folder, a profile's Favorites), in the group's order.
            var lists: [String: [Int]] = [:]
            for (i, item) in written.enumerated() { lists["\(item.container)|\(item.parentID ?? "")", default: []].append(i) }
            for indices in lists.values {
                let consistent = indices.allSatisfy { before.items[written[$0].id] != nil }
                    && zip(indices, indices.dropFirst()).allSatisfy { written[$0.0].order < written[$0.1].order }
                if !consistent { for (rank, i) in indices.enumerated() { written[i].order = Double(rank + 1) } }
            }
            for item in written where state.items[item.id] != item { put(item) }

            for (id, unpinned) in gone where state.items[id] != nil { removeSynced(id, keepPage: unpinned, replace: replace, keep: Set(local.values)) }

            for id in doomed {
                for x in splits(ofSpace: id) { remove(Split.self, x.id) }
                for t in todayTabs(ofSpace: id) { _ = archive(t, reason: .spaceDeleted) }
                for root in pinnedRoots(ofSpace: id) { removeItemTree(root.id) }
                remove(Space.self, id)
            }
            if let selected = windowState.selectedSpaceID, state.spaces[selected] == nil, let first = orderedSpaces.first {
                updateWindowState { $0.selectedSpaceID = first.id }
            }
        }
        adapter = binder
        result.changed = state != before
        return result
    }

    /// A pinned item or Favorite that went elsewhere. Its children the group still has were moved already; local-only
    /// ones (splits) go to the root, or with it on Replace. An unpinned pinned tab's open page becomes a Today tab.
    private func removeSynced(_ id: String, keepPage: Bool, replace: Bool, keep: Set<String>) {
        for child in state.items.values where child.parentID == id && !keep.contains(child.id) {
            // Local-only rows are never erased: they move to the root of their Space with the rest of a merge.
            if replace && !SyncStoreAdapter.isLocalOnly(child) && !containsLocalOnly(child.id) { removeItemTree(child.id) }
            else { var c = child; c.parentID = nil; put(c) }
        }
        if let tab = liveTab(forItem: id) {
            var t = tab
            if keepPage, let space = t.spaceID, state.spaces[space] != nil {
                t.itemID = nil
                t.order = (todayTabs(ofSpace: space).map(\.order).min() ?? 1) - 1
                put(t)
            } else {
                remove(LiveTab.self, tab.id)
            }
        }
        remove(Item.self, id)
    }

    /// The live page of an item that moved to another Space or into Favorites follows it; across profiles it closes
    /// (a page can't change profile; the item reopens it in the new one).
    private func follow(_ tab: LiveTab, to container: ItemContainer) {
        var t = tab
        switch container {
        case .pinned(let space):
            guard let profile = state.spaces[space]?.profileID, profile == t.profileID else { return remove(LiveTab.self, t.id) }
            t.spaceID = space
        case .favorites(let profile):
            guard profile == t.profileID else { return remove(LiveTab.self, t.id) }
            t.spaceID = nil
        }
        put(t)
    }

    /// A folder (or split) with a local-only row somewhere inside.
    private func containsLocalOnly(_ id: String) -> Bool {
        state.items.values.contains { $0.parentID == id && (SyncStoreAdapter.isLocalOnly($0) || containsLocalOnly($0.id)) }
    }

    private func insideSplit(_ item: Item) -> Bool {
        var cursor: Item? = item
        var seen = Set<String>()
        while let row = cursor, seen.insert(row.id).inserted {
            if row.kind == .split { return true }
            cursor = row.parentID.flatMap { state.items[$0] }
        }
        return false
    }
}
