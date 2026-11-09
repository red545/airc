// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit
final class TidyTitlePrivacyTests: XCTestCase {
    func testProfileAndURLPurgeAlsoDropsLegacyEntries() throws {
        var cache = TidyTitleCache()
        for key in ["a\nhttps://example.org", "b\nhttps://example.org", "https://legacy.example"] {
            cache.set(url: key, fingerprint: "title", name: "Title")
        }
        cache.remove(profileID: "a")
        let data = try JSONEncoder().encode(cache)
        let reloaded = try JSONDecoder().decode(TidyTitleCache.self, from: data)
        XCTAssertEqual(Set(reloaded.entries.keys), ["b\nhttps://example.org"])
        cache.remove(profileID: "b", url: "https://example.org")
        XCTAssertTrue(cache.entries.isEmpty)
    }
}
