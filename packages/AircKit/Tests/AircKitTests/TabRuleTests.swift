// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class TodayTests: XCTestCase {
    func testNewTabsGoToTheTop() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let c = try s.openTab(url: "https://c.com", inSpace: sp)
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(s.lastActiveTab(ofSpace: sp)?.id, c.id)
    }

    func testBackgroundLinksLineUpAfterTheirOpener() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let x = try s.openTab(url: "https://x.com", inSpace: sp)
        let opener = try s.openTab(url: "https://news.com", inSpace: sp)
        let l1 = try s.openTab(url: "https://news.com/1", inSpace: sp, openerID: opener.id, background: true, activate: false)
        let l2 = try s.openTab(url: "https://news.com/2", inSpace: sp, openerID: opener.id, background: true, activate: false)
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [opener.id, l1.id, l2.id, x.id])
        // A foreground link goes to the top.
        let f = try s.openTab(url: "https://news.com/3", inSpace: sp, openerID: opener.id, background: false)
        XCTAssertEqual(s.todayTabs(ofSpace: sp).first?.id, f.id)
    }

    func testLinksFromPinnedTabsGoToTheTop() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let x = try s.openTab(url: "https://x.com", inSpace: sp)
        let p = try s.openTab(url: "https://p.com", inSpace: sp)
        try s.move(.tab(p.id), to: .pinned(spaceID: sp, parentID: nil, index: 0))
        let l = try s.openTab(url: "https://other.com", inSpace: sp, openerID: p.id, background: true, activate: false)
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [l.id, x.id])
    }

    func testCommandWOnTodayArchivesAndUndoRestores() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.com", inSpace: sp, title: "A")
        let outcome = try s.closeTab(a.id)
        guard case .archived(let entry) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(s.tab(a.id))
        XCTAssertEqual(s.state.archive[entry]?.title, "A")
        XCTAssertEqual(s.state.archive[entry]?.reason, .manual)
        try s.undo()
        XCTAssertEqual(s.tab(a.id)?.url, "https://a.com")
        XCTAssertNil(s.state.archive[entry])
    }

    func testCommandWOnPinnedUnloadsAndKeepsTheRow() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://app.com/home", inSpace: sp)
        try s.move(.tab(t.id), to: .pinned(spaceID: sp, parentID: nil, index: 0))
        let item = s.pinnedRoots(ofSpace: sp)[0]
        s.updateTab(t.id, url: "https://app.com/elsewhere")
        XCTAssertEqual(try s.closeTab(t.id), .unloaded)
        XCTAssertNil(s.tab(t.id))
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp).map(\.id), [item.id])
        // Reopening snaps back to the saved URL.
        let again = try s.openItem(item.id, inSpace: sp)
        XCTAssertEqual(again.url, "https://app.com/home")
        XCTAssertTrue(s.archivedEntries.isEmpty)
    }

    func testTabToSelectAfterClosingPrefersBelow() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let c = try s.openTab(url: "https://c.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        XCTAssertEqual(s.tabToSelect(afterClosing: b.id, inSpace: sp)?.id, c.id)
        XCTAssertEqual(s.tabToSelect(afterClosing: c.id, inSpace: sp)?.id, b.id)
        XCTAssertEqual(s.tabToSelect(afterClosing: a.id, inSpace: sp)?.id, b.id)
    }

    func testClearKeepsTheVisibleTabAndUndoes() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let c = try s.openTab(url: "https://c.com", inSpace: sp)
        let cleared = try s.clearToday(inSpace: sp, keeping: b.id)
        XCTAssertEqual(Set(cleared), [a.id, c.id])
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [b.id])
        XCTAssertTrue(s.archivedEntries.allSatisfy { $0.reason == .clear })
        XCTAssertEqual(s.undoLabel, "Clear Today")
        try s.undo()
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [c.id, b.id, a.id])
    }

    func testArchiveTabsArchivesOnlyTodayTabsAsOneStep() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let c = try s.openTab(url: "https://c.com", inSpace: sp)
        try s.togglePin(c.id, inSpace: sp)
        let done = try s.archiveTabs([a.id, c.id, "missing"], reason: .clear, label: "Clear Today")
        XCTAssertEqual(done, [a.id], "the pinned tab and a missing ID are left out")
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [b.id])
        XCTAssertEqual(s.archivedEntries.map(\.reason), [.clear])
        XCTAssertEqual(s.undoLabel, "Clear Today")
        XCTAssertEqual(try s.archiveTabs([], reason: .clear, label: "Clear Today"), [])
        try s.undo()
        XCTAssertEqual(Set(s.todayTabs(ofSpace: sp).map(\.id)), [a.id, b.id])
    }

    func testAutoArchiveUsesEachProfilesInterval() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let work = try s.createProfile(name: "Work")
        try s.updateProfile(work.id) { $0.archiveAfter = .sevenDays }
        let home = s.selectedSpace.id
        let office = try s.createSpace(name: "Office", profileID: work.id).id
        let h = try s.openTab(url: "https://h.com", inSpace: home)
        let shown = try s.openTab(url: "https://shown.com", inSpace: home)
        let w = try s.openTab(url: "https://w.com", inSpace: office)
        let pinned = try s.openTab(url: "https://p.com", inSpace: home)
        try s.togglePin(pinned.id, inSpace: home)
        clock.advance(13 * 3600)
        XCTAssertEqual(try s.autoArchive(protected: [shown.id]), [h.id])
        XCTAssertNotNil(s.tab(w.id))
        XCTAssertNotNil(s.tab(pinned.id), "pinned tabs never auto-archive")
        clock.advance(7 * 86400)
        XCTAssertEqual(try s.autoArchive(protected: [shown.id]), [w.id])
    }

    func testViewingResetsTheArchiveTimer() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        clock.advance(11 * 3600)
        try s.activate(t.id, inSpace: sp)
        clock.advance(11 * 3600)
        XCTAssertEqual(try s.autoArchive(), [])
        clock.advance(2 * 3600)
        XCTAssertEqual(try s.autoArchive(), [t.id])
    }

    func testNextAutoArchiveDateIsTheEarliestDueTab() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        XCTAssertNil(s.nextAutoArchiveDate())
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        clock.advance(3600)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let due = try XCTUnwrap(s.nextAutoArchiveDate())
        XCTAssertEqual(due.timeIntervalSince(a.lastActiveAt), 12 * 3600, accuracy: 0.5)
        let later = try XCTUnwrap(s.nextAutoArchiveDate(protected: [a.id]))
        XCTAssertEqual(later.timeIntervalSince(b.lastActiveAt), 12 * 3600, accuracy: 0.5)
        XCTAssertNil(s.nextAutoArchiveDate(protected: [a.id, b.id]))
    }

    func testForgetTabLeavesNoArchiveOrUndo() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "about:blank", inSpace: sp)
        let archived = s.archivedEntries.count
        let undo = s.undoLabel
        try s.forgetTab(t.id)
        XCTAssertNil(s.tab(t.id))
        XCTAssertEqual(s.archivedEntries.count, archived)
        XCTAssertEqual(s.undoLabel, undo)
    }

    func testRestoreArchivedGoesBackToItsSpaceOrTheFallback() throws {
        let s = try makeStore()
        let a = s.selectedSpace.id
        let b = try s.createSpace(name: "B").id
        let t = try s.openTab(url: "https://a.com", inSpace: b)
        guard case .archived(let e) = try s.closeTab(t.id) else { return XCTFail() }
        XCTAssertEqual(try s.restoreArchived(e, fallbackSpaceID: a).spaceID, b)
        guard case .archived(let e2) = try s.closeTab(t.id) else { return XCTFail() }
        try s.deleteSpace(b)
        let restored = try s.restoreArchived(e2, fallbackSpaceID: a)
        XCTAssertEqual(restored.spaceID, a)
        XCTAssertEqual(s.todayTabs(ofSpace: a).first?.id, t.id)
    }

    func testMoveTabToSpaceOfAnotherProfileNeedsReload() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = s.selectedSpace.id
        let b = try s.createSpace(name: "B").id
        let c = try s.createSpace(name: "C", profileID: work.id).id
        let t = try s.openTab(url: "https://a.com", inSpace: a)
        XCTAssertFalse(try s.moveTab(t.id, toSpace: b))
        XCTAssertTrue(try s.moveTab(t.id, toSpace: c))
        XCTAssertEqual(s.tab(t.id)?.profileID, work.id)
        XCTAssertNil(s.space(a)?.lastActiveTabID)
    }
}

final class PinnedRuleTests: XCTestCase {
    func testDriftAndReset() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://github.com/airc", inSpace: sp)
        try s.togglePin(t.id, inSpace: sp)
        XCTAssertFalse(s.isDrifted(t.id))
        s.updateTab(t.id, url: "https://github.com/airc/")
        XCTAssertFalse(s.isDrifted(t.id), "a trailing slash isn't drift")
        s.updateTab(t.id, url: "https://github.com/airc/issues")
        XCTAssertTrue(s.isDrifted(t.id))
        XCTAssertEqual(try s.resetToSavedURL(t.id), "https://github.com/airc")
        XCTAssertFalse(s.isDrifted(t.id))
    }

    func testTypingIntoAPinnedTabOpensATodayTab() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let today = try s.openTab(url: "https://a.com", inSpace: sp)
        let pinned = try s.openTab(url: "https://p.com", inSpace: sp)
        try s.togglePin(pinned.id, inSpace: sp)
        XCTAssertEqual(s.navigationDecision(forTab: today.id), .loadInPlace)
        XCTAssertEqual(s.navigationDecision(forTab: pinned.id), .openTodayTab)
        XCTAssertEqual(s.navigationDecision(forTab: nil), .openTodayTab)
    }

    func testPinnedItemRemembersTitleOnlyOnItsSavedPage() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://docs.com/a", inSpace: sp)
        try s.togglePin(t.id, inSpace: sp)
        s.updateTab(t.id, title: "Doc A")
        let item = s.pinnedRoots(ofSpace: sp)[0]
        XCTAssertEqual(s.item(item.id)?.pageTitle, "Doc A")
        s.updateTab(t.id, url: "https://other.com", title: "Other")
        XCTAssertEqual(s.item(item.id)?.pageTitle, "Doc A")
    }

    func testTogglePinRoundTrip() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.togglePin(t.id, inSpace: sp)
        XCTAssertTrue(s.todayTabs(ofSpace: sp).isEmpty)
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp).first?.savedURL, "https://a.com")
        try s.togglePin(t.id, inSpace: sp)
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [t.id])
        XCTAssertTrue(s.pinnedRoots(ofSpace: sp).isEmpty)
    }
}

final class DragAndDropTests: XCTestCase {
    func testFavoritesCapAtTwelve() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let pid = s.defaultProfile.id
        for i in 0..<12 {
            let t = try s.openTab(url: "https://\(i).com", inSpace: sp)
            try s.move(.tab(t.id), to: .favorites(profileID: pid, index: i))
        }
        let extra = try s.openTab(url: "https://13.com", inSpace: sp)
        XCTAssertThrowsError(try s.move(.tab(extra.id), to: .favorites(profileID: pid, index: 0))) {
            XCTAssertEqual($0 as? StoreError, .favoritesFull)
        }
        // Reordering within a full grid still works.
        let first = s.favorites(ofProfile: pid)[0]
        try s.move(.item(first.id), to: .favorites(profileID: pid, index: 12))
        XCTAssertEqual(s.favorites(ofProfile: pid).last?.id, first.id)
    }

    func testReorderUsesIndexBeforeTheMove() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        var ids: [String] = []
        for i in 0..<4 {
            let t = try s.openTab(url: "https://\(i).com", inSpace: sp)
            try s.move(.tab(t.id), to: .pinned(spaceID: sp, parentID: nil, index: i))
            ids.append(s.tab(t.id)!.itemID!)
        }
        // Drag the first row to the gap after the third (index 3 in the list as shown).
        try s.move(.item(ids[0]), to: .pinned(spaceID: sp, parentID: nil, index: 3))
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp).map(\.id), [ids[1], ids[2], ids[0], ids[3]])
        // And back to the top.
        try s.move(.item(ids[0]), to: .pinned(spaceID: sp, parentID: nil, index: 0))
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp).map(\.id), ids)
    }

    func testTodayReorder() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let c = try s.openTab(url: "https://c.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.move(.tab(a.id), to: .today(spaceID: sp, index: 3))
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.id), [b.id, c.id, a.id])
    }

    func testFoldersNestAndRejectCycles() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let outer = try s.createFolder(named: "Outer", inSpace: sp)
        let inner = try s.createFolder(named: "Inner", inSpace: sp, parentID: outer.id)
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.move(.tab(t.id), to: .pinned(spaceID: sp, parentID: inner.id, index: 0))
        let rows = s.pinnedRows(ofSpace: sp)
        XCTAssertEqual(rows.count, 3)
        if case .pinned(_, let depth, let live) = rows[2] {
            XCTAssertEqual(depth, 2)
            XCTAssertEqual(live?.id, t.id)
        } else { XCTFail("\(rows[2])") }
        XCTAssertThrowsError(try s.move(.item(outer.id), to: .pinned(spaceID: sp, parentID: inner.id, index: 0))) {
            XCTAssertEqual($0 as? StoreError, .invalidMove)
        }
        XCTAssertThrowsError(try s.move(.item(outer.id), to: .favorites(profileID: s.defaultProfile.id, index: 0)))
        XCTAssertThrowsError(try s.move(.item(outer.id), to: .today(spaceID: sp, index: 0)))
        // Collapsing hides the contents.
        try s.toggleFolder(outer.id)
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).count, 1)
        XCTAssertEqual(s.allLinks(inFolder: outer.id), ["https://a.com"])
    }

    func testFolderFromSelection() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.com", inSpace: sp)
        let b = try s.openTab(url: "https://b.com", inSpace: sp)
        let f = try s.createFolder(named: "Two", inSpace: sp, containing: [.tab(a.id), .tab(b.id)])
        XCTAssertEqual(s.children(of: .pinned(spaceID: sp), parent: f.id).map(\.savedURL), ["https://a.com", "https://b.com"])
        XCTAssertTrue(s.todayTabs(ofSpace: sp).isEmpty)
    }

    func testMovingFolderToAnotherSpaceMovesItsContents() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = s.selectedSpace.id
        let b = try s.createSpace(name: "B", profileID: work.id).id
        let f = try s.createFolder(named: "F", inSpace: a)
        let t = try s.openTab(url: "https://a.com", inSpace: a)
        try s.move(.tab(t.id), to: .pinned(spaceID: a, parentID: f.id, index: 0))
        let reload = try s.move(.item(f.id), to: .pinned(spaceID: b, parentID: nil, index: 0))
        XCTAssertEqual(reload, [t.id])
        XCTAssertEqual(s.pinnedRows(ofSpace: b).count, 2)
        XCTAssertEqual(s.tab(t.id)?.spaceID, b)
        XCTAssertEqual(s.tab(t.id)?.profileID, work.id)
    }

    func testUnpinUnloadedItemCreatesTodayTab() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.togglePin(t.id, inSpace: sp)
        try s.closeTab(t.id)
        let item = s.pinnedRoots(ofSpace: sp)[0]
        try s.move(.item(item.id), to: .today(spaceID: sp, index: 0))
        XCTAssertEqual(s.todayTabs(ofSpace: sp).map(\.url), ["https://a.com"])
        XCTAssertNil(s.item(item.id))
    }

    func testDeleteItemUndo() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let f = try s.createFolder(named: "F", inSpace: sp)
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.move(.tab(t.id), to: .pinned(spaceID: sp, parentID: f.id, index: 0))
        try s.deleteItem(f.id)
        XCTAssertTrue(s.pinnedRows(ofSpace: sp).isEmpty)
        XCTAssertNil(s.tab(t.id))
        try s.undo()
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).count, 2)
        XCTAssertNotNil(s.tab(t.id))
    }

    func testDuplicateFolderCopiesChildren() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let f = try s.createFolder(named: "F", inSpace: sp)
        let t = try s.openTab(url: "https://a.com", inSpace: sp)
        try s.move(.tab(t.id), to: .pinned(spaceID: sp, parentID: f.id, index: 0))
        let copy = try s.duplicateItem(f.id)
        XCTAssertEqual(s.pinnedRoots(ofSpace: sp).map(\.id), [f.id, copy.id])
        XCTAssertEqual(s.allLinks(inFolder: copy.id), ["https://a.com"])
    }
}

final class SidebarOrderTests: XCTestCase {
    func testCommandNumbersCountFavoritesFirstAndNineIsLast() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let fav = try s.openTab(url: "https://fav.com", inSpace: sp)
        try s.move(.tab(fav.id), to: .favorites(profileID: s.defaultProfile.id, index: 0))
        let pin = try s.openTab(url: "https://pin.com", inSpace: sp)
        try s.togglePin(pin.id, inSpace: sp)
        _ = try s.createFolder(named: "Folder", inSpace: sp)
        let t1 = try s.openTab(url: "https://t1.com", inSpace: sp)
        let t2 = try s.openTab(url: "https://t2.com", inSpace: sp)
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp)?.liveTab?.id, fav.id)
        XCTAssertEqual(s.commandNumberTarget(2, inSpace: sp)?.liveTab?.id, pin.id)
        XCTAssertEqual(s.commandNumberTarget(3, inSpace: sp)?.liveTab?.id, t2.id)
        XCTAssertEqual(s.commandNumberTarget(9, inSpace: sp)?.liveTab?.id, t1.id)
        XCTAssertNil(s.commandNumberTarget(5, inSpace: sp))
        XCTAssertEqual(s.adjacentEntry(to: t1.id, offset: 1, inSpace: sp)?.liveTab?.id, fav.id, "wraps")
        // Folding the pinned section skips it.
        try s.updateSpace(sp) { $0.pinnedCollapsed = true }
        XCTAssertEqual(s.commandNumberTarget(2, inSpace: sp)?.liveTab?.id, t2.id)
    }

    func testFavoritesGridColumnRule() {
        // Arc's measured examples at the default 228 pt sidebar (212 pt inside the 8 pt insets).
        let w = 212.0
        XCTAssertEqual(FavoritesGrid.layout(count: 2, width: w).columns, 2)
        XCTAssertEqual(FavoritesGrid.layout(count: 4, width: w).columns, 4)
        XCTAssertEqual(FavoritesGrid.layout(count: 5, width: w).columns, 3)
        XCTAssertEqual(FavoritesGrid.layout(count: 6, width: w).columns, 3)
        XCTAssertEqual(FavoritesGrid.layout(count: 7, width: w).columns, 4)
        XCTAssertEqual(FavoritesGrid.layout(count: 9, width: w).columns, 3)
        XCTAssertEqual(FavoritesGrid.layout(count: 4, width: 184).columns, 2, "4 tiles at 200 pt → 2×2")
        let l = FavoritesGrid.layout(count: 7, width: w)
        XCTAssertEqual(l.rows, 2)
        XCTAssertEqual(l.height, 47 * 2 + 8)
        XCTAssertEqual(FavoritesGrid.frame(index: 5, layout: l).x, l.tileWidth + 8, accuracy: 0.001)
        XCTAssertEqual(FavoritesGrid.layout(count: 0, width: w).height, 0)
    }

    func testSpaceBarSqueeze() {
        XCTAssertEqual(SpaceBarLayout.span(sidebarWidth: 228), 144)
        XCTAssertEqual(SpaceBarLayout.cellWidths(count: 3, current: 0, span: 144), [34, 34, 34])
        XCTAssertEqual(SpaceBarLayout.cellWidths(count: 6, current: 0, span: 144), Array(repeating: 24, count: 6))
        // 12 / 16 / 22 Spaces in a 300 pt sidebar: the current keeps 22, others about 17.5 / 13 / 9
        // (Arc ref §2.9, measured values rounded).
        let w = SpaceBarLayout.cellWidths(count: 12, current: 3, span: 217)
        XCTAssertEqual(w[3], 22)
        XCTAssertEqual(w[0], 17.5, accuracy: 0.3)
        XCTAssertEqual(SpaceBarLayout.cellWidths(count: 22, current: 0, span: 217)[1], 9, accuracy: 0.3)
        XCTAssertEqual(SpaceBarLayout.cellWidths(count: 16, current: 0, span: 217)[1], 13, accuracy: 0.01)
    }
}
