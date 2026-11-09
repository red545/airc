// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// What the sidebar shows, in order, and the geometry rules Arc uses for the Favorites grid
// and the Space bar. Pure functions so they can be tested without a UI.

/// One row of a Space's sidebar, top to bottom.
public enum SidebarEntry: Hashable, Sendable {
    case favorite(Item, LiveTab?)
    case pinned(Item, depth: Int, LiveTab?)
    case folder(Item, depth: Int)
    case today(LiveTab)
    /// SV-1: a split, one row in Today, with its tabs in pane order.
    case split(Split, [LiveTab])

    /// The tab the row opens: a split's focused pane.
    public var liveTab: LiveTab? {
        switch self {
        case .favorite(_, let t), .pinned(_, _, let t): t
        case .today(let t): t
        case .split(let x, let tabs): tabs.first { $0.id == x.focusedTabID } ?? tabs.first
        case .folder: nil
        }
    }

    public var item: Item? {
        switch self {
        case .favorite(let i, _), .pinned(let i, _, _), .folder(let i, _): i
        case .today, .split: nil
        }
    }

    /// Stable identity for the UI: the item's ID, the Today tab's ID or the split's.
    public var id: String {
        if case .split(let x, _) = self { return x.id }
        return item?.id ?? liveTab!.id
    }

    /// The split this row is, if it is one.
    public var split: Split? {
        if case .split(let x, _) = self { return x }
        return nil
    }

    /// Whether the row shows `tabID` (a split row shows all its panes).
    public func shows(_ tabID: String?) -> Bool {
        guard let tabID else { return false }
        if case .split(_, let tabs) = self { return tabs.contains { $0.id == tabID } }
        return liveTab?.id == tabID
    }
}

extension SpacesStore {
    /// The pinned tree of a Space, flattened with depth. Collapsed folders hide their contents.
    public func pinnedRows(ofSpace spaceID: String) -> [SidebarEntry] {
        var out: [SidebarEntry] = []
        func walk(_ parent: String?, depth: Int) {
            for i in children(of: .pinned(spaceID: spaceID), parent: parent) {
                if i.kind == .folder {
                    out.append(.folder(i, depth: depth))
                    if !i.isCollapsed { walk(i.id, depth: depth + 1) }
                } else if i.kind == .split {
                    // SV-2: a pinned split is one row; it opens to its focused pane.
                    out.append(.pinned(i, depth: depth, liveTab(forSplitItem: i.id)))
                } else {
                    out.append(.pinned(i, depth: depth, liveTab(forItem: i.id)))
                }
            }
        }
        walk(nil, depth: 0)
        return out
    }

    /// Everything in a Space's sidebar in display order: Favorites (of its profile), pinned rows,
    /// Today tabs. With `skippingCollapsed`, a folded pinned section is left out (Arc's keyboard
    /// navigation skips it).
    public func sidebarEntries(ofSpace spaceID: String, skippingCollapsed: Bool = true) -> [SidebarEntry] {
        guard let s = space(spaceID) else { return [] }
        var out = favorites(ofProfile: s.profileID).map {
            SidebarEntry.favorite($0, $0.kind == .split ? liveTab(forSplitItem: $0.id) : liveTab(forItem: $0.id))
        }
        if !(skippingCollapsed && s.pinnedCollapsed) { out += pinnedRows(ofSpace: spaceID) }
        out += todayRows(ofSpace: spaceID)
        return out
    }

    /// ⌘1–⌘8 open the Nth sidebar tab, ⌘9 the last one (CB-2), with Arc's two choices (K02): Favorites count first
    /// unless "Include Favorites in ordering" is off, and ⌘9 is the ninth item with "Switch to ninth tab" on. Folders
    /// don't count; a folded pinned section and closed folders' tabs are skipped, as the keyboard skips them in Arc; an
    /// unloaded pinned tab or Favorite counts (the key loads it); a split is one item.
    public func commandNumberTarget(_ n: Int, inSpace spaceID: String,
                                    preferences: SidebarNavigationPreferences = SidebarNavigation.preferences) -> SidebarEntry? {
        let tabs = sidebarEntries(ofSpace: spaceID).filter {
            switch $0 {
            case .folder: return false
            case .favorite: return preferences.includeFavoritesInOrdering
            default: return true
            }
        }
        guard n >= 1, !tabs.isEmpty else { return nil }
        if n >= 9, !preferences.switchToNinthItem { return tabs.last }
        return n <= tabs.count ? tabs[n - 1] : nil
    }

    /// ⌥⌘↑ / ⌥⌘↓: the previous or next tab in sidebar order, wrapping.
    public func adjacentEntry(to currentID: String?, offset: Int, inSpace spaceID: String) -> SidebarEntry? {
        let tabs = sidebarEntries(ofSpace: spaceID).filter {
            if case .folder = $0 { return false }
            return true
        }
        guard !tabs.isEmpty else { return nil }
        guard let currentID, let i = tabs.firstIndex(where: { $0.shows(currentID) || $0.id == currentID })
        else { return offset >= 0 ? tabs.first : tabs.last }
        let j = ((i + offset) % tabs.count + tabs.count) % tabs.count
        return tabs[j]
    }
}

/// Arc's Favorites grid rule (SB-11, Arc ref §2.3).
public enum FavoritesGrid {
    public static let tileHeight: Double = 47
    public static let gap: Double = 8
    public static let minTileWidth: Double = 47
    public static let maxColumns = 4

    public struct Layout: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var tileWidth: Double
        public var height: Double
    }

    /// Take the most columns (≤ 4) that keep tiles ≥ 47 pt wide; then the fewest columns that
    /// need no more rows. A short last row keeps the tile width and is left-aligned.
    public static func layout(count: Int, width: Double) -> Layout {
        guard count > 0 else { return Layout(columns: 0, rows: 0, tileWidth: 0, height: 0) }
        func tileWidth(_ cols: Int) -> Double { (width - Double(cols - 1) * gap) / Double(cols) }
        var maxCols = maxColumns
        while maxCols > 1 && tileWidth(maxCols) < minTileWidth { maxCols -= 1 }
        maxCols = min(maxCols, count)
        let rows = (count + maxCols - 1) / maxCols
        var cols = maxCols
        while cols > 1 && (count + cols - 2) / (cols - 1) <= rows { cols -= 1 }
        let w = tileWidth(cols)
        return Layout(columns: cols, rows: rows, tileWidth: w,
                      height: Double(rows) * tileHeight + Double(rows - 1) * gap)
    }

    /// Frame of tile `index` (origin top-left, y down) for a layout.
    public static func frame(index: Int, layout: Layout) -> (x: Double, y: Double, w: Double, h: Double) {
        let c = index % max(layout.columns, 1)
        let r = index / max(layout.columns, 1)
        return (Double(c) * (layout.tileWidth + gap), Double(r) * (tileHeight + gap), layout.tileWidth, tileHeight)
    }
}

/// Arc's Space bar squeeze (SB-51, Arc ref §2.9): cells are at most 34 pt; when a share would drop
/// below 22 pt the current Space keeps 22 and the others share the rest.
public enum SpaceBarLayout {
    public static let maxCell: Double = 34
    public static let minCurrent: Double = 22

    public static func cellWidths(count: Int, current: Int, span: Double) -> [Double] {
        guard count > 0 else { return [] }
        let share = min(maxCell, span / Double(count))
        if share >= minCurrent || count == 1 { return Array(repeating: share, count: count) }
        let others = (span - minCurrent) / Double(count - 1)
        return (0..<count).map { $0 == current ? minCurrent : max(0, others) }
    }

    /// The span between the Library button and "+": 42 pt from each edge.
    public static func span(sidebarWidth: Double) -> Double { max(0, sidebarWidth - 84) }
}
