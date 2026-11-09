// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class ExtensionStoreURLTests: XCTestCase {
    func testIDMatchingAcrossStoreRedirects() {
        let id = String(repeating: "a", count: 32)
        for url in ["https://chromewebstore.google.com/detail/\(id)",
                    "https://chromewebstore.google.com/detail/reader/\(id)/?hl=de#reviews",
                    "https://chrome.google.com/webstore/detail/reader/\(id)?utm_source=test",
                    "https://chromewebstore.google.com/detail/reader/\(id)/reviews",
                    "https://chromewebstore.google.com/detail/\(id)/support"] {
            XCTAssertTrue(ExtensionStoreURL.matches(url, extensionID: id), url)
        }
        for url in ["https://example.com/detail/\(id)",
                    "https://chromewebstore.google.com.evil.test/detail/\(id)",
                    "https://chromewebstore.google.com/detail/\(id)b",
                    "https://chromewebstore.google.com/detail/\(id)/unknown",
                    "https://chromewebstore.google.com/search/\(id)",
                    "https://chrome.google.com/detail/\(id)"] {
            XCTAssertFalse(ExtensionStoreURL.matches(url, extensionID: id), url)
        }
    }
}
