// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// S09/S11 (moveto): Favorite › Move to › (Spaces and other profiles, grouped by profile), Folder › Move to › with its
/// nesting, Reset Folder and Turn into Space, each one ⌘Z.
final class MoveToTests: XCTestCase {
    /// Home (default profile) and Work (same profile), Club (profile "Club"); a Favorite "Mail" in the default profile;
    /// Trip › [Alpha, Tickets › [Bravo]] pinned in Home.
    private struct World {
        let s: SpacesStore
        let home: String, work: String, club: String, pid: String, clubPID: String
        let fav: String, favTab: String, folder: String, nested: String, alpha: String, bravo: String
    }

    private func world() throws -> World {
        let s = try makeStore()
        let home = s.selectedSpace.id
        try s.updateSpace(home) { $0.name = "Home" }
        let pid = s.profile(ofSpace: home).id
        let work = try s.createSpace(name: "Work", icon: .emoji("💼")).id
        let clubP = try s.createProfile(name: "Club")
        let club = try s.createSpace(name: "Club", profileID: clubP.id).id
        let m = try s.openTab(url: "https://mail.example/", inSpace: home, title: "Mail")
        try s.move(.tab(m.id), to: .favorites(profileID: pid, index: 0))
        let fav = try XCTUnwrap(s.tab(m.id)?.itemID)
        func pin(_ title: String, _ url: String) throws -> (tab: String, item: String) {
            let t = try s.openTab(url: url, inSpace: home, title: title)
            try s.move(.tab(t.id), to: .pinned(spaceID: home, parentID: nil, index: s.pinnedRoots(ofSpace: home).count))
            return (t.id, try XCTUnwrap(s.tab(t.id)?.itemID))
        }
        let a = try pin("Alpha", "https://a.example/"), b = try pin("Bravo", "https://b.example/")
        let tickets = try s.createFolder(named: "Tickets", inSpace: home, containing: [.item(b.item)])
        let trip = try s.createFolder(named: "Trip", inSpace: home, index: 0, containing: [.item(a.item), .item(tickets.id)])
        return World(s: s, home: home, work: work, club: club, pid: pid, clubPID: clubP.id, fav: fav, favTab: m.id,
                     folder: trip.id, nested: tickets.id, alpha: a.tab, bravo: b.tab)
    }

    func testAFavoritesPlanListsItsProfilesSpacesThenEachOtherProfileWithItsFavorites() throws {
        let w = try world()
        let plan = w.s.moveToPlan(forItem: w.fav)
        XCTAssertEqual(plan.sections.map(\.header), [nil, "Club"])
        XCTAssertEqual(plan.sections[0].rows.map(\.target), [.space(w.home), .space(w.work)], "every Space of its profile")
        XCTAssertEqual(plan.sections[0].rows.map(\.title), [w.home, w.work].compactMap { w.s.space($0).map(LinkSpaceMenu.title(of:)) })
        XCTAssertEqual(plan.sections[0].rows.last?.title, "💼 Work")
        XCTAssertEqual(plan.sections[1].rows.map(\.target), [.favorites(profileID: w.clubPID), .space(w.club)])
        XCTAssertEqual(plan.rows.map(\.crossProfile), [false, false, true, true])
    }

    func testAFoldersPlanLeavesOutItsOwnSpaceAndNeverOffersFavorites() throws {
        let w = try world()
        let plan = w.s.moveToPlan(forItem: w.folder)
        XCTAssertEqual(plan.rows.map(\.target), [.space(w.work), .space(w.club)])
        XCTAssertEqual(plan.sections.map(\.header), [nil, "Club"])
        // One profile only: no headers.
        let s = try makeStore()
        _ = try s.createSpace(name: "Two")
        let f = try s.createFolder(named: "F", inSpace: s.selectedSpace.id)
        XCTAssertEqual(s.moveToPlan(forItem: f.id).sections.map(\.header), [nil])
        XCTAssertTrue(w.s.moveToPlan(forItem: "nope").isEmpty)
    }

    func testAFavoriteMovedToASpaceBecomesItsLastPinnedTabInOneUndoStep() throws {
        let w = try world()
        let reload = try w.s.moveFavorites([w.fav], to: .space(w.work))
        XCTAssertTrue(reload.isEmpty, "same profile: the page stays")
        XCTAssertEqual(w.s.item(w.fav)?.container, .pinned(spaceID: w.work))
        XCTAssertEqual(w.s.pinnedRoots(ofSpace: w.work).last?.id, w.fav)
        XCTAssertTrue(w.s.favorites(ofProfile: w.pid).isEmpty)
        XCTAssertEqual(w.s.undoLabel, "Move to Space")
        _ = try w.s.undo()
        XCTAssertEqual(w.s.item(w.fav)?.container, .favorites(profileID: w.pid), "⌘Z: a Favorite again")
    }

    func testAFavoriteMovedToAnotherProfileReopensThere() throws {
        let w = try world()
        let reload = try w.s.moveFavorites([w.fav], to: .favorites(profileID: w.clubPID))
        XCTAssertEqual(reload, [w.favTab], "its page reopens with Club's cookies")
        XCTAssertEqual(w.s.tab(w.favTab)?.profileID, w.clubPID)
        XCTAssertEqual(w.s.favorites(ofProfile: w.clubPID).map(\.id), [w.fav])
        XCTAssertEqual(w.s.undoLabel, "Move Favorite")
        _ = try w.s.undo()
        XCTAssertEqual(w.s.tab(w.favTab)?.profileID, w.pid)

        let r2 = try w.s.moveFavorites([w.fav], to: .space(w.club))
        XCTAssertEqual(r2, [w.favTab])
        XCTAssertEqual(w.s.item(w.fav)?.container, .pinned(spaceID: w.club))
        XCTAssertEqual(w.s.tab(w.favTab)?.profileID, w.clubPID)
        XCTAssertThrowsError(try w.s.moveFavorites([w.folder], to: .space(w.work)), "only Favorites")
    }

    func testAFullFavoritesGridRefusesTheWholeMove() throws {
        let w = try world()
        for i in 0..<SpacesStore.maxFavorites {
            let t = try w.s.openTab(url: "https://f\(i).example/", inSpace: w.club)
            try w.s.move(.tab(t.id), to: .favorites(profileID: w.clubPID, index: i))
        }
        XCTAssertThrowsError(try w.s.moveFavorites([w.fav], to: .favorites(profileID: w.clubPID))) {
            XCTAssertEqual($0 as? StoreError, .favoritesFull)
        }
        XCTAssertEqual(w.s.item(w.fav)?.container, .favorites(profileID: w.pid))
    }

    func testAFolderMovesWithItsNestingIntactAcrossProfilesInOneUndoStep() throws {
        let w = try world()
        XCTAssertEqual(Set(w.s.tabsReopening([.item(w.folder)], inProfile: w.clubPID).map(\.id)), [w.alpha, w.bravo])
        let reload = try w.s.moveRows([.item(w.folder)], toSpace: w.club)
        XCTAssertEqual(Set(reload), [w.alpha, w.bravo], "nested tabs reopen too")
        XCTAssertEqual(w.s.item(w.folder)?.container, .pinned(spaceID: w.club))
        XCTAssertEqual(w.s.item(w.nested)?.parentID, w.folder, "Tickets stays inside Trip")
        XCTAssertEqual(w.s.item(w.nested)?.container, .pinned(spaceID: w.club))
        XCTAssertEqual(w.s.tab(w.bravo)?.spaceID, w.club)
        XCTAssertEqual(w.s.tab(w.bravo)?.profileID, w.clubPID)
        XCTAssertEqual(w.s.undoLabel, "Move to Space")
        _ = try w.s.undo()
        XCTAssertEqual(w.s.item(w.folder)?.container, .pinned(spaceID: w.home))
        XCTAssertEqual(w.s.tab(w.bravo)?.profileID, w.pid)
        XCTAssertEqual(w.s.tab(w.bravo)?.spaceID, w.home)
    }

    func testASelectionOfAFolderAndAFavoriteMovesBothInOneStep() throws {
        let w = try world()
        _ = try w.s.moveRows([.item(w.folder), .item(w.fav)], toSpace: w.work)
        XCTAssertEqual(w.s.item(w.folder)?.container, .pinned(spaceID: w.work))
        XCTAssertEqual(w.s.item(w.fav)?.container, .pinned(spaceID: w.work))
        _ = try w.s.undo()
        XCTAssertEqual(w.s.item(w.folder)?.container, .pinned(spaceID: w.home))
        XCTAssertEqual(w.s.item(w.fav)?.container, .favorites(profileID: w.pid), "one ⌘Z for both")
    }

    func testResetFolderAndTurnIntoSpaceStayOneUndoStepEach() throws {
        let w = try world()
        w.s.updateTab(w.bravo, url: "https://elsewhere.example/")
        XCTAssertEqual(w.s.driftedPinnedTabs(inFolder: w.folder).map(\.id), [w.bravo])
        let (made, _) = try w.s.turnFolderIntoSpace(w.folder)
        XCTAssertEqual(made.name, "Trip")
        XCTAssertEqual(w.s.pinnedRoots(ofSpace: made.id).count, 2)
        _ = try w.s.undo()
        XCTAssertNil(w.s.space(made.id))
        XCTAssertEqual(w.s.item(w.nested)?.parentID, w.folder)
    }
}
