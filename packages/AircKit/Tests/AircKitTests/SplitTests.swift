// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// SV-1 Split View: one row in Today, tabs that keep their own Space and profile, ⌘Z, Separate All Tabs, relaunch.
final class SplitTests: XCTestCase {
    private func rows(_ s: SpacesStore, _ sp: String) -> [String] { s.todayRows(ofSpace: sp).map(\.id) }

    func testASplitIsOneRowWhereItsFirstTabWas() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        XCTAssertEqual(rows(s, sp), [c.id, b.id, a.id])
        let x = try s.createSplit([b.id, a.id], inSpace: sp, focused: a.id)
        XCTAssertEqual(rows(s, sp), [c.id, x.id])
        XCTAssertEqual(x.fractions, [0.5, 0.5])
        guard case .split(let row, let tabs)? = s.sidebarEntries(ofSpace: sp).last else { return XCTFail("no split row") }
        XCTAssertEqual(row.id, x.id)
        XCTAssertEqual(tabs.map(\.id), [b.id, a.id])
        // The row opens its focused pane; it shows both.
        XCTAssertEqual(s.sidebarEntries(ofSpace: sp).last?.liveTab?.id, a.id)
        XCTAssertTrue(s.sidebarEntries(ofSpace: sp).last!.shows(b.id))
        // New tabs still go to the top, above the split.
        let d = try s.openTab(url: "https://d.test", inSpace: sp)
        XCTAssertEqual(rows(s, sp), [d.id, c.id, x.id])
        // ⌘N counts the split as one row.
        XCTAssertEqual(s.commandNumberTarget(3, inSpace: sp)?.id, x.id)
    }

    func testDroppingATabOnATabMakesASplitInTheHalfItLands() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        // c dropped on the right half of a: a | c, in a's place.
        try s.move(.tab(c.id), to: .split(spaceID: sp, target: a.id, leading: false))
        let x = try XCTUnwrap(s.split(containing: a.id))
        XCTAssertEqual(x.tabIDs, [a.id, c.id])
        XCTAssertEqual(x.focusedTabID, c.id)
        XCTAssertEqual(rows(s, sp), [b.id, x.id])
        // b dropped on the left half of the split row: first.
        try s.move(.tab(b.id), to: .split(spaceID: sp, target: x.id, leading: true))
        XCTAssertEqual(s.split(x.id)?.tabIDs, [b.id, a.id, c.id])
        XCTAssertEqual(s.split(x.id)!.fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(s.split(x.id)!.fractions[0], 1.0 / 3, accuracy: 1e-9)
        // On a pane's tab: next to it.
        let d = try s.openTab(url: "https://d.test", inSpace: sp)
        try s.move(.tab(d.id), to: .split(spaceID: sp, target: a.id, leading: false))
        XCTAssertEqual(s.split(x.id)?.tabIDs, [b.id, a.id, d.id, c.id])
        // Four is Arc's limit.
        let e = try s.openTab(url: "https://e.test", inSpace: sp)
        XCTAssertThrowsError(try s.move(.tab(e.id), to: .split(spaceID: sp, target: x.id, leading: false))) {
            XCTAssertEqual($0 as? StoreError, .splitFull)
        }
        XCTAssertNil(s.split(containing: e.id))
        // A tab can't be dropped on itself, and ⌥ (copy) onto a tab does nothing.
        XCTAssertThrowsError(try s.move(.tab(e.id), to: .split(spaceID: sp, target: e.id, leading: true)))
        XCTAssertThrowsError(try s.copy(.tab(e.id), to: .split(spaceID: sp, target: b.id, leading: true)))
    }

    func testClosingAPaneShrinksTheSplitAndUndoBringsItBack() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        let x = try s.createSplit([a.id, b.id, c.id], inSpace: sp)
        s.setSplitFractions(x.id, [0.5, 0.25, 0.25])
        try s.closeTab(b.id)
        let after = try XCTUnwrap(s.split(x.id))
        XCTAssertEqual(after.tabIDs, [a.id, c.id])
        // b's share goes to the others in proportion.
        XCTAssertEqual(after.fractions[0], 2.0 / 3, accuracy: 1e-9)
        try s.undo()
        XCTAssertEqual(s.split(x.id)?.tabIDs, [a.id, b.id, c.id])
        XCTAssertEqual(s.split(x.id)?.fractions, [0.5, 0.25, 0.25])
        // Down to one pane, there's no split: the last tab is a row of its own.
        try s.closeTab(a.id)
        try s.closeTab(c.id)
        XCTAssertNil(s.split(x.id))
        XCTAssertEqual(rows(s, sp), [b.id])
        try s.undo()
        XCTAssertEqual(s.split(x.id)?.tabIDs, [b.id, c.id])
    }

    func testSeparateAllTabsPutsThePanesWhereTheRowWas() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        let d = try s.openTab(url: "https://d.test", inSpace: sp)
        // Rows: d c b a. Split (a, c) sits where c was.
        let x = try s.createSplit([a.id, c.id], inSpace: sp)
        XCTAssertEqual(rows(s, sp), [d.id, x.id, b.id])
        try s.separateSplit(x.id)
        XCTAssertNil(s.split(x.id))
        XCTAssertEqual(rows(s, sp), [d.id, a.id, c.id, b.id])
        try s.undo()
        XCTAssertEqual(rows(s, sp), [d.id, x.id, b.id])
        // One pane out: just below the split's row.
        let e = try s.openTab(url: "https://e.test", inSpace: sp)
        try s.move(.tab(e.id), to: .split(spaceID: sp, target: x.id, leading: false))
        try s.removeFromSplit(a.id)
        XCTAssertEqual(s.split(x.id)?.tabIDs, [c.id, e.id])
        XCTAssertEqual(rows(s, sp), [d.id, x.id, a.id, b.id])
        try s.undo()
        XCTAssertEqual(s.split(x.id)?.tabIDs, [a.id, c.id, e.id])
    }

    func testMovingATabAnywhereTakesItOutOfItsSplit() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        let x = try s.createSplit([a.id, b.id, c.id], inSpace: sp)
        // Dragged into Pinned on its own (⌘D pins the whole split since SV-2: ItemSplitTests).
        try s.move(.tab(a.id), to: .pinned(spaceID: sp, parentID: nil, index: 0))
        XCTAssertEqual(s.split(x.id)?.tabIDs, [b.id, c.id])
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id)
        try s.moveTab(b.id, toSpace: other.id)
        XCTAssertNil(s.split(x.id))
        XCTAssertEqual(rows(s, other.id), [b.id])
    }

    func testASplitRowMovesInToday() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        let d = try s.openTab(url: "https://d.test", inSpace: sp)
        let x = try s.createSplit([d.id, c.id], inSpace: sp)
        XCTAssertEqual(rows(s, sp), [x.id, b.id, a.id])
        try s.move(.split(x.id), to: .today(spaceID: sp, index: 3))
        XCTAssertEqual(rows(s, sp), [b.id, a.id, x.id])
        // A tab dropped between rows counts the split as one row.
        try s.move(.tab(b.id), to: .today(spaceID: sp, index: 3))
        XCTAssertEqual(rows(s, sp), [a.id, x.id, b.id])
        // A split's row stays in its Space.
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id)
        XCTAssertThrowsError(try s.move(.split(x.id), to: .today(spaceID: other.id, index: 0)))
        // ⌘Z puts the row back (the tab's move after it isn't an undo step of its own).
        try s.undo()
        XCTAssertEqual(rows(s, sp), [x.id, a.id, b.id])
    }

    func testACrossSpacePaneKeepsItsProfile() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let work = try s.createProfile(name: "Work")
        let w = try s.createSpace(name: "Work", profileID: work.id)
        let a = try s.openTab(url: "https://a.test", inSpace: home)
        let mail = try s.openTab(url: "https://mail.test", inSpace: w.id)
        XCTAssertEqual(s.lastActiveTab(ofSpace: w.id)?.id, mail.id)
        // Dragged from Work onto a Home tab: the pane keeps Work's profile and Space.
        try s.move(.tab(mail.id), to: .split(spaceID: home, target: a.id, leading: false))
        let x = try XCTUnwrap(s.split(containing: mail.id))
        XCTAssertEqual(x.spaceID, home)
        XCTAssertEqual(s.tab(mail.id)?.profileID, work.id)
        XCTAssertEqual(s.tab(mail.id)?.spaceID, w.id)
        // It shows in Home's split row, not as a row in Work; Work doesn't open on it.
        XCTAssertEqual(rows(s, home), [x.id])
        XCTAssertEqual(rows(s, w.id), [])
        XCTAssertNil(s.lastActiveTab(ofSpace: w.id))
        try s.activate(mail.id, inSpace: home)
        XCTAssertEqual(s.lastActiveTab(ofSpace: home)?.id, mail.id)
        // Separated, it goes back to Work.
        try s.separateSplit(x.id)
        XCTAssertEqual(rows(s, w.id), [mail.id])
        XCTAssertEqual(rows(s, home), [a.id])
    }

    func testClearTodayKeepsTheSplitOnScreen() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let c = try s.openTab(url: "https://c.test", inSpace: sp)
        let d = try s.openTab(url: "https://d.test", inSpace: sp)
        _ = try s.createSplit([a.id, b.id], inSpace: sp)
        let y = try s.createSplit([c.id, d.id], inSpace: sp)
        try s.clearToday(inSpace: sp, keeping: a.id)
        XCTAssertEqual(rows(s, sp).count, 1)
        XCTAssertNotNil(s.tab(b.id))
        XCTAssertNil(s.split(y.id))
        XCTAssertNil(s.tab(c.id))
        try s.undo()
        XCTAssertEqual(s.split(y.id)?.tabIDs, [c.id, d.id])
    }

    func testDeletingASpaceTakesItsSplitsAndUndoRestoresThem() throws {
        let s = try makeStore()
        let first = s.selectedSpace.id
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id)
        let a = try s.openTab(url: "https://a.test", inSpace: other.id)
        let b = try s.openTab(url: "https://b.test", inSpace: other.id)
        let home = try s.openTab(url: "https://home.test", inSpace: first)
        let x = try s.createSplit([a.id, b.id], inSpace: other.id)
        // A pane from the first Space in Other's split.
        try s.addToSplit(x.id, tabID: home.id)
        try s.deleteSpace(other.id)
        XCTAssertNil(s.split(x.id))
        XCTAssertEqual(rows(s, first), [home.id])
        try s.undo()
        XCTAssertEqual(s.split(x.id)?.tabIDs, [a.id, b.id, home.id])
    }

    func testFractionsFocusAndAxis() throws {
        let s = try makeStore()
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        let x = try s.createSplit([a.id, b.id], inSpace: sp, axis: .vertical)
        s.setSplitFractions(x.id, [3, 1])
        XCTAssertEqual(s.split(x.id)?.fractions, [0.75, 0.25])
        s.setSplitFractions(x.id, [-1, .nan])
        XCTAssertEqual(s.split(x.id)?.fractions, [0.5, 0.5])
        s.setSplitFocus(x.id, b.id)
        XCTAssertEqual(s.split(x.id)?.focusedTabID, b.id)
        s.setSplitFocus(x.id, "nope")
        XCTAssertEqual(s.split(x.id)?.focusedTabID, b.id)
        try s.setSplitAxis(x.id, .horizontal)
        XCTAssertEqual(s.split(x.id)?.axis, .horizontal)
        try s.movePane(x.id, from: 0, to: 1)
        XCTAssertEqual(s.split(x.id)?.tabIDs, [b.id, a.id])
        XCTAssertEqual(Split.normalized([1, 1, 2], count: 3), [0.25, 0.25, 0.5])
    }

    func testSplitsSurviveARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var ids: (String, String, String, String) = ("", "", "", "")
        do {
            let s = try SpacesStore(path: path)
            let sp = s.selectedSpace.id
            let a = try s.openTab(url: "https://a.test", inSpace: sp)
            let b = try s.openTab(url: "https://b.test", inSpace: sp)
            let x = try s.createSplit([a.id, b.id], inSpace: sp, axis: .vertical, focused: b.id)
            s.setSplitFractions(x.id, [0.3, 0.7])
            try s.flush()
            ids = (sp, a.id, b.id, x.id)
        }
        let s = try SpacesStore(path: path)
        let x = try XCTUnwrap(s.split(ids.3))
        XCTAssertEqual(x.tabIDs, [ids.1, ids.2])
        XCTAssertEqual(x.axis, .vertical)
        XCTAssertEqual(x.focusedTabID, ids.2)
        XCTAssertEqual(x.fractions[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.todayRows(ofSpace: ids.0).map(\.id), [ids.3])
    }

    func testAnUnusableSplitIsHiddenNotDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var splitID = ""
        do {
            let s = try SpacesStore(path: path)
            let sp = s.selectedSpace.id
            let a = try s.openTab(url: "https://a.test", inSpace: sp)
            // Written by hand as a newer or damaged build might: one of its tabs is missing.
            let x = Split(spaceID: sp, tabIDs: [a.id, "gone"], order: 0)
            try s.perform(nil) { s.put(x) }
            try s.flush()
            splitID = x.id
        }
        let s = try SpacesStore(path: path)
        XCTAssertNil(s.split(splitID))
        XCTAssertTrue(s.unreadableRows.contains { $0.kind == "split" && $0.id == splitID })
    }

    func testOlderBackupsWithoutSplitsStillRead() throws {
        let s = try makeStore()
        let json = String(decoding: try s.exportJSON(), as: UTF8.self)
        let old = json.replacingOccurrences(of: "\"splits\" : {\n\n    },", with: "")
            .replacingOccurrences(of: "\"splits\" : {\n\n    }", with: "")
        XCTAssertFalse(old.contains("splits"))
        XCTAssertNoThrow(try s.restore(fromBackup: Data(old.utf8)))
    }
}
