// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// WIN-7's blank window (⌃⌘N): a Space of its own, never listed with the others, kept across a relaunch, gone (its
/// Today tabs archived) when its window closes.
final class BlankWindowTests: XCTestCase {
    func testBlankWindowSpaceIsUnlistedAndNeverSelected() throws {
        let s = try makeStore()
        let work = try s.createSpace(name: "Work", theme: .single("7EB6D5"))
        s.selectSpace(work.id)
        let blank = try s.createBlankWindowSpace(from: work.id)
        XCTAssertTrue(blank.isBlankWindow)
        XCTAssertEqual(blank.profileID, work.profileID)
        XCTAssertEqual(blank.theme, work.theme)
        XCTAssertFalse(s.orderedSpaces.contains { $0.id == blank.id }, "not in the Space bar")
        XCTAssertEqual(s.blankWindowSpaces.map(\.id), [blank.id])
        s.selectSpace(blank.id)
        XCTAssertEqual(s.selectedSpace.id, work.id, "the selection stays on a listed Space")
        // Its Today tabs are its own.
        let t = try s.openTab(url: "https://example.com", inSpace: blank.id)
        XCTAssertEqual(s.todayTabs(ofSpace: blank.id).map(\.id), [t.id])
        XCTAssertTrue(s.todayTabs(ofSpace: work.id).isEmpty)
    }

    func testClosingArchivesItsTabsAndRemovesTheSpace() throws {
        let s = try makeStore()
        let blank = try s.createBlankWindowSpace()
        let t = try s.openTab(url: "https://example.com/a", inSpace: blank.id)
        try s.closeBlankWindowSpace(blank.id)
        XCTAssertNil(s.space(blank.id))
        XCTAssertNil(s.tab(t.id))
        XCTAssertTrue(s.state.archive.values.contains { $0.tab.id == t.id }, "its tab is in the Archive")
        XCTAssertThrowsError(try s.closeBlankWindowSpace(s.orderedSpaces[0].id), "only a blank window's Space")
    }

    func testTheLastListedSpaceStaysWithABlankWindowOpen() throws {
        let s = try makeStore()
        let only = s.orderedSpaces[0]
        _ = try s.createBlankWindowSpace()
        XCTAssertThrowsError(try s.deleteSpace(only.id)) { XCTAssertEqual($0 as? StoreError, .cannotDeleteLastSpace) }
    }

    func testBlankWindowSpacePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-blank-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var blankID = "", tabID = ""
        do {
            let s = try SpacesStore(path: path)
            blankID = try s.createBlankWindowSpace().id
            tabID = try s.openTab(url: "https://example.com", inSpace: blankID).id
            try s.flush()
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.space(blankID)?.isBlankWindow, true)
        XCTAssertEqual(s.orderedSpaces.count, 1)
        XCTAssertEqual(s.tab(tabID)?.spaceID, blankID)
    }
}
