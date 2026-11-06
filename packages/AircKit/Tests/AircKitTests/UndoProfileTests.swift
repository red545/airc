// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Code review H3: ⌘Z never brings a tab back in a profile other than the one it was closed in.
final class UndoProfileTests: XCTestCase {
    /// Every tab loads in its Space's (or Favorite's) profile, and every profile it names exists.
    private func assertProfilesConsistent(_ s: SpacesStore, file: StaticString = #filePath, line: UInt = #line) {
        for t in s.state.tabs.values {
            XCTAssertNotNil(s.profile(t.profileID), "tab \(t.url) names a missing profile", file: file, line: line)
            let expected: String? = if let iid = t.itemID {
                switch s.item(iid)?.container {
                case .pinned(let sid)?: s.space(sid)?.profileID
                case .favorites(let pid)?: pid
                case nil: nil
                }
            } else { s.space(t.spaceID)?.profileID }
            XCTAssertEqual(t.profileID, expected, "tab \(t.url) loads in another profile than its Space", file: file, line: line)
        }
        for sp in s.state.spaces.values {
            XCTAssertNotNil(s.profile(sp.profileID), "Space \(sp.name) names a missing profile", file: file, line: line)
        }
    }

    func testClosedTabReopensInASpaceOfItsOwnProfile() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "Work A", profileID: work.id)
        let b = try s.createSpace(name: "Work B", profileID: work.id)
        let bank = try s.openTab(url: "https://bank.example/", inSpace: a.id)
        try s.closeTab(bank.id)
        try s.setProfile(ofSpace: a.id, to: s.defaultProfile.id)
        let result = try s.undo()
        XCTAssertEqual(result, .restored(label: "Close Tab", movedTabs: [bank.id]))
        XCTAssertEqual(s.tab(bank.id)?.profileID, work.id)
        XCTAssertEqual(s.tab(bank.id)?.spaceID, b.id)
        XCTAssertEqual(s.todayTabs(ofSpace: b.id).first?.id, bank.id)
        XCTAssertTrue(s.archivedEntries.isEmpty)
        assertProfilesConsistent(s)
    }

    func testRefusedWhenNoSpaceUsesTheProfileAnyMore() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "Work", profileID: work.id)
        let bank = try s.openTab(url: "https://bank.example/", inSpace: a.id)
        try s.closeTab(bank.id)
        try s.setProfile(ofSpace: a.id, to: s.defaultProfile.id)
        guard case .refused(let label, let reason)? = try s.undo() else { return XCTFail("restored into Personal") }
        XCTAssertEqual(label, "Close Tab")
        XCTAssertTrue(reason.contains("Work"), reason)
        XCTAssertNil(s.tab(bank.id))
        XCTAssertEqual(s.archivedEntries.map(\.url), ["https://bank.example/"], "the closed tab stays in the Archive")
        XCTAssertFalse(s.canUndo)
        assertProfilesConsistent(s)
    }

    func testPinnedTabIsNotReloadedInTheNewProfile() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "Work", profileID: work.id)
        let t = try s.openTab(url: "https://mail.example/", inSpace: a.id)
        try s.move(.tab(t.id), to: .pinned(spaceID: a.id, parentID: nil, index: 0))
        try s.closeTab(t.id)
        try s.setProfile(ofSpace: a.id, to: s.defaultProfile.id)
        guard case .refused? = try s.undo() else { return XCTFail("pinned page came back in Personal") }
        XCTAssertNil(s.tab(t.id))
        XCTAssertEqual(s.pinnedRoots(ofSpace: a.id).count, 1, "the pinned row stays")
        assertProfilesConsistent(s)
    }

    func testDeletedSpaceWhoseProfileWasDeletedIsNotRestored() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "Work", profileID: work.id)
        _ = try s.openTab(url: "https://bank.example/", inSpace: a.id)
        try s.deleteSpace(a.id)
        try s.deleteProfile(work.id)
        guard case .refused(_, let reason)? = try s.undo() else { return XCTFail("Space restored on a missing profile") }
        XCTAssertTrue(reason.contains("deleted"), reason)
        XCTAssertNil(s.space(a.id))
        assertProfilesConsistent(s)
    }

    func testUnchangedProfileUndoesAsBefore() throws {
        let s = try makeStore()
        let sp = s.selectedSpace
        let t = try s.openTab(url: "https://a.example/", inSpace: sp.id)
        try s.closeTab(t.id)
        XCTAssertEqual(try s.undo(), .restored(label: "Close Tab", movedTabs: []))
        XCTAssertEqual(s.tab(t.id)?.spaceID, sp.id)
        assertProfilesConsistent(s)
    }

    func testDeleteFolderUndoKeepsRowsButNotOtherProfilesPages() throws {
        let s = try makeStore()
        let work = try s.createProfile(name: "Work")
        let a = try s.createSpace(name: "Work", profileID: work.id)
        let t = try s.openTab(url: "https://docs.example/", inSpace: a.id)
        let folder = try s.createFolder(named: "Docs", inSpace: a.id, containing: [.tab(t.id)])
        try s.deleteItem(folder.id)
        try s.setProfile(ofSpace: a.id, to: s.defaultProfile.id)
        XCTAssertEqual(try s.undo(), .restored(label: "Delete", movedTabs: []))
        XCTAssertNotNil(s.item(folder.id))
        XCTAssertEqual(s.allLinks(inFolder: folder.id), ["https://docs.example/"])
        XCTAssertNil(s.tab(t.id), "the Work page isn't restored into the Personal Space")
        assertProfilesConsistent(s)
    }
}
