// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class ExpiringLRUTests: XCTestCase {
    func testEntriesExpire() {
        var lru = ExpiringLRU<String, Int>(limit: 10)
        let now = Date()
        lru.set(1, for: "a", expires: now.addingTimeInterval(10), now: now)
        lru.set(2, for: "b", expires: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(lru.value(for: "a", now: now), 1)
        XCTAssertNil(lru.value(for: "b", now: now), "expired")
        XCTAssertEqual(lru.count, 1, "an expired entry asked for is dropped")
        lru.set(3, for: "c", expires: now.addingTimeInterval(5), now: now)
        lru.prune(now: now.addingTimeInterval(6))
        XCTAssertEqual(lru.count, 1)
        XCTAssertNil(lru.peek("c"))
    }

    func testTheLeastRecentlyUsedGoFirst() {
        var lru = ExpiringLRU<Int, Int>(limit: 8)
        let now = Date(), later = now.addingTimeInterval(3600)
        for i in 0..<8 { lru.set(i, for: i, expires: later, now: now) }
        _ = lru.value(for: 0, now: now)   // 0 is used again: 1 is now the oldest
        lru.set(8, for: 8, expires: later, now: now)
        XCTAssertEqual(lru.count, 7, "down to seven eighths of the limit")
        XCTAssertNotNil(lru.peek(0))
        XCTAssertNil(lru.peek(1))
        XCTAssertNil(lru.peek(2))
        XCTAssertNotNil(lru.peek(8))
        for i in 100..<10_000 { lru.set(i, for: i, expires: later, now: now) }
        XCTAssertLessThanOrEqual(lru.count, 8, "never past its limit")
    }

    func testExpiredEntriesGoBeforeLiveOnes() {
        var lru = ExpiringLRU<Int, Int>(limit: 4)
        let now = Date()
        lru.set(0, for: 0, expires: now.addingTimeInterval(3600), now: now)
        for i in 1..<4 { lru.set(i, for: i, expires: now.addingTimeInterval(1), now: now) }
        lru.set(4, for: 4, expires: now.addingTimeInterval(3600), now: now.addingTimeInterval(2))
        XCTAssertEqual(lru.count, 2)
        XCTAssertNotNil(lru.peek(0), "the oldest, but live")
        XCTAssertNotNil(lru.peek(4))
    }
}
