// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit
final class ProfileSignInPollingTests: XCTestCase {
    func testBackoffBoundAndExplicitRestart() {
        var p = ProfileSignInPolling(); let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(p.due(["a"], now: t), ["a"])
        XCTAssertEqual(p.due(["a"], now: t), []) // second window
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(5)), ["a"])
        XCTAssertEqual(p.next(["a"], now: t), t.addingTimeInterval(20))
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(20)), ["a"])
        XCTAssertEqual(p.next(["a"], now: t), t.addingTimeInterval(80))
        XCTAssertNil(p.next([], now: t)) // closed or dismissed, including relaunch
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(301)), [])
        XCTAssertNil(p.next(["a"], now: t.addingTimeInterval(301)))
        p.restart("a")
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(301)), ["a"])
    }
    func testRedirectProbeRunsOnceWithoutExtendingDeadline() {
        var p = ProfileSignInPolling(); let t = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(p.requestFinalProbe("a", now: t)) // no sign-in started
        XCTAssertEqual(p.due(["a"], now: t), ["a"])
        XCTAssertTrue(p.requestFinalProbe("a", now: t.addingTimeInterval(1)))
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(1)), ["a"])
        XCTAssertFalse(p.requestFinalProbe("a", now: t.addingTimeInterval(2)))
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(2)), [])
        XCTAssertTrue(p.isActive("a", now: t.addingTimeInterval(299)))
        XCTAssertFalse(p.isActive("a", now: t.addingTimeInterval(300)))
        XCTAssertEqual(p.due(["a"], now: t.addingTimeInterval(300)), [])
        p.restart("a")
        _ = p.due(["a"], now: t.addingTimeInterval(301))
        XCTAssertTrue(p.requestFinalProbe("a", now: t.addingTimeInterval(302)))
    }

}
