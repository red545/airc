// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// C08b: another browser's engines merged into a profile's site searches (made-up sites on example domains).
final class SearchEngineImportTests: XCTestCase {
    typealias Entry = SearchEngineImport.Entry
    let video = Entry(name: "Video Sample", keyword: "vs", template: "https://video.example.com/results?q=%s")
    let wiki = Entry(name: "Wiki Sample", keyword: "ws", template: "https://wiki.example.org/w/index.php?search={searchTerms}")

    func testKnownDefaultSetsTheEngineAndClearsASiteDefault() {
        var s = SiteSearchSettings()
        XCTAssertTrue(s.setDefault("default.amazon", for: "p"))
        let o = s.apply(.init(defaultSearch: .engine(.duckDuckGo), shortcuts: [video]), to: "p")
        XCTAssertEqual(o.engine, .duckDuckGo)
        XCTAssertNil(s.defaultSite(for: "p"), "the picker engine is the default again")
        XCTAssertEqual(o.added, 1)
        XCTAssertEqual(s.searches(for: "p").last?.keyword, "vs")
        XCTAssertEqual(s.searches(for: "p").count, SiteSearchSettings.defaults.count + 1, "Airc's seeded sites stay")
    }

    func testCustomDefaultBecomesTheDefaultSite() {
        var s = SiteSearchSettings()
        let o = s.apply(.init(defaultSearch: .site(wiki), shortcuts: [video]), to: "p")
        XCTAssertNil(o.engine)
        XCTAssertEqual(o.defaultSite?.keyword, "ws")
        XCTAssertEqual(s.defaultSite(for: "p")?.template, "https://wiki.example.org/w/index.php?search=%s")
        XCTAssertEqual(s.defaultSearch(for: "p", engine: .google).url(for: "a b")?.absoluteString,
                       "https://wiki.example.org/w/index.php?search=a+b")
    }

    func testDefaultWithoutKeywordGetsOne() {
        var s = SiteSearchSettings()
        let o = s.apply(.init(defaultSearch: .site(.init(name: "Find", keyword: "", template: "https://find.example.com/?q=%s")), shortcuts: []), to: "p")
        XCTAssertEqual(o.defaultSite?.keyword, "example")
    }

    func testImportingAgainUpdatesNotDuplicates() {
        var s = SiteSearchSettings()
        s.apply(.init(defaultSearch: nil, shortcuts: [video, wiki]), to: "p")
        var moved = video
        moved.template = "https://video.example.com/find?q=%s"
        let o = s.apply(.init(defaultSearch: nil, shortcuts: [moved, wiki]), to: "p")
        XCTAssertEqual(o.updated, 1)
        XCTAssertEqual(o.existing, 1)
        XCTAssertEqual(s.searches(for: "p").filter { $0.keyword == "vs" }.map(\.template), ["https://video.example.com/find?q=%s"])
        XCTAssertEqual(s.searches(for: "p").count, SiteSearchSettings.defaults.count + 2)
    }

    func testUsersOwnShortcutWins() {
        var s = SiteSearchSettings()
        _ = s.add(name: "Mine", keyword: "vs", template: "https://mine.example.net/?q=%s", to: "p")
        let o = s.apply(.init(defaultSearch: nil, shortcuts: [video]), to: "p")
        XCTAssertEqual(o.skipped, 1)
        XCTAssertEqual(s.searches(for: "p").first { $0.keyword == "vs" }?.name, "Mine")
    }

    func testSameSiteAsASeededOneIsKept() {
        var s = SiteSearchSettings()
        // Arc's "yt" for the same site Airc seeds under "yt", with another path.
        let o = s.apply(.init(defaultSearch: nil, shortcuts: [Entry(name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query=%s&x=1")]), to: "p")
        XCTAssertEqual(o.existing, 1)
        XCTAssertEqual(s.searches(for: "p").count, SiteSearchSettings.defaults.count)
    }

    func testUnsafeEntriesAreSkipped() {
        var s = SiteSearchSettings()
        let o = s.apply(.init(defaultSearch: .site(Entry(name: "JS", keyword: "js", template: "javascript:alert(%s)")),
                              shortcuts: [Entry(name: "Plain", keyword: "pl", template: "http://plain.example.com/?q=%s"),
                                          Entry(name: "None", keyword: "nn", template: "https://none.example.com/")]), to: "p")
        XCTAssertEqual(o.skipped, 3)
        XCTAssertNil(s.defaultSite(for: "p"))
        XCTAssertNil(s.profiles["p"], "nothing changed")
    }

    func testProfilesStaySeparate() {
        var s = SiteSearchSettings()
        s.apply(.init(defaultSearch: .site(wiki), shortcuts: []), to: "a")
        XCTAssertNil(s.defaultSite(for: "b"))
        XCTAssertFalse(s.searches(for: "b").contains { $0.keyword == "ws" })
    }
}
