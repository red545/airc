// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// SP-31: "Open Link in Space ›" rows (Browser/PageContextMenu.swift, both engines' link menus).
final class LinkSpaceMenuTests: XCTestCase {
    private func space(_ name: String, _ icon: SpaceIcon? = nil, profile: String = "p1", blank: Bool = false) -> Space {
        var s = Space(id: "id-" + name, name: name, icon: icon, profileID: profile)
        if blank { s.blankWindow = true }
        return s
    }

    func testEverySpaceInOrderWithItsEmojiAcrossProfiles() {
        let work = space("Work", .emoji("💼")), home = space("Home", .emoji("🏠"), profile: "p2"), plain = space("Plain")
        let rows = LinkSpaceMenu.rows(spaces: [work, home, plain], current: work)
        XCTAssertEqual(rows.map { $0["id"] }, ["id-Work", "id-Home", "id-Plain"], "sidebar order, another profile's Space too")
        XCTAssertEqual(rows.map { $0["title"] }, ["💼 Work", "🏠 Home", "● Plain"])
    }

    func testABlankWindowListsOnlyItself() {
        let blank = space("Blank", blank: true), work = space("Work", .emoji("💼"))
        XCTAssertEqual(LinkSpaceMenu.rows(spaces: [work], current: blank).map { $0["id"] }, ["id-Blank"])
        XCTAssertEqual(LinkSpaceMenu.rows(spaces: [work, blank], current: work).map { $0["id"] }, ["id-Work"],
                       "another window's blank Space is never listed")
    }

    func testNoEmojiOrAnEmptyOneGetsADot() {
        XCTAssertEqual(LinkSpaceMenu.title(of: space("A", .emoji(""))), "● A")
        XCTAssertEqual(LinkSpaceMenu.title(of: space("B", .symbol("star"))), "● B")
    }

    func testAtMostTheEnginesLimit() {
        let many = (0..<130).map { space("S\($0)") }
        XCTAssertEqual(LinkSpaceMenu.rows(spaces: many, current: nil).count, LinkSpaceMenu.limit)
    }

    func testOnlyWebLinksOpenInASpace() {
        XCTAssertTrue(LinkSpaceMenu.opens(URL(string: "https://a.example/x")!))
        XCTAssertTrue(LinkSpaceMenu.opens(URL(string: "HTTP://a.example")!))
        for raw in ["mailto:a@b.example", "javascript:alert(1)", "file:///etc/hosts", "airc://settings"] {
            XCTAssertFalse(LinkSpaceMenu.opens(URL(string: raw)!), raw)
        }
    }
}
