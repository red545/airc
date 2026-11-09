// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// K06, Arc's tab switcher without a switcher on screen (Arc 1.170 shows the last-used tab at once): ⌃Tab goes to the
/// tab used before this one; pressing Tab again while ⌃ is still held goes one further back through the recent tabs,
/// ⌃⇧Tab one forward again, as ⌘Tab does with apps. The walk follows the order at the first press (each tab shown on the
/// way is used again, which would otherwise reshuffle it), keeps to Arc's five most recent tabs (Arc's help), wraps,
/// and ends when ⌃ is let go. As with ⌘Tab, only where it stops counts as used: the tabs passed on the way get their
/// last use back (`lastUse`, `SpacesStore.restoreLastUse`).
public struct TabSwitcherWalk: Equatable, Sendable {
    /// The recent tabs at the first press, most recent first: [0] is the tab that was on screen.
    public let order: [String]
    public private(set) var index = 0
    /// When each tab in `order` was last used at the first press.
    public let lastUse: [String: Date]

    /// Arc's help: "the five most recent tabs".
    public static let depth = 5

    /// Nil when there's nothing to switch to (no other recent tab).
    public init?(recent: [String], current: String?, lastUse: [String: Date] = [:]) {
        var seen = Set<String>()
        var o: [String] = []
        if let current { o.append(current); seen.insert(current) }
        for id in recent where seen.insert(id).inserted { o.append(id) }
        o = Array(o.prefix(Self.depth))
        guard o.count >= 2 || (current == nil && !o.isEmpty) else { return nil }
        order = o
        index = current == nil ? -1 : 0
        self.lastUse = lastUse.filter { o.contains($0.key) }
    }

    /// One step: +1 back in time (⌃Tab), -1 forward again (⌃⇧Tab). The tab to show.
    public mutating func step(_ offset: Int) -> String {
        let n = order.count
        index = ((index + offset) % n + n) % n
        return order[index]
    }
}

extension SpacesStore {
    /// The live tabs of a Space's sidebar (Favorites, pinned, Today, a split once by its focused pane), most recently used
    /// first.
    public func recentTabs(inSpace spaceID: String) -> [String] {
        TabMRU.order(sidebarEntries(ofSpace: spaceID, skippingCollapsed: false).compactMap(\.liveTab)
            .map { TabMRU.Use(id: $0.id, lastUse: $0.lastActiveAt) })
    }

    /// When these tabs were last used.
    public func lastUse(of ids: [String]) -> [String: Date] {
        Dictionary(ids.compactMap { id in tab(id).map { (id, $0.lastActiveAt) } }, uniquingKeysWith: { a, _ in a })
    }

    /// A switcher walk ended on `kept`: the other tabs it showed on the way get their last use back.
    public func restoreLastUse(_ dates: [String: Date], except kept: String?) throws {
        let changes = dates.filter { $0.key != kept && tab($0.key) != nil }
        guard !changes.isEmpty else { return }
        try perform(nil, contentOnly: true) {
            for (id, d) in changes { if var t = tab(id) { t.lastActiveAt = d; put(t) } }
        }
    }
}

// MARK: P03b, Arc's Cycle Tab

/// The order Airc's recent-tab keys share (K06: ⌃Tab's walk and ⌃⌘← ⌃⌘→'s cycle): a Space's tabs, the one used last
/// first. A private window's pages never count (Airc keeps nothing of them, PrivateWindow.swift): they're left out even
/// when a caller hands them in, so no main window's keys can land on one.
public enum TabMRU {
    public struct Use: Equatable, Sendable {
        public var id: String
        public var lastUse: Date
        public var isPrivate: Bool

        public init(id: String, lastUse: Date, isPrivate: Bool = false) {
            self.id = id
            self.lastUse = lastUse
            self.isPrivate = isPrivate
        }
    }

    /// Most recently used first; tabs used in the same instant by ID, so the order is stable.
    public static func order(_ uses: [Use]) -> [String] {
        var seen = Set<String>()
        return uses.filter { !$0.isPrivate }
            .sorted { ($0.lastUse, $0.id) > ($1.lastUse, $1.id) }
            .compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }
}

/// Arc's Cycle Tab Forward and Cycle Tab Backward (⌃⌘→ ⌃⌘←, in Arc 1.171's menus): every tab of the Space in the
/// order they were last used, not only ⌃Tab's five. Forward goes back in time (the tab used before, then the one
/// before that), Backward the other way, and both wrap.
///
/// Repeated presses go on through the order as it was at the first press (the tabs shown on the way would otherwise
/// reshuffle it) for as long as the tab on screen is the one the cycle showed, whether or not the keys were let go in
/// between. Showing a tab any other way (a click, ⌘1, a new tab, another Space) starts the next cycle from the new
/// order. As with ⌃Tab and ⌘Tab only where it stops counts as used: each step gives the tabs it passed their last use
/// back (`lastUse`, `SpacesStore.restoreLastUse`). A tab closed meanwhile drops out at the next step.
public struct TabCycle: Equatable, Sendable {
    /// The Space whose tabs these are: another Space's keys start a cycle of their own.
    public let spaceID: String
    /// The Space's tabs at the first press, most recent first: [0] is the tab that was on screen.
    public private(set) var order: [String]
    /// The stop shown now; -1 before the first step when nothing was on screen.
    public private(set) var index: Int
    /// When each tab in `order` was last used at the first press.
    public let lastUse: [String: Date]

    /// Nil when there's nothing to cycle to (no other tab in the Space).
    public init?(spaceID: String, recent: [String], current: String?, lastUse: [String: Date] = [:]) {
        var seen = Set<String>()
        var o: [String] = []
        if let current { o.append(current); seen.insert(current) }
        for id in recent where seen.insert(id).inserted { o.append(id) }
        guard o.count >= 2 || (current == nil && !o.isEmpty) else { return nil }
        self.spaceID = spaceID
        order = o
        index = current == nil ? -1 : 0
        self.lastUse = lastUse.filter { o.contains($0.key) }
    }

    /// The tab the cycle showed last (the one on screen at the first press before any step).
    public var stop: String? { order.indices.contains(index) ? order[index] : nil }

    /// The next press goes on with this cycle: it's this Space's, and the tab on screen is still the cycle's.
    public func continues(inSpace spaceID: String, shown: String?) -> Bool {
        self.spaceID == spaceID && shown != nil && shown == stop
    }

    /// One step, +1 Forward (back in time) or -1 Backward, over the tabs still `open`. The tab to show; nil when no
    /// other tab is left.
    public mutating func step(_ offset: Int, open: Set<String>) -> String? {
        let current = stop
        order.removeAll { $0 != current && !open.contains($0) }
        index = current.flatMap { order.firstIndex(of: $0) } ?? -1
        let n = order.count
        if index < 0 {
            guard n > 0 else { return nil }
            index = offset >= 0 ? 0 : n - 1
            return order[index]
        }
        guard n >= 2 else { return nil }
        index = ((index + offset) % n + n) % n
        return order[index]
    }
}
