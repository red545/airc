// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// ⌥-drag (SB-35): `copy(_:to:)` leaves the source and puts a copy at the destination, in one undo step.
final class CopyTests: XCTestCase {
    func testTodayTabCopiedIntoPinnedKeepsTheTab() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let t = try s.openTab(url: "https://example.com/a", inSpace: sid, title: "A")
        let id = try s.copy(.tab(t.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))
        XCTAssertEqual(s.todayTabs(ofSpace: sid).map(\.id), [t.id], "the Today tab stays")
        XCTAssertEqual(s.pinnedRoots(ofSpace: sid).map(\.id), [id])
        XCTAssertEqual(s.item(id)?.savedURL, "https://example.com/a")
        XCTAssertNil(s.liveTab(forItem: id), "the copy has no page until it's opened")
    }

    func testPinnedItemCopiedIntoTodayOfAnotherSpace() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let p = try s.createProfile(name: "Work")
        let work = try s.createSpace(name: "Work", profileID: p.id).id
        let t = try s.openTab(url: "https://example.com/pin", inSpace: home, title: "Pin")
        try s.move(.tab(t.id), to: .pinned(spaceID: home, parentID: nil, index: 0))
        let item = try XCTUnwrap(s.pinnedRoots(ofSpace: home).first)
        let id = try s.copy(.item(item.id), to: .today(spaceID: work, index: 0))
        XCTAssertEqual(s.pinnedRoots(ofSpace: home).map(\.id), [item.id], "the pinned item stays")
        let copy = try XCTUnwrap(s.tab(id))
        XCTAssertEqual(copy.spaceID, work)
        XCTAssertEqual(copy.profileID, p.id, "the copy loads in the destination Space's profile")
        XCTAssertEqual(copy.url, "https://example.com/pin")
    }

    func testFolderCopiedWithChildrenIntoAnotherSpaceAndUndoneInOneStep() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id).id
        let folder = try s.createFolder(named: "F", inSpace: home)
        let t = try s.openTab(url: "https://example.com/in", inSpace: home)
        try s.move(.tab(t.id), to: .pinned(spaceID: home, parentID: folder.id, index: 0))
        let id = try s.copy(.item(folder.id), to: .pinned(spaceID: other, parentID: nil, index: 0))
        let kids = s.children(of: .pinned(spaceID: other), parent: id)
        XCTAssertEqual(kids.map(\.savedURL), ["https://example.com/in"], "children come along, in the new Space")
        XCTAssertEqual(s.children(of: .pinned(spaceID: home), parent: folder.id).count, 1, "the original keeps its child")
        _ = try s.undo()
        XCTAssertNil(s.item(id))
        XCTAssertTrue(s.pinnedRoots(ofSpace: other).isEmpty)
    }

    func testCopyIntoFullFavoritesIsRefused() throws {
        let s = try makeStore()
        let sid = s.selectedSpace.id
        let pid = s.defaultProfile.id
        for i in 0..<SpacesStore.maxFavorites {
            let t = try s.openTab(url: "https://example.com/\(i)", inSpace: sid)
            try s.move(.tab(t.id), to: .favorites(profileID: pid, index: i))
        }
        let t = try s.openTab(url: "https://example.com/x", inSpace: sid)
        XCTAssertThrowsError(try s.copy(.tab(t.id), to: .favorites(profileID: pid, index: 0)))
    }
}
