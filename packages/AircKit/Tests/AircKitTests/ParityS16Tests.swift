// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import XCTest

/// S16 sidebar tab screenshots: Arc's per-row "Show Hover Preview" and the kept picture's age hint.
final class ParityS16Tests: XCTestCase {
    func testHoverPreviewIsOnUntilTurnedOffAndForgetsDeletedRows() throws {
        var p = SidebarItemPreferences()
        XCTAssertTrue(p.showsHoverPreview("docs"))
        p.setHoverPreview(false, for: "docs", existing: ["docs", "mail"])
        p.setHoverPreview(false, for: "mail", existing: ["docs", "mail"])
        XCTAssertFalse(p.showsHoverPreview("docs"))
        XCTAssertTrue(p.showsUnreadBadge("docs"), "the unread switch is separate")
        p.setHoverPreview(true, for: "mail", existing: ["mail"])
        XCTAssertEqual(p.noHoverPreview, [], "docs' row is gone, mail's back on")
        p.setHoverPreview(false, for: "docs", existing: ["docs"])
        let round = try JSONDecoder().decode(SidebarItemPreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
        let older = try JSONDecoder().decode(SidebarItemPreferences.self, from: Data(#"{"noUnreadBadge":["x"]}"#.utf8))
        XCTAssertEqual(older.noUnreadBadge, ["x"])
        XCTAssertEqual(older.noHoverPreview, [], "settings from before S16 load with every preview on")
    }

    func testStaleHint() {
        XCTAssertNil(TabPreviewStaleness.hint(age: 5, loaded: true), "a fresh picture of a loaded page says nothing")
        XCTAssertNil(TabPreviewStaleness.hint(age: 59.9, loaded: true))
        XCTAssertEqual(TabPreviewStaleness.hint(age: 60, loaded: true), "Pictured 1 min ago")
        XCTAssertEqual(TabPreviewStaleness.hint(age: 5, loaded: false), "Not loaded · pictured just now")
        XCTAssertEqual(TabPreviewStaleness.hint(age: 12 * 60 + 30, loaded: false), "Not loaded · pictured 12 min ago")
        XCTAssertEqual(TabPreviewStaleness.ago(3 * 3600 + 5), "3 hr ago")
        XCTAssertEqual(TabPreviewStaleness.ago(86400 * 1.5), "1 day ago")
        XCTAssertEqual(TabPreviewStaleness.ago(86400 * 3), "3 days ago")
        XCTAssertEqual(TabPreviewStaleness.ago(-4), "just now", "a clock step back never shows a negative age")
    }
}
