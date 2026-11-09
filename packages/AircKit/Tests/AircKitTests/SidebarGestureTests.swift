// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class SidebarGestureTests: XCTestCase {
    private let ready = SidebarRevealGate.Conditions(windowIsKey: true, sidebarHidden: true, alreadyRevealed: false,
                                                     pointerInStrip: true, sheetOrModal: false, menuOpen: false,
                                                     mouseButtonDown: false)

    /// SB-61: the dwell reveals only if everything that started it still holds.
    func testRevealGateRechecksEveryCondition() {
        XCTAssertNil(SidebarRevealGate.refusal(ready))
        var c = ready; c.windowIsKey = false
        XCTAssertEqual(SidebarRevealGate.refusal(c), .notKey)
        c = ready; c.sidebarHidden = false
        XCTAssertEqual(SidebarRevealGate.refusal(c), .notHidden)
        c = ready; c.alreadyRevealed = true
        XCTAssertEqual(SidebarRevealGate.refusal(c), .revealed)
        c = ready; c.pointerInStrip = false
        XCTAssertEqual(SidebarRevealGate.refusal(c), .pointerLeft)
        c = ready; c.sheetOrModal = true
        XCTAssertEqual(SidebarRevealGate.refusal(c), .sheet)
        c = ready; c.menuOpen = true
        XCTAssertEqual(SidebarRevealGate.refusal(c), .menu)
        c = ready; c.mouseButtonDown = true
        XCTAssertEqual(SidebarRevealGate.refusal(c), .drag)
    }

    /// WIN-4: hides once the drag goes below the minimum, not 40 pt later.
    func testResizeHidesJustPastTheMinimum() {
        XCTAssertFalse(SidebarResize.hides(proposedWidth: 164, minWidth: 164))
        XCTAssertFalse(SidebarResize.hides(proposedWidth: 300, minWidth: 164))
        XCTAssertTrue(SidebarResize.hides(proposedWidth: 163.5, minWidth: 164))
        XCTAssertTrue(SidebarResize.hides(proposedWidth: 124, minWidth: 164))
    }

    /// SP-21 / SP-25: 22.7 pt of pull on screen readies either end.
    func testOverscrollDetentIsArcsMeasuredPull() {
        XCTAssertEqual(SwipeOverscroll.detent, 22.7)
        XCTAssertNil(SwipeOverscroll.pull(position: 1.5, pageCount: 3, pageWidth: 228))
        let travel = SwipeOverscroll.fingerTravel(forPull: SwipeOverscroll.detent, pageWidth: 228)
        // At the default width that's about 51.5 pt of finger travel (the old 0.32-page detent was 73).
        XCTAssertEqual(travel, 51.5, accuracy: 0.2)
        let atLast = SwipeOverscroll.pull(position: 2 + travel / 228, pageCount: 3, pageWidth: 228)
        XCTAssertEqual(atLast?.end, .last)
        XCTAssertEqual(atLast?.points ?? 0, 22.7, accuracy: 1e-6)
        let atFirst = SwipeOverscroll.pull(position: -travel / 228, pageCount: 3, pageWidth: 228)
        XCTAssertEqual(atFirst?.end, .first)
        XCTAssertEqual(atFirst?.points ?? 0, 22.7, accuracy: 1e-6)
        // The rubber band stays under half a page however far the finger goes.
        XCTAssertLessThan(SwipeOverscroll.pull(position: 10, pageCount: 3, pageWidth: 228)?.points ?? 0, 114)
    }

    func testOverscrollReadinessHasHysteresis() {
        XCTAssertFalse(SwipeOverscroll.isReady(points: 22.6, wasReady: false))
        XCTAssertTrue(SwipeOverscroll.isReady(points: 22.7, wasReady: false))
        XCTAssertTrue(SwipeOverscroll.isReady(points: 20.5, wasReady: true))
        XCTAssertFalse(SwipeOverscroll.isReady(points: 19.6, wasReady: true))
        XCTAssertFalse(SwipeOverscroll.isReady(points: 0, wasReady: true))
    }
}
