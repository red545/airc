// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class MiniPlayerTests: XCTestCase {
    func testSitePolicyAndRoundTrip() throws {
        let key = try XCTUnwrap(MiniPlayerSite.origin("HTTPS://Meet.Example.com:443/room?q=1"))
        XCTAssertEqual(key, "https://meet.example.com")
        let sites = try JSONDecoder().decode([String: Bool].self, from: JSONEncoder().encode([key: false]))
        XCTAssertFalse(MiniPlayerSite.allowed(URL(string: key + "/another"), automatic: true, sites: sites))
        XCTAssertTrue(MiniPlayerSite.allowed(URL(string: "https://other.example.com"), automatic: true, sites: sites))
        XCTAssertFalse(MiniPlayerSite.allowed(URL(string: key), automatic: false, sites: [key: true]))
        XCTAssertNil(MiniPlayerSite.origin("file:///tmp/movie"))
        XCTAssertEqual(MiniPlayerSite.origin("http://localhost:8080/call"), "http://localhost:8080")
    }
    func testRepeatedCollapseAndReopen() {
        var state = MiniPlayerState()
        let frame = CGRect(x: 100, y: 80, width: 360, height: 240)
        XCTAssertNil(state.expand())
        state.minimize(from: frame)
        state.minimize(from: CGRect(x: 200, y: 80, width: 260, height: 48))
        XCTAssertTrue(state.isMinimized)
        XCTAssertEqual(state.expand(), frame)
        XCTAssertFalse(state.isMinimized)
        state.minimize(from: frame.offsetBy(dx: 40, dy: 0))
        XCTAssertEqual(state.expand(), frame.offsetBy(dx: 40, dy: 0))
    }
}
