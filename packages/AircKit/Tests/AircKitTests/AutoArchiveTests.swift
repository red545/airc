// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// SB-43: the app closes each due tab's page before archiving it, so a tab is archived only if it's still due by then,
/// or when its page has closed for auto-archiving.
final class AutoArchiveTests: XCTestCase {
    func testOnlyTabsStillDueAreArchivedUnlessTheirPageClosed() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        let a = try s.openTab(url: "https://a.test", inSpace: sp)
        clock.advance(60)
        let b = try s.openTab(url: "https://b.test", inSpace: sp)
        XCTAssertEqual(s.dueForAutoArchive(), [])
        clock.advance(13 * 3600)
        // Longest idle first; protected tabs left out.
        XCTAssertEqual(s.dueForAutoArchive(), [a.id, b.id])
        XCTAssertEqual(s.dueForAutoArchive(protected: [a.id]), [b.id])
        // b was viewed again while a's page was closing: only a goes.
        try s.activate(b.id, inSpace: sp)
        XCTAssertEqual(try s.autoArchive([a.id, b.id]), [a.id])
        XCTAssertNotNil(s.tab(b.id))
        // A page that has closed for auto-archiving goes whatever happened since.
        XCTAssertEqual(try s.autoArchive([b.id], pageClosed: true), [b.id])
        XCTAssertEqual(s.state.archive.values.filter { $0.reason == .auto }.count, 2)
        XCTAssertFalse(s.canUndo)
    }
}
