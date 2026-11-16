// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// MEM-6 (idletimers): the live-folder timer is armed for the next due folder, not a fixed 30 s tick.
final class LiveFolderScheduleTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func folder() -> LiveFolderDefinition {
        LiveFolderDefinition(folderID: "f", query: GitHubPullQuery(repository: "a/b"), createdAt: t0)
    }

    func testNeverRefreshedIsDueNow() {
        let d = folder()
        XCTAssertEqual(LiveFolderSchedule.nextTimerRefresh(d, now: t0), t0)
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .timer, now: t0))
    }

    func testNextRefreshIsTheFirstDueMoment() {
        var d = folder()
        d.lastAttempt = t0
        let at = try! XCTUnwrap(LiveFolderSchedule.nextTimerRefresh(d, now: t0.addingTimeInterval(5)))
        XCTAssertEqual(at, t0.addingTimeInterval(LiveFolderSchedule.interval - 1))
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .timer, now: at))
        XCTAssertFalse(LiveFolderSchedule.isDue(d, trigger: .timer, now: at.addingTimeInterval(-1)))
        // Overdue (the Mac slept): now, not in the past.
        let late = t0.addingTimeInterval(3600)
        XCTAssertEqual(LiveFolderSchedule.nextTimerRefresh(d, now: late), late)
    }

    func testBackoffAndRateLimitWaitForNextAllowed() {
        var d = folder()
        d.lastAttempt = t0
        d.status = .offline
        d.nextAllowed = t0.addingTimeInterval(1800)
        let at = try! XCTUnwrap(LiveFolderSchedule.nextTimerRefresh(d, now: t0))
        XCTAssertEqual(at, d.nextAllowed)
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .timer, now: at))
        d.status = .rateLimited(until: t0.addingTimeInterval(1800))
        XCTAssertTrue(LiveFolderSchedule.isDue(d, trigger: .timer, now: try! XCTUnwrap(LiveFolderSchedule.nextTimerRefresh(d, now: t0))))
    }

    func testSignedOutArmsNothing() {
        var d = folder()
        d.status = .signedOut
        XCTAssertNil(LiveFolderSchedule.nextTimerRefresh(d, now: t0))
    }
}
