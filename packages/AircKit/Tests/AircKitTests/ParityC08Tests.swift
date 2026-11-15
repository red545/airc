// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// C08 (docs/qa/parity-audit.md): the profile's engine choice, its suggestions, and "Search … for" on a selection.
final class ParityC08Tests: XCTestCase {
    override func tearDown() { SearchEngineStandIn.origin = nil }

    func testEngineChoicesCoverChromiumsRegionalList() {
        // Chromium 156's US list (Google, DuckDuckGo, Brave, Bing, Ecosia), the German one's Perplexity, Startpage and
        // Yahoo, and Kagi.
        XCTAssertEqual(SearchEngine.allCases.map(\.name),
                       ["Google", "Bing", "DuckDuckGo", "Ecosia", "Brave", "Yahoo", "Startpage", "Perplexity", "Kagi"])
        XCTAssertEqual(Set(SearchEngine.allCases.map(\.rawValue)).count, SearchEngine.allCases.count)
        // Stored names never change: older rows still read.
        XCTAssertEqual(SearchEngine(rawValue: "duckDuckGo"), .duckDuckGo)
    }

    func testEverySearchAndSuggestionAddress() {
        let q = "wool & socks"
        let search: [SearchEngine: String] = [
            .google: "https://www.google.com/search?q=wool%20%26%20socks",
            .bing: "https://www.bing.com/search?q=wool%20%26%20socks",
            .duckDuckGo: "https://duckduckgo.com/?q=wool%20%26%20socks",
            .ecosia: "https://www.ecosia.org/search?q=wool%20%26%20socks",
            .brave: "https://search.brave.com/search?q=wool%20%26%20socks",
            .yahoo: "https://search.yahoo.com/search?p=wool%20%26%20socks",
            .startpage: "https://www.startpage.com/sp/search?q=wool%20%26%20socks",
            .perplexity: "https://www.perplexity.ai/search?q=wool%20%26%20socks",
            .kagi: "https://kagi.com/search?q=wool%20%26%20socks",
        ]
        for e in SearchEngine.allCases {
            XCTAssertEqual(e.searchURL(for: q).absoluteString, search[e], e.name)
            let s = SearchSuggestions.url(for: q, engine: e)
            XCTAssertEqual(s?.scheme, "https", e.name)
            XCTAssertTrue(s?.absoluteString.hasSuffix("wool%20%26%20socks") == true, e.name)
        }
    }

    func testLoopbackStandInNamesTheEngine() {
        SearchEngineStandIn.origin = "http://127.0.0.1:9"
        XCTAssertEqual(SearchEngine.brave.searchURL(for: "a b").absoluteString, "http://127.0.0.1:9/search.brave.com/search?q=a%20b")
        XCTAssertEqual(SearchSuggestions.url(for: "a", engine: .duckDuckGo)?.absoluteString,
                       "http://127.0.0.1:9/duckduckgo.com/ac/?type=list&q=a")
        XCTAssertEqual(DefaultSearch.engine(.yahoo).url(for: "x")?.host, "127.0.0.1")
        SearchEngineStandIn.origin = nil
        XCTAssertEqual(SearchEngine.brave.searchURL(for: "x").host, "search.brave.com")
    }

    func testSuggestionsArePerProfileAndOnByDefault() throws {
        var p = Profile(name: "Work")
        XCTAssertTrue(p.includesSearchSuggestions)
        p.searchSuggestions = false
        XCTAssertFalse(p.includesSearchSuggestions)
        // A profile an older build saved (no field) reads as on; the choice survives a round trip.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p)).searchSuggestions, false)
        json["searchSuggestions"] = nil
        let old = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.searchSuggestions)
        XCTAssertTrue(old.includesSearchSuggestions)
    }

    func testStorePersistsEngineAndSuggestionsPerProfile() throws {
        let store = try SpacesStore(path: nil)
        let work = try store.createProfile(name: "Work")
        try store.updateProfile(work.id) { $0.searchEngine = .brave; $0.searchSuggestions = false }
        let def = try XCTUnwrap(store.state.profiles.values.first { $0.isDefault })
        XCTAssertEqual(store.profile(work.id)?.searchEngine, .brave)
        XCTAssertEqual(store.profile(work.id)?.includesSearchSuggestions, false)
        XCTAssertEqual(store.profile(def.id)?.searchEngine, .google, "another profile's choice is its own")
        XCTAssertEqual(store.profile(def.id)?.includesSearchSuggestions, true)
    }

    func testSelectionSearchTitleAndAddress() {
        let ddg = DefaultSearch.engine(.duckDuckGo)
        XCTAssertEqual(SelectionSearch.title("  flowers\n in   spring ", search: ddg), "Search DuckDuckGo for “flowers in spring”")
        XCTAssertEqual(SelectionSearch.url("flowers\nin spring", search: ddg)?.absoluteString, "https://duckduckgo.com/?q=flowers%20in%20spring")
        XCTAssertNil(SelectionSearch.title(" \n\t", search: ddg))
        XCTAssertNil(SelectionSearch.url("", search: ddg))
        // Elided at a word to Chromium's 50 characters.
        let long = String(repeating: "word ", count: 20)
        let t = SelectionSearch.title(long, search: ddg)!
        let shown = t.dropFirst("Search DuckDuckGo for “".count).dropLast()
        XCTAssertLessThanOrEqual(shown.count, 50)
        XCTAssertTrue(shown.hasSuffix("word…"))
        XCTAssertEqual(SelectionSearch.elide(String(repeating: "x", count: 80)).count, 50)
        // A site search made the default (P07d) is what's named and searched.
        let site = SiteSearch(name: "Loopback Find", keyword: "lf", template: "http://127.0.0.1:1/find?q=%s")
        XCTAssertEqual(SelectionSearch.title("a&b", search: .site(site)), "Search Loopback Find for “a&b”")
        XCTAssertEqual(SelectionSearch.url("a&b", search: .site(site))?.absoluteString, "http://127.0.0.1:1/find?q=a%26b")
    }
}

extension ParityC08Tests {
    /// Instant Links (P07c) reads any engine's results page; every engine in the picker is known as an engine, so its
    /// own links (settings, other searches) never count as answers.
    func testInstantLinksKnowsEveryPickerEngine() {
        for e in SearchEngine.allCases {
            let host = e.searchURL(for: "x").host ?? ""
            XCTAssertTrue(InstantLinks.searchEngineLabels.contains(InstantLinks.siteLabel(host)), "\(e.name): \(host)")
        }
        let page = [InstantLinksPageLink(title: "Settings", href: "https://www.perplexity.ai/settings", isResult: true),
                    InstantLinksPageLink(title: "Swift", href: "https://www.swift.org/", isResult: true)]
        let url = SearchEngine.perplexity.searchURL(for: "swift")
        XCTAssertEqual(InstantLinks.candidates(page, searchURL: url, search: .engine(.perplexity)).map(\.href), ["https://www.swift.org/"])
    }
}
