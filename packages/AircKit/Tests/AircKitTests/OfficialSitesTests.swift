// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class OfficialSitesTests: XCTestCase {
    func testTheStoreIsSupportedInAirc() {
        let s = OfficialSites.match("https://chromewebstore.google.com/detail/1password/aeblfdkhhhdcdjpifhhbdiojplfjncoa")
        XCTAssertEqual(s?.name, "Chrome Web Store")
        XCTAssertEqual(s?.label, "Supported in Airc")
        XCTAssertEqual(OfficialSites.match("https://chromewebstore.google.com")?.label, OfficialSites.supported)
        XCTAssertEqual(OfficialSites.match("https://chrome.google.com/webstore/category/extensions")?.label, OfficialSites.supported)
    }

    func testTheOtherOfficialSites() {
        for url in ["https://accounts.google.com/signin", "https://mail.google.com/mail/u/0/", "https://docs.google.com/document/d/x",
                    "https://drive.google.com/", "https://calendar.google.com/", "https://meet.google.com/abc-defg-hij",
                    "https://www.youtube.com/watch?v=1", "https://github.com/apple/swift", "https://aircbrowser.com/download",
                    "https://www.aircbrowser.com/", "https://support.apple.com/en-us/102000", "https://www.apple.com/support/",
                    "https://www.apple.com/support", "https://GitHub.com/x", "https://github.com:443/x"] {
            XCTAssertEqual(OfficialSites.match(url)?.label, OfficialSites.official, url)
        }
    }

    func testLookalikesAndUnsafeAddressesNeverMatch() {
        for url in [
            "https://chromewebstore.google.com.evil.example/detail/x",   // the real host as a prefix
            "https://chromewebstore.google.com./detail/x",               // trailing dot
            "https://evil-chromewebstore.google.com.example/",
            "https://chromewebstore-google.com/",
            "https://chromewebstore.googIe.com/",                        // capital I for l
            "https://xn--chromewebstre-2ib.google.com/",                 // punycode confusable
            "https://xn--gthub-n4a.com/",
            "https://gіthub.com/",                                       // Cyrillic і, unencoded
            "http://chromewebstore.google.com/",                         // http
            "http://github.com/",
            "ftp://github.com/",
            "https://chromewebstore.google.com@evil.example/",           // user info
            "https://user:pw@github.com/",
            "https://github.com:8443/",                                  // another port
            "https://140.82.112.3/",                                     // an IP
            "https://[2606:50c0:8000::153]/",
            "https://gist.github.com/",                                  // a host under an entry's domain, not on the list
            "https://www.github.com/",
            "https://apple.com/support",
            "https://www.apple.com/supportx",                            // a path that only starts like /support
            "https://www.apple.com/iphone/",
            "https://chrome.google.com/",                                // outside /webstore
            "https://google.com.evil.example/",
            "chromewebstore.google.com",                                 // no scheme
            "",
        ] {
            XCTAssertNil(OfficialSites.match(url), url)
        }
    }

    func testEveryEntryIsWellFormed() {
        XCTAssertFalse(OfficialSites.all.isEmpty)
        for s in OfficialSites.all {
            XCTAssertEqual(s.host, s.host.lowercased(), s.host)
            XCTAssertTrue(OfficialSites.isPlainName(s.host), s.host)
            XCTAssertTrue(s.host == s.domain || s.host.hasSuffix("." + s.domain), s.host)
            XCTAssertTrue(s.label == OfficialSites.official || s.label == OfficialSites.supported, s.host)
            XCTAssertTrue(s.path.isEmpty || (s.path.hasPrefix("/") && !s.path.hasSuffix("/")), s.host)
            XCTAssertNotNil(OfficialSites.match("https://\(s.host)\(s.path)/"), s.host)
        }
        // Only the store is "Supported in Airc": extensions install from it.
        XCTAssertEqual(Set(OfficialSites.all.filter { $0.label == OfficialSites.supported }.map(\.name)), ["Chrome Web Store"])
    }

    func testMonogramNamesAndColours() {
        XCTAssertEqual(SiteMonogram.name(forPage: "https://www.derstandard.at/story/1"), "derstandard")
        XCTAssertEqual(SiteMonogram.name(forPage: "https://chromewebstore.google.com/"), "google")
        XCTAssertEqual(SiteMonogram.name(forPage: "https://news.bbc.co.uk/"), "bbc")
        XCTAssertEqual(SiteMonogram.name(forPage: "http://localhost:3000/"), "localhost")
        XCTAssertNil(SiteMonogram.name(forPage: "about:blank"))
        XCTAssertEqual(SiteMonogram.letter(for: "derstandard"), "D")
        XCTAssertEqual(SiteMonogram.letter(for: "1password"), "1")
        XCTAssertEqual(SiteMonogram.letter(for: "--"), "•")
        let a = SiteMonogram.colorIndex(for: "derstandard", count: 8)
        XCTAssertEqual(a, SiteMonogram.colorIndex(for: "derstandard", count: 8))
        XCTAssertTrue((0..<8).contains(a))
        // Different sites spread over the colours.
        let spread = Set(["github", "google", "derstandard", "spotify", "notion", "figma", "linear", "apple"].map {
            SiteMonogram.colorIndex(for: $0, count: 8)
        })
        XCTAssertGreaterThan(spread.count, 3)
    }
}
