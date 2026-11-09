// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Space name row's states (P02, Arc ref §2.4): a press folds the pinned section; while it's folded the keyboard
/// skips the pinned rows, and the header is drawn bold when the tab on screen is one of them, so the selection never
/// disappears without a trace (Arc 2024: "We've bolded your Space header while Pinned Tabs are collapsed in cases where
/// your last Pinned Tab is in view").
public enum SpaceHeaderPolicy {
    public struct State: Equatable, Sendable {
        /// The pinned section shows.
        public var isExpanded: Bool
        /// Bold: folded, and the tab on screen is a pinned one inside.
        public var isEmphasized: Bool
        /// The keyboard and ⌘1–9 go through the pinned rows (not while folded).
        public var pinnedRowsNavigable: Bool
    }

    public static func state(pinnedCollapsed: Bool, shownRowIsPinned: Bool) -> State {
        State(isExpanded: !pinnedCollapsed, isEmphasized: pinnedCollapsed && shownRowIsPinned,
              pinnedRowsNavigable: !pinnedCollapsed)
    }

    /// P01c (Arc ref §2.4, its showSpaceHeaderOnSingleUnnamedSpaces): the only Space, with no name and no icon, hides
    /// its name row, unless "Show Space Header" is on. Any other Space shows it, and so does one whose pinned section is
    /// folded (only the row unfolds it).
    public static func showsHeader(spaceCount: Int, name: String, hasIcon: Bool, pinnedCollapsed: Bool = false,
                                   showOnSingleUnnamed: Bool) -> Bool {
        !hidesOnItsOwn(spaceCount: spaceCount, name: name, hasIcon: hasIcon) || pinnedCollapsed || showOnSingleUnnamed
    }

    /// The Space is the only one, unnamed and without an icon: the case "Show Space Header" / "Hide Space Header" is for.
    public static func hidesOnItsOwn(spaceCount: Int, name: String, hasIcon: Bool) -> Bool {
        spaceCount == 1 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasIcon
    }

    /// What VoiceOver hears after the Space's name: its pinned section's state, and that the current tab is inside.
    public static func accessibilityValue(_ s: State) -> String {
        s.isEmphasized ? "collapsed, contains the current tab" : (s.isExpanded ? "expanded" : "collapsed")
    }
}

extension SpacesStore {
    /// The header's state for a Space, with `shownTabID` the tab its page shows.
    public func headerState(ofSpace spaceID: String, shownTabID: String?) -> SpaceHeaderPolicy.State {
        let collapsed = space(spaceID)?.pinnedCollapsed ?? false
        return SpaceHeaderPolicy.state(pinnedCollapsed: collapsed, shownRowIsPinned: isPinnedRow(tabID: shownTabID, inSpace: spaceID))
    }

    /// Whether `spaceID`'s name row shows (`showsHeader`), the Spaces counted as the sidebar lists them.
    public func showsHeader(ofSpace spaceID: String, showOnSingleUnnamed: Bool) -> Bool {
        guard let s = space(spaceID) else { return true }
        return SpaceHeaderPolicy.showsHeader(spaceCount: orderedSpaces.count, name: s.name, hasIcon: s.icon != nil,
                                             pinnedCollapsed: s.pinnedCollapsed, showOnSingleUnnamed: showOnSingleUnnamed)
    }

    /// Whether the Space menu offers Show / Hide Space Header for `spaceID`.
    public func offersHeaderToggle(ofSpace spaceID: String) -> Bool {
        guard let s = space(spaceID) else { return false }
        return SpaceHeaderPolicy.hidesOnItsOwn(spaceCount: orderedSpaces.count, name: s.name, hasIcon: s.icon != nil)
    }

    /// `tabID`'s row is in `spaceID`'s pinned section (a pinned tab, a pinned split's pane, anything in its folders).
    public func isPinnedRow(tabID: String?, inSpace spaceID: String) -> Bool {
        guard let t = tab(tabID), let id = t.itemID, let item = splitItem(ofPane: id) ?? item(id) else { return false }
        if case .pinned(let s) = item.container { return s == spaceID }
        return false
    }
}
