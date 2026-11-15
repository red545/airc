// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class UpdateDownloadRetryTests: XCTestCase {
    private func sparkle(_ code: Int, _ underlying: NSError? = nil) -> NSError {
        NSError(domain: "SUSparkleErrorDomain", code: code,
                userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }
    private func url(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }

    /// What Sparkle 2.10.1 reports for a stalled download: SPUDownloadDriver's 2001 around SPUDownloader's NSURLError
    /// (persistent downloads), or around another 2001 (temporary downloads).
    func testTimeoutsAndLostConnectionsRetry() {
        XCTAssertTrue(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorTimedOut))))
        XCTAssertTrue(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorNetworkConnectionLost))))
        XCTAssertTrue(UpdateDownloadRetry.isRetriable(sparkle(2001, sparkle(2001, url(NSURLErrorTimedOut)))))
        XCTAssertTrue(UpdateDownloadRetry.isRetriable(sparkle(2001, NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)))))
    }

    func testOtherErrorsNeverRetry() {
        // Signature (3001), extraction (3000), installation (4005), appcast (1002), no update (1001).
        for code in [3001, 3000, 4005, 1002, 1001] {
            XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(code, url(NSURLErrorTimedOut))), "\(code)")
        }
        // A download error without a cause, or caused by the disk, HTTP status or being offline.
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001)))
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))))
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorCannotWriteToFile))))
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorNotConnectedToInternet))))
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorBadServerResponse))))
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, url(NSURLErrorCancelled))))
        // A timeout that isn't Sparkle's download error.
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(url(NSURLErrorTimedOut)))
        // A timeout under a non-download layer (e.g. a file error wrapping one) doesn't count.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: [NSUnderlyingErrorKey: url(NSURLErrorTimedOut)])
        XCTAssertFalse(UpdateDownloadRetry.isRetriable(sparkle(2001, wrapped)))
    }

    func testRootCause() {
        XCTAssertEqual(UpdateDownloadRetry.rootCause(sparkle(2001, sparkle(2001, url(-1001)))).code, -1001)
        XCTAssertEqual(UpdateDownloadRetry.rootCause(sparkle(2001)).code, 2001)
    }

    func testOneRetryNeverARetryOfARetry() {
        let stall = sparkle(2001, url(NSURLErrorTimedOut))
        var gate = UpdateDownloadRetry.Gate()
        XCTAssertTrue(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertEqual(gate.state, .scheduled)
        XCTAssertTrue(gate.retryFiring(allowed: true))
        XCTAssertEqual(gate.state, .running)
        // The retry stalls too: no second retry; the error stands.
        XCTAssertFalse(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertEqual(gate.state, .idle)
        // A later, independent failure (the next scheduled check) gets its own single retry.
        XCTAssertTrue(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertTrue(gate.retryFiring(allowed: true))
        XCTAssertFalse(gate.cycleEnded(error: nil, allowed: true))
        XCTAssertEqual(gate.state, .idle)
    }

    func testCyclesWhileScheduledDontAddRetries() {
        let stall = sparkle(2001, url(NSURLErrorNetworkConnectionLost))
        var gate = UpdateDownloadRetry.Gate()
        XCTAssertTrue(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertFalse(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertTrue(gate.retryFiring(allowed: true))
        XCTAssertFalse(gate.retryFiring(allowed: true))
        XCTAssertFalse(gate.cycleEnded(error: stall, allowed: true))
    }

    func testAutomaticUpdatesOffMeansNoRetry() {
        let stall = sparkle(2001, url(NSURLErrorTimedOut))
        var gate = UpdateDownloadRetry.Gate()
        XCTAssertFalse(gate.cycleEnded(error: stall, allowed: false))
        XCTAssertEqual(gate.state, .idle)
        // Turned off during the delay: the retry doesn't start.
        XCTAssertTrue(gate.cycleEnded(error: stall, allowed: true))
        XCTAssertFalse(gate.retryFiring(allowed: false))
        XCTAssertEqual(gate.state, .idle)
    }

    func testRetryThatCannotStartResets() {
        var gate = UpdateDownloadRetry.Gate()
        XCTAssertTrue(gate.cycleEnded(error: sparkle(2001, url(NSURLErrorTimedOut)), allowed: true))
        XCTAssertTrue(gate.retryFiring(allowed: true))
        gate.retryNotStarted()
        XCTAssertEqual(gate.state, .idle)
        XCTAssertFalse(gate.cycleEnded(error: nil, allowed: true))
    }

    func testSuccessAndNoErrorNeverRetry() {
        var gate = UpdateDownloadRetry.Gate()
        XCTAssertFalse(gate.cycleEnded(error: nil, allowed: true))
        XCTAssertFalse(gate.cycleEnded(error: sparkle(1001), allowed: true))
        XCTAssertEqual(gate.state, .idle)
    }
}
