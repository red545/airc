// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// P01c: a folder's own reset, Turn into Space (Arc's newSpaceFromFolder) and the Space header rule for the only,
/// unnamed Space (Arc's showSpaceHeaderOnSingleUnnamedSpaces).
final class ParityP01cTests: XCTestCase {
    /// Trip › [Alpha, Tickets › [Bravo]], and Delta outside it, pinned in the store's one Space.
    private func trip() throws -> (s: SpacesStore, sid: String, folder: String, nested: String, alpha: String, bravo: String, delta: String) {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        func pin(_ title: String, _ url: String) throws -> (tab: String, item: String) {
            let t = try s.openTab(url: url, inSpace: sid, title: title)
            try s.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: nil, index: s.pinnedRoots(ofSpace: sid).count))
            let i = try XCTUnwrap(s.tab(t.id)?.itemID)
            try s.renameItem(i, to: title)
            return (t.id, i)
        }
        let a = try pin("Alpha", "https://a.example/"), b = try pin("Bravo", "https://b.example/"), d = try pin("Delta", "https://d.example/")
        let tickets = try s.createFolder(named: "Tickets", inSpace: sid, containing: [.item(b.item)])
        let folder = try s.createFolder(named: "Trip", inSpace: sid, index: 0, containing: [.item(a.item), .item(tickets.id)])
        try s.setItemIcon(folder.id, to: "🧳")
        return (s, sid, folder.id, tickets.id, a.tab, b.tab, d.tab)
    }

    func testFolderResetTakesOnlyTheFoldersDriftedTabsNestedOnesToo() throws {
        let t = try trip()
        XCTAssertTrue(t.s.driftedPinnedTabs(inFolder: t.folder).isEmpty)
        t.s.updateTab(t.bravo, url: "https://elsewhere.example/b")
        t.s.updateTab(t.delta, url: "https://elsewhere.example/d")
        XCTAssertEqual(t.s.driftedPinnedTabs(inFolder: t.folder).map(\.id), [t.bravo], "the nested tab, not Delta outside")
        XCTAssertEqual(t.s.driftedPinnedTabs(inFolder: t.nested).map(\.id), [t.bravo])
        XCTAssertEqual(Set(t.s.driftedPinnedTabs(inSpace: t.sid).map(\.id)), [t.bravo, t.delta])
        XCTAssertTrue(t.s.driftedPinnedTabs(inFolder: "no such folder").isEmpty)
    }

    func testTurnIntoSpaceMakesASpaceOfTheFolderInOneUndoStep() throws {
        let t = try trip()
        let from = try XCTUnwrap(t.s.space(t.sid))
        let (made, reload) = try t.s.turnFolderIntoSpace(t.folder)
        XCTAssertEqual(made.name, "Trip")
        XCTAssertEqual(made.icon, .emoji("🧳"))
        XCTAssertEqual(made.profileID, from.profileID)
        XCTAssertEqual(made.theme, from.theme)
        XCTAssertEqual(t.s.orderedSpaces.map(\.id), [t.sid, made.id], "right after the folder's Space")
        let roots = t.s.pinnedRoots(ofSpace: made.id)
        XCTAssertEqual(roots.map(\.id).last, t.nested, "Alpha, then Tickets, in the folder's order")
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(t.s.children(of: .pinned(spaceID: made.id), parent: t.nested).count, 1, "Bravo stays inside Tickets")
        XCTAssertEqual(t.s.tab(t.alpha)?.spaceID, made.id, "a tab of the folder lives in the new Space")
        XCTAssertNil(t.s.item(t.folder), "the folder goes")
        XCTAssertEqual(t.s.pinnedRoots(ofSpace: t.sid).count, 1, "Delta stays where it was")
        XCTAssertTrue(reload.isEmpty, "the same profile: nothing reloads")
        XCTAssertEqual(t.s.undoLabel, "Turn into Space")
        _ = try t.s.undo()
        XCTAssertNil(t.s.space(made.id))
        XCTAssertEqual(t.s.item(t.nested)?.parentID, t.folder, "⌘Z: the folder back with its rows")
        XCTAssertEqual(t.s.tab(t.alpha)?.spaceID, t.sid)
        XCTAssertThrowsError(try t.s.turnFolderIntoSpace(t.alpha), "a tab isn't a folder")
    }

    func testTheOnlyUnnamedSpaceHidesItsHeaderUnlessAskedToShowIt() throws {
        XCTAssertFalse(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "", hasIcon: false, showOnSingleUnnamed: false))
        XCTAssertFalse(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "  ", hasIcon: false, showOnSingleUnnamed: false))
        XCTAssertTrue(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "", hasIcon: false, showOnSingleUnnamed: true), "Show Space Header")
        XCTAssertTrue(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "", hasIcon: false, pinnedCollapsed: true, showOnSingleUnnamed: false),
                      "a folded pinned section keeps the row that unfolds it")
        XCTAssertTrue(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "Home", hasIcon: false, showOnSingleUnnamed: false))
        XCTAssertTrue(SpaceHeaderPolicy.showsHeader(spaceCount: 1, name: "", hasIcon: true, showOnSingleUnnamed: false))
        XCTAssertTrue(SpaceHeaderPolicy.showsHeader(spaceCount: 2, name: "", hasIcon: false, showOnSingleUnnamed: false))

        let s = try makeStore()
        let sid = s.selectedSpace.id
        try s.updateSpace(sid) { $0.name = ""; $0.icon = nil }
        XCTAssertTrue(s.offersHeaderToggle(ofSpace: sid))
        XCTAssertFalse(s.showsHeader(ofSpace: sid, showOnSingleUnnamed: false))
        _ = try s.createSpace(name: "Work")
        XCTAssertFalse(s.offersHeaderToggle(ofSpace: sid), "with a second Space every header shows")
        XCTAssertTrue(s.showsHeader(ofSpace: sid, showOnSingleUnnamed: false))
    }
}
