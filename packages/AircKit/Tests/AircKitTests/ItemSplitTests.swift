// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// SV-2 pinned and Favorite splits: one item with a pane item per tab, saved URLs per pane, closing keeps it, drag and
/// unsplit in all three sections, relaunch, older stores, import.
final class ItemSplitTests: XCTestCase {
    /// A Today split of two tabs (Left 30 %, Right 70 %, stacked, Right focused), pinned at the top of the Space.
    private func pinnedSplit(_ s: SpacesStore, axis: SplitAxis = .vertical) throws -> (space: String, split: String, a: String, b: String) {
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://left.test/", inSpace: sp, title: "Left")
        let b = try s.openTab(url: "https://right.test/", inSpace: sp, title: "Right")
        let x = try s.createSplit([a.id, b.id], inSpace: sp, axis: axis, focused: b.id)
        s.setSplitFractions(x.id, [0.3, 0.7])
        try s.move(.split(x.id), to: .pinned(spaceID: sp, parentID: nil, index: 0))
        return (sp, x.id, a.id, b.id)
    }

    private func paneURLs(_ s: SpacesStore, _ id: String) -> [String?] { s.panes(ofSplitItem: id).map(\.savedURL) }

    func testATodaySplitDraggedIntoPinnedIsOnePinnedRowWithItsLayout() throws {
        let s = try makeStore()
        let (sp, id, a, b) = try pinnedSplit(s)
        // Same ID, now an item: one pinned row, nothing in Today.
        XCTAssertNil(s.state.splits[id])
        let item = try XCTUnwrap(s.item(id))
        XCTAssertEqual(item.kind, .split)
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).map(\.id), [id])
        XCTAssertTrue(s.todayRows(ofSpace: sp).isEmpty)
        guard case .pinned(let row, 0, let live)? = s.pinnedRows(ofSpace: sp).first else { return XCTFail("no pinned row") }
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(live?.id, b, "the row opens its focused pane")
        // Each pane is a pinned tab with its own saved URL.
        XCTAssertEqual(paneURLs(s, id), ["https://left.test/", "https://right.test/"])
        XCTAssertEqual(s.tab(a)?.itemID, s.panes(ofSplitItem: id)[0].id)
        XCTAssertFalse(s.tab(a)!.isToday)
        // The window gets an ordinary split for it, with the same ID.
        let x = try XCTUnwrap(s.split(containing: a))
        XCTAssertEqual(x.id, id)
        XCTAssertEqual(x.itemID, id)
        XCTAssertEqual(x.spaceID, sp)
        XCTAssertEqual(x.tabIDs, [a, b])
        XCTAssertEqual(x.axis, .vertical)
        XCTAssertEqual(x.focusedTabID, b)
        XCTAssertEqual(x.fractions[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.split(id)?.tabIDs, [a, b])
        // Pinned panes never auto-archive (SB-43), and Clear leaves them.
        XCTAssertTrue(s.dueForAutoArchive().isEmpty)
        XCTAssertEqual(try s.clearToday(inSpace: sp, keeping: nil), [])
        // ⌘1 opens it.
        XCTAssertEqual(s.commandNumberTarget(1, inSpace: sp)?.id, id)
    }

    func testClosingAPinnedSplitFreesEveryPaneAndKeepsTheItem() throws {
        let s = try makeStore()
        let (sp, id, a, b) = try pinnedSplit(s)
        let third = try s.openTab(url: "https://third.test/", inSpace: sp)
        try s.addToSplit(id, tabID: third.id, focus: false)
        XCTAssertEqual(try s.closeTab(a), .unloaded)
        XCTAssertTrue(s.state.splits.isEmpty, "unloading the panes left a Today split behind")
        XCTAssertNil(s.tab(third.id))
        try s.undo()                        // the panes' tabs come back
        try s.removeFromSplit(third.id)     // back to two panes
        XCTAssertEqual(try s.closeTab(a), .unloaded)
        XCTAssertNil(s.tab(a))
        XCTAssertNil(s.tab(b))
        XCTAssertNotNil(s.item(id))
        XCTAssertEqual(s.panes(ofSplitItem: id).count, 2)
        XCTAssertNil(s.split(id), "nothing on screen to show")
        guard case .pinned(_, _, nil)? = s.pinnedRows(ofSpace: sp).first else { return XCTFail("the row should stay, unloaded") }
        // A click opens every pane at its saved URL, the focused one in front.
        let t = try s.openItem(id, inSpace: sp)
        XCTAssertEqual(t.url, "https://right.test/")
        let x = try XCTUnwrap(s.split(id))
        XCTAssertEqual(x.tabIDs.compactMap { s.tab($0)?.url }, ["https://left.test/", "https://right.test/"])
        XCTAssertEqual(x.focusedTabID, t.id)
        XCTAssertEqual(x.fractions[1], 0.7, accuracy: 1e-9)
        // ⌘Z after a close brings the pages' tabs back.
        try s.closeTab(t.id)
        try s.undo()
        XCTAssertEqual(s.paneTabs(ofSplitItem: id).count, 2)
        // A pane picked on its own (the Command Bar) opens the whole split, focused on that pane.
        try s.closeTab(t.id)
        let left = s.panes(ofSplitItem: id)[0]
        let opened = try s.openItem(left.id, inSpace: sp)
        XCTAssertEqual(opened.itemID, left.id)
        XCTAssertEqual(s.split(containing: opened.id)?.focusedTabID, opened.id)
        XCTAssertEqual(s.paneTabs(ofSplitItem: id).count, 2)
    }

    func testPanesDriftAndResetOnTheirOwn() throws {
        let s = try makeStore()
        let (_, id, a, b) = try pinnedSplit(s)
        s.updateTab(a, url: "https://left.test/elsewhere", title: "Elsewhere")
        XCTAssertTrue(s.isDrifted(a))
        XCTAssertFalse(s.isDrifted(b))
        // The pane remembers its saved page's title, not the one it wandered to.
        XCTAssertEqual(s.panes(ofSplitItem: id)[0].pageTitle, "Left")
        XCTAssertEqual(try s.resetToSavedURL(a), "https://left.test/")
        XCTAssertFalse(s.isDrifted(a))
        // Typing a URL into a pane opens a Today tab (SB-32), as in any pinned tab.
        XCTAssertEqual(s.navigationDecision(forTab: b), .openTodayTab)
        // Replace with Current URL works per pane.
        s.updateTab(b, url: "https://right.test/new")
        try s.replaceSavedURL(ofItem: s.panes(ofSplitItem: id)[1].id, with: "https://right.test/new")
        XCTAssertEqual(paneURLs(s, id), ["https://left.test/", "https://right.test/new"])
    }

    func testFoldersFavoritesAndBackToToday() throws {
        let s = try makeStore()
        let (sp, id, a, b) = try pinnedSplit(s)
        // Into a folder: one row inside it.
        let folder = try s.createFolder(named: "Docs", inSpace: sp)
        try s.move(.item(id), to: .pinned(spaceID: sp, parentID: folder.id, index: 0))
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).map(\.id), [folder.id, id])
        guard case .pinned(_, 1, _)? = s.pinnedRows(ofSpace: sp).last else { return XCTFail("not in the folder") }
        // Into Favorites: one tile; its panes and tabs follow (no Space, the profile's).
        let pid = s.profile(ofSpace: sp).id
        try s.move(.item(id), to: .favorites(profileID: pid, index: 0))
        XCTAssertEqual(s.favorites(ofProfile: pid).map(\.id), [id])
        XCTAssertTrue(s.panes(ofSplitItem: id).allSatisfy { $0.container == .favorites(profileID: pid) })
        XCTAssertNil(s.tab(a)?.spaceID)
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).map(\.id), [folder.id])
        guard case .favorite(let tile, let live)? = s.sidebarEntries(ofSpace: sp).first else { return XCTFail("no tile") }
        XCTAssertEqual(tile.id, id)
        XCTAssertEqual(live?.id, b)
        // A Favorite split shows in every Space of its profile.
        let other = try s.createSpace(name: "Other")
        let x = try XCTUnwrap(s.split(id))
        XCTAssertTrue(s.showsSplit(x, inSpace: other.id))
        try s.activate(b, inSpace: other.id)
        XCTAssertEqual(s.lastActiveTab(ofSpace: other.id)?.id, b)
        let work = try s.createProfile(name: "Work")
        let ws = try s.createSpace(name: "Work", profileID: work.id)
        XCTAssertFalse(s.showsSplit(x, inSpace: ws.id))
        // Back to Today: a Today split with the same ID, sizes and focus.
        try s.move(.item(id), to: .today(spaceID: sp, index: 0))
        XCTAssertNil(s.item(id))
        let today = try XCTUnwrap(s.state.splits[id])
        XCTAssertEqual(today.tabIDs, [a, b])
        XCTAssertEqual(today.focusedTabID, b)
        XCTAssertEqual(today.fractions[0], 0.3, accuracy: 1e-9)
        XCTAssertTrue(s.tab(a)!.isToday)
        XCTAssertEqual(s.todayRows(ofSpace: sp).map(\.id), [id])
        XCTAssertTrue(s.state.items.values.allSatisfy { $0.kind != .tab || $0.parentID == nil }, "pane items left behind")
    }

    func testAnUnloadedPinnedSplitDraggedIntoTodayGetsTabsAtItsSavedURLs() throws {
        let s = try makeStore()
        let (sp, id, a, _) = try pinnedSplit(s)
        try s.closeTab(a)
        try s.move(.item(id), to: .today(spaceID: sp, index: 0))
        let x = try XCTUnwrap(s.state.splits[id])
        XCTAssertEqual(x.tabIDs.compactMap { s.tab($0)?.url }, ["https://left.test/", "https://right.test/"])
        XCTAssertTrue(x.tabIDs.allSatisfy { s.tab($0)?.isToday == true })
    }

    func testFavoritesCountASplitAsOneTile() throws {
        let s = try makeStore()
        let (sp, id, _, _) = try pinnedSplit(s)
        let pid = s.profile(ofSpace: sp).id
        for n in 0..<11 {
            let t = try s.openTab(url: "https://fav\(n).test/", inSpace: sp)
            try s.move(.tab(t.id), to: .favorites(profileID: pid, index: n))
        }
        try s.move(.item(id), to: .favorites(profileID: pid, index: 11))
        XCTAssertEqual(s.favorites(ofProfile: pid).count, 12)
        // Separating it would make 13: refused, nothing changes.
        XCTAssertThrowsError(try s.separateSplit(id)) { XCTAssertEqual($0 as? StoreError, .favoritesFull) }
        XCTAssertEqual(s.item(id)?.kind, .split)
        // Another split can't come in either.
        let c = try s.openTab(url: "https://c.test/", inSpace: sp)
        let d = try s.openTab(url: "https://d.test/", inSpace: sp)
        let y = try s.createSplit([c.id, d.id], inSpace: sp)
        XCTAssertThrowsError(try s.move(.split(y.id), to: .favorites(profileID: pid, index: 0))) { XCTAssertEqual($0 as? StoreError, .favoritesFull) }
        XCTAssertNotNil(s.state.splits[y.id])
    }

    func testSeparateAllTabsInPinnedAndFavoritesAndUndo() throws {
        let s = try makeStore()
        let (sp, id, a, b) = try pinnedSplit(s)
        let after = try s.openTab(url: "https://after.test/", inSpace: sp)
        try s.move(.tab(after.id), to: .pinned(spaceID: sp, parentID: nil, index: 1))
        try s.separateSplit(id)
        XCTAssertNil(s.item(id))
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).compactMap { $0.liveTab?.id }, [a, b, after.id], "the panes take the split's place, in order")
        try s.undo()
        XCTAssertEqual(s.item(id)?.kind, .split)
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).map(\.id), [id, s.tab(after.id)!.itemID!])
        // In Favorites: Favorites of their own.
        let pid = s.profile(ofSpace: sp).id
        try s.move(.item(id), to: .favorites(profileID: pid, index: 0))
        try s.separateSplit(id)
        XCTAssertEqual(s.favorites(ofProfile: pid).compactMap { s.liveTab(forItem: $0.id)?.id }, [a, b])
    }

    func testOnePaneSeparatedOrDraggedOut() throws {
        let s = try makeStore()
        let (sp, id, a, b) = try pinnedSplit(s)
        let c = try s.openTab(url: "https://third.test/", inSpace: sp)
        try s.addToSplit(id, tabID: c.id)
        XCTAssertEqual(s.split(id)?.tabIDs, [a, b, c.id])
        XCTAssertEqual(s.split(id)?.focusedTabID, c.id)
        XCTAssertEqual(s.split(id)!.fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(s.split(id)!.fractions[2], 1.0 / 3, accuracy: 1e-9)
        // Separate the middle pane: a pinned tab of its own just below the split.
        try s.removeFromSplit(b)
        XCTAssertEqual(s.split(id)?.tabIDs, [a, c.id])
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).map { $0.liveTab?.id }, [c.id, b])
        XCTAssertEqual(s.split(id)?.focusedTabID, c.id)
        // Drag a pane out into Today: a split of one pane ends, the other becomes a plain pinned tab in its place.
        try s.move(.tab(c.id), to: .today(spaceID: sp, index: 0))
        XCTAssertTrue(s.tab(c.id)!.isToday)
        XCTAssertNil(s.item(id))
        XCTAssertEqual(s.pinnedRows(ofSpace: sp).compactMap { $0.liveTab?.id }, [a, b])
        XCTAssertNil(s.split(containing: a))
    }

    func testAPinnedSplitTakesUpToFourPanesFromItsProfile() throws {
        let s = try makeStore()
        let (sp, id, _, _) = try pinnedSplit(s)
        let c = try s.openTab(url: "https://c.test/", inSpace: sp)
        let d = try s.openTab(url: "https://d.test/", inSpace: sp)
        let e = try s.openTab(url: "https://e.test/", inSpace: sp)
        try s.addToSplit(id, tabID: c.id, at: 0)
        XCTAssertEqual(s.split(id)?.tabIDs.first, c.id)
        try s.addToSplit(id, tabID: d.id)
        XCTAssertThrowsError(try s.addToSplit(id, tabID: e.id)) { XCTAssertEqual($0 as? StoreError, .splitFull) }
        XCTAssertEqual(paneURLs(s, id).count, 4)
        // A tab of another profile can't become a pane here.
        let work = try s.createProfile(name: "Work")
        let ws = try s.createSpace(name: "Work", profileID: work.id)
        let w = try s.openTab(url: "https://w.test/", inSpace: ws.id)
        try s.removeFromSplit(d.id)
        XCTAssertThrowsError(try s.addToSplit(id, tabID: w.id))
        // A pane of a pinned split can't join a Today split as it is.
        let f = try s.openTab(url: "https://f.test/", inSpace: sp)
        XCTAssertThrowsError(try s.createSplit([c.id, f.id], inSpace: sp))
        // Dropped onto a Today tab, it leaves the pinned split for a new Today split, in one undo step.
        try s.move(.tab(c.id), to: .split(spaceID: sp, target: f.id, leading: true))
        XCTAssertEqual(s.split(containing: c.id)?.tabIDs, [c.id, f.id])
        XCTAssertEqual(s.state.splits.count, 1, "a pane leaving a pinned split made a Today split of the rest")
        XCTAssertEqual(s.split(id)?.tabIDs.count, 2)
        try s.undo()
        XCTAssertEqual(s.split(id)?.tabIDs.first, c.id)
    }

    func testATabDroppedOntoAPinnedSplitsRowIsOneMorePane() throws {
        let s = try makeStore()
        let (sp, id, _, b) = try pinnedSplit(s)
        // Closed first: the drop works on an unloaded row too, and counts every pane.
        _ = try s.closeTab(b)
        XCTAssertNil(s.liveTab(forSplitItem: id))
        let lead = try s.openTab(url: "https://lead.test/", inSpace: sp)
        try s.move(.tab(lead.id), to: .split(spaceID: sp, target: id, leading: true))
        XCTAssertEqual(paneURLs(s, id), ["https://lead.test/", "https://left.test/", "https://right.test/"])
        XCTAssertFalse(s.tab(lead.id)!.isToday, "the tab is a pinned pane now")
        XCTAssertEqual(s.item(id)?.splitLayout?.focusedItemID, s.tab(lead.id)?.itemID)
        // Open: the right half adds it last.
        _ = try s.openItem(id, inSpace: sp)
        let tail = try s.openTab(url: "https://tail.test/", inSpace: sp)
        try s.move(.tab(tail.id), to: .split(spaceID: sp, target: id, leading: false))
        XCTAssertEqual(paneURLs(s, id).last, "https://tail.test/")
        XCTAssertEqual(s.split(id)?.tabIDs.last, tail.id)
        // Four is the limit.
        let fifth = try s.openTab(url: "https://fifth.test/", inSpace: sp)
        XCTAssertThrowsError(try s.move(.tab(fifth.id), to: .split(spaceID: sp, target: id, leading: false)))
        XCTAssertTrue(s.tab(fifth.id)!.isToday)
        // One undo step each.
        _ = try s.undo()
        XCTAssertEqual(paneURLs(s, id).count, 3)
    }

    func testLayoutEditsAreSavedOnTheItem() throws {
        let s = try makeStore()
        let (_, id, a, b) = try pinnedSplit(s)
        s.setSplitFractions(id, [0.25, 0.75])
        XCTAssertEqual(s.split(id)!.fractions[0], 0.25, accuracy: 1e-9)
        try s.setSplitAxis(id, .horizontal)
        XCTAssertEqual(s.item(id)?.splitLayout?.axis, .horizontal)
        s.setSplitFocus(id, a)
        XCTAssertEqual(s.split(id)?.focusedTabID, a)
        XCTAssertEqual(s.liveTab(forSplitItem: id)?.id, a)
        // Swapping keeps each pane's size.
        try s.movePane(id, from: 0, to: 1)
        XCTAssertEqual(s.split(id)?.tabIDs, [b, a])
        XCTAssertEqual(s.split(id)!.fractions[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(paneURLs(s, id), ["https://right.test/", "https://left.test/"])
    }

    func testCommandDPinsAndUnpinsTheWholeSplit() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test/", inSpace: sp)
        let b = try s.openTab(url: "https://b.test/", inSpace: sp)
        let x = try s.createSplit([a.id, b.id], inSpace: sp)
        try s.togglePin(b.id, inSpace: sp)
        XCTAssertEqual(s.item(x.id)?.kind, .split)
        try s.togglePin(a.id, inSpace: sp)
        XCTAssertNil(s.item(x.id))
        XCTAssertEqual(s.state.splits[x.id]?.tabIDs, [a.id, b.id])
    }

    func testDuplicateAndCopyKeepThePanes() throws {
        let s = try makeStore()
        let (sp, id, _, _) = try pinnedSplit(s)
        let copy = try s.duplicateItem(id)
        XCTAssertEqual(copy.kind, .split)
        XCTAssertEqual(paneURLs(s, copy.id), paneURLs(s, id))
        let copied = s.item(copy.id)!.splitLayout!
        let panes = s.panes(ofSplitItem: copy.id).map(\.id)
        XCTAssertEqual(copied.focusedItemID, panes[1])
        XCTAssertEqual(copied.fractions(panes)[0], 0.3, accuracy: 1e-9)
        // ⌥-drag into Favorites.
        let pid = s.profile(ofSpace: sp).id
        let fav = try s.copy(.item(id), to: .favorites(profileID: pid, index: 0))
        XCTAssertEqual(s.item(fav)?.kind, .split)
        XCTAssertEqual(paneURLs(s, fav), paneURLs(s, id))
        XCTAssertTrue(s.panes(ofSplitItem: fav).allSatisfy(\.isFavorite))
        // Deleting a split takes its panes and their pages; ⌘Z restores all of it.
        let before = s.state.items.count
        try s.deleteItem(id)
        XCTAssertEqual(s.state.items.count, before - 3)
        try s.undo()
        XCTAssertEqual(s.state.items.count, before)
    }

    func testPinnedAndFavoriteSplitsSurviveARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-itemsplit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var ids: (sp: String, pinned: String, fav: String) = ("", "", "")
        do {
            let s = try SpacesStore(path: path)
            let (sp, id, _, _) = try pinnedSplit(s)
            let c = try s.openTab(url: "https://c.test/", inSpace: sp)
            let d = try s.openTab(url: "https://d.test/", inSpace: sp)
            let y = try s.createSplit([c.id, d.id], inSpace: sp)
            try s.move(.split(y.id), to: .favorites(profileID: s.profile(ofSpace: sp).id, index: 0))
            try s.closeTab(c.id)
            try s.flush()
            ids = (sp, id, y.id)
        }
        let s = try SpacesStore(path: path)
        XCTAssertTrue(s.unreadableRows.isEmpty, "\(s.unreadableRows)")
        XCTAssertEqual(s.pinnedRows(ofSpace: ids.sp).map(\.id), [ids.pinned])
        XCTAssertEqual(paneURLs(s, ids.pinned), ["https://left.test/", "https://right.test/"])
        let x = try XCTUnwrap(s.split(ids.pinned))
        XCTAssertEqual(x.axis, .vertical)
        XCTAssertEqual(x.fractions[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.favorites(ofProfile: s.profile(ofSpace: ids.sp).id).map(\.id), [ids.fav])
        XCTAssertEqual(paneURLs(s, ids.fav), ["https://c.test/", "https://d.test/"])
        XCTAssertNil(s.split(ids.fav), "it was closed: unloaded after the relaunch too")
    }

    func testOlderStoresAndLayoutsStillRead() throws {
        // An item row as builds before SV-2 wrote it (no splitLayout key) reads.
        let old = #"{"container":{"pinned":{"spaceID":"s"}},"createdAt":1800000000,"id":"i","isCollapsed":false,"kind":"tab","order":0,"savedURL":"https://a.test/"}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let item = try d.decode(Item.self, from: Data(old.utf8))
        XCTAssertNil(item.splitLayout)
        // A layout a newer build wrote (an unknown axis, an extra field) reads with defaults; a split with none is even.
        let layout = try d.decode(SplitLayout.self, from: Data(#"{"axis":"diagonal","shares":{"p":2},"future":1}"#.utf8))
        XCTAssertEqual(layout.axis, .horizontal)
        XCTAssertEqual(layout.fractions(["p", "q"])[0], 0.8, accuracy: 1e-9)   // q has no share: an even one (0.5)
        XCTAssertEqual(SplitLayout().fractions(["p", "q"]), [0.5, 0.5])
        // Encoding a plain item still writes no layout.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("splitLayout"))
    }

    func testImportedSplitsInPinnedFoldersAndFavorites() throws {
        typealias B = ImportBlueprint
        let tab = { (id: String) in B.Tab(sourceID: "arc-item:" + id, url: "https://\(id.lowercased()).test/", pageTitle: id) }
        let split = B.SplitView(sourceID: "arc-item:SV1", axis: .vertical, shares: [1, 3], focusedSourceID: "arc-item:B", tabs: [tab("A"), tab("B")])
        let favSplit = B.SplitView(sourceID: "arc-item:SV2", tabs: [tab("F"), tab("G")])
        let b = B(profiles: [.init(sourceID: "arc-profile:Default", name: "Personal", isSourceDefault: true)],
                  spaces: [.init(sourceID: "arc-space:S", name: "Home", profileSourceID: "arc-profile:Default",
                                 pinned: [.folder(.init(sourceID: "arc-item:F1", title: "Docs", children: [.tab(tab("P")), .split(split)]))])],
                  favorites: ["arc-profile:Default": [tab("E"), tab("F"), tab("G")]],
                  favoriteNodes: ["arc-profile:Default": [.tab(tab("E")), .split(favSplit)]])
        XCTAssertEqual(b.favoriteCount, 2)
        XCTAssertEqual(b.spaces[0].pinnedTabCount, 3)
        let s = try makeStore()
        let r = try s.applyImport(b)
        XCTAssertEqual(r.splits, 2)
        XCTAssertEqual(r.favorites, 2)
        let sp = try XCTUnwrap(s.space(sourceID: "arc-space:S"))
        let rows = s.pinnedRows(ofSpace: sp.id)
        XCTAssertEqual(rows.count, 3)
        let pinned = try XCTUnwrap(rows.last?.item)
        XCTAssertEqual(pinned.kind, .split)
        XCTAssertEqual(paneURLs(s, pinned.id), ["https://a.test/", "https://b.test/"])
        let panes = s.panes(ofSplitItem: pinned.id)
        XCTAssertEqual(pinned.splitLayout?.axis, .vertical)
        XCTAssertEqual(pinned.splitLayout?.focusedItemID, panes[1].id)
        XCTAssertEqual(pinned.splitLayout!.fractions(panes.map(\.id))[0], 0.25, accuracy: 1e-9)
        let favs = s.favorites(ofProfile: s.defaultProfile.id)
        XCTAssertEqual(favs.map(\.kind), [.tab, .split])
        XCTAssertEqual(paneURLs(s, favs[1].id), ["https://f.test/", "https://g.test/"])
        // Opening the imported split shows both panes.
        _ = try s.openItem(pinned.id, inSpace: sp.id)
        XCTAssertEqual(s.split(pinned.id)?.tabIDs.count, 2)
        // A second import updates in place.
        let count = s.state.items.count
        try s.applyImport(b)
        XCTAssertEqual(s.state.items.count, count)
        // Older blueprints (no favoriteNodes) still import their Favorites flat.
        let flat = try makeStore()
        try flat.applyImport(B(profiles: b.profiles, spaces: [], favorites: b.favorites))
        XCTAssertEqual(flat.favorites(ofProfile: flat.defaultProfile.id).count, 3)
    }
}
