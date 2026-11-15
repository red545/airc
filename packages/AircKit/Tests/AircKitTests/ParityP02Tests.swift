// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// P02: the Space header's fold rules (Arc ref §2.4): only a named Space folds its pinned section; the chevron turns a
/// quarter turn; the fold is kept per Space.
final class ParityP02Tests: XCTestCase {
    func testOnlyNamedSpacesFold() {
        XCTAssertTrue(SpaceHeaderPolicy.canFold(name: "Home"))
        XCTAssertFalse(SpaceHeaderPolicy.canFold(name: ""))
        XCTAssertFalse(SpaceHeaderPolicy.canFold(name: "  \n"))
    }

    func testChevronTurnsAQuarterTurnTowardsTheEnd() {
        XCTAssertEqual(SpaceHeaderPolicy.chevronAngle(collapsed: false, flipped: false), 0)
        XCTAssertEqual(SpaceHeaderPolicy.chevronAngle(collapsed: false, flipped: true), 0)
        // Down turned counter-clockwise a quarter (y up) points right; with y down the same look is clockwise.
        XCTAssertEqual(SpaceHeaderPolicy.chevronAngle(collapsed: true, flipped: false), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(SpaceHeaderPolicy.chevronAngle(collapsed: true, flipped: true), -.pi / 2, accuracy: 1e-9)
    }

    func testStoreFoldRulesPerSpace() throws {
        let s = try makeStore()
        let home = s.selectedSpace.id
        try s.updateSpace(home) { $0.name = "Home" }
        let work = try s.createSpace(name: "Work")
        try s.updateSpace(work.id) { $0.name = "" }
        XCTAssertTrue(s.canFoldPinned(ofSpace: home))
        XCTAssertFalse(s.canFoldPinned(ofSpace: work.id), "unnamed")
        XCTAssertFalse(s.canFoldPinned(ofSpace: "missing"))
        try s.updateSpace(home) { $0.pinnedCollapsed = true }
        XCTAssertEqual(s.space(home)?.pinnedCollapsed, true)
        XCTAssertEqual(s.space(work.id)?.pinnedCollapsed, false, "kept per Space")
        // An unnamed Space's row still shows with two Spaces, and a folded one keeps its row even alone.
        XCTAssertTrue(s.showsHeader(ofSpace: work.id, showOnSingleUnnamed: false))
    }

    func testFoldSurvivesAReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p02-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var home = ""
        do {
            let s = try SpacesStore(path: path)
            home = s.selectedSpace.id
            try s.updateSpace(home) { $0.name = "Home"; $0.pinnedCollapsed = true }
            try s.flush()
        }
        let again = try SpacesStore(path: path)
        XCTAssertEqual(again.space(home)?.pinnedCollapsed, true)
    }
}
