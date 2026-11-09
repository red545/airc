// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P03: the sidebar without a mouse. Numeric ordering (K02), the per-command key priority (K03), the keyboard focus's
/// rules and Reveal (K04), the Space header's states (P02).
final class ParityP03Tests: XCTestCase {
    // MARK: K02 numeric ordering

    /// Favorite, a pinned tab, a pinned folder with a tab in it, two Today tabs (newest first).
    private func sample() throws -> (SpacesStore, sp: String, fav: String, pin: String, inFolder: String, folder: String, t1: String, t2: String) {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let fav = try s.openTab(url: "https://fav.example", inSpace: sp)
        try s.move(.tab(fav.id), to: .favorites(profileID: s.defaultProfile.id, index: 0))
        let pin = try s.openTab(url: "https://pin.example", inSpace: sp)
        try s.togglePin(pin.id, inSpace: sp)
        let folder = try s.createFolder(named: "Folder", inSpace: sp)
        let child = try s.openTab(url: "https://child.example", inSpace: sp)
        _ = try s.move([.tab(child.id)], intoFolder: folder.id)
        let t1 = try s.openTab(url: "https://t1.example", inSpace: sp)
        let t2 = try s.openTab(url: "https://t2.example", inSpace: sp)
        return (s, sp, fav.id, pin.id, child.id, folder.id, t1.id, t2.id)
    }

    func testNumericOrderingBothChoices() throws {
        let (s, sp, fav, pin, child, _, t1, t2) = try sample()
        let arc = SidebarNavigationPreferences()
        XCTAssertTrue(arc.includeFavoritesInOrdering)
        XCTAssertFalse(arc.switchToNinthItem)
        // Arc's defaults: Favorites first, folders skipped, ⌘9 the last item.
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp, preferences: arc)?.liveTab?.id, fav)
        XCTAssertEqual(s.commandNumberTarget(2, inSpace: sp, preferences: arc)?.liveTab?.id, pin)
        XCTAssertEqual(s.commandNumberTarget(3, inSpace: sp, preferences: arc)?.liveTab?.id, child)
        XCTAssertEqual(s.commandNumberTarget(4, inSpace: sp, preferences: arc)?.liveTab?.id, t2)
        XCTAssertEqual(s.commandNumberTarget(9, inSpace: sp, preferences: arc)?.liveTab?.id, t1)
        // Favorites left out: ⌘1 is the first pinned tab.
        let noFavs = SidebarNavigationPreferences(includeFavoritesInOrdering: false)
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp, preferences: noFavs)?.liveTab?.id, pin)
        XCTAssertEqual(s.commandNumberTarget(4, inSpace: sp, preferences: noFavs)?.liveTab?.id, t1)
        XCTAssertNil(s.commandNumberTarget(5, inSpace: sp, preferences: noFavs))
        // ⌘9 as the ninth: there are only five, so nothing.
        let ninth = SidebarNavigationPreferences(switchToNinthItem: true)
        XCTAssertNil(s.commandNumberTarget(9, inSpace: sp, preferences: ninth))
        XCTAssertEqual(s.commandNumberTarget(5, inSpace: sp, preferences: ninth)?.liveTab?.id, t1)
    }

    func testNumericOrderingWithCollapsedPinsClosedFoldersAndUnloadedItems() throws {
        let (s, sp, fav, pin, _, folder, _, t2) = try sample()
        // A closed folder's tab doesn't count.
        try s.toggleFolder(folder)
        let arc = SidebarNavigationPreferences()
        XCTAssertEqual(s.commandNumberTarget(3, inSpace: sp, preferences: arc)?.liveTab?.id, t2)
        // A folded pinned section is skipped, with or without Favorites.
        try s.updateSpace(sp) { $0.pinnedCollapsed = true }
        XCTAssertEqual(s.commandNumberTarget(2, inSpace: sp, preferences: arc)?.liveTab?.id, t2)
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp, preferences: .init(includeFavoritesInOrdering: false))?.liveTab?.id, t2)
        try s.updateSpace(sp) { $0.pinnedCollapsed = false }
        // An unloaded pinned tab (closed: the row stays, with no live tab) still counts: the key loads it.
        let pinItem = try XCTUnwrap(s.tab(pin)?.itemID)
        _ = try s.closeTab(pin)
        let e = s.commandNumberTarget(2, inSpace: sp, preferences: arc)
        XCTAssertEqual(e?.item?.id, pinItem)
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp, preferences: arc)?.liveTab?.id, fav)
    }

    func testDefaultArgumentFollowsTheAppsPreferences() throws {
        let (s, sp, _, pin, _, _, _, _) = try sample()
        let saved = SidebarNavigation.preferences
        defer { SidebarNavigation.preferences = saved }
        SidebarNavigation.preferences = .init(includeFavoritesInOrdering: false)
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp)?.liveTab?.id, pin)
    }

    func testPreferencesPersistAndOldFilesKeepArcsDefaults() throws {
        let p = SidebarNavigationPreferences(includeFavoritesInOrdering: false, switchToNinthItem: true, optionRevealsSidebar: false)
        let back = try JSONDecoder().decode(SidebarNavigationPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        let old = try JSONDecoder().decode(SidebarNavigationPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old, SidebarNavigationPreferences())
        let partial = try JSONDecoder().decode(SidebarNavigationPreferences.self, from: Data(#"{"switchToNinthItem":true,"optionRevealsSidebar":"x"}"#.utf8))
        XCTAssertTrue(partial.switchToNinthItem)
        XCTAssertTrue(partial.optionRevealsSidebar, "an unreadable field keeps its default")
        XCTAssertEqual(SidebarNavigationPreferences().describe(number: 9), "Jumps to the last item at the bottom of your Sidebar.")
        XCTAssertEqual(SidebarNavigationPreferences(includeFavoritesInOrdering: false).describe(number: 2),
                       "Jumps to the second item in your Sidebar, after your Favorites at the top.")
    }

    // MARK: K03 priority

    private func map(_ stored: [String: String] = [:]) -> ShortcutMap {
        ShortcutMap(commands: [.init(id: "file.openLocation", defaultKey: KeyCombo("l", .command)),
                               .init(id: "tabs.pin", defaultKey: KeyCombo("d", .command))], stored: stored)
    }

    func testThreePrioritiesInArcsOrderAndStorage() {
        XCTAssertEqual(KeyPriority.allCases.map(\.title), ["Use Both", "Prefer Websites", "Prefer Airc"])
        var m = map()
        XCTAssertEqual(m.priority("file.openLocation"), .websites)
        XCTAssertEqual(m.setPriority(.websitesOnly, for: "file.openLocation"), .done)
        XCTAssertEqual(m.setPriority(.airc, for: "tabs.pin"), .done)
        XCTAssertEqual(m.stored, ["file.openLocation:first": "websitesOnly", "tabs.pin:first": "airc"])
        let again = map(m.stored)
        XCTAssertEqual(again, m)
        XCTAssertEqual(again.priority("file.openLocation"), .websitesOnly)
        XCTAssertEqual(again.aircFirst, ["tabs.pin"])
        // Back to Use Both: nothing stored.
        m.setPriority(.websites, for: "file.openLocation")
        m.reset("tabs.pin")
        XCTAssertEqual(m.stored, [:])
        // An unknown spelling reads as the default.
        XCTAssertEqual(map(["tabs.pin:first": "sometimes"]).priority("tabs.pin"), .websites)
    }

    func testArbitrationWebsiteRepeat() {
        // Use Both: the page first; a second press within a second runs Airc's command.
        XCTAssertEqual(KeyArbitration.decide(.websites, pageCanUse: true, sincePageUsed: nil), .offerToPage)
        XCTAssertEqual(KeyArbitration.decide(.websites, pageCanUse: true, sincePageUsed: 0.4), .runCommand)
        XCTAssertEqual(KeyArbitration.decide(.websites, pageCanUse: true, sincePageUsed: 1.2), .offerToPage)
        // Prefer Websites: a page that uses the key keeps it, however fast it's pressed again.
        XCTAssertEqual(KeyArbitration.decide(.websitesOnly, pageCanUse: true, sincePageUsed: 0.2), .offerToPage)
        // Prefer Airc, or a key no page may have (⌘T, ⌃ keys).
        XCTAssertEqual(KeyArbitration.decide(.airc, pageCanUse: true, sincePageUsed: nil), .runCommand)
        XCTAssertEqual(KeyArbitration.decide(.websitesOnly, pageCanUse: false, sincePageUsed: nil), .runCommand)
    }

    func testControlSpaceIsArcsRevealKeyWithAWarning() {
        let k = KeyCombo("space", .control)
        XCTAssertTrue(ShortcutMap.allowed(k))
        XCTAssertEqual(KeyReservation.of(k)?.kind, .systemMayTake)
        XCTAssertEqual(KeyReservation.of(KeyCombo("space", .command))?.kind, .system)
    }

    // MARK: K04 keyboard focus

    /// Five Favorites in a 3-column grid, the header, an open folder with a child, a pinned tab, New Tab, two Today tabs.
    private var navigator: SidebarNavigator {
        var items = (1...5).map { SidebarNavItem(id: "f\($0)", kind: .favorite, section: .favorites, title: "Fav \($0)") }
        items += [
            .init(id: "header", kind: .header, section: .pinned, title: "Work", isExpanded: true),
            .init(id: "folder", kind: .folder, section: .pinned, title: "Docs", isExpanded: true),
            .init(id: "child", kind: .row, section: .pinned, title: "Spec", depth: 1, parentID: "folder"),
            .init(id: "pin", kind: .row, section: .pinned, title: "Mail"),
            .init(id: "newtab", kind: .newTab, section: .today, title: "New Tab"),
            .init(id: "t1", kind: .row, section: .today, title: "Ärzte"),
            .init(id: "t2", kind: .row, section: .today, title: "Maps"),
        ]
        return SidebarNavigator(items: items, favoriteColumns: 3, pageStep: 3)
    }

    func testArrowsWalkTheFavoritesGridAndEverySection() {
        let n = navigator
        XCTAssertEqual(n.move(.down, from: nil), .focus("f1"))
        XCTAssertEqual(n.move(.right, from: "f1"), .focus("f2"))
        XCTAssertEqual(n.move(.right, from: "f3"), .none, "the row's end")
        XCTAssertEqual(n.move(.down, from: "f2"), .focus("f5"))
        XCTAssertEqual(n.move(.down, from: "f3"), .focus("f5"), "no tile below: the last one")
        XCTAssertEqual(n.move(.down, from: "f5"), .focus("header"))
        XCTAssertEqual(n.move(.up, from: "header"), .focus("f4"), "back to the bottom row's first tile")
        XCTAssertEqual(n.move(.up, from: "f2"), .none)
        XCTAssertEqual(n.move(.down, from: "header"), .focus("folder"))
        XCTAssertEqual(n.move(.down, from: "pin"), .focus("newtab"))
        XCTAssertEqual(n.move(.down, from: "t2"), .none)
        XCTAssertEqual(n.move(.end, from: "f1"), .focus("t2"))
        XCTAssertEqual(n.move(.home, from: "t2"), .focus("f1"))
        XCTAssertEqual(n.move(.pageDown, from: "header"), .focus("pin"))
        // Tab and ⇧Tab: section by section.
        XCTAssertEqual(n.move(.nextSection, from: "f2"), .focus("header"))
        XCTAssertEqual(n.move(.nextSection, from: "folder"), .focus("newtab"))
        XCTAssertEqual(n.move(.nextSection, from: "t1"), .none)
        XCTAssertEqual(n.move(.previousSection, from: "t1"), .focus("newtab"))
        XCTAssertEqual(n.move(.previousSection, from: "newtab"), .focus("header"))
    }

    func testFoldersOpenAndCloseInPlace() {
        let n = navigator
        XCTAssertEqual(n.move(.left, from: "folder"), .collapse("folder"))
        XCTAssertEqual(n.move(.right, from: "folder"), .focus("child"))
        XCTAssertEqual(n.move(.left, from: "child"), .focus("folder"), "to its folder")
        XCTAssertEqual(n.move(.left, from: "header"), .collapse("header"))
        let closed = SidebarNavigator(items: [
            .init(id: "header", kind: .header, section: .pinned, title: "Work", isExpanded: false),
            .init(id: "folder", kind: .folder, section: .pinned, title: "Docs", isExpanded: false),
        ], favoriteColumns: 1)
        XCTAssertEqual(closed.move(.right, from: "folder"), .expand("folder"))
        XCTAssertEqual(closed.move(.right, from: "header"), .expand("header"))
        XCTAssertEqual(closed.move(.left, from: "folder"), .none)
    }

    func testTypeahead() {
        let n = navigator
        XCTAssertEqual(n.typeahead("m", from: "f1"), "pin")
        XCTAssertEqual(n.typeahead("m", from: "pin"), "t2", "the same letter again moves on")
        XCTAssertEqual(n.typeahead("ma", from: "t2"), "t2", "a longer prefix stays")
        XCTAssertEqual(n.typeahead("arz", from: nil), "t1", "accents and case are folded")
        XCTAssertNil(n.typeahead("zz", from: "f1"))
    }

    func testRevealPlanOpensFoldersAndTheFoldedPinnedSection() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let outer = try s.createFolder(named: "Outer", inSpace: sp)
        let inner = try s.createFolder(named: "Inner", inSpace: sp, parentID: outer.id)
        let t = try s.openTab(url: "https://deep.example", inSpace: sp)
        _ = try s.move([.tab(t.id)], intoFolder: inner.id)
        try s.toggleFolder(outer.id)
        try s.toggleFolder(inner.id)
        try s.updateSpace(sp) { $0.pinnedCollapsed = true }
        let plan = try XCTUnwrap(s.revealPlan(forTab: t.id, inSpace: sp))
        XCTAssertTrue(plan.expandPinnedSection)
        XCTAssertEqual(plan.foldersToOpen, [outer.id, inner.id], "outermost first")
        let today = try s.openTab(url: "https://today.example", inSpace: sp)
        XCTAssertEqual(s.revealPlan(forTab: today.id, inSpace: sp)?.isEmpty, true)
        XCTAssertNil(s.revealPlan(forTab: "nope", inSpace: sp))
    }

    // MARK: K06 recent tabs

    func testTabSwitcherWalksTheRecentTabsWhileControlIsHeld() throws {
        var w = try XCTUnwrap(TabSwitcherWalk(recent: ["a", "b", "c", "d", "e", "f", "g"], current: "a"))
        XCTAssertEqual(w.order, ["a", "b", "c", "d", "e"], "Arc's five most recent")
        XCTAssertEqual(w.step(1), "b", "the first press: the tab used before")
        XCTAssertEqual(w.step(1), "c", "Tab again with ⌃ held: one further back")
        XCTAssertEqual(w.step(-1), "b", "⌃⇧Tab: forward again")
        XCTAssertEqual(w.step(-1), "a")
        XCTAssertEqual(w.step(-1), "e", "wraps")
        // The current tab is first even when the list doesn't say so; duplicates go.
        let x = try XCTUnwrap(TabSwitcherWalk(recent: ["b", "a", "b", "c"], current: "a"))
        XCTAssertEqual(x.order, ["a", "b", "c"])
        XCTAssertNil(TabSwitcherWalk(recent: ["a"], current: "a"), "nothing to switch to")
        var none = try XCTUnwrap(TabSwitcherWalk(recent: ["b", "c"], current: nil))
        XCTAssertEqual(none.step(1), "b", "with nothing on screen, the most recent tab first")
    }

    func testRecentTabsFollowLastUseInTheSpace() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.example", inSpace: sp)
        clock.advance(10)
        let b = try s.openTab(url: "https://b.example", inSpace: sp)
        clock.advance(10)
        let c = try s.openTab(url: "https://c.example", inSpace: sp)
        clock.advance(10)
        try s.activate(a.id, inSpace: sp)
        XCTAssertEqual(s.recentTabs(inSpace: sp).prefix(3), [a.id, c.id, b.id])
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id, after: sp)
        _ = try s.openTab(url: "https://elsewhere.example", inSpace: other.id)
        XCTAssertFalse(s.recentTabs(inSpace: sp).contains { s.tab($0)?.spaceID == other.id }, "only this Space's tabs")
        // A walk from A shows C on the way and stops at B: only B counts as used (⌘Tab's rule).
        var w = try XCTUnwrap(TabSwitcherWalk(recent: s.recentTabs(inSpace: sp), current: a.id, lastUse: s.lastUse(of: s.recentTabs(inSpace: sp))))
        clock.advance(10)
        try s.activate(w.step(1), inSpace: sp)   // C
        clock.advance(10)
        let stop = w.step(1)                     // B
        try s.activate(stop, inSpace: sp)
        try s.restoreLastUse(w.lastUse, except: stop)
        XCTAssertEqual(s.recentTabs(inSpace: sp).prefix(3), [b.id, a.id, c.id])
    }

    // MARK: P02 header states

    func testHeaderIsBoldWhileFoldedOverTheShownPinnedTab() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let pin = try s.openTab(url: "https://pin.example", inSpace: sp)
        try s.togglePin(pin.id, inSpace: sp)
        let today = try s.openTab(url: "https://today.example", inSpace: sp)
        XCTAssertEqual(s.headerState(ofSpace: sp, shownTabID: pin.id),
                       .init(isExpanded: true, isEmphasized: false, pinnedRowsNavigable: true))
        try s.updateSpace(sp) { $0.pinnedCollapsed = true }
        let folded = s.headerState(ofSpace: sp, shownTabID: pin.id)
        XCTAssertTrue(folded.isEmphasized)
        XCTAssertFalse(folded.pinnedRowsNavigable)
        XCTAssertEqual(SpaceHeaderPolicy.accessibilityValue(folded), "collapsed, contains the current tab")
        XCTAssertFalse(s.headerState(ofSpace: sp, shownTabID: today.id).isEmphasized)
        XCTAssertEqual(SpaceHeaderPolicy.accessibilityValue(s.headerState(ofSpace: sp, shownTabID: today.id)), "collapsed")
    }
}
