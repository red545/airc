// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// The sidebar without a mouse (K02, K04, W03): the user's numeric-order and Option-reveal choices, and the pure rules
// for moving a keyboard focus through every section (Favorites, the Space header, pinned rows and folders, Today).

/// What Settings → Shortcuts keeps about the sidebar's keys. Arc has the first two in the same pane, under the shortcut
/// list ("Include Favorites in ordering.", "Switch to ninth tab.").
public struct SidebarNavigationPreferences: Codable, Equatable, Sendable {
    /// Arc's "Include Favorites in ordering." (on): ⌘1 is the first Favorite. Off: ⌘1 is the first item after them.
    public var includeFavoritesInOrdering: Bool
    /// Arc's "Switch to ninth tab." (off): ⌘9 jumps to the last item at the bottom of the sidebar. On: the ninth item.
    public var switchToNinthItem: Bool
    /// Holding ⌥ alone briefly shows a hidden sidebar (Arc ref §2.10); Settings can turn it off.
    public var optionRevealsSidebar: Bool

    public init(includeFavoritesInOrdering: Bool = true, switchToNinthItem: Bool = false, optionRevealsSidebar: Bool = true) {
        self.includeFavoritesInOrdering = includeFavoritesInOrdering
        self.switchToNinthItem = switchToNinthItem
        self.optionRevealsSidebar = optionRevealsSidebar
    }

    private enum CodingKeys: String, CodingKey { case includeFavoritesInOrdering, switchToNinthItem, optionRevealsSidebar }

    /// A missing or unreadable field keeps Arc's default (older settings files have none of them).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SidebarNavigationPreferences()
        includeFavoritesInOrdering = (try? c.decodeIfPresent(Bool.self, forKey: .includeFavoritesInOrdering)) ?? d.includeFavoritesInOrdering
        switchToNinthItem = (try? c.decodeIfPresent(Bool.self, forKey: .switchToNinthItem)) ?? d.switchToNinthItem
        optionRevealsSidebar = (try? c.decodeIfPresent(Bool.self, forKey: .optionRevealsSidebar)) ?? d.optionRevealsSidebar
    }

    /// Arc's description of ⌘`n` under these choices (Settings → Shortcuts shows it under the Sidebar Tab rows).
    public func describe(number n: Int) -> String {
        if n >= 9 && !switchToNinthItem { return "Jumps to the last item at the bottom of your Sidebar." }
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth"]
        let which = ordinals[max(0, min(n, 9) - 1)]
        return "Jumps to the \(which) item in your Sidebar, "
            + (includeFavoritesInOrdering ? "starting with your Favorites at the top." : "after your Favorites at the top.")
    }
}

/// The preferences the app read from settings.json (ShortcutCenter sets it at launch and on every change), so
/// `commandNumberTarget`'s default follows the user's choice wherever ⌘1–9 is run from.
public enum SidebarNavigation {
    nonisolated(unsafe) public static var preferences = SidebarNavigationPreferences()
}

/// One place the keyboard focus can be in a Space's sidebar, top to bottom.
public struct SidebarNavItem: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case favorite
        /// The Space name row: expanded = the pinned section shows.
        case header
        case folder
        /// A pinned or Today tab, a split, a note.
        case row
        /// "+ New Tab".
        case newTab
    }

    public enum Section: Int, Equatable, Sendable, Comparable {
        case favorites, pinned, today
        public static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String
    public var kind: Kind
    public var section: Section
    public var title: String
    /// Folder nesting: 0 at the top level.
    public var depth: Int
    /// The folder it's in (nil at the top level).
    public var parentID: String?
    /// Folders and the header: whether their contents show.
    public var isExpanded: Bool?

    public init(id: String, kind: Kind, section: Section, title: String, depth: Int = 0, parentID: String? = nil,
                isExpanded: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.section = section
        self.title = title
        self.depth = depth
        self.parentID = parentID
        self.isExpanded = isExpanded
    }
}

/// The keys the sidebar's keyboard focus takes.
public enum SidebarNavKey: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown
    /// Tab and ⇧Tab: the next or previous section.
    case nextSection, previousSection
}

/// What a key does to the focus.
public enum SidebarNavMove: Equatable, Sendable {
    case focus(String)
    /// Open a folder or the pinned section in place: no page loads.
    case expand(String)
    case collapse(String)
    /// Nowhere to go (the first row and ↑, a closed folder's child and ←).
    case none
}

/// The rules, on the rows as they show now (a closed folder's children and a folded pinned section aren't in `items`).
public struct SidebarNavigator: Equatable, Sendable {
    public let items: [SidebarNavItem]
    /// Columns of the Favorites grid (FavoritesGrid.layout).
    public let columns: Int
    /// How many rows ⇞ and ⇟ move.
    public let pageStep: Int

    public init(items: [SidebarNavItem], favoriteColumns: Int, pageStep: Int = 10) {
        self.items = items
        columns = max(1, favoriteColumns)
        self.pageStep = max(1, pageStep)
    }

    private var favorites: [SidebarNavItem] { items.filter { $0.section == .favorites } }

    public func index(of id: String?) -> Int? { id.flatMap { id in items.firstIndex { $0.id == id } } }

    /// Where the focus goes for `key` from `id` (nil: the focus isn't on a row yet, so the first or last row).
    public func move(_ key: SidebarNavKey, from id: String?) -> SidebarNavMove {
        guard !items.isEmpty else { return .none }
        guard let i = index(of: id) else {
            switch key {
            case .up, .end, .pageUp, .previousSection: return .focus(items[items.count - 1].id)
            default: return .focus(items[0].id)
            }
        }
        let item = items[i]
        let favs = favorites
        let tileIndex = item.section == .favorites ? favs.firstIndex { $0.id == item.id } : nil
        switch key {
        case .down:
            if let t = tileIndex {
                // Down a column; from the last tile row to the first row below the grid.
                let below = t + columns
                if below < favs.count { return .focus(favs[below].id) }
                let lastRowStart = ((favs.count - 1) / columns) * columns
                if t < lastRowStart { return .focus(favs[favs.count - 1].id) }
                return i + favs.count - t < items.count ? .focus(items[i + favs.count - t].id) : .none
            }
            return i + 1 < items.count ? .focus(items[i + 1].id) : .none
        case .up:
            if let t = tileIndex { return t >= columns ? .focus(favs[t - columns].id) : .none }
            guard i > 0 else { return .none }
            // Up from the first row under the grid: the bottom row's first tile.
            if items[i - 1].section == .favorites, !favs.isEmpty {
                return .focus(favs[((favs.count - 1) / columns) * columns].id)
            }
            return .focus(items[i - 1].id)
        case .left:
            if let t = tileIndex { return t % columns > 0 ? .focus(favs[t - 1].id) : .none }
            if (item.kind == .folder || item.kind == .header), item.isExpanded == true { return .collapse(item.id) }
            if let parent = item.parentID, items.contains(where: { $0.id == parent }) { return .focus(parent) }
            return .none
        case .right:
            if let t = tileIndex { return t % columns < columns - 1 && t + 1 < favs.count ? .focus(favs[t + 1].id) : .none }
            if item.kind == .folder || item.kind == .header {
                if item.isExpanded != true { return .expand(item.id) }
                // An open folder: into its first child, if it has one.
                if item.kind == .folder, i + 1 < items.count, items[i + 1].parentID == item.id { return .focus(items[i + 1].id) }
            }
            return .none
        case .home: return .focus(items[0].id)
        case .end: return .focus(items[items.count - 1].id)
        case .pageDown: return .focus(items[min(items.count - 1, i + pageStep)].id)
        case .pageUp: return .focus(items[max(0, i - pageStep)].id)
        case .nextSection:
            guard let next = items[(i + 1)...].first(where: { $0.section > item.section }) else { return .none }
            return .focus(next.id)
        case .previousSection:
            // To the start of this section, then to the start of the one before it.
            let start = items.firstIndex { $0.section == item.section } ?? i
            if start < i { return .focus(items[start].id) }
            guard let prev = items[..<i].last(where: { $0.section < item.section }) else { return .none }
            return .focus(items.first { $0.section == prev.section }!.id)
        }
    }

    /// Type-to-select (as in Finder's lists): the next row whose title starts with `typed`, after `id` when `typed` is
    /// one character (so pressing it again moves on), from `id` itself when the user is typing a longer prefix.
    /// Case- and accent-insensitive; wraps around.
    public func typeahead(_ typed: String, from id: String?) -> String? {
        let needle = Self.fold(typed)
        guard !needle.isEmpty, !items.isEmpty else { return nil }
        let start = index(of: id) ?? -1
        let first = needle.count == 1 || start < 0 ? start + 1 : start
        for k in 0..<items.count {
            let j = ((first + k) % items.count + items.count) % items.count
            if Self.fold(items[j].title).hasPrefix(needle) { return items[j].id }
        }
        return nil
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// What "Reveal" has to open so a row shows: the pinned section (folded) and every closed folder above it, outermost
/// first. Nothing to open: both empty.
public struct SidebarRevealPlan: Equatable, Sendable {
    public var expandPinnedSection: Bool
    public var foldersToOpen: [String]
    public var isEmpty: Bool { !expandPinnedSection && foldersToOpen.isEmpty }
}

extension SpacesStore {
    /// How to make the sidebar show the row of `tabID` in `spaceID` (Reveal Current Tab, Arc ref §7). A Favorite and a
    /// Today tab always show; a pinned tab may sit in closed folders or a folded pinned section. Nil when the tab has no
    /// row in that Space.
    public func revealPlan(forTab tabID: String?, inSpace spaceID: String) -> SidebarRevealPlan? {
        guard let tabID, let tab = tab(tabID), let space = space(spaceID) else { return nil }
        // A split's pane shows on its split's row; a pinned split's row is its item.
        let rowItemID: String? = tab.itemID.flatMap { id in splitItem(ofPane: id)?.id ?? id }
        guard let rowItemID, let item = item(rowItemID) else {
            return tab.spaceID == spaceID ? SidebarRevealPlan(expandPinnedSection: false, foldersToOpen: []) : nil
        }
        if case .favorites = item.container { return SidebarRevealPlan(expandPinnedSection: false, foldersToOpen: []) }
        guard case .pinned(let s) = item.container, s == spaceID else { return nil }
        var folders: [String] = []
        var parent = item.parentID
        var guardCount = 0
        while let p = parent, let f = self.item(p), guardCount < 64 {
            if f.isCollapsed { folders.insert(f.id, at: 0) }
            parent = f.parentID
            guardCount += 1
        }
        return SidebarRevealPlan(expandPinnedSection: space.pinnedCollapsed, foldersToOpen: folders)
    }
}
