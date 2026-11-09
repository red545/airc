// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P07d (C08): any of a profile's site searches can be its default search engine. Typed text that isn't an address goes
/// to that site, encoded as its site search encodes it; a removed default hands back to the profile's built-in engine.
final class ParityP07dTests: XCTestCase {
    private let pid = "profile-a"

    func testNoDefaultSiteMeansTheBuiltInEngine() {
        let s = SiteSearchSettings()
        XCTAssertNil(s.defaultSite(for: pid))
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .duckDuckGo), .engine(.duckDuckGo))
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .duckDuckGo).name, "DuckDuckGo")
        XCTAssertEqual(URLRules.resolve("wool socks", search: s.defaultSearch(for: pid, engine: .google)),
                       URLRules.resolve("wool socks", engine: .google))
    }

    func testASeededSiteBecomesTheDefault() {
        var s = SiteSearchSettings()
        XCTAssertTrue(s.setDefault("default.amazon", for: pid))
        XCTAssertEqual(s.defaultSite(for: pid)?.name, "Amazon")
        let search = s.defaultSearch(for: pid, engine: .google)
        XCTAssertEqual(search.name, "Amazon")
        XCTAssertEqual(search.url(for: "wool socks")?.absoluteString, "https://www.amazon.com/s?k=wool+socks")
        // The seeded list is still all there, and the profile's other settings are untouched.
        XCTAssertEqual(s.searches(for: pid).count, SiteSearchSettings.defaults.count)
        XCTAssertFalse(s.spaceTriggers(for: pid))
    }

    func testPercentEncodingIsTheSiteSearchs() {
        var s = SiteSearchSettings()
        s.setDefault("default.amazon", for: pid)
        let amazon = s.defaultSearch(for: pid, engine: .google)
        // As SiteSearchTemplate.expand (Chromium's EscapeQueryParamValue after "?").
        XCTAssertEqual(amazon.url(for: "a+b&c=d#e?f/g%h")?.absoluteString, "https://www.amazon.com/s?k=a%2Bb%26c%3Dd%23e%3Ff%2Fg%25h")
        XCTAssertEqual(amazon.url(for: "東京 天気")?.absoluteString, "https://www.amazon.com/s?k=%E6%9D%B1%E4%BA%AC+%E5%A4%A9%E6%B0%97")
        XCTAssertEqual(amazon.url(for: "  trimmed  ")?.absoluteString, "https://www.amazon.com/s?k=trimmed")
        // A path template (Spotify's /search/%s): EscapePath, space as %20.
        s.setDefault("default.spotify", for: pid)
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .google).url(for: "AC/DC live")?.absoluteString,
                       "https://open.spotify.com/search/AC/DC%20live")
        // Same result as the site search itself, for anything typed.
        for q in ["x", "50% off? #1", "café 🎵", "a&b=c"] {
            XCTAssertEqual(s.defaultSearch(for: pid, engine: .google).url(for: q), s.defaultSite(for: pid)?.url(for: q))
        }
    }

    func testAddressesStillOpenAndEmptyTextDoesNothing() {
        var s = SiteSearchSettings()
        s.setDefault("default.github", for: pid)
        let search = s.defaultSearch(for: pid, engine: .google)
        XCTAssertEqual(URLRules.resolve("example.com/path", search: search)?.absoluteString, "https://example.com/path")
        XCTAssertEqual(URLRules.resolve("https://apple.com", search: search)?.absoluteString, "https://apple.com")
        XCTAssertEqual(URLRules.resolve("swift concurrency", search: search)?.absoluteString,
                       "https://github.com/search?q=swift+concurrency")
        XCTAssertNil(URLRules.resolve("   ", search: search))
        XCTAssertNil(search.url(for: ""))
        XCTAssertNil(DefaultSearch.engine(.google).url(for: "  "))
    }

    func testAnOwnSiteCanBeTheDefaultAndStaysItWhenEdited() throws {
        var s = SiteSearchSettings()
        let mine = try s.add(name: "Docs", keyword: "dd", template: "docs.example.org/find?q=%s", to: pid).get()
        XCTAssertTrue(s.setDefault(mine.id, for: pid))
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .google).url(for: "a b")?.absoluteString,
                       "https://docs.example.org/find?q=a+b")
        _ = try s.update(mine.id, name: "Team Docs", keyword: "td", template: "https://docs.example.org/search?term=%s", in: pid).get()
        XCTAssertEqual(s.defaultSite(for: pid)?.name, "Team Docs")
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .google).url(for: "a b")?.absoluteString,
                       "https://docs.example.org/search?term=a+b")
    }

    func testRemovingTheDefaultFallsBackToTheBuiltInEngine() {
        var s = SiteSearchSettings()
        s.setDefault("default.youtube", for: pid)
        s.remove("default.youtube", from: pid)
        XCTAssertNil(s.defaultSite(for: pid))
        XCTAssertNil(s.profiles[pid]?.defaultID)
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .kagi), .engine(.kagi))
        // Restoring the seeded sites brings YouTube back, but not as the default.
        s.restoreDefaults(for: pid)
        XCTAssertTrue(s.searches(for: pid).contains { $0.id == "default.youtube" })
        XCTAssertNil(s.defaultSite(for: pid))
        // Removing another site keeps the default.
        s.setDefault("default.wikipedia", for: pid)
        s.remove("default.reddit", from: pid)
        XCTAssertEqual(s.defaultSite(for: pid)?.id, "default.wikipedia")
    }

    func testUnknownSitesAreRefusedAndNilResets() {
        var s = SiteSearchSettings()
        XCTAssertFalse(s.setDefault("nope", for: pid))
        XCTAssertNil(s.profiles[pid], "a refused default writes nothing")
        XCTAssertTrue(s.setDefault(nil, for: pid))
        XCTAssertNil(s.profiles[pid], "resetting an unchanged profile writes nothing")
        s.setDefault("default.x", for: pid)
        XCTAssertTrue(s.setDefault(nil, for: pid))
        XCTAssertEqual(s.defaultSearch(for: pid, engine: .bing), .engine(.bing))
    }

    func testProfilesKeepTheirOwnDefault() {
        var s = SiteSearchSettings()
        s.setDefault("default.amazon", for: "a")
        s.setDefault("default.wikipedia", for: "b")
        XCTAssertEqual(s.defaultSite(for: "a")?.name, "Amazon")
        XCTAssertEqual(s.defaultSite(for: "b")?.name, "Wikipedia")
        XCTAssertNil(s.defaultSite(for: "c"))
        s.forget(profileID: "a")
        XCTAssertNil(s.defaultSite(for: "a"))
        XCTAssertEqual(s.defaultSite(for: "b")?.name, "Wikipedia")
    }

    func testTheDefaultSurvivesARoundTripAndOldFilesStillRead() throws {
        var s = SiteSearchSettings()
        s.setDefault("default.github", for: pid)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SiteSearchSettings.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.defaultSite(for: pid)?.name, "GitHub")
        // A file written before P07d (no defaultID) reads with the built-in engine.
        let old = #"{"profiles":{"p":{"searches":[{"id":"a","name":"A","keyword":"a","template":"https://a.example/?q=%s"}],"spaceTriggers":true}}}"#
        let read = try JSONDecoder().decode(SiteSearchSettings.self, from: Data(old.utf8))
        XCTAssertNil(read.defaultSite(for: "p"))
        XCTAssertTrue(read.spaceTriggers(for: "p"))
        // A default naming a site that isn't in the list (a hand edit) is dropped, not followed.
        let dangling = #"{"profiles":{"p":{"searches":[{"id":"a","name":"A","keyword":"a","template":"https://a.example/?q=%s"}],"defaultID":"gone"}}}"#
        let d = try JSONDecoder().decode(SiteSearchSettings.self, from: Data(dangling.utf8))
        XCTAssertNil(d.profiles["p"]?.defaultID)
        XCTAssertEqual(d.defaultSearch(for: "p", engine: .ecosia), .engine(.ecosia))
        // A default whose site was dropped as malformed falls back too.
        let bad = #"{"profiles":{"p":{"searches":[{"id":"a","name":"A","keyword":"a","template":"javascript:%s"}],"defaultID":"a"}}}"#
        XCTAssertNil(try JSONDecoder().decode(SiteSearchSettings.self, from: Data(bad.utf8)).defaultSite(for: "p"))
    }
}
