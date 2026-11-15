// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Folders in Today (Arc's unpinned folders; Tidy Tabs puts its groups there). A Today folder is an `Item` of kind
// `.folder` in `.today(spaceID:)`, so it has an ID, an order, a title, an icon, `isCollapsed` and undo for free. It can
// hold Today folders (`parentID`), as Arc's sidebar tree does in Today as in Pinned. Its tabs stay Today tabs
// (`itemID == nil`) and say where they are with `LiveTab.folderID`, so auto-archive (SB-43), Clear (SB-40), ⌘W and the
// Archive treat them as every other Today tab.
//
// Rules:
// - A tab in a Today folder is a Today tab of that folder's Space, outside any split. Anything that makes it otherwise
//   (pinning it, a Favorite, Move to Space, a split) takes it out of the folder in the same transaction
//   (`tidyTodayFolders`).
// - A Today folder that a change left without any tab in it (or in its folders) goes in the same transaction, with the
//   folders above it that it left empty: Arc's folders go when their last tab is archived. One ⌘Z brings both back. A
//   folder made empty on purpose (New Folder in Today) stays until Clear, or until it's older than its profile's
//   archive interval at the next launch.
// - Today folders never sync (docs/user/sync.md: Today stays on this Mac) and are schema 3 (SpacesStore.schemaMark).

extension SpacesStore {
    // MARK: Queries

    /// The Today folder `id`, if it is one.
    public func todayFolder(_ id: String?) -> Item? {
        guard let i = item(id), i.isTodayFolder, i.kind == .folder else { return nil }
        return i
    }

    /// Every Today folder of a Space, nested ones too, in no particular order.
    public func todayFolders(ofSpace id: String) -> [Item] {
        state.items.values.filter { $0.container == .today(spaceID: id) && $0.kind == .folder }
    }

    /// The folder a Today tab is shown in: its `folderID` when that's a Today folder of its Space and the tab is a
    /// Today tab outside a split; else nil (the tab is loose in Today).
    public func shownTodayFolderID(of t: LiveTab) -> String? {
        guard let f = t.folderID, t.itemID == nil, let folder = todayFolder(f), folder.spaceID == t.spaceID,
              !state.splits.values.contains(where: { $0.tabIDs.contains(t.id) }) else { return nil }
        return f
    }

    /// How many Today folders a Today tab is inside (its row's indent).
    public func todayDepth(ofTab id: String) -> Int {
        guard let t = tab(id), let f = shownTodayFolderID(of: t) else { return 0 }
        return 1 + todayFolderDepth(f)
    }

    /// How many Today folders `folderID` is inside.
    func todayFolderDepth(_ folderID: String) -> Int {
        var depth = 0
        var cursor = todayFolder(folderID)?.parentID
        var seen = Set<String>()
        while let p = cursor, let f = todayFolder(p), seen.insert(p).inserted {
            depth += 1
            cursor = f.parentID
        }
        return depth
    }

    /// One pass over a Space's Today (its tabs, splits and Today folders), each row filed under where it is shown: nil for
    /// Today's top level, else its Today folder. Every row list below is built from this, so a render costs one pass
    /// over the tabs whatever the number of folders (a 5,000-tab Today renders in budget).
    private struct TodayIndex {
        enum Row { case tab(LiveTab), split(Split, [LiveTab]), folder(Item) }
        var groups: [String?: [(order: Double, created: Date, id: String, row: Row)]] = [:]

        func rows(_ parent: String?, depth: Int) -> [SidebarEntry] {
            (groups[parent] ?? []).map {
                switch $0.row {
                case .tab(let t): .today(t)
                case .split(let x, let m): .split(x, m)
                case .folder(let f): .folder(f, depth: depth)
                }
            }
        }
    }

    private func todayIndex(ofSpace id: String) -> TodayIndex {
        var index = TodayIndex()
        var folders: [String: Item] = [:]
        for i in state.items.values where i.kind == .folder && i.container == .today(spaceID: id) { folders[i.id] = i }
        for f in folders.values {
            let parent = f.parentID.flatMap { folders[$0] == nil ? nil : $0 }
            index.groups[parent, default: []].append((f.order, f.createdAt, f.id, .folder(f)))
        }
        let inSplits = Set(state.splits.values.flatMap(\.tabIDs))
        for t in state.tabs.values where t.itemID == nil && t.spaceID == id && !inSplits.contains(t.id) {
            let folder = t.folderID.flatMap { folders[$0] == nil ? nil : $0 }
            index.groups[folder, default: []].append((t.order, t.createdAt, t.id, .tab(t)))
        }
        for x in splits(ofSpace: id) {
            let m = members(of: x)
            guard m.count >= 2 else { continue }
            index.groups[nil, default: []].append((x.order, x.createdAt, x.id, .split(x, m)))
        }
        for k in index.groups.keys {
            index.groups[k]?.sort { ($0.order, $0.created, $0.id) < ($1.order, $1.created, $1.id) }
        }
        return index
    }

    /// A Today folder's own rows, in order: its folders (`.folder` at `depth`) and its tabs (`.today`).
    public func todayFolderContents(_ folderID: String, depth: Int = 1) -> [SidebarEntry] {
        guard let sid = todayFolder(folderID)?.spaceID else { return [] }
        return todayIndex(ofSpace: sid).rows(folderID, depth: depth)
    }

    /// Every tab in a Today folder and the folders inside it, top first.
    public func todayFolderTabs(_ folderID: String) -> [LiveTab] {
        guard let sid = todayFolder(folderID)?.spaceID else { return [] }
        let index = todayIndex(ofSpace: sid)
        var out: [LiveTab] = []
        var seen = Set<String>()
        func walk(_ id: String) {
            guard seen.insert(id).inserted else { return }
            for e in index.rows(id, depth: 0) {
                switch e {
                case .folder(let f, _): walk(f.id)
                case .today(let t): out.append(t)
                default: break
                }
            }
        }
        walk(folderID)
        return out
    }

    /// The top level of a Space's Today list, top first: its loose Today tabs, its splits (one row each) and its Today
    /// folders. Indexes into Today (`DropDestination.today`) count these rows.
    public func todayRootRows(ofSpace id: String) -> [SidebarEntry] {
        todayIndex(ofSpace: id).rows(nil, depth: 0)
    }

    /// A Space's Today list as shown: the top-level rows, each open Today folder followed by its rows (with
    /// `expandingCollapsed`, closed ones too). One pass over Today (`todayIndex`).
    public func todayRows(ofSpace id: String, expandingCollapsed: Bool) -> [SidebarEntry] {
        let index = todayIndex(ofSpace: id)
        var out: [SidebarEntry] = []
        var seen = Set<String>()
        func add(_ parent: String?, depth: Int) {
            for e in index.rows(parent, depth: depth) {
                out.append(e)
                if case .folder(let f, _) = e, expandingCollapsed || !f.isCollapsed, seen.insert(f.id).inserted {
                    add(f.id, depth: depth + 1)
                }
            }
        }
        add(nil, depth: 0)
        return out
    }

    /// A Today folder's rows as its menu copies them (`folderLinks`): each tab's page, nested folders in place.
    func todayFolderLinks(_ id: String, depth: Int = 0) -> [FolderLink] {
        todayFolderContents(id).flatMap { e -> [FolderLink] in
            switch e {
            case .folder(let f, _):
                return [FolderLink(title: f.displayTitle, kind: .folder, depth: depth)] + todayFolderLinks(f.id, depth: depth + 1)
            case .today(let t):
                return LocalDocumentURL.isLocal(t.url) || URLRules.isNewTab(t.url) ? []
                    : [FolderLink(title: t.displayTitle, kind: .link(url: t.url), depth: depth)]
            default:
                return []
            }
        }
    }

    /// Whether any tab is in `folderID` or a folder inside it.
    func todayFolderHasTabs(_ folderID: String) -> Bool {
        var inside: Set<String> = [folderID]
        var grew = true
        while grew {
            grew = false
            for i in state.items.values where i.isTodayFolder && !inside.contains(i.id) && i.parentID.map(inside.contains) == true {
                inside.insert(i.id)
                grew = true
            }
        }
        return state.tabs.values.contains { t in t.folderID.map(inside.contains) == true && shownTodayFolderID(of: t) != nil }
    }

    // MARK: Actions

    /// New Folder in Today: a Today folder at the top of the Space's Today list (or inside `parentID`, a Today folder,
    /// at `index`), holding `sources` in order (Today tabs, pinned tabs, folders). One undo step ("New Folder").
    @discardableResult
    public func createTodayFolder(named name: String = "New Folder", inSpace spaceID: String, parentID: String? = nil,
                                  index: Int? = nil, containing sources: [DragSource] = []) throws -> Item {
        guard space(spaceID) != nil else { throw StoreError.notFound }
        if let parentID { guard todayFolder(parentID)?.spaceID == spaceID else { throw StoreError.invalidMove } }
        let siblings = parentID.map { todayFolderContents($0) } ?? todayRootRows(ofSpace: spaceID)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Item(kind: .folder, container: .today(spaceID: spaceID), parentID: parentID,
                          order: Ordering.insertion(at: index ?? 0, in: siblings.map(rowOrder)),
                          title: trimmed.isEmpty ? "New Folder" : trimmed, createdAt: now())
        try perform("New Folder", undoable: true) {
            put(folder)
            for (n, src) in sources.enumerated() {
                try move(src, to: .todayFolder(folderID: folder.id, index: n))
            }
        }
        return item(folder.id) ?? folder
    }

    /// Ungroup: a Today folder's rows go where it was (in order), and the folder goes. One undo step.
    public func ungroupTodayFolder(_ id: String) throws {
        guard let f = todayFolder(id), let sid = f.spaceID else { throw StoreError.notFound }
        let contents = todayFolderContents(id)
        let siblings = (f.parentID.map { todayFolderContents($0) } ?? todayRootRows(ofSpace: sid)).filter { $0.id != id }
        let at = (f.parentID.map { todayFolderContents($0) } ?? todayRootRows(ofSpace: sid)).firstIndex { $0.id == id } ?? 0
        let lo = at > 0 ? rowOrder(siblings[at - 1]) : nil
        let hi = at < siblings.count ? rowOrder(siblings[at]) : nil
        try perform("Ungroup", undoable: true) {
            var previous = lo
            for e in contents {
                let order = Ordering.between(previous, hi)
                previous = order
                switch e {
                case .folder(var sub, _):
                    sub.parentID = f.parentID
                    sub.order = order
                    put(sub)
                case .today(var t):
                    t.folderID = f.parentID
                    t.order = order
                    put(t)
                default: break
                }
            }
            remove(Item.self, id)
        }
    }

    /// A Space's Today folders go (its Today tabs have gone or are going to the Archive): deleting the Space, closing a
    /// blank window, a Space deleted on another Mac.
    func removeTodayFolders(ofSpace id: String) {
        for f in todayFolders(ofSpace: id) { remove(Item.self, f.id) }
    }

    /// Clear: the Space's Today folders that hold no tab any more.
    func removeEmptyTodayFolders(ofSpace id: String) {
        for f in todayFolders(ofSpace: id) where item(f.id) != nil && !todayFolderHasTabs(f.id) {
            removeTodayFolderTree(f.id)
        }
    }

    /// A Today folder and the folders inside it. Its tabs, if any, go to the Archive (a tab that only names it, and
    /// isn't shown in it, stays in Today).
    func removeTodayFolderTree(_ id: String) {
        for sub in state.items.values where sub.parentID == id && sub.isTodayFolder { removeTodayFolderTree(sub.id) }
        for var t in state.tabs.values where t.folderID == id {
            if shownTodayFolderID(of: t) == id { archive(t, reason: .manual) } else { t.folderID = nil; put(t) }
        }
        remove(Item.self, id)
    }

    /// The live tabs `source` is in Today (a folder's: every tab inside it).
    func todayTabsMoving(_ source: DragSource) -> [LiveTab] {
        switch source {
        case .tab(let id): return tab(id).map { [$0] } ?? []
        case .split(let id): return split(id).map(members) ?? []
        case .item(let id): return todayFolder(id) != nil ? todayFolderTabs(id) : liveTab(forItem: id).map { [$0] } ?? []
        }
    }

    // MARK: Moving into and out of Today folders (inside `move`'s transaction)

    /// A folder (pinned or Today, with everything inside) becomes a Today folder of `spaceID` inside `parentID` (nil:
    /// Today's top level) at `order`. A pinned tab inside becomes a Today tab of its folder (its page, or a new one at
    /// its saved address, as Unpin makes); a pinned split inside can't go (the caller refuses the move first).
    func moveFolderIntoToday(_ folder: Item, spaceID: String, parentID: String?, order: Double, reload: inout [String]) {
        let profileID = profile(ofSpace: spaceID).id
        var f = folder
        let wasPinned = !folder.isTodayFolder
        f.container = .today(spaceID: spaceID)
        f.parentID = parentID
        f.order = order
        put(f)
        if wasPinned {
            for child in state.items.values.filter({ $0.parentID == folder.id }) {
                switch child.kind {
                case .folder:
                    moveFolderIntoToday(child, spaceID: spaceID, parentID: folder.id, order: child.order, reload: &reload)
                case .tab:
                    var t = liveTab(forItem: child.id) ?? LiveTab(profileID: profileID, spaceID: spaceID,
                                                                  url: child.savedURL ?? "", title: child.pageTitle ?? "",
                                                                  faviconURL: child.faviconURL, createdAt: now())
                    remove(Item.self, child.id)
                    t.icon = child.icon
                    t.itemID = nil
                    t.spaceID = spaceID
                    t.folderID = folder.id
                    t.order = child.order
                    if t.profileID != profileID { t.profileID = profileID; reload.append(t.id) }
                    put(t)
                case .split:
                    break
                }
            }
        } else {
            for sub in state.items.values.filter({ $0.parentID == folder.id && $0.isTodayFolder }) {
                moveFolderIntoToday(sub, spaceID: spaceID, parentID: folder.id, order: sub.order, reload: &reload)
            }
            for var t in state.tabs.values where t.folderID == folder.id && t.isToday {
                t.spaceID = spaceID
                if t.profileID != profileID { t.profileID = profileID; reload.append(t.id) }
                put(t)
            }
        }
    }

    /// A Today folder (with everything inside) becomes a pinned folder of `spaceID` inside `parentID` at `order`: its
    /// tabs become its pinned tabs, as pinning a Today tab makes them.
    func moveTodayFolderIntoPinned(_ folder: Item, spaceID: String, parentID: String?, order: Double, reload: inout [String]) {
        let profileID = profile(ofSpace: spaceID).id
        let subs = state.items.values.filter { $0.parentID == folder.id && $0.isTodayFolder }
        let tabs = state.tabs.values.filter { $0.folderID == folder.id && $0.isToday }
        var f = folder
        f.container = .pinned(spaceID: spaceID)
        f.parentID = parentID
        f.order = order
        put(f)
        for sub in subs { moveTodayFolderIntoPinned(sub, spaceID: spaceID, parentID: folder.id, order: sub.order, reload: &reload) }
        for var t in tabs {
            leaveSplit(t.id)
            let i = Item(kind: .tab, container: .pinned(spaceID: spaceID), parentID: folder.id, order: t.order,
                         savedURL: t.url, pageTitle: t.title, faviconURL: t.faviconURL, icon: t.icon, createdAt: now())
            put(i)
            t.itemID = i.id
            t.icon = nil
            t.folderID = nil
            t.spaceID = spaceID
            if t.profileID != profileID { t.profileID = profileID; reload.append(t.id) }
            put(t)
        }
    }

    /// Whether `ancestor` is `id` or a folder `id` is inside (pinned or Today).
    public func isFolderAncestorOrSelf(_ ancestor: String, of id: String) -> Bool {
        var cursor: String? = id
        var seen = Set<String>()
        while let c = cursor, seen.insert(c).inserted {
            if c == ancestor { return true }
            cursor = item(c)?.parentID
        }
        return false
    }

    /// Whether a pinned folder holds a split anywhere inside (it can't go into Today: Today's splits are rows of their
    /// own, never in a folder).
    func folderHoldsSplit(_ id: String) -> Bool {
        state.items.values.contains { $0.parentID == id && ($0.kind == .split || ($0.kind == .folder && folderHoldsSplit($0.id))) }
    }

    // MARK: Consistency

    /// End of every transaction (SpacesStore.perform): tabs that can't be in their Today folder any more leave it, and
    /// the Today folders a change left without tabs go (with the folders above them it left empty). `before` is the
    /// transaction's before-images, so only folders this transaction touched are looked at.
    func tidyTodayFolders(before: [EntityRef: EntitySnapshot]) {
        var suspects = Set<String>()
        var touched: [String] = []
        for (ref, snap) in before {
            switch snap {
            case .tab(let old):
                if let f = old?.folderID, state.tabs[ref.id]?.folderID != f { suspects.insert(f) }
                if state.tabs[ref.id]?.folderID != nil { touched.append(ref.id) }
            case .item(let old):
                if let old, old.isTodayFolder, let p = old.parentID, state.items[ref.id]?.parentID != p { suspects.insert(p) }
            case .split(let old):
                // A tab that joined a Today split leaves its folder.
                for id in old?.tabIDs ?? [] where state.tabs[id]?.folderID != nil { touched.append(id) }
                for id in state.splits[ref.id]?.tabIDs ?? [] where state.tabs[id]?.folderID != nil { touched.append(id) }
            default:
                break
            }
        }
        guard !suspects.isEmpty || !touched.isEmpty else { return }
        for id in touched {
            guard var t = state.tabs[id], let f = t.folderID, shownTodayFolderID(of: t) == nil else { continue }
            t.folderID = nil
            put(t)
            suspects.insert(f)
        }
        var queue = Array(suspects)
        while let f = queue.popLast() {
            guard let folder = todayFolder(f), !todayFolderHasTabs(f) else { continue }
            removeTodayFolderTree(f)
            if let p = folder.parentID { queue.append(p) }
        }
    }

    /// At open (`repair`): what an older build or a damaged row left. A tab whose folder is gone, isn't a Today folder
    /// of its Space, or that an older build pinned or put in a split (it keeps `folderID` on disk, H4) is loose in
    /// Today; a Today folder inside something that isn't a Today folder of its Space goes to Today's top level; an empty
    /// Today folder older than its profile's archive interval goes (an older build archived its tabs, or it was left
    /// empty), unless rows this build can't read might be its tabs.
    func repairTodayFolders() {
        for var t in state.tabs.values where t.folderID != nil && shownTodayFolderID(of: t) == nil {
            t.folderID = nil
            put(t)
        }
        for var f in state.items.values where f.isTodayFolder {
            if let p = f.parentID, todayFolder(p)?.spaceID != f.spaceID || isFolderAncestorOrSelf(f.id, of: p) {
                f.parentID = nil
                put(f)
            }
        }
        guard !unreadableRows.contains(where: { $0.kind == EntityKind.tab.rawValue }) else { return }
        let date = now()
        for f in state.items.values where f.isTodayFolder && item(f.id) != nil && !todayFolderHasTabs(f.id) {
            let interval = profile(ofSpace: f.spaceID ?? "").archiveAfter.seconds
            if date.timeIntervalSince(f.createdAt) >= interval { removeTodayFolderTree(f.id) }
        }
    }
}
