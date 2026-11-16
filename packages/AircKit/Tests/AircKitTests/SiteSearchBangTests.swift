// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// DuckDuckGo-style bangs in the Command Bar: "!yt cats", "cats !yt", the profile's own shortcuts as bangs, the
/// built-in table, and what isn't a bang.
final class SiteSearchBangTests: XCTestCase {
    private let own = SiteSearchIndex(SiteSearchSettings.defaults + [
        SiteSearch(id: "mine", name: "Loopback", keyword: "LB", template: "http://127.0.0.1:8080/find?q=%s"),
    ])

    private func url(_ text: String, own: SiteSearchIndex? = nil) -> String? {
        SiteSearchBang.match(text, own: own)?.url?.absoluteString
    }

    // MARK: Position

    func testBangAnywhereInTheQuery() {
        let want = "https://www.youtube.com/results?search_query=cute+cats"
        XCTAssertEqual(url("!yt cute cats"), want)
        XCTAssertEqual(url("cute cats !yt"), want)
        XCTAssertEqual(url("cute !yt cats"), want)
        XCTAssertEqual(url("  !yt   cute cats  "), want)
        XCTAssertEqual(SiteSearchBang.match("cute  !yt  cats", own: nil)?.query, "cute cats")
    }

    func testFirstKnownBangWins() {
        // An unknown word first, then a known one: the known one.
        let m = SiteSearchBang.match("!nosuchbang cats !gm", own: nil)
        XCTAssertEqual(m?.site.name, "Google Maps")
        XCTAssertEqual(m?.query, "!nosuchbang cats")
        XCTAssertEqual(SiteSearchBang.match("!w !yt cats", own: nil)?.site.name, "Wikipedia")
    }

    // MARK: Case and keywords

    func testCaseIsIgnored() {
        XCTAssertEqual(url("!YT cats"), "https://www.youtube.com/results?search_query=cats")
        XCTAssertEqual(url("!Gm Vienna"), "https://www.google.com/maps/search/Vienna")
        XCTAssertEqual(SiteSearchBang.match("!YT cats", own: nil)?.keyword, "yt")
    }

    func testRequestedBuiltInBangs() {
        let names: [String: String] = [
            "g": "Google", "gm": "Google Maps", "maps": "Google Maps", "gt": "Google Translate", "gi": "Google Images",
            "yt": "YouTube", "w": "Wikipedia", "wiki": "Wikipedia", "a": "Amazon", "amazon": "Amazon", "gh": "GitHub",
            "so": "Stack Overflow", "r": "Reddit", "reddit": "Reddit", "imdb": "IMDb", "twitter": "X", "x": "X", "tw": "X",
            "ddg": "DuckDuckGo", "b": "Bing", "bing": "Bing", "npm": "npm", "mdn": "MDN Web Docs", "hn": "Hacker News",
            "wa": "WolframAlpha", "ebay": "eBay", "spotify": "Spotify", "applemaps": "Apple Maps",
        ]
        for (k, name) in names {
            XCTAssertEqual(SiteSearchBang.builtIn[k]?.name, name, "!\(k)")
        }
    }

    func testEveryBuiltInTemplateIsValid() {
        for s in SiteSearchBang.builtInSites {
            XCTAssertTrue(SiteSearchTemplate.isValid(s.template), "\(s.name): \(s.template)")
            XCTAssertTrue(SiteSearchBang.isBuiltIn(s))
            XCTAssertNotNil(s.homeURL, s.name)
        }
        XCTAssertEqual(Set(SiteSearchBang.builtInSites.map(\.id)).count, SiteSearchBang.builtInSites.count)
    }

    func testRequestedTargets() {
        XCTAssertEqual(url("!gm vienna"), "https://www.google.com/maps/search/vienna")
        XCTAssertEqual(url("!g swift"), "https://www.google.com/search?q=swift")
        XCTAssertEqual(url("!w Vienna"), "https://en.wikipedia.org/wiki/Special:Search?search=Vienna")
        XCTAssertEqual(url("!ddg x"), "https://duckduckgo.com/?q=x")
        XCTAssertEqual(url("!npm left-pad"), "https://www.npmjs.com/search?q=left-pad")
        let gt = url("!gt guten Morgen") ?? ""
        XCTAssertTrue(gt.hasPrefix("https://translate.google.com/?sl=auto&tl=") && gt.hasSuffix("&text=guten+Morgen&op=translate"), gt)
    }

    func testOwnSiteSearchesAreBangs() {
        // The profile's own shortcut, ignoring case, its own address (never the stand-in).
        XCTAssertEqual(url("!lb hello", own: own), "http://127.0.0.1:8080/find?q=hello")
        XCTAssertEqual(url("hello !LB", own: own), "http://127.0.0.1:8080/find?q=hello")
        XCTAssertEqual(SiteSearchBang.match("!lb hello", own: own)?.site.id, "mine")
        // A seeded site (Settings → Site Search) comes first: "!gdocs", which has no built-in bang.
        XCTAssertEqual(SiteSearchBang.match("!gdocs plan", own: own)?.site.name, "Google Docs")
        XCTAssertNil(SiteSearchBang.match("!gdocs plan", own: nil))
        // Without the profile's list, the built-in one.
        XCTAssertNil(SiteSearchBang.match("!lb hello", own: nil))
        XCTAssertEqual(SiteSearchBang.match("!yt a", own: own)?.site.id, "default.youtube")
        XCTAssertEqual(SiteSearchBang.match("!yt a", own: nil)?.site.id, "bang.yt")
    }

    func testOwnSiteOverridesBuiltIn() {
        let mine = SiteSearchIndex([SiteSearch(id: "g2", name: "My G", keyword: "g", template: "https://g.example.com/?q=%s")])
        XCTAssertEqual(url("!g q", own: mine), "https://g.example.com/?q=q")
    }

    // MARK: Not bangs

    func testUnknownBangsAreLeftAlone() {
        XCTAssertNil(SiteSearchBang.match("!nosuchbang cats", own: own))
        XCTAssertTrue(SiteSearchBang.hasBangWord("!nosuchbang cats"))
    }

    func testBangAloneAndPunctuation() {
        for text in ["!", "!!", "! yt cats", "!! cats", "!?", "wow!", "cats ! yt", "!!yt cats", "!y!t cats", "hi!yt cats", ""] {
            XCTAssertNil(SiteSearchBang.match(text, own: own), text)
        }
        XCTAssertFalse(SiteSearchBang.hasBangWord("wow! great"))
        XCTAssertFalse(SiteSearchBang.hasBangWord("! x"))
        XCTAssertTrue(SiteSearchBang.hasBangWord("x !y"))
        XCTAssertFalse(SiteSearchBang.hasBangWord("cats"))
    }

    func testURLsContainingBangs() {
        for text in ["https://example.com/#!/yt", "example.com/!yt", "https://x.com/a!yt?b=!g", "mailto:a!yt@example.com"] {
            XCTAssertNil(SiteSearchBang.match(text, own: own), text)
            XCTAssertFalse(SiteSearchBang.hasBangWord(text), text)
        }
        // An address after a bang is the query.
        XCTAssertEqual(url("!w https://example.com/#!/a"),
                       "https://en.wikipedia.org/wiki/Special:Search?search=https%3A%2F%2Fexample.com%2F%23!%2Fa")
    }

    func testBangWithoutQuery() {
        let m = SiteSearchBang.match("!yt", own: nil)
        XCTAssertEqual(m?.site.name, "YouTube")
        XCTAssertEqual(m?.query, "")
        XCTAssertNil(m?.url)
        XCTAssertEqual(SiteSearchBang.match("  !yt  ", own: nil)?.query, "")
    }

    // MARK: Encoding

    func testQueryEncoding() {
        XCTAssertEqual(url("!yt 東京 & c++ 50%"), "https://www.youtube.com/results?search_query=%E6%9D%B1%E4%BA%AC+%26+c%2B%2B+50%25")
        XCTAssertEqual(url("!a it's (1)*-._~!"), "https://www.amazon.com/s?k=it's+(1)*-._~!")
        // A path template: path escaping, space as %20, "/" and "&" kept.
        XCTAssertEqual(url("!spotify AC/DC live & loud"), "https://open.spotify.com/search/AC/DC%20live%20&%20loud")
        XCTAssertEqual(url("!gm St. Stephen's #1"), "https://www.google.com/maps/search/St.%20Stephen's%20%231")
        // Another "!" inside the query is kept and escaped as Chromium does (a query value keeps "!").
        XCTAssertEqual(url("!yt wow! !nope"), "https://www.youtube.com/results?search_query=wow!+!nope")
    }

    func testStandInRoutesBuiltInsOnly() {
        SearchEngineStandIn.origin = "http://127.0.0.1:9"
        defer { SearchEngineStandIn.origin = nil }
        XCTAssertEqual(url("!yt test"), "http://127.0.0.1:9/www.youtube.com/results?search_query=test")
        XCTAssertEqual(url("!lb hello", own: own), "http://127.0.0.1:8080/find?q=hello")
        // A seeded site search is Airc's too.
        XCTAssertEqual(url("!yt test", own: own), "http://127.0.0.1:9/www.youtube.com/results?search_query=test")
    }
}
