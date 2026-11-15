// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class InlinePrefixRangeTests: XCTestCase {
    func testPrefixRangePreservesRankingBoundariesAndExtraWeights() {
        let keys = [
            InlineCompletion.Key(text: "r.example", url: "https://r.example/", weight: 1000),
            InlineCompletion.Key(text: "s", url: "https://s/", weight: 1000),
            InlineCompletion.Key(text: "s-long.example", url: "https://s-long.example/", weight: 8),
            InlineCompletion.Key(text: "s.a", url: "https://s.a/", weight: 8),
            InlineCompletion.Key(text: "s.b", url: "https://s.b/", weight: 8),
            InlineCompletion.Key(text: "s.c", url: "https://s.c/", weight: 1),
            InlineCompletion.Key(text: "t.example", url: "https://t.example/", weight: 1000),
        ]
        func complete(_ text: String, extra: [(url: String, weight: Double)] = []) -> InlineCompletion.Match? {
            InlineCompletion.complete(text, hostKeys: keys, addressKeys: [], extra: extra)
        }
        XCTAssertEqual(complete("s")?.text, "s.a", "shortest on weight ties, first sorted key on full ties")
        XCTAssertEqual(complete("s", extra: [("https://s.c/path", 10)])?.text, "s.c")
        XCTAssertEqual(complete("S-")?.text, "S-long.example")
        XCTAssertNil(complete("s.c"), "exact matches have no suffix")
        XCTAssertNil(complete("z"))
    }

    func testUnicodeAndAddressPrefixes() {
        let keys = [
            InlineCompletion.Key(text: "example.com/éclair", url: "https://example.com/éclair", weight: 2),
            InlineCompletion.Key(text: "example.com/élan", url: "https://example.com/élan", weight: 3),
            InlineCompletion.Key(text: "example.com/ê", url: "https://example.com/ê", weight: 100),
        ]
        let result = InlineCompletion.complete("example.com/é", hostKeys: [], addressKeys: keys, extra: [])
        XCTAssertEqual(result?.text, "example.com/élan")
        XCTAssertEqual(result?.suffix, "lan")
    }
}
