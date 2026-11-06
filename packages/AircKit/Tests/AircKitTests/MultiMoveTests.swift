// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// SB-36: dragging a multi-selection moves (or ⌥ copies) every selected row, in order, in one undo step.
final class MultiMoveTests: XCTestCase {
    private func todayTitles(_ s: SpacesStore, _ sid: String) -> [String] { s.todayTabs(ofSpace: sid).map(\.title) }
    private func pinnedTitles(_ s: SpacesStore, _ sid: String) -> [String] {
        s.pinnedRoots(ofSpace: sid).map { $0.displayTitle }
    }

    func testTwoTodayTabsMoveIntoPinnedTogetherAndUndoInOneStep() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let a = try s.openTab(url: "https://example.com/a", inSpace: sid, title: "A")
        let b = try s.openTab(url: "https://example.com/b", inSpace: sid, title: "B")
        let c = try s.openTab(url: "https://example.com/c", inSpace: sid, title: "C")
        let order = todayTitles(s, sid)
        let picked = s.todayTabs(ofSpace: sid).filter { $0.id != b.id }.map { DragSource.tab($0.id) }
        try s.move(picked, to: .pinned(spaceID: sid, parentID: nil, index: 0))
        XCTAssertEqual(todayTitles(s, sid), ["B"], "only the unselected tab stays in Today")
        XCTAssertEqual(pinnedTitles(s, sid), order.filter { $0 != "B" }, "both are pinned, in the order they had")
        XCTAssertNotNil(s.tab(a.id)?.itemID)
        XCTAssertNotNil(s.tab(c.id)?.itemID)
        _ = try s.undo()
        XCTAssertEqual(todayTitles(s, sid), order, "one ⌘Z puts both back where they were")
        XCTAssertTrue(s.pinnedRoots(ofSpace: sid).isEmpty)
    }

    func testRowsDroppedInsideTheirOwnListKeepTheirOrderAtTheDrop() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        for t in ["A", "B", "C", "D", "E"] { _ = try s.openTab(url: "https://example.com/" + t, inSpace: sid, title: t) }
        let tabs = s.todayTabs(ofSpace: sid)
        let titles = tabs.map(\.title)
        // Pick the first and third rows and drop them below the last one.
        let picked = [tabs[0], tabs[2]].map { DragSource.tab($0.id) }
        try s.move(picked, to: .today(spaceID: sid, index: tabs.count))
        let rest = titles.enumerated().filter { $0.offset != 0 && $0.offset != 2 }.map(\.element)
        XCTAssertEqual(todayTitles(s, sid), rest + [titles[0], titles[2]])
        // And back to the top, between nothing: the same two first, in order.
        let again = s.todayTabs(ofSpace: sid).suffix(2).map { DragSource.tab($0.id) }
        try s.move(again, to: .today(spaceID: sid, index: 0))
        XCTAssertEqual(Array(todayTitles(s, sid).prefix(2)), [titles[0], titles[2]])
    }

    func testTabsAcrossSpacesTakeTheDestinationProfile() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let p = try s.createProfile(name: "Work")
        let work = try s.createSpace(name: "Work", profileID: p.id).id
        let a = try s.openTab(url: "https://example.com/a", inSpace: home, title: "A")
        let b = try s.openTab(url: "https://example.com/b", inSpace: home, title: "B")
        let reload = try s.move([.tab(a.id), .tab(b.id)], to: .today(spaceID: work, index: 0))
        XCTAssertEqual(Set(reload), [a.id, b.id], "both pages reload in the Work profile")
        XCTAssertEqual(s.tab(a.id)?.spaceID, work)
        XCTAssertEqual(s.tab(b.id)?.profileID, p.id)
    }

    func testAFolderAndItsOwnChildMoveAsTheFolder() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id).id
        let folder = try s.createFolder(named: "F", inSpace: home)
        let t = try s.openTab(url: "https://example.com/in", inSpace: home, title: "In")
        try s.move(.tab(t.id), to: .pinned(spaceID: home, parentID: folder.id, index: 0))
        let child = try XCTUnwrap(s.children(of: .pinned(spaceID: home), parent: folder.id).first)
        try s.move([.item(folder.id), .item(child.id)], to: .pinned(spaceID: other, parentID: nil, index: 0))
        XCTAssertEqual(s.pinnedRoots(ofSpace: other).map(\.id), [folder.id], "the child isn't pulled out of its folder")
        XCTAssertEqual(s.children(of: .pinned(spaceID: other), parent: folder.id).map(\.id), [child.id])
    }

    func testAFolderInTheSelectionStaysWhenTheRestGoesToToday() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let folder = try s.createFolder(named: "F", inSpace: sid)
        let t = try s.openTab(url: "https://example.com/p", inSpace: sid, title: "P")
        try s.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: nil, index: 1))
        let pin = try XCTUnwrap(s.pinnedRoots(ofSpace: sid).first { $0.id != folder.id })
        try s.move([.item(folder.id), .item(pin.id)], to: .today(spaceID: sid, index: 0))
        XCTAssertEqual(s.pinnedRoots(ofSpace: sid).map(\.id), [folder.id], "a folder can't be a Today tab")
        XCTAssertEqual(todayTitles(s, sid), ["P"])
    }

    func testFavoritesThatCantTakeThemAllRefuseTheLot() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let pid = s.defaultProfile.id
        for i in 0..<(SpacesStore.maxFavorites - 1) {
            let t = try s.openTab(url: "https://example.com/\(i)", inSpace: sid)
            try s.move(.tab(t.id), to: .favorites(profileID: pid, index: i))
        }
        let a = try s.openTab(url: "https://example.com/x", inSpace: sid)
        let b = try s.openTab(url: "https://example.com/y", inSpace: sid)
        XCTAssertThrowsError(try s.move([.tab(a.id), .tab(b.id)], to: .favorites(profileID: pid, index: 0)))
        XCTAssertNil(s.tab(a.id)?.itemID, "nothing moved")
        XCTAssertEqual(s.favorites(ofProfile: pid).count, SpacesStore.maxFavorites - 1)
    }

    func testCopyingASelectionCopiesEachOnceInOneUndoStep() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let a = try s.openTab(url: "https://example.com/a", inSpace: sid, title: "A")
        let b = try s.openTab(url: "https://example.com/b", inSpace: sid, title: "B")
        let made = try s.copy([.tab(a.id), .tab(b.id)], to: .pinned(spaceID: sid, parentID: nil, index: 0))
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(s.todayTabs(ofSpace: sid).count, 2, "the tabs stay")
        XCTAssertEqual(s.pinnedRoots(ofSpace: sid).map(\.id), made, "the copies land in order")
        _ = try s.undo()
        XCTAssertTrue(s.pinnedRoots(ofSpace: sid).isEmpty, "one ⌘Z removes both copies")
    }
}
