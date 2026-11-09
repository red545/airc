// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// SB-36: a multi-selection's actions keep the selection's order, take one undo step, and handle pinned, Today and
/// folder rows together.
final class BulkActionTests: XCTestCase {
    private func today(_ s: SpacesStore, _ sid: String) -> [String] {
        s.todayRows(ofSpace: sid).map { $0.split == nil ? $0.liveTab?.title ?? "?" : "split" }
    }
    private func pinned(_ s: SpacesStore, _ sid: String, in parent: String? = nil) -> [String] {
        s.children(of: .pinned(spaceID: sid), parent: parent).map(\.displayTitle)
    }

    /// Today: C B A (newest first), pinned: P (loaded) and Q (not loaded), folder F holding X (loaded) and Y.
    private struct Fixture {
        let s: SpacesStore
        let sid: String
        let a, b, c: LiveTab
        let p, q, f, x, y: Item
    }

    private func fixture() throws -> Fixture {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        func pin(_ title: String, parent: String? = nil, load: Bool) throws -> Item {
            let t = try s.openTab(url: "https://example.com/" + title.lowercased(), inSpace: sid, title: title)
            let n = s.children(of: .pinned(spaceID: sid), parent: parent).count
            try s.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: parent, index: n))
            let item = try XCTUnwrap(s.item(s.tab(t.id)?.itemID))
            try s.renameItem(item.id, to: title)
            if !load { _ = try s.closeTab(t.id) }
            return s.item(item.id)!
        }
        let p = try pin("P", load: true)
        let q = try pin("Q", load: false)
        let f = try s.createFolder(named: "F", inSpace: sid)
        let x = try pin("X", parent: f.id, load: true)
        let y = try pin("Y", parent: f.id, load: false)
        let a = try s.openTab(url: "https://example.com/a", inSpace: sid, title: "A")
        let b = try s.openTab(url: "https://example.com/b", inSpace: sid, title: "B")
        let c = try s.openTab(url: "https://example.com/c", inSpace: sid, title: "C")
        return Fixture(s: s, sid: sid, a: a, b: b, c: c, p: p, q: q, f: s.item(f.id)!, x: x, y: y)
    }

    func testFixtureIsAsDescribed() throws {
        let k = try fixture()
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["X", "Y"])
        XCTAssertNotNil(k.s.liveTab(forItem: k.p.id))
        XCTAssertNil(k.s.liveTab(forItem: k.q.id))
        XCTAssertNotNil(k.s.liveTab(forItem: k.x.id))
    }

    func testLiveTabsAndLinksFollowTheSelectionOrderAndOpenFolders() throws {
        let k = try fixture()
        let sel: [DragSource] = [.item(k.p.id), .item(k.q.id), .item(k.f.id), .item(k.x.id), .tab(k.b.id)]
        XCTAssertEqual(k.s.liveTabs(of: sel).map(\.title), ["P", "X", "B"], "loaded tabs only; X once, with its folder")
        XCTAssertEqual(k.s.links(of: sel), ["https://example.com/p", "https://example.com/q", "https://example.com/x",
                                            "https://example.com/y", "https://example.com/b"])
        let current = k.s.links(of: [.tab(k.b.id)]) { $0.id == k.b.id ? "https://example.com/b2" : nil }
        XCTAssertEqual(current, ["https://example.com/b2"], "the page's own address wins over the stored one")
    }

    func testCloseArchivesTodayTabsAndUnloadsPinnedOnesInOneUndoStep() throws {
        let k = try fixture()
        let pTab = try XCTUnwrap(k.s.liveTab(forItem: k.p.id))
        let undoDepth = k.s.undoStack.count
        let closed = try k.s.closeTabs([.item(k.p.id), .tab(k.c.id), .tab(k.a.id)])
        XCTAssertEqual(closed, [pTab.id, k.c.id, k.a.id])
        XCTAssertEqual(today(k.s, k.sid), ["B"])
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"], "a pinned tab keeps its row")
        XCTAssertNil(k.s.liveTab(forItem: k.p.id))
        XCTAssertEqual(Set(k.s.archivedEntries.map(\.title)), ["A", "C"], "only Today tabs go to the Archive")
        XCTAssertEqual(k.s.undoStack.count, undoDepth + 1)
        XCTAssertEqual(k.s.undoLabel, "Close Tabs")
        _ = try k.s.undo()
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertEqual(k.s.liveTab(forItem: k.p.id)?.id, pTab.id)
        XCTAssertTrue(k.s.archivedEntries.isEmpty)
    }

    func testCloseOnlyTakesThePagesThatClosed() throws {
        let k = try fixture()
        try k.s.closeTabs([.tab(k.c.id), .tab(k.a.id)], only: [k.a.id])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B"], "C's page asked first: it stays")
    }

    func testArchiveTakesTodayTabsPinnedRowsAndAFolderWithItsTabsAndUndoesAtOnce() throws {
        let k = try fixture()
        let pages = try [XCTUnwrap(k.s.liveTab(forItem: k.p.id)).id, XCTUnwrap(k.s.liveTab(forItem: k.x.id)).id, k.b.id]
        let gone = try k.s.archive([.item(k.p.id), .item(k.q.id), .item(k.f.id), .item(k.y.id), .tab(k.b.id)])
        XCTAssertEqual(gone, pages, "the pages to close: P's, X's (in the folder) and B's")
        XCTAssertTrue(k.s.pinnedRoots(ofSpace: k.sid).isEmpty, "P, Q and the folder leave the sidebar")
        XCTAssertNil(k.s.item(k.x.id))
        XCTAssertEqual(today(k.s, k.sid), ["C", "A"])
        XCTAssertEqual(Set(k.s.archivedEntries.map(\.title)), ["P", "Q", "X", "Y", "B"], "every tab is in the Archive once")
        XCTAssertEqual(k.s.archivedEntries.first { $0.title == "Q" }?.url, "https://example.com/q", "an unloaded one by its saved address")
        XCTAssertEqual(k.s.undoLabel, "Archive")
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["X", "Y"])
        XCTAssertNotNil(k.s.liveTab(forItem: k.x.id), "X's page comes back with its row")
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertTrue(k.s.archivedEntries.isEmpty)
        // An archived pinned tab comes back from the Library as a Today tab.
        try k.s.archive([.item(k.q.id)])
        let e = try XCTUnwrap(k.s.archivedEntries.first)
        let t = try k.s.restoreArchived(e.id, fallbackSpaceID: k.sid)
        XCTAssertTrue(t.isToday)
        XCTAssertEqual(t.url, "https://example.com/q")
    }

    func testPinKeepsOrderAndUnpinPutsThemAtTheTopOfTodayInOrder() throws {
        let k = try fixture()
        // Mixed: C, A (Today) and P (pinned): the Today ones are pinned, in order, at the end.
        try k.s.togglePin([.item(k.p.id), .tab(k.c.id), .tab(k.a.id)], inSpace: k.sid)
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F", "C", "A"])
        XCTAssertEqual(today(k.s, k.sid), ["B"])
        XCTAssertEqual(k.s.undoLabel, "Pin")
        _ = try k.s.undo()
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        // Only pinned rows: they go to the top of Today, in order; the folder stays pinned.
        try k.s.togglePin([.item(k.p.id), .item(k.q.id), .item(k.f.id)], inSpace: k.sid)
        XCTAssertEqual(today(k.s, k.sid), ["P", "Q", "C", "B", "A"])
        XCTAssertEqual(pinned(k.s, k.sid), ["F"])
        XCTAssertEqual(k.s.undoLabel, "Unpin")
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
    }

    func testMoveToSpaceKeepsSectionsAndOrderAndUndoesInOneStep() throws {
        let k = try fixture()
        let other = try k.s.createSpace(name: "Other", profileID: k.s.defaultProfile.id).id
        _ = try k.s.openTab(url: "https://example.com/o", inSpace: other, title: "O")
        let undoDepth = k.s.undoStack.count
        try k.s.move([.item(k.p.id), .item(k.f.id), .tab(k.c.id), .tab(k.a.id)], toSpace: other)
        XCTAssertEqual(pinned(k.s, other), ["P", "F"])
        XCTAssertEqual(pinned(k.s, other, in: k.f.id), ["X", "Y"], "the folder brings its rows")
        XCTAssertEqual(today(k.s, other), ["C", "A", "O"], "Today rows on top, in order")
        XCTAssertEqual(pinned(k.s, k.sid), ["Q"])
        XCTAssertEqual(today(k.s, k.sid), ["B"])
        XCTAssertEqual(k.s.liveTab(forItem: k.x.id)?.spaceID, other, "a loaded tab in the folder moves with it")
        XCTAssertEqual(k.s.undoStack.count, undoDepth + 1)
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertEqual(today(k.s, other), ["O"])
    }

    func testMoveToAnotherProfilesSpaceReloadsTheTabsThatMoved() throws {
        let k = try fixture()
        let work = try k.s.createProfile(name: "Work")
        let other = try k.s.createSpace(name: "Work", profileID: work.id).id
        let reload = try k.s.move([.item(k.p.id), .tab(k.b.id)], toSpace: other)
        XCTAssertEqual(Set(reload), Set([k.s.liveTab(forItem: k.p.id)!.id, k.b.id]))
        XCTAssertEqual(k.s.tab(k.b.id)?.profileID, work.id)
    }

    func testAddToFolderAppendsInOrderAndSkipsTheFolderItself() throws {
        let k = try fixture()
        try k.s.move([.item(k.q.id), .item(k.f.id), .tab(k.c.id), .tab(k.a.id)], intoFolder: k.f.id)
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["X", "Y", "Q", "C", "A"])
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["B"])
        XCTAssertEqual(k.s.undoLabel, "Add to Folder")
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["X", "Y"])
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
    }

    func testNewFolderWithMixedRowsGoesAtTheEndOfPinnedInOrder() throws {
        let k = try fixture()
        let f = try k.s.newFolder(with: [.item(k.p.id), .tab(k.c.id), .tab(k.a.id)], inSpace: k.sid)
        XCTAssertEqual(pinned(k.s, k.sid), ["Q", "F", "New Folder"])
        XCTAssertEqual(pinned(k.s, k.sid, in: f.id), ["P", "C", "A"])
        XCTAssertEqual(today(k.s, k.sid), ["B"])
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
        XCTAssertNil(k.s.item(f.id), "one ⌘Z takes the folder away too")
    }

    func testNewFolderFromRowsInsideAFolderNestsWhereTheyWere() throws {
        let k = try fixture()
        let z = try k.s.openTab(url: "https://example.com/z", inSpace: k.sid, title: "Z")
        try k.s.move(.tab(z.id), to: .pinned(spaceID: k.sid, parentID: k.f.id, index: 0))
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["Z", "X", "Y"])
        let nested = try k.s.newFolder(with: [.item(k.x.id), .item(k.y.id)], inSpace: k.sid)
        XCTAssertEqual(nested.parentID, k.f.id)
        XCTAssertEqual(pinned(k.s, k.sid, in: k.f.id), ["Z", "New Folder"])
        XCTAssertEqual(pinned(k.s, k.sid, in: nested.id), ["X", "Y"])
        // Top-level pinned rows: the folder takes the first one's place.
        let top = try k.s.newFolder(with: [.item(k.q.id), .item(k.f.id)], named: "Both", inSpace: k.sid)
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Both"])
        XCTAssertEqual(pinned(k.s, k.sid, in: top.id), ["Q", "F"])
    }

    func testDuplicatePutsEachCopyBelowItsRowInOneStep() throws {
        let k = try fixture()
        let made = try k.s.duplicate([.item(k.p.id), .tab(k.c.id), .tab(k.a.id)])
        XCTAssertEqual(made.count, 3)
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "C", "B", "A", "A"])
        XCTAssertEqual(k.s.undoLabel, "Duplicate")
        _ = try k.s.undo()
        XCTAssertEqual(pinned(k.s, k.sid), ["P", "Q", "F"])
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
    }

    func testDuplicatingOnlyTodayTabsUndoes() throws {
        // An undo that only takes away tabs the action made (no tab comes back) isn't refused.
        let k = try fixture()
        try k.s.duplicate([.tab(k.b.id), .tab(k.c.id)])
        XCTAssertEqual(today(k.s, k.sid), ["C", "C", "B", "B", "A"])
        let r = try k.s.undo()
        guard case .restored("Duplicate", _)? = r else { return XCTFail("refused: \(String(describing: r))") }
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
    }

    func testOpenInSplitTakesTwoToFourTabRowsAndOpensUnloadedOnes() throws {
        let k = try fixture()
        XCTAssertNil(k.s.splitCandidates([.tab(k.a.id)]), "one row isn't a split")
        XCTAssertNil(k.s.splitCandidates([.tab(k.a.id), .item(k.f.id)]), "nor is a folder")
        XCTAssertNil(k.s.splitCandidates([.tab(k.a.id), .tab(k.b.id), .tab(k.c.id), .item(k.p.id), .item(k.q.id)]), "five is too many")
        let x = try k.s.openInSplit([.item(k.q.id), .tab(k.c.id), .tab(k.a.id)], inSpace: k.sid)
        let qTab = try XCTUnwrap(k.s.liveTab(forItem: k.q.id), "Q opened for the split")
        XCTAssertEqual(x.tabIDs, [qTab.id, k.c.id, k.a.id])
        XCTAssertEqual(today(k.s, k.sid), ["split", "B"], "the split takes C's place, the first Today row")
        _ = try k.s.undo()
        XCTAssertNil(k.s.split(x.id))
        XCTAssertNil(k.s.liveTab(forItem: k.q.id), "one ⌘Z, and Q is unloaded again")
        XCTAssertEqual(today(k.s, k.sid), ["C", "B", "A"])
    }

    func testAllPinned() throws {
        let k = try fixture()
        XCTAssertTrue(k.s.allPinned([.item(k.p.id), .item(k.f.id)]))
        XCTAssertFalse(k.s.allPinned([.item(k.p.id), .tab(k.a.id)]))
        XCTAssertFalse(k.s.allPinned([]))
    }
}
