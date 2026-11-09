// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// SV-2 pinned and Favorite splits (spec §2.16b, Arc ref §2.3 and §2.11). A split in Pinned or Favorites is a sidebar
// item like a pinned tab: it lives in a Space's pinned tree (folders too) or a profile's Favorites, survives without a
// loaded page, and is one row or one tile. As in Arc's sidebar data (a `splitView` item whose children are tab items),
// its panes are its child items, in order: each is a pinned tab with its own saved URL, so a pane that wandered off
// shows " /" and resets on its own (SB-31). The layout (axis, each pane's share, the focused pane) is on the split item.
//
// While at least two of its panes are loaded the store hands the window an ordinary `Split` value for it (same ID as
// the item, `itemID` set), so it shows, resizes and focuses like a Today split. Closing it unloads every pane and keeps
// the item (SB-30); it never auto-archives (SB-43). Dragged into Today it becomes a Today split again, and a Today split
// dragged above the divider becomes a pinned or Favorite one, keeping its ID so the split on screen stays put.

/// How a pinned or Favorite split's panes sit.
public struct SplitLayout: Codable, Hashable, Sendable {
    public var axis: SplitAxis
    /// Each pane's share along `axis`, by pane item ID. Read in pane order and scaled to add up to 1; a pane without a
    /// share gets an equal one.
    public var shares: [String: Double]
    /// The pane item with the keyboard; the row opens to it.
    public var focusedItemID: String?

    public init(axis: SplitAxis = .horizontal, shares: [String: Double] = [:], focusedItemID: String? = nil) {
        self.axis = axis
        self.shares = shares
        self.focusedItemID = focusedItemID
    }

    private enum CodingKeys: String, CodingKey { case axis, shares, focusedItemID }

    /// Fields a newer Airc may leave out or change read as their defaults (code review H4).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        axis = (try? c.decodeIfPresent(SplitAxis.self, forKey: .axis)) ?? .horizontal
        shares = (try? c.decodeIfPresent([String: Double].self, forKey: .shares)) ?? [:]
        focusedItemID = try? c.decodeIfPresent(String.self, forKey: .focusedItemID)
    }

    /// The panes' fractions in `paneIDs` order, adding up to 1.
    public func fractions(_ paneIDs: [String]) -> [Double] {
        Split.normalized(paneIDs.map { shares[$0] ?? 0 }, count: paneIDs.count)
    }
}

extension SpacesStore {
    // MARK: Queries

    /// A split item's panes, in order.
    public func panes(ofSplitItem id: String) -> [Item] {
        guard let s = item(id), s.kind == .split else { return [] }
        return children(of: s.container, parent: id).filter { $0.kind == .tab }
    }

    /// The pinned or Favorite split a pane item belongs to.
    public func splitItem(ofPane itemID: String?) -> Item? {
        guard let p = item(itemID), p.kind == .tab, let s = item(p.parentID), s.kind == .split else { return nil }
        return s
    }

    /// The loaded panes' tabs of a split item, in pane order.
    public func paneTabs(ofSplitItem id: String) -> [LiveTab] {
        panes(ofSplitItem: id).compactMap { liveTab(forItem: $0.id) }
    }

    /// The tab a split item's row opens: its focused pane's, else its first loaded pane's; nil when none is loaded.
    public func liveTab(forSplitItem id: String) -> LiveTab? {
        let panes = self.panes(ofSplitItem: id)
        let focused = item(id)?.splitLayout?.focusedItemID
        if let f = panes.first(where: { $0.id == focused }), let t = liveTab(forItem: f.id) { return t }
        return panes.lazy.compactMap { self.liveTab(forItem: $0.id) }.first
    }

    func isItemSplitPane(_ tabID: String) -> Bool { splitItem(ofPane: tab(tabID)?.itemID) != nil }

    /// Whether `x` shows in `spaceID`'s sidebar and window: a Favorite split in every Space of its profile, any other in
    /// its own Space.
    public func showsSplit(_ x: Split, inSpace spaceID: String) -> Bool {
        if let iid = x.itemID, case .favorites(let pid)? = item(iid)?.container { return space(spaceID)?.profileID == pid }
        return x.spaceID == spaceID
    }

    /// The `Split` a pinned or Favorite split shows as, while at least two of its panes are loaded.
    func itemSplit(_ id: String) -> Split? {
        guard let s = item(id), s.kind == .split else { return nil }
        let loaded = panes(ofSplitItem: id).compactMap { p in liveTab(forItem: p.id).map { (pane: p.id, tab: $0.id) } }
        guard loaded.count >= 2 else { return nil }
        let layout = s.splitLayout ?? SplitLayout()
        let focused = loaded.first { $0.pane == layout.focusedItemID }?.tab ?? loaded[0].tab
        var x = Split(id: id, spaceID: homeSpace(of: s), tabIDs: loaded.map(\.tab), axis: layout.axis,
                      fractions: layout.fractions(loaded.map(\.pane)), focusedTabID: focused, order: s.order, createdAt: s.createdAt)
        x.itemID = id
        return x
    }

    /// A pinned split's Space; a Favorite split's is the window's Space when it uses that profile, else the profile's
    /// first Space.
    private func homeSpace(of s: Item) -> String {
        switch s.container {
        case .pinned(let sid): return sid
        case .favorites(let pid):
            if let w = space(windowState.selectedSpaceID), w.profileID == pid { return w.id }
            return spaces(usingProfile: pid).first?.id ?? ""
        }
    }

    /// The Space and profile a container's live tabs belong to.
    func binding(of container: ItemContainer) -> (spaceID: String?, profileID: String) {
        switch container {
        case .pinned(let sid): (sid, profile(ofSpace: sid).id)
        case .favorites(let pid): (nil, pid)
        }
    }

    // MARK: Opening and closing

    /// Opens every pane of a split item (`itemID` is the split or one of its panes, which then gets the keyboard).
    /// Unloaded panes get a tab at their saved URL. Returns the focused pane's tab.
    @discardableResult
    func openSplitItem(_ itemID: String, inSpace spaceID: String, activate: Bool) throws -> LiveTab {
        let s: Item
        var focus: String?
        if let i = item(itemID), i.kind == .split { s = i } else if let i = splitItem(ofPane: itemID) { s = i; focus = itemID } else {
            throw StoreError.notFound
        }
        let panes = self.panes(ofSplitItem: s.id).filter { $0.savedURL != nil }
        guard !panes.isEmpty else { throw StoreError.notFound }
        let wanted = focus ?? s.splitLayout?.focusedItemID
        let focusedPane = panes.contains { $0.id == wanted } ? wanted! : panes[0].id
        let (sid, pid) = binding(of: s.container)
        var shown = ""
        try perform(nil) {
            for p in panes {
                var t = liveTab(forItem: p.id)
                if t == nil {
                    let n = LiveTab(profileID: pid, spaceID: sid, itemID: p.id, url: p.savedURL!, title: p.pageTitle ?? "",
                                    faviconURL: p.faviconURL, createdAt: now())
                    put(n)
                    t = n
                }
                if p.id == focusedPane { shown = t!.id }
            }
            if var i = item(s.id), i.splitLayout?.focusedItemID != focusedPane {
                var l = i.splitLayout ?? SplitLayout()
                l.focusedItemID = focusedPane
                i.splitLayout = l
                put(i)
            }
            if activate { markActive(shown, inSpace: spaceID) }
        }
        return tab(shown)!
    }

    /// Inside a transaction: every pane's page goes; the split and its panes stay (SB-30).
    func unloadPanes(ofSplitItem id: String) {
        for t in paneTabs(ofSplitItem: id) { remove(LiveTab.self, t.id) }
    }

    // MARK: Into and out of Pinned and Favorites

    /// A Today split dragged into Pinned or Favorites: one split item there with a pane item per tab, in pane order, with
    /// the split's sizes and focus. A pinned tab or Favorite that was a pane brings its own item. Keeps the split's ID.
    /// Returns the tabs that must reload in another profile.
    func pinSplit(_ splitID: String, to destination: DropDestination) throws -> [String] {
        guard let x = state.splits[splitID] else { throw StoreError.notFound }
        let tabs = members(of: x)
        // Notes stay out of pinned and Favorite splits (Splits.swift's canBeTodayPane).
        guard tabs.count >= 2, !tabs.contains(where: { NoteURL.isNote($0.url) }) else { throw StoreError.invalidMove }
        var container = ItemContainer.favorites(profileID: "")
        var parentID: String?
        var index = 0
        switch destination {
        case .pinned(let sid, let parent, let i):
            guard space(sid) != nil else { throw StoreError.notFound }
            if let parent {
                guard let f = item(parent), f.kind == .folder, f.container == .pinned(spaceID: sid) else { throw StoreError.invalidMove }
            }
            container = .pinned(spaceID: sid)
            parentID = parent
            index = i
        case .favorites(let pid, let i):
            guard profile(pid) != nil else { throw StoreError.notFound }
            if favorites(ofProfile: pid).count >= Self.maxFavorites { throw StoreError.favoritesFull }
            container = .favorites(profileID: pid)
            index = i
        default:
            throw StoreError.invalidMove
        }
        let (sid, pid) = binding(of: container)
        let siblings = children(of: container, parent: parentID)
        let share = Dictionary(zip(x.tabIDs, x.fractions), uniquingKeysWith: { a, _ in a })
        var reload: [String] = []
        try perform(nil) {
            remove(Split.self, x.id)
            var s = Item(id: x.id, kind: .split, container: container, parentID: parentID,
                         order: Ordering.insertion(at: min(max(index, 0), siblings.count), in: siblings.map(\.order)), createdAt: now())
            var layout = SplitLayout(axis: x.axis)
            for (k, t) in tabs.enumerated() {
                var p = item(t.itemID) ?? Item(kind: .tab, container: container, savedURL: t.url, pageTitle: t.title,
                                               faviconURL: t.faviconURL, createdAt: now())
                p.container = container
                p.parentID = s.id
                p.order = Double(k)
                put(p)
                layout.shares[p.id] = share[t.id]
                if t.id == x.focusedTabID { layout.focusedItemID = p.id }
                var m = t
                m.itemID = p.id
                m.spaceID = sid
                if m.profileID != pid { m.profileID = pid; reload.append(m.id) }
                put(m)
            }
            s.splitLayout = layout
            put(s)
        }
        if case .favorites = container { Telemetry.shared.record(.featureUsed(.splitFavorite)) } else { Telemetry.shared.record(.featureUsed(.splitPin)) }
        return reload
    }

    /// A pinned or Favorite split dragged somewhere: into Favorites, Pinned (any folder) or Today (where it becomes a
    /// Today split with the same ID; unloaded panes become Today tabs at their saved URLs). Returns the tabs that must
    /// reload in another profile.
    func moveSplitItem(_ id: String, to destination: DropDestination) throws -> [String] {
        guard var s = item(id), s.kind == .split else { throw StoreError.notFound }
        var reload: [String] = []
        switch destination {
        case .favorites(let pid, let index):
            guard profile(pid) != nil else { throw StoreError.notFound }
            let current = favorites(ofProfile: pid)
            if s.container != .favorites(profileID: pid), current.count >= Self.maxFavorites { throw StoreError.favoritesFull }
            let orders = siblingOrders(current, excluding: id, index: index)
            let wasFavorite = s.isFavorite
            try perform(nil) {
                s.container = .favorites(profileID: pid)
                s.parentID = nil
                s.order = Ordering.insertion(at: orders.index, in: orders.orders)
                put(s)
                moveDescendants(of: id, to: s.container, reload: &reload)
            }
            if !wasFavorite { Telemetry.shared.record(.featureUsed(.splitFavorite)) }
        case .pinned(let sid, let parentID, let index):
            guard space(sid) != nil else { throw StoreError.notFound }
            if let parentID {
                guard let f = item(parentID), f.kind == .folder, f.container == .pinned(spaceID: sid) else { throw StoreError.invalidMove }
            }
            let orders = siblingOrders(children(of: .pinned(spaceID: sid), parent: parentID), excluding: id, index: index)
            try perform(nil) {
                s.container = .pinned(spaceID: sid)
                s.parentID = parentID
                s.order = Ordering.insertion(at: orders.index, in: orders.orders)
                put(s)
                moveDescendants(of: id, to: s.container, reload: &reload)
            }
        case .today(let sid, let index):
            guard let sp = space(sid) else { throw StoreError.notFound }
            let rows = todayRows(ofSpace: sid)
            let order = Ordering.insertion(at: min(max(index, 0), rows.count), in: rows.map(rowOrder))
            let panes = self.panes(ofSplitItem: id)
            let layout = s.splitLayout ?? SplitLayout()
            let fractions = layout.fractions(panes.map(\.id))
            try perform(nil) {
                var ids: [String] = []
                var shares: [Double] = []
                var focused: String?
                for (k, p) in panes.enumerated() {
                    var t = liveTab(forItem: p.id) ?? LiveTab(profileID: sp.profileID, spaceID: sid, url: p.savedURL ?? "",
                                                              title: p.pageTitle ?? "", faviconURL: p.faviconURL, createdAt: now())
                    t.itemID = nil
                    t.spaceID = sid
                    t.order = order
                    if t.profileID != sp.profileID { t.profileID = sp.profileID; reload.append(t.id) }
                    put(t)
                    remove(Item.self, p.id)
                    ids.append(t.id)
                    shares.append(fractions[k])
                    if p.id == layout.focusedItemID { focused = t.id }
                }
                remove(Item.self, id)
                if ids.count >= 2 {
                    put(Split(id: id, spaceID: sid, tabIDs: ids, axis: layout.axis, fractions: shares,
                              focusedTabID: focused ?? ids[0], order: order, createdAt: now()))
                }
            }
        case .split:
            throw StoreError.invalidMove
        }
        return reload
    }

    // MARK: Changing a pinned or Favorite split

    /// A tab joins a pinned or Favorite split as a pane at `index` (counting the panes as shown, or every pane when none
    /// is shown; default: last). It
    /// becomes a pane item there (a pinned tab or Favorite brings its item), so it must already be in the split's profile.
    func addPane(_ tabID: String, toSplitItem id: String, at index: Int?, focus: Bool) throws {
        guard let s = item(id), s.kind == .split, var t = tab(tabID) else { throw StoreError.invalidMove }
        let panes = self.panes(ofSplitItem: id)
        guard !panes.contains(where: { $0.id == t.itemID }), !isItemSplitPane(tabID), !NoteURL.isNote(t.url) else { throw StoreError.invalidMove }
        guard panes.count < Split.maxPanes else { throw StoreError.splitFull }
        let (sid, pid) = binding(of: s.container)
        guard t.profileID == pid else { throw StoreError.invalidMove }
        let shown = panes.filter { liveTab(forItem: $0.id) != nil }
        var at = panes.count
        if let i = index, shown.indices.contains(i), let k = panes.firstIndex(where: { $0.id == shown[i].id }) { at = k }
        else if let i = index, shown.isEmpty { at = min(max(i, 0), panes.count) }
        try perform("Split View", undoable: true) {
            leaveSplit(tabID)
            var p = item(t.itemID) ?? Item(kind: .tab, container: s.container, savedURL: t.url, pageTitle: t.title,
                                           faviconURL: t.faviconURL, createdAt: now())
            p.container = s.container
            p.parentID = id
            var list = panes
            list.insert(p, at: at)
            for (k, q) in list.enumerated() {
                var m = q
                m.order = Double(k)
                put(m)
            }
            t.itemID = p.id
            t.spaceID = sid
            put(t)
            // The new pane takes an equal share from the others.
            var i = item(id)!
            var layout = i.splitLayout ?? SplitLayout()
            let n = Double(panes.count)
            let old = layout.fractions(panes.map(\.id))
            layout.shares = Dictionary(uniqueKeysWithValues: zip(panes.map(\.id), old.map { $0 * n / (n + 1) }))
            layout.shares[p.id] = 1 / (n + 1)
            if focus { layout.focusedItemID = p.id }
            i.splitLayout = layout
            put(i)
        }
    }

    /// "Separate All Tabs" on a pinned or Favorite split: its panes become pinned tabs or Favorites of their own where the
    /// split was, in pane order. One undo step.
    func separateSplitItem(_ id: String) throws {
        guard let s = item(id), s.kind == .split else { throw StoreError.notFound }
        let panes = self.panes(ofSplitItem: id)
        if case .favorites(let pid) = s.container, favorites(ofProfile: pid).count - 1 + panes.count > Self.maxFavorites {
            throw StoreError.favoritesFull
        }
        try perform("Separate All Tabs", undoable: true) { dissolve(s, panes: panes) }
    }

    /// "Separate" one pane: it becomes a pinned tab or Favorite of its own just after the split (a split of two ends).
    func separatePane(_ paneID: String) throws {
        guard let s = splitItem(ofPane: paneID), let pane = item(paneID) else { throw StoreError.notFound }
        let panes = self.panes(ofSplitItem: s.id)
        if panes.count <= 2 { return try separateSplitItem(s.id) }
        if case .favorites(let pid) = s.container, favorites(ofProfile: pid).count >= Self.maxFavorites { throw StoreError.favoritesFull }
        try perform("Separate Tab", undoable: true) {
            var m = pane
            m.parentID = s.parentID
            m.order = (s.order + nextSiblingOrder(after: s)) / 2
            put(m)
            tidySplitItem(s.id)
        }
    }

    func setItemSplitFractions(_ id: String, _ fractions: [Double]) {
        guard var s = item(id), s.kind == .split, let x = itemSplit(id) else { return }
        let loaded = x.tabIDs.compactMap { tab($0)?.itemID }
        let all = panes(ofSplitItem: id).map(\.id)
        var layout = s.splitLayout ?? SplitLayout()
        let current = layout.fractions(all)
        // Panes that aren't loaded keep their shares; the loaded ones share the rest.
        var shares: [String: Double] = [:]
        for (p, v) in zip(all, current) where !loaded.contains(p) { shares[p] = v }
        let rest = 1 - shares.values.reduce(0, +)
        for (p, v) in zip(loaded, Split.normalized(fractions, count: loaded.count)) { shares[p] = v * rest }
        guard shares != layout.shares else { return }
        layout.shares = shares
        s.splitLayout = layout
        try? perform(nil, deferred: true, contentOnly: true) { put(s) }
    }

    func setItemSplitAxis(_ id: String, _ axis: SplitAxis) throws {
        guard var s = item(id), s.kind == .split else { throw StoreError.notFound }
        var layout = s.splitLayout ?? SplitLayout()
        guard layout.axis != axis else { return }
        layout.axis = axis
        s.splitLayout = layout
        try perform(nil) { put(s) }
    }

    func setItemSplitFocus(_ id: String, _ tabID: String) {
        guard var s = item(id), s.kind == .split, let pane = tab(tabID)?.itemID, item(pane)?.parentID == id else { return }
        var layout = s.splitLayout ?? SplitLayout()
        guard layout.focusedItemID != pane else { return }
        layout.focusedItemID = pane
        s.splitLayout = layout
        try? perform(nil, deferred: true, contentOnly: true) { put(s) }
    }

    /// Moves the shown pane at `from` to `to`; each pane keeps its size (shares go by pane).
    func moveItemSplitPane(_ id: String, from: Int, to: Int) throws {
        guard let x = itemSplit(id), x.tabIDs.indices.contains(from), x.tabIDs.indices.contains(to) else { throw StoreError.invalidMove }
        guard from != to else { return }
        var panes = self.panes(ofSplitItem: id)
        guard let a = panes.firstIndex(where: { $0.id == tab(x.tabIDs[from])?.itemID }),
              let b = panes.firstIndex(where: { $0.id == tab(x.tabIDs[to])?.itemID }) else { throw StoreError.invalidMove }
        panes.insert(panes.remove(at: a), at: b)
        try perform(nil) {
            for (k, q) in panes.enumerated() where q.order != Double(k) {
                var m = q
                m.order = Double(k)
                put(m)
            }
        }
    }

    // MARK: Inside transactions

    /// After a pane left (dragged out, separated): a split of one pane ends (that pane takes its place), an empty one
    /// goes, and the layout forgets the pane.
    func tidySplitItem(_ id: String) {
        guard var s = item(id), s.kind == .split else { return }
        let panes = self.panes(ofSplitItem: id)
        if panes.count < 2 { return dissolve(s, panes: panes) }
        guard var layout = s.splitLayout else { return }
        let ids = Set(panes.map(\.id))
        let before = layout
        layout.shares = layout.shares.filter { ids.contains($0.key) }
        if let f = layout.focusedItemID, !ids.contains(f) { layout.focusedItemID = panes[0].id }
        if layout != before { s.splitLayout = layout; put(s) }
    }

    /// The panes take the split's place among its siblings, in pane order, and the split item goes.
    private func dissolve(_ s: Item, panes: [Item]) {
        let next = nextSiblingOrder(after: s)
        for (k, p) in panes.enumerated() {
            var m = p
            m.parentID = s.parentID
            m.container = s.container
            m.order = s.order + (next - s.order) * Double(k) / Double(panes.count)
            put(m)
        }
        remove(Item.self, s.id)
    }

    private func nextSiblingOrder(after s: Item) -> Double {
        let siblings = children(of: s.container, parent: s.parentID)
        guard let i = siblings.firstIndex(where: { $0.id == s.id }), i + 1 < siblings.count else { return s.order + 1 }
        return siblings[i + 1].order
    }

    /// Copies a split's panes under the copy `to` (⌥-drag, Duplicate), with the layout pointing at the copies.
    func copyPanes(from: String, to: String, container: ItemContainer) {
        var map: [String: String] = [:]
        for p in panes(ofSplitItem: from) {
            var c = p
            c.id = newID()
            c.parentID = to
            c.container = container
            c.createdAt = now()
            put(c)
            map[p.id] = c.id
        }
        guard var copy = item(to), var layout = copy.splitLayout else { return }
        layout.shares = Dictionary(uniqueKeysWithValues: layout.shares.compactMap { k, v in map[k].map { ($0, v) } })
        layout.focusedItemID = layout.focusedItemID.flatMap { map[$0] }
        copy.splitLayout = layout
        put(copy)
    }
}
