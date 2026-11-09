// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P03b (K06): Arc's Cycle Tab Forward / Backward (⌃⌘→ ⌃⌘←) over a Space's tabs in the order they were last used.
final class ParityP03bTests: XCTestCase {
    /// Four tabs used A, B, C, D in turn (D last).
    private func fourTabs() throws -> (SpacesStore, TestClock, sp: String, a: String, b: String, c: String, d: String) {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        var ids: [String] = []
        for name in ["a", "b", "c", "d"] {
            clock.advance(10)
            let t = try s.openTab(url: "https://\(name).example", inSpace: sp)
            try s.activate(t.id, inSpace: sp)
            ids.append(t.id)
        }
        return (s, clock, sp, ids[0], ids[1], ids[2], ids[3])
    }

    /// What the app does per press (Sidebar/SidebarKeyboard.swift): go on with the cycle while its tab is on screen,
    /// else start one; show the stop; give the tabs passed their last use back.
    private func press(_ offset: Int, _ s: SpacesStore, _ clock: TestClock, space sp: String, shown: inout String?,
                       cycle: inout TabCycle?) throws -> String? {
        let recent = s.recentTabs(inSpace: sp)
        if cycle?.continues(inSpace: sp, shown: shown) != true {
            cycle = TabCycle(spaceID: sp, recent: recent, current: shown, lastUse: s.lastUse(of: recent))
        }
        guard var c = cycle, let id = c.step(offset, open: Set(recent)) else { cycle = nil; return nil }
        cycle = c
        clock.advance(1)
        try s.activate(id, inSpace: sp)
        try s.restoreLastUse(c.lastUse, except: id)
        shown = id
        return id
    }

    func testCycleGoesThroughEveryTabInRecentOrderAndWraps() throws {
        let (s, clock, sp, a, b, c, d) = try fourTabs()
        XCTAssertEqual(s.recentTabs(inSpace: sp), [d, c, b, a])
        var shown: String? = d
        var cycle: TabCycle?
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), c, "Forward: the tab used before")
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), b, "and on, past ⌃Tab's two")
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), a)
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), d, "wraps")
        XCTAssertEqual(try press(-1, s, clock, space: sp, shown: &shown, cycle: &cycle), a, "Backward: the other way")
        XCTAssertEqual(try press(-1, s, clock, space: sp, shown: &shown, cycle: &cycle), b)
        // Only the stop counts as used: B is first, the rest keep their order.
        XCTAssertEqual(s.recentTabs(inSpace: sp), [b, d, c, a])
    }

    func testCycleIsNotLimitedToFiveTabs() throws {
        let order = (0..<9).map { "t\($0)" }
        var c = try XCTUnwrap(TabCycle(spaceID: "s", recent: order, current: "t0"))
        XCTAssertEqual(c.order.count, 9, "every tab, unlike ⌃Tab's walk")
        for i in 1..<9 { XCTAssertEqual(c.step(1, open: Set(order)), "t\(i)") }
        XCTAssertEqual(c.step(1, open: Set(order)), "t0")
        XCTAssertNil(TabCycle(spaceID: "s", recent: ["t0"], current: "t0"), "nothing to cycle to")
        var none = try XCTUnwrap(TabCycle(spaceID: "s", recent: ["x", "y", "z"], current: nil))
        XCTAssertEqual(none.step(-1, open: ["x", "y", "z"]), "z", "nothing on screen: Backward starts at the oldest")
    }

    func testOpeningATabStartsTheNextCycleWithIt() throws {
        let (s, clock, sp, _, b, c, d) = try fourTabs()
        var shown: String? = d
        var cycle: TabCycle?
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), c)
        // A new tab shows: it's the most recent, and the cycle doesn't go on from C.
        clock.advance(10)
        let e = try s.openTab(url: "https://e.example", inSpace: sp)
        try s.activate(e.id, inSpace: sp)
        shown = e.id
        XCTAssertEqual(s.recentTabs(inSpace: sp).prefix(3), [e.id, c, d])
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), c, "the new order: E, C, D …")
        XCTAssertEqual(cycle?.order.first, e.id)
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), d)
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), b)
    }

    func testAClosedTabDropsOutOfTheCycle() throws {
        let (s, clock, sp, a, b, c, d) = try fourTabs()
        var shown: String? = d
        var cycle: TabCycle?
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), c)
        try s.closeTab(b)
        XCTAssertFalse(s.recentTabs(inSpace: sp).contains(b))
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), a, "B is gone: C, then A")
        XCTAssertEqual(cycle?.order, [d, c, a])
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), d)
        // Down to one tab: nothing to cycle to.
        try s.closeTab(a)
        try s.closeTab(c)
        XCTAssertNil(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle))
    }

    func testEachSpaceCyclesItsOwnTabs() throws {
        let (s, clock, sp, _, _, c, d) = try fourTabs()
        let other = try s.createSpace(name: "Other", profileID: s.defaultProfile.id, after: sp)
        var otherTabs: [String] = []
        for name in ["x", "y"] {
            clock.advance(10)
            let t = try s.openTab(url: "https://\(name).example", inSpace: other.id)
            try s.activate(t.id, inSpace: other.id)
            otherTabs.append(t.id)
        }
        var shown: String? = d
        var cycle: TabCycle?
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), c)
        // The Space switch shows Y there: the next press is a new cycle over that Space's tabs only.
        s.selectSpace(other.id)
        shown = otherTabs[1]
        XCTAssertFalse(cycle?.continues(inSpace: other.id, shown: shown) ?? true)
        XCTAssertEqual(try press(1, s, clock, space: other.id, shown: &shown, cycle: &cycle), otherTabs[0])
        XCTAssertEqual(try press(1, s, clock, space: other.id, shown: &shown, cycle: &cycle), otherTabs[1], "two tabs: wraps")
        XCTAssertEqual(Set(cycle?.order ?? []), Set(otherTabs))
        // Back in the first Space its order is as it was left (C used last), untouched by the other Space's cycle.
        s.selectSpace(sp)
        shown = c
        XCTAssertEqual(s.recentTabs(inSpace: sp).prefix(2), [c, d])
        XCTAssertEqual(try press(1, s, clock, space: sp, shown: &shown, cycle: &cycle), d)
    }

    func testPrivatePagesNeverEnterTheOrder() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let uses = [
            TabMRU.Use(id: "a", lastUse: t0),
            TabMRU.Use(id: "private-1", lastUse: t0.addingTimeInterval(30), isPrivate: true),
            TabMRU.Use(id: "b", lastUse: t0.addingTimeInterval(10)),
            TabMRU.Use(id: "private-2", lastUse: t0.addingTimeInterval(40), isPrivate: true),
            TabMRU.Use(id: "c", lastUse: t0.addingTimeInterval(10)),
        ]
        XCTAssertEqual(TabMRU.order(uses), ["c", "b", "a"], "private pages left out; equal times by ID")
        var cycle = try XCTUnwrap(TabCycle(spaceID: "s", recent: TabMRU.order(uses), current: "c"))
        var seen: [String] = []
        for _ in 0..<4 { seen.append(try XCTUnwrap(cycle.step(1, open: ["a", "b", "c"]))) }
        XCTAssertFalse(seen.contains { $0.hasPrefix("private") })
        // The store never holds a private window's pages (PrivateWindow.swift): its order is the Space's tabs only.
        let (s, _, sp, a, b, c, d) = try fourTabs()
        XCTAssertEqual(Set(s.recentTabs(inSpace: sp)), Set([a, b, c, d]))
    }
}
