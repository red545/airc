// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

/// Wall-clock budgets (milliseconds per keystroke and the like) hold only on a quiet Mac. The plain suite also runs
/// inside app builds and under `swift test --parallel` (one test process per core), where the keystroke budget
/// measured 2.025 ms against 2.0 ms every time. So timed tests skip, with the reason in the log, except in the
/// dedicated timing run:
///
///     AIRC_TIMING_RUN=1 swift test --package-path packages/AircKit --filter HistoryPerfTests
///
/// on the build Mac, serially, under the agents' timing-run declaration (status/timing-run), with nothing else
/// building or checking. Keep the functional half of a timed test in a test of its own, so every run still checks it.
enum TimingBudget {
    static let environmentKey = "AIRC_TIMING_RUN"

    static var enforced: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }

    /// Skips the calling test's budget assertions outside the timing run, with the reason in the test log.
    static func requireTimingRun(_ what: String) throws {
        try XCTSkipUnless(enforced, "\(what): wall-clock budget, asserted only with \(environmentKey)=1 in the dedicated "
                          + "serial timing run (shared-Mac load and --parallel workers make absolute ms bounds flaky)")
    }
}
