// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class BlockingListUpdateTests: XCTestCase {
    func testNotModifiedRequiresActualCache() throws {
        XCTAssertThrowsError(try BlockingListUpdate.evaluate(.init(status: 304), current: nil, now: Date()))
        let body = Data("[Adblock Plus 2.0]\n! Version: 202611081049\n||ads.example^".utf8)
        let now = Date(timeIntervalSince1970: 1000)
        let version = BlockingListVersion(digest: "abc", converterVersion: 1,
            metadata: try .parse(body), etag: "\"one\"", checkedAt: now)
        guard case .unchanged(let update) = try BlockingListUpdate.evaluate(.init(status: 304, etag: "\"two\""), current: version,
                                                                         now: now.addingTimeInterval(100)) else { return XCTFail() }
        XCTAssertEqual(update.digest, version.digest)
        XCTAssertEqual(update.etag, "\"two\"")
        XCTAssertEqual(update.checkedAt, now.addingTimeInterval(100))
    }
    func testFailuresAndStaleCandidatesDoNotReplaceGoodVersion() throws {
        func body(_ version: String) -> Data { Data("[Adblock Plus 2.0]\n! Version: \(version)\n||ads.example^".utf8) }
        let old = BlockingListVersion(digest: "abc", converterVersion: 1,
                                     metadata: try .parse(body("202611081049")), checkedAt: Date())
        XCTAssertThrowsError(try BlockingListUpdate.evaluate(.init(status: 503), current: old, now: Date()))
        XCTAssertThrowsError(try BlockingListUpdate.evaluate(.init(status: 200, body: body("202611071049")), current: old, now: Date()))
        guard case .candidate = try BlockingListUpdate.evaluate(.init(status: 200, body: body("202611081049")), current: old, now: Date()) else { return XCTFail() }
        XCTAssertEqual(old.digest, "abc")
        XCTAssertEqual(BlockingListUpdate.retryDelay(failures: 1), 3600)
        XCTAssertEqual(BlockingListUpdate.retryDelay(failures: Int.max), 86400)
    }
}
