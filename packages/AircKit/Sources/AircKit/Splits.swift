// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// SV-1 Split View (spec §2.16b, Arc ref §2.11 and §5). Arc keeps a split as one sidebar item that holds its tabs, with
// each tab's width factor, one orientation and the focused tab (`SidebarSplitViewData { itemWidthFactors,
// layoutOrientation, focusItemID }`). Here a split is its own entity: the tabs stay ordinary live tabs (each keeps its
// Space, profile and page), and the split says which ones show together, in which order and at which sizes. It is one
// row in its Space's Today list, at `order` (the same scale as Today tabs' orders); its tabs aren't rows of their own.
//
// A split's tabs are usually Today tabs of its Space. A pinned tab or Favorite can be one of them too (Peek → Split
// from a pinned app); its own row stays where it is. A Today tab of another Space can join (a cross-Space split): it
// keeps its Space and profile, and shows in this Space's split row until it leaves.

/// How a split's panes sit.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Side by side, left to right (Arc's "New Right Split").
    case horizontal
    /// Stacked, top to bottom (Arc's "New Bottom Split").
    case vertical
}

extension SplitAxis {
    public init(from decoder: Decoder) throws {
        self = SplitAxis(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .horizontal
    }
}

public struct Split: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// The Space whose Today list shows the split's row.
    public var spaceID: String
    /// The panes' tabs, in order (left to right, or top to bottom). 2–4.
    public var tabIDs: [String]
    public var axis: SplitAxis
    /// Each pane's share of the split along `axis`, in `tabIDs` order; they add up to 1.
    public var fractions: [Double]
    /// The pane that has the keyboard (⌘L, ⌘W, find and zoom act on it).
    public var focusedTabID: String?
    /// Position in Today (smaller is higher), on the same scale as LiveTab.order.
    public var order: Double
    public var createdAt: Date
    /// SV-2: the pinned or Favorite split item this split shows, nil for a Today split. Such a split isn't a stored
    /// Split: the store makes it from the item and its loaded panes (ItemSplits.swift), with the item's ID.
    public var itemID: String? = nil

    public static let maxPanes = 4

    public init(id: String = newID(), spaceID: String, tabIDs: [String], axis: SplitAxis = .horizontal,
                fractions: [Double]? = nil, focusedTabID: String? = nil, order: Double = 0, createdAt: Date = Date()) {
        self.id = id
        self.spaceID = spaceID
        self.tabIDs = tabIDs
        self.axis = axis
        self.fractions = fractions ?? Array(repeating: 1 / Double(max(tabIDs.count, 1)), count: tabIDs.count)
        self.focusedTabID = focusedTabID ?? tabIDs.first
        self.order = order
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, spaceID, tabIDs, axis, fractions, focusedTabID, order, createdAt }

    /// Fields a newer Airc may leave out read as their defaults (code review H4).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        spaceID = try c.decode(String.self, forKey: .spaceID)
        tabIDs = try c.decode([String].self, forKey: .tabIDs)
        axis = try c.decodeIfPresent(SplitAxis.self, forKey: .axis) ?? .horizontal
        fractions = try c.decodeIfPresent([Double].self, forKey: .fractions) ?? []
        focusedTabID = try c.decodeIfPresent(String.self, forKey: .focusedTabID)
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    /// One fraction per pane, each above zero, adding up to 1, and the focus on a pane.
    public var isNormalized: Bool {
        fractions.count == tabIDs.count && fractions.allSatisfy { $0 > 0 }
            && abs(fractions.reduce(0, +) - 1) < 1e-9 && (focusedTabID.map(tabIDs.contains) ?? false)
    }

    /// Keeps only `members` (in their order here); a pane that goes gives its share to the others in proportion.
    public mutating func keep(_ members: [String]) {
        var shares: [Double] = []
        for id in members {
            let i = tabIDs.firstIndex(of: id)
            shares.append(i.flatMap { fractions.indices.contains($0) ? fractions[$0] : nil } ?? 0)
        }
        tabIDs = members
        fractions = Self.normalized(shares, count: members.count)
        if focusedTabID.map(members.contains) != true { focusedTabID = members.first }
    }

    /// `shares` scaled to add up to 1; missing or non-positive shares become equal ones.
    public static func normalized(_ shares: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        var s = Array(shares.prefix(count))
        while s.count < count { s.append(0) }
        let fill = 1 / Double(count)
        s = s.map { $0.isFinite && $0 > 0 ? $0 : fill }
        let total = s.reduce(0, +)
        return s.map { $0 / total }
    }
}

extension SpacesStore {
    // MARK: Queries

    /// A Today split, or (SV-2) a pinned or Favorite split with at least two panes loaded.
    public func split(_ id: String?) -> Split? { id.flatMap { state.splits[$0] ?? itemSplit($0) } }

    /// The split showing `tabID`, if any.
    public func split(containing tabID: String?) -> Split? {
        guard let tabID else { return nil }
        if let x = state.splits.values.first(where: { $0.tabIDs.contains(tabID) }) { return x }
        return splitItem(ofPane: tab(tabID)?.itemID).flatMap { itemSplit($0.id) }
    }

    public func splits(ofSpace id: String) -> [Split] {
        state.splits.values.filter { $0.spaceID == id }.sorted { ($0.order, $0.createdAt, $0.id) < ($1.order, $1.createdAt, $1.id) }
    }

    /// A split's tabs, in pane order (tabs that are gone are left out).
    public func members(of split: Split) -> [LiveTab] { split.tabIDs.compactMap { tab($0) } }

    /// A Space's Today list as rows, top first: its Today tabs that aren't in a split, and its splits (one row each).
    public func todayRows(ofSpace id: String) -> [SidebarEntry] {
        let inSplits = Set(state.splits.values.flatMap(\.tabIDs))
        var rows: [(order: Double, created: Date, id: String, entry: SidebarEntry)] = state.tabs.values
            .filter { $0.itemID == nil && $0.spaceID == id && !inSplits.contains($0.id) }
            .map { ($0.order, $0.createdAt, $0.id, .today($0)) }
        for x in splits(ofSpace: id) {
            let m = members(of: x)
            guard m.count >= 2 else { continue }
            rows.append((x.order, x.createdAt, x.id, .split(x, m)))
        }
        return rows.sorted { ($0.order, $0.created, $0.id) < ($1.order, $1.created, $1.id) }.map(\.entry)
    }

    /// The tabs a Space's Today list shows, top first, a split's in pane order (what Clear and Archive Tabs Below see).
    public func todayRowTabs(ofSpace id: String) -> [LiveTab] {
        todayRows(ofSpace: id).flatMap { e -> [LiveTab] in
            switch e {
            case .split(_, let tabs): tabs.filter(\.isToday)
            default: e.liveTab.map { [$0] } ?? []
            }
        }
    }

    /// The Today order of a row (a tab's or a split's).
    func rowOrder(_ e: SidebarEntry) -> Double {
        switch e {
        case .split(let x, _): x.order
        default: e.liveTab?.order ?? 0
        }
    }

    /// The order of the top of a Space's Today list.
    func topOfToday(_ spaceID: String, excluding id: String? = nil) -> Double {
        Ordering.between(nil, todayRows(ofSpace: spaceID).first { $0.id != id }.map(rowOrder))
    }

    // MARK: Making and changing splits

    /// Whether `tabID` can be a pane of a Today split: any tab, and a note while it's in Today (New Note in Split,
    /// Arc's "a new Note beside your current page"). A pinned note isn't one, and a split holding a note never becomes
    /// a pinned or Favorite split (pinSplit); drags never put a note in a split (dropIntoSplit).
    func canBeTodayPane(_ tabID: String) -> Bool { !isNoteTab(tabID) || tab(tabID)?.isToday == true }

    /// A split of `tabIDs` (2–4 distinct live tabs, in pane order) shown in `spaceID`'s Today list at `order` (default:
    /// where its first Today tab of that Space was, else the top). Tabs in another split leave it. One undo step.
    @discardableResult
    public func createSplit(_ tabIDs: [String], inSpace spaceID: String, axis: SplitAxis = .horizontal,
                            focused: String? = nil, order: Double? = nil) throws -> Split {
        var seen = Set<String>()
        let ids = tabIDs.filter { seen.insert($0).inserted }
        guard space(spaceID) != nil, (2...Split.maxPanes).contains(ids.count), ids.allSatisfy({ tab($0) != nil }),
              !ids.contains(where: isItemSplitPane), ids.allSatisfy(canBeTodayPane) else {
            throw StoreError.invalidMove
        }
        let place = order ?? ids.compactMap { tab($0) }.filter { $0.isToday && $0.spaceID == spaceID && split(containing: $0.id) == nil }
            .map(\.order).min() ?? topOfToday(spaceID)
        let x = Split(spaceID: spaceID, tabIDs: ids, axis: axis, focusedTabID: focused.flatMap { ids.contains($0) ? $0 : nil },
                      order: place, createdAt: now())
        try perform("Split View", undoable: true) {
            for id in ids { leaveSplit(id) }
            put(x)
            if var s = space(spaceID), let f = x.focusedTabID, s.lastActiveTabID != f { s.lastActiveTabID = f; put(s) }
        }
        return split(x.id)!
    }

    /// Adds `tabID` as a pane at `index` (default: last). The new pane takes an equal share from the others.
    public func addToSplit(_ splitID: String, tabID: String, at index: Int? = nil, focus: Bool = true) throws {
        if state.splits[splitID] == nil, item(splitID)?.kind == .split { return try addPane(tabID, toSplitItem: splitID, at: index, focus: focus) }
        guard var x = split(splitID), tab(tabID) != nil, !x.tabIDs.contains(tabID), !isItemSplitPane(tabID), canBeTodayPane(tabID) else { throw StoreError.invalidMove }
        guard x.tabIDs.count < Split.maxPanes else { throw StoreError.splitFull }
        let n = Double(x.tabIDs.count)
        let i = min(max(index ?? x.tabIDs.count, 0), x.tabIDs.count)
        try perform("Split View", undoable: true) {
            leaveSplit(tabID)
            x = split(splitID) ?? x
            x.fractions = x.fractions.map { $0 * n / (n + 1) }
            x.tabIDs.insert(tabID, at: i)
            x.fractions.insert(1 / (n + 1), at: i)
            x.fractions = Split.normalized(x.fractions, count: x.tabIDs.count)
            if focus { x.focusedTabID = tabID }
            put(x)
        }
    }

    /// "Separate All Tabs" (Arc): every pane becomes a tab of its own again, where the split's row was, in pane order.
    /// One undo step.
    public func separateSplit(_ splitID: String) throws {
        if state.splits[splitID] == nil, item(splitID)?.kind == .split { return try separateSplitItem(splitID) }
        guard let x = split(splitID) else { throw StoreError.notFound }
        try perform("Separate All Tabs", undoable: true) {
            remove(Split.self, x.id)
            placeInToday(x.tabIDs, at: x)
        }
    }

    /// One pane leaves the split and becomes a tab of its own, just below the split's row (or where the row was, if
    /// that leaves a single pane). One undo step.
    public func removeFromSplit(_ tabID: String) throws {
        if let pane = tab(tabID)?.itemID, splitItem(ofPane: pane) != nil { return try separatePane(pane) }
        guard let x = split(containing: tabID) else { throw StoreError.notFound }
        try perform("Separate Tab", undoable: true) {
            leaveSplit(tabID)
            if split(x.id) == nil { placeInToday(x.tabIDs, at: x) } else { placeInToday([tabID], at: x, after: true) }
        }
    }

    /// Divider drags: the panes' new shares. Written with the next flush; changes no sidebar row.
    public func setSplitFractions(_ splitID: String, _ fractions: [Double]) {
        guard var x = state.splits[splitID] else { return setItemSplitFractions(splitID, fractions) }
        let f = Split.normalized(fractions, count: x.tabIDs.count)
        guard f != x.fractions else { return }
        x.fractions = f
        try? perform(nil, deferred: true, contentOnly: true) { put(x) }
    }

    public func setSplitAxis(_ splitID: String, _ axis: SplitAxis) throws {
        guard var x = state.splits[splitID] else { return try setItemSplitAxis(splitID, axis) }
        guard x.axis != axis else { return }
        x.axis = axis
        try perform(nil) { put(x) }
    }

    /// The pane with the keyboard. Written with the next flush (it changes on every pane click).
    public func setSplitFocus(_ splitID: String, _ tabID: String) {
        guard state.splits[splitID] != nil else { return setItemSplitFocus(splitID, tabID) }
        guard var x = split(splitID), x.tabIDs.contains(tabID), x.focusedTabID != tabID else { return }
        x.focusedTabID = tabID
        try? perform(nil, deferred: true, contentOnly: true) { put(x) }
    }

    /// Moves the pane at `from` to `to` (pane order), keeping each pane's size.
    public func movePane(_ splitID: String, from: Int, to: Int) throws {
        if state.splits[splitID] == nil, item(splitID)?.kind == .split { return try moveItemSplitPane(splitID, from: from, to: to) }
        guard var x = split(splitID), x.tabIDs.indices.contains(from), x.tabIDs.indices.contains(to) else { throw StoreError.invalidMove }
        guard from != to else { return }
        let t = x.tabIDs.remove(at: from), f = x.fractions.remove(at: from)
        x.tabIDs.insert(t, at: to)
        x.fractions.insert(f, at: to)
        try perform(nil) { put(x) }
    }

    /// SB-35 / SV-1: a tab dropped on a Today row of `spaceID`. On a tab, the two become a split (the dropped tab first
    /// when `leading`); on a split (or a tab in one), the tab joins it next to its target. The dropped tab keeps its
    /// own Space and profile, so a tab dragged in from another Space keeps its logins (a cross-Space split).
    func dropIntoSplit(_ tabID: String, inSpace spaceID: String, onto target: String, leading: Bool) throws {
        // Notes are never panes (Notes.swift): not dropped onto a row, and nothing dropped onto theirs.
        guard tab(tabID) != nil, target != tabID, space(spaceID) != nil, !isNoteTab(tabID), !isNoteTab(target),
              !NoteURL.isNote(item(target)?.savedURL) else { throw StoreError.invalidMove }
        // SV-2: a pinned or Favorite split's pane leaves it for Today first, in the same undo step.
        if isItemSplitPane(tabID) {
            return try perform("Split View", undoable: true) {
                _ = try move(.tab(tabID), to: .today(spaceID: spaceID, index: 0))
                try dropIntoSplit(tabID, inSpace: spaceID, onto: target, leading: leading)
            }
        }
        // SV-2: onto a pinned split's row (open or not): one more pane, first or last.
        if let s = item(target), s.kind == .split {
            return try addPane(tabID, toSplitItem: target, at: leading ? 0 : nil, focus: true)
        }
        if let x = split(target) ?? split(containing: target) {
            guard !x.tabIDs.contains(tabID) else { throw StoreError.invalidMove }
            let at: Int
            if x.id == target { at = leading ? 0 : x.tabIDs.count }
            else { at = (x.tabIDs.firstIndex(of: target) ?? 0) + (leading ? 0 : 1) }
            try addToSplit(x.id, tabID: tabID, at: at)
            return
        }
        guard let t = tab(target) else { throw StoreError.invalidMove }
        let order = t.isToday && t.spaceID == spaceID ? t.order : nil
        try createSplit(leading ? [tabID, target] : [target, tabID], inSpace: spaceID, focused: tabID, order: order)
    }

    /// A split's row dragged within its Space's Today list (`index` counts the rows as shown before the move).
    func moveSplit(_ splitID: String, to destination: DropDestination) throws -> [String] {
        // SV-2: a Today split dragged above the divider (or a pinned one's split value): pinned or a Favorite.
        if state.splits[splitID] == nil, item(splitID)?.kind == .split { return try move(.item(splitID), to: destination) }
        switch destination {
        case .pinned, .favorites: return try pinSplit(splitID, to: destination)
        default: break
        }
        guard var x = split(splitID), case .today(let sid, let index) = destination, sid == x.spaceID else {
            throw StoreError.invalidMove
        }
        let rows = todayRows(ofSpace: sid)
        let others = rows.filter { $0.id != splitID }
        var adjusted = index
        if let si = rows.firstIndex(where: { $0.id == splitID }), si < index { adjusted -= 1 }
        x.order = Ordering.insertion(at: min(max(adjusted, 0), others.count), in: others.map(rowOrder))
        try perform("Move", undoable: true) { put(x) }
        return []
    }

    // MARK: Inside transactions

    /// Takes `tabID` out of the Today split it's in (if any). A split left with one pane is removed. (A pinned or
    /// Favorite split's panes leave through their items: ItemSplits.swift.)
    func leaveSplit(_ tabID: String) {
        guard var x = state.splits.values.first(where: { $0.tabIDs.contains(tabID) }) else { return }
        x.keep(x.tabIDs.filter { $0 != tabID && tab($0) != nil })
        if x.tabIDs.count < 2 { remove(Split.self, x.id) } else { put(x) }
    }

    /// Gives the Today tabs among `tabIDs` that belong to the split's Space consecutive orders where the split's row is
    /// (or just below it, `after`), in the order given. Other tabs (pinned, Favorites, another Space's) keep theirs.
    private func placeInToday(_ tabIDs: [String], at x: Split, after: Bool = false) {
        let mine = tabIDs.compactMap { tab($0) }.filter { $0.isToday && $0.spaceID == x.spaceID }
        guard !mine.isEmpty else { return }
        let orders = todayRows(ofSpace: x.spaceID).filter { e in
            if case .today(let t) = e { return !tabIDs.contains(t.id) }
            return e.id != x.id
        }.map(rowOrder)
        let lo = after ? x.order : orders.filter { $0 < x.order }.max() ?? x.order - 1
        let hi = after ? orders.filter { $0 > x.order }.min() ?? x.order + 1 : x.order
        for (k, t) in mine.enumerated() {
            var m = t
            m.order = lo + (hi - lo) * Double(k + 1) / Double(mine.count + 1)
            put(m)
        }
    }
}
