// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class FaviconGuessTests: XCTestCase {
    func testTheGuessKeepsThePort() {
        XCTAssertEqual(FaviconGuess.url(for: "http://localhost:3000/dashboard?tab=1"), "http://localhost:3000/favicon.ico")
        XCTAssertEqual(FaviconGuess.url(for: "http://127.0.0.1:52144/page.html"), "http://127.0.0.1:52144/favicon.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://staging.example.com:8443/"), "https://staging.example.com:8443/favicon.ico")
        // Another scheme's default port isn't this one's.
        XCTAssertEqual(FaviconGuess.url(for: "http://example.com:443/"), "http://example.com:443/favicon.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://example.com:80/"), "https://example.com:80/favicon.ico")
    }

    func testDefaultPortsGiveTodaysURL() {
        // The cache keys of normal sites don't change: no port, or the scheme's default, gives the same guess.
        for page in ["https://example.com/a/b", "https://example.com:443/a/b", "https://Example.COM/"] {
            XCTAssertEqual(FaviconGuess.url(for: page), "https://example.com/favicon.ico", page)
        }
        for page in ["http://example.com/", "http://example.com:80/x"] {
            XCTAssertEqual(FaviconGuess.url(for: page), "http://example.com/favicon.ico", page)
        }
    }

    func testIPv6LiteralsKeepTheirBrackets() {
        XCTAssertEqual(FaviconGuess.url(for: "http://[::1]:8080/"), "http://[::1]:8080/favicon.ico")
        XCTAssertEqual(FaviconGuess.url(for: "http://[::1]/"), "http://[::1]/favicon.ico")
    }

    func testKnownSites() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day7 = Date(timeIntervalSince1970: 1_794_052_800)   // 2026-11-07 12:00 UTC
        XCTAssertEqual(FaviconGuess.url(for: "https://calendar.google.com/calendar/u/0/r", now: day7, calendar: calendar),
                       "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_7.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://docs.google.com/spreadsheets/d/x"), "https://ssl.gstatic.com/docs/spreadsheets/favicon3.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://docs.google.com/document/d/x"), "https://ssl.gstatic.com/docs/documents/images/kix-favicon7.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://mail.google.com:443/mail/u/0"), "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico")
        XCTAssertEqual(FaviconGuess.url(for: "https://notion.so/workspace"), "https://www.notion.so/images/favicon.ico")
    }

    func testOnlyWebPages() {
        for page in ["file:///Users/x/a.html", "about:blank", "airc-note:abc", "not a url", "http:///nohost", ""] {
            XCTAssertNil(FaviconGuess.url(for: page), page)
        }
    }
}
