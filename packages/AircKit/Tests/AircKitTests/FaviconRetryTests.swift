// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class FaviconRetryTests: XCTestCase {
    private let icon = FaviconBackoff.Key(url: "https://example.com/favicon.ico", profile: "p1")

    func testTheLadderClimbsAndStopsAtADay() {
        var b = FaviconBackoff()
        var now = Date(timeIntervalSince1970: 1_000_000)
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            b.failed(icon, .transient, now: now)
            let due = b.record(icon)!.due
            waits.append(due.timeIntervalSince(now))
            XCTAssertFalse(b.mayStart(icon, trigger: .shown, now: due.addingTimeInterval(-1)), "not before it's due")
            XCTAssertTrue(b.mayStart(icon, trigger: .shown, now: due), "a trigger once it's due starts a round")
            now = due
        }
        XCTAssertEqual(waits, [60, 300, 1800, 86_400, 86_400, 86_400])
    }

    func testAMissingIconStartsOneStepUp() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        b.failed(icon, .missing, now: now)
        XCTAssertEqual(b.record(icon)!.due.timeIntervalSince(now), 300)
        b.failed(icon, .missing, now: now)
        XCTAssertEqual(b.record(icon)!.due.timeIntervalSince(now), 1800)
    }

    func testAFailureIsNeverFinal() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<50 { b.failed(icon, .missing, now: now) }
        XCTAssertTrue(b.mayStart(icon, trigger: .shown, now: now.addingTimeInterval(86_400)), "a day later it's asked again")
    }

    func testFailuresArePerProfile() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        b.failed(icon, .transient, now: now)
        let other = FaviconBackoff.Key(url: icon.url, profile: "p2")
        XCTAssertFalse(b.mayStart(icon, trigger: .shown, now: now))
        XCTAssertTrue(b.mayStart(other, trigger: .shown, now: now), "another profile's rows aren't held by this one's failure")
        XCTAssertEqual(FaviconBackoff.Key(url: icon.url, profile: nil).profile, "")
    }

    func testAPageLoadAsksATransientFailureAgainAtMostOncePerFloor() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        b.failed(icon, .transient, now: now)
        XCTAssertFalse(b.mayStart(icon, trigger: .pageLoaded, now: now.addingTimeInterval(10)), "a configure storm isn't a page load")
        XCTAssertTrue(b.mayStart(icon, trigger: .pageLoaded, now: now.addingTimeInterval(30)))
        XCTAssertFalse(b.mayStart(icon, trigger: .shown, now: now.addingTimeInterval(30)), "the row coming on screen still waits")

        b.failed(icon, .missing, now: now)
        XCTAssertFalse(b.mayStart(icon, trigger: .pageLoaded, now: now.addingTimeInterval(120)), "a missing icon waits out its backoff")
    }

    func testTheNetworkComingBackForgetsTransientFailuresOnly() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let missing = FaviconBackoff.Key(url: "https://example.org/favicon.ico", profile: "p1")
        let offline = FaviconBackoff.Key(url: "https://example.net/favicon.ico", profile: "p1")
        b.failed(icon, .transient, now: now)
        b.failed(missing, .missing, now: now)
        b.failed(offline, .missing, online: false, now: now)
        XCTAssertTrue(b.mayStart(icon, trigger: .networkRestored, now: now))
        XCTAssertFalse(b.mayStart(missing, trigger: .networkRestored, now: now))
        b.networkRestored()
        XCTAssertNil(b.record(icon))
        XCTAssertNil(b.record(offline), "a failure made offline says nothing about the icon")
        XCTAssertNotNil(b.record(missing))
        XCTAssertTrue(b.mayStart(icon, trigger: .shown, now: now))
    }

    func testOfflineFailuresDontClimbTheLadder() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<5 { b.failed(icon, .transient, online: false, now: now) }
        XCTAssertEqual(b.record(icon)?.rounds, 0)
        XCTAssertEqual(b.record(icon)!.due.timeIntervalSince(now), 60)
        b.failed(icon, .transient, now: now)
        XCTAssertEqual(b.record(icon)!.due.timeIntervalSince(now), 60, "the first failure online is the first step")
    }

    func testSuccessForgetsAndOldRecordsExpire() {
        var b = FaviconBackoff()
        let now = Date(timeIntervalSince1970: 1_000_000)
        b.failed(icon, .transient, now: now)
        b.failed(icon, .transient, now: now)
        b.succeeded(icon)
        XCTAssertNil(b.record(icon))
        b.failed(icon, .transient, now: now)
        XCTAssertEqual(b.record(icon)?.rounds, 1, "the ladder starts over after a success")
        let longAfter = now.addingTimeInterval(60 + 2 * 86_400)
        XCTAssertTrue(b.mayStart(icon, trigger: .shown, now: longAfter))
        XCTAssertNil(b.record(icon), "asked about long after it was due, the record is dropped")
    }

    func testTheRecordsAreBounded() {
        let p = FaviconBackoff.Policy.standard
        var b = FaviconBackoff(policy: .init(ladder: p.ladder, roundRetries: p.roundRetries, pageLoadFloor: p.pageLoadFloor,
                                             forgetAfter: p.forgetAfter, limit: 16))
        let now = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<1000 {
            b.failed(.init(url: "https://site\(i).example/favicon.ico", profile: nil), .transient, now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertLessThanOrEqual(b.count, 16)
        XCTAssertNotNil(b.record(.init(url: "https://site999.example/favicon.ico", profile: nil)), "the newest stay")
        XCTAssertNil(b.record(.init(url: "https://site0.example/favicon.ico", profile: nil)), "the oldest go")
    }

    func testRoundRetriesAreShortAndBounded() {
        let p = FaviconBackoff.Policy.standard
        XCTAssertEqual((1...4).map { p.roundRetry(afterAttempts: $0, .transient) }, [4, 16, 40, nil])
        XCTAssertNil(p.roundRetry(afterAttempts: 1, .missing))
    }

    func testHowAFetchWent() {
        XCTAssertNil(FaviconBackoff.failure(status: 200, bytes: 400, decoded: true))
        XCTAssertEqual(FaviconBackoff.failure(status: nil, bytes: 0, decoded: false), .transient, "no answer")
        XCTAssertEqual(FaviconBackoff.failure(status: 200, bytes: 0, decoded: false), .transient, "an empty answer")
        XCTAssertEqual(FaviconBackoff.failure(status: 200, bytes: 12, decoded: false), .missing, "not an image")
        for s in [408, 425, 429, 500, 503] { XCTAssertEqual(FaviconBackoff.failure(status: s, bytes: 5, decoded: false), .transient, "\(s)") }
        for s in [401, 403, 404, 410] { XCTAssertEqual(FaviconBackoff.failure(status: s, bytes: 5, decoded: false), .missing, "\(s)") }
        XCTAssertEqual(FaviconBackoff.failure(status: 404, bytes: 5, decoded: true), .missing, "an image on an error page isn't the icon")
    }

    func testTheGateRunsAtMostItsLimitEachKeyOnce() {
        var g = FetchGate<Int>(limit: 3)
        XCTAssertEqual((0..<5).map { g.request($0) }, [.start, .start, .start, .queued, .queued])
        XCTAssertEqual(g.request(1), .duplicate, "running")
        XCTAssertEqual(g.request(4), .duplicate, "waiting")
        XCTAssertEqual(g.waiting, 2)
        XCTAssertEqual(g.finish(0), 3, "the first to wait goes next")
        XCTAssertEqual(g.running, [1, 2, 3])
        XCTAssertEqual(g.finish(4), nil, "a waiting job dropped frees nothing")
        XCTAssertEqual(g.waiting, 0)
        XCTAssertNil(g.finish(1))
        XCTAssertNil(g.finish(9), "an unknown key changes nothing")
        XCTAssertEqual(g.running, [2, 3])
        XCTAssertEqual(g.peak, 3)
        g.removeAll()
        XCTAssertEqual(g.request(7), .start)
    }
}
