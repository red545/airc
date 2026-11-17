// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// C08 (cbfixes): an imported engine's suggestion endpoint (Chromium's `suggest_url`) on its site search: template
/// expansion, what's kept, and how imports and edits carry it. Made-up sites on example domains.
final class SiteSearchSuggestTests: XCTestCase {
    typealias Entry = SearchEngineImport.Entry
    let site = SiteSearch(id: "s", name: "Sample", keyword: "ss", template: "https://search.example.com/find?q=%s",
                          suggestTemplate: "https://suggest.example.com/complete?client=x&q=%s")

    override func tearDown() { SearchEngineStandIn.origin = nil }

    // MARK: Expansion

    func testQueryIsEscapedAsAQueryValue() {
        XCTAssertEqual(site.suggestionURL(for: "  café & co+1 ")?.absoluteString,
                       "https://suggest.example.com/complete?client=x&q=caf%C3%A9+%26+co%2B1")
        XCTAssertEqual(site.suggestionURL(for: "a/b?c#d")?.absoluteString,
                       "https://suggest.example.com/complete?client=x&q=a%2Fb%3Fc%23d")
    }

    func testQueryInThePathIsEscapedAsAPath() {
        let s = SiteSearch(name: "Path", keyword: "p", template: "https://p.example.com/?q=%s", suggestTemplate: "https://p.example.com/sugg/%s.json")
        XCTAssertEqual(s.suggestionURL(for: "a b?")?.absoluteString, "https://p.example.com/sugg/a%20b%3F.json")
    }

    func testEmptyQueryOrNoEndpointAsksNothing() {
        XCTAssertNil(site.suggestionURL(for: "   "))
        XCTAssertNil(SiteSearch(name: "None", keyword: "n", template: "https://n.example.com/?q=%s").suggestionURL(for: "a"))
    }

    func testSourceURLs() {
        XCTAssertEqual(SearchSuggestions.url(for: "ab", source: .site(site))?.host, "suggest.example.com")
        XCTAssertEqual(SearchSuggestions.url(for: "ab", source: .engine(.duckDuckGo)), SearchSuggestions.url(for: "ab", engine: .duckDuckGo))
        XCTAssertNotEqual(SearchSuggestions.Source.site(site).cacheKey, SearchSuggestions.Source.engine(.google).cacheKey)
        var other = site
        other.suggestTemplate = "https://other.example.com/s?q=%s"
        XCTAssertNotEqual(SearchSuggestions.Source.site(site).cacheKey, SearchSuggestions.Source.site(other).cacheKey)
    }

    func testStandInTakesSiteEndpointsToo() {
        SearchEngineStandIn.origin = "http://127.0.0.1:9"
        XCTAssertEqual(site.suggestionURL(for: "ab")?.absoluteString, "http://127.0.0.1:9/suggest.example.com/complete?client=x&q=ab")
    }

    // MARK: What's kept

    func testOnlyHttpsEndpointsAreKept() {
        for bad in ["http://s.example.com/?q=%s", "javascript:%s", "https://s.example.com/", "https://%s.example.com/",
                    "file:///tmp/%s", "https://s.example.com/?q=%s x"] {
            XCTAssertNil(SiteSearch(name: "B", keyword: "b", template: "https://b.example.com/?q=%s", suggestTemplate: bad).suggestTemplate, bad)
        }
        XCTAssertEqual(SiteSearch(name: "C", keyword: "c", template: "https://c.example.com/?q=%s",
                                  suggestTemplate: "https://c.example.com/ac?q={searchTerms}").suggestTemplate, "https://c.example.com/ac?q=%s")
    }

    func testCodableKeepsItAndReadsOldRecords() throws {
        let data = try JSONEncoder().encode(site)
        XCTAssertEqual(try JSONDecoder().decode(SiteSearch.self, from: data), site)
        let old = #"{"id":"o","name":"Old","keyword":"o","template":"https://o.example.com/?q=%s"}"#
        XCTAssertNil(try JSONDecoder().decode(SiteSearch.self, from: Data(old.utf8)).suggestTemplate)
        let bad = #"{"id":"o","name":"Old","keyword":"o","template":"https://o.example.com/?q=%s","suggestTemplate":"http://o.example.com/%s"}"#
        let read = try JSONDecoder().decode(SiteSearch.self, from: Data(bad.utf8))
        XCTAssertEqual(read.name, "Old", "the site stays")
        XCTAssertNil(read.suggestTemplate, "a suggestion address in the clear doesn't")
    }

    // MARK: Imports and edits

    func testImportCarriesTheEndpoint() {
        var s = SiteSearchSettings()
        let def = Entry(name: "Sample", keyword: "ss", template: "https://search.example.com/find?q={searchTerms}",
                        suggest: "https://suggest.example.com/complete?q={searchTerms}")
        let video = Entry(name: "Video", keyword: "vs", template: "https://video.example.com/r?q=%s", suggest: "http://video.example.com/s?q=%s")
        s.apply(.init(defaultSearch: .site(def), shortcuts: [video]), to: "p")
        XCTAssertEqual(s.defaultSite(for: "p")?.suggestTemplate, "https://suggest.example.com/complete?q=%s")
        XCTAssertNil(s.searches(for: "p").first { $0.keyword == "vs" }?.suggestTemplate, "http: not kept")
        guard case .site(let d) = s.defaultSearch(for: "p", engine: .google) else { return XCTFail("site default") }
        XCTAssertEqual(SearchSuggestions.url(for: "ab", source: .site(d))?.absoluteString, "https://suggest.example.com/complete?q=ab")
    }

    func testImportingAgainFillsAnEarlierImportsEndpoint() {
        var s = SiteSearchSettings()
        let plain = Entry(name: "Video", keyword: "vs", template: "https://video.example.com/r?q=%s")
        s.apply(.init(defaultSearch: nil, shortcuts: [plain]), to: "p")
        var with = plain
        with.suggest = "https://video.example.com/s?q=%s"
        let o = s.apply(.init(defaultSearch: nil, shortcuts: [with]), to: "p")
        XCTAssertEqual(o.updated, 1)
        XCTAssertEqual(s.searches(for: "p").first { $0.keyword == "vs" }?.suggestTemplate, "https://video.example.com/s?q=%s")
        // Same address under the user's own site: theirs is left alone.
        var mine = SiteSearchSettings()
        _ = mine.add(name: "Mine", keyword: "mv", template: "https://video.example.com/r?q=%s", to: "p")
        let o2 = mine.apply(.init(defaultSearch: nil, shortcuts: [with]), to: "p")
        XCTAssertEqual(o2.existing, 1)
        XCTAssertNil(mine.searches(for: "p").first { $0.keyword == "mv" }?.suggestTemplate)
    }

    func testEditInSettingsKeepsTheEndpoint() {
        var s = SiteSearchSettings()
        s.apply(.init(defaultSearch: nil, shortcuts: [Entry(name: "Video", keyword: "vs", template: "https://video.example.com/r?q=%s",
                                                            suggest: "https://video.example.com/s?q=%s")]), to: "p")
        let id = s.searches(for: "p").first { $0.keyword == "vs" }!.id
        guard case .success(let edited) = s.update(id, name: "Videos", keyword: "v", template: "https://video.example.com/r?q=%s", in: "p")
        else { return XCTFail("edit") }
        XCTAssertEqual(edited.suggestTemplate, "https://video.example.com/s?q=%s")
        XCTAssertEqual(s.searches(for: "p").first { $0.id == id }?.suggestTemplate, "https://video.example.com/s?q=%s")
    }
}
