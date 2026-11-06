// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import QuartzCore
import XCTest
@testable import AircKit

/// The Command Bar's built-in sites (CommonSites) and how they rank against your own results (CommandSearch.blend).
final class CommonSitesTests: XCTestCase {
    private var sites: CommonSitesSnapshot { CommonSitesIndex.shared.snapshotNow() }

    private func names(_ m: [CommonSites.Match]) -> [String] { m.map(\.site.name) }

    // MARK: The list

    func testListIsCleanAndCoversTheBasics() throws {
        let t0 = CACurrentMediaTime()
        let s = CommonSitesSnapshot(sites: CommonSites.parse(CommonSitesData.list))
        print(String(format: "common sites: %d sites, %d keys, index built in %.1f ms", s.count, s.keys.count,
                     (CACurrentMediaTime() - t0) * 1000))
        XCTAssert((1_000...2_000).contains(s.count), "\(s.count) sites")
        // Every line parses (comments and blank lines aside).
        let lines = CommonSitesData.list.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(lines.count, s.count, "every line is a site")
        var urls = Set<String>(), homeHosts: [String: String] = [:]
        for site in s.sites {
            XCTAssert((1...3).contains(site.tier), site.name)
            XCTAssertFalse(site.name.isEmpty)
            let u = try XCTUnwrap(URLComponents(string: site.url), site.url)
            XCTAssertEqual(u.scheme, "https", site.url)
            XCTAssertNotNil(u.host, site.url)
            XCTAssert(urls.insert(site.url.replacingOccurrences(of: "://www.", with: "://")).inserted, "duplicate \(site.url)")
            for r in site.regions { XCTAssertEqual(r.count, 2, "\(site.name): region \(r)") }
            // One site per home page: a second site on the same host must be a part of it (a path).
            if site.path.isEmpty {
                XCTAssertNil(homeHosts[site.hosts[0]], "\(site.name) and \(homeHosts[site.hosts[0]] ?? "") share \(site.hosts[0])")
                homeHosts[site.hosts[0]] = site.name
            }
        }
        let want: [String: String] = [
            "Spotify": "https://open.spotify.com", "Gmail": "https://mail.google.com", "YouTube": "https://www.youtube.com",
            "Netflix": "https://www.netflix.com", "GitHub": "https://github.com", "Notion": "https://www.notion.so",
            "Figma": "https://www.figma.com", "Linear": "https://linear.app", "ChatGPT": "https://chatgpt.com",
            "Claude": "https://claude.ai", "Der Standard": "https://www.derstandard.at", "ORF": "https://orf.at",
            "willhaben": "https://www.willhaben.at",
        ]
        for (name, url) in want {
            XCTAssertEqual(s.sites.first { $0.name == name }?.url, url, name)
        }
    }

    // MARK: Matching

    func testPrefixOfNameOrDomain() {
        XCTAssertEqual(sites.search("spot", region: "at").first?.site.name, "Spotify")
        XCTAssertEqual(sites.search("netfl", region: "at").first?.site.name, "Netflix")
        XCTAssertEqual(sites.search("gma", region: "at").first?.site.name, "Gmail")
        XCTAssertEqual(sites.search("derst", region: "at").first?.site.name, "Der Standard")
        XCTAssertEqual(sites.search("willh", region: "at").first?.site.name, "willhaben")
        XCTAssertEqual(sites.search("chatg", region: "us").first?.site.name, "ChatGPT")
        // Case and accents don't matter; a scheme or "www." is skipped.
        XCTAssertEqual(sites.search("SPOT", region: "at").first?.site.name, "Spotify")
        XCTAssertEqual(sites.search("www.netfl", region: "at").first?.site.name, "Netflix")
        XCTAssertEqual(sites.search("ö3", region: "at").first?.site.name, "Ö3")
        // The typed letters are marked in the name.
        XCTAssertEqual(sites.search("spot", region: "at").first?.matches, [0, 1, 2, 3])
    }

    func testAliases() {
        for (q, name) in [("yt", "YouTube"), ("gh", "GitHub"), ("gcal", "Google Calendar"), ("gmail", "Gmail"),
                          ("hn", "Hacker News"), ("twitter", "X")] {
            let top = sites.search(q, region: "at").first
            XCTAssertEqual(top?.site.name, name, q)
            XCTAssertEqual(top?.isExact, true, q)
        }
    }

    func testMultiWordAndLaterWords() {
        XCTAssertEqual(sites.search("google cal", region: "at").first?.site.name, "Google Calendar")
        XCTAssertEqual(sites.search("der standard", region: "at").first?.site.name, "Der Standard")
        XCTAssertEqual(sites.search("der standard", region: "at").first?.isExact, true)
        XCTAssertEqual(sites.search("derstandard", region: "at").first?.isExact, true)
        // A later word of the name.
        XCTAssert(names(sites.search("standard", region: "at")).contains("Der Standard"))
        XCTAssert(names(sites.search("calendar", region: "at")).contains("Google Calendar"))
    }

    func testNothingForOneLetterOrNonsense() {
        XCTAssertEqual(sites.search("s", region: "at"), [])
        XCTAssertEqual(sites.search("xqzzv", region: "at"), [])
        // Only prefixes of words: "tify" is inside Spotify's name, not a start.
        XCTAssertFalse(names(sites.search("tify", region: "at")).contains("Spotify"))
    }

    func testRegionLiftsLocalSites() {
        XCTAssertEqual(sites.search("kro", region: "at").first?.site.name, "Krone")
        XCTAssertEqual(sites.search("kro", region: "us").first?.site.name, "Kroger")
        XCTAssertEqual(sites.inlineCompletion(for: "amaz", region: "at")?.match.url, "https://www.amazon.de")
        XCTAssertEqual(sites.inlineCompletion(for: "amaz", region: "us")?.match.url, "https://www.amazon.com")
    }

    // MARK: Inline completion

    func testInlineCompletion() {
        let spot = sites.inlineCompletion(for: "spot", region: "at")
        XCTAssertEqual(spot?.match.text, "spotify.com")
        XCTAssertEqual(spot?.match.url, "https://open.spotify.com")
        XCTAssertEqual(spot?.match.suffix, "ify.com")
        XCTAssertEqual(spot?.site.name, "Spotify")
        // What was typed keeps its case.
        XCTAssertEqual(sites.inlineCompletion(for: "Spot", region: "at")?.match.text, "Spotify.com")
        XCTAssertEqual(sites.inlineCompletion(for: "derst", region: "at")?.match.text, "derstandard.at")
        XCTAssertEqual(sites.inlineCompletion(for: "gma", region: "at")?.match.text, "gmail.com")
        XCTAssertEqual(sites.inlineCompletion(for: "gma", region: "at")?.match.url, "https://mail.google.com")
        XCTAssertEqual(sites.inlineCompletion(for: "https://www.netf", region: "at")?.match.text, "https://www.netflix.com")
        // Nothing to add, a path, a space, one letter.
        XCTAssertNil(sites.inlineCompletion(for: "spotify.com", region: "at"))
        XCTAssertNil(sites.inlineCompletion(for: "spotify.com/", region: "at"))
        XCTAssertNil(sites.inlineCompletion(for: "spot ify", region: "at"))
        XCTAssertNil(sites.inlineCompletion(for: "s", region: "at"))
    }

    // MARK: Ranking against your own results

    private func history(_ title: String, _ url: String, boost: Double = 2) -> CommandSearch.Candidate {
        .init(id: url, kind: .history, title: title, subtitle: URLRules.displayURL(url), boost: boost)
    }

    private func blended(_ q: String, _ personal: [CommandSearch.Candidate], urls: [String]? = nil) -> [String] {
        let ranked = CommandSearch.rank(q, personal, limit: 7)
        let out = CommandSearch.blend(ranked, sites: sites.search(q, region: "at"),
                                      personalURLs: urls ?? personal.map(\.id))
        return out.map {
            switch $0 {
            case .personal(let r): return "mine: " + r.candidate.title
            case .site(let s): return "site: " + s.site.name
            }
        }
    }

    func testNoHistoryOffersTheSite() {
        XCTAssertEqual(blended("spot", []), ["site: Spotify"])
    }

    func testYourHistoryRanksAboveBuiltIn() {
        // A page you visited whose title starts with what you typed stays first.
        let rows = blended("spot", [history("Spotlight — the news", "https://spotlight.example.org/")])
        XCTAssertEqual(rows, ["mine: Spotlight — the news", "site: Spotify"])
        // So does a word-start match (80 against the site's 100: within the margin).
        let word = blended("spot", [history("Weekend spot ideas", "https://ideas.example.org/weekend")])
        XCTAssertEqual(word.first, "mine: Weekend spot ideas")
    }

    func testWeakPersonalMatchesGoBelowTheSite() {
        // Scattered letters ("s…p…o…t") don't keep a well-known site out of reach.
        let rows = blended("spot", [history("Sales pipeline of Tuesday", "https://crm.example.org/p")])
        XCTAssertEqual(rows, ["site: Spotify", "mine: Sales pipeline of Tuesday"])
    }

    func testNoDuplicateWhenTheSiteIsAlsoYours() {
        // Spotify in your history (any page on its hosts) shows once, as yours.
        let rows = blended("spot", [history("Discover Weekly – playlist by Spotify", "https://open.spotify.com/playlist/37i9")])
        XCTAssertEqual(rows, ["mine: Discover Weekly – playlist by Spotify"])
        XCTAssertEqual(blended("spot", [], urls: ["https://www.spotify.com/at/premium/"]), [])
        // Gmail open as a tab, by its other domain.
        XCTAssertFalse(blended("gma", [], urls: ["https://mail.google.com/mail/u/0/#inbox"]).contains("site: Gmail"))
        // A site that is part of a host is only covered by pages under its path: Docs doesn't hide Sheets.
        let sheets = sites.sites.first { $0.name == "Google Sheets" }!
        XCTAssertTrue(sheets.covers(host: "docs.google.com", path: "/spreadsheets/d/1abc/edit"))
        XCTAssertFalse(sheets.covers(host: "docs.google.com", path: "/document/d/1abc/edit"))
        XCTAssertTrue(sheets.covers(host: "sheets.google.com", path: "/"))
    }

    func testAtMostTwoSitesUnlessClearlyASiteName() {
        let some = CommandSearch.blend([], sites: sites.search("goo", region: "at", limit: 8), personalURLs: [])
        XCTAssertEqual(some.count, CommandSearch.maxSites)
        // "google" is a site's name: Google and its apps.
        let named = CommandSearch.blend([], sites: sites.search("google", region: "at", limit: 8), personalURLs: [])
        XCTAssertEqual(named.count, CommandSearch.maxSitesForName)
        if case .site(let first) = named.first { XCTAssertEqual(first.site.name, "Google") } else { XCTFail() }
    }

    func testYourResultsKeepTheirOrder() {
        // Two of yours that match the same: both stay above the site, in their order.
        let ranked = CommandSearch.rank("git", [
            .init(id: "https://git.example.org/a", kind: .openTab, title: "Git hooks — docs", boost: 2),
            history("Git cheat sheet", "https://cheats.example.org/git", boost: 0),
        ])
        let out = CommandSearch.blend(ranked, sites: sites.search("git", region: "at"), personalURLs: ranked.map(\.candidate.id))
        let kinds = out.map { if case .site = $0 { "site" } else { "mine" } }
        XCTAssertEqual(Array(kinds.prefix(2)), ["mine", "mine"])
        XCTAssert(kinds.dropFirst(2).allSatisfy { $0 == "site" } && kinds.count > 2, "\(kinds)")
    }

    // MARK: Speed (§2.12: local results in the keystroke's frame)

    func testKeystrokeCost() {
        let s = sites
        let queries = ["g", "go", "goo", "goog", "google cal", "spot", "derst", "yt", "a", "am", "ama", "the", "xqz", "net", "ö3"]
        var worst = 0.0
        for q in queries {
            var best = Double.infinity
            for _ in 0..<5 {
                let a = CACurrentMediaTime()
                _ = s.search(q, region: "at")
                _ = s.inlineCompletion(for: q, region: "at")
                best = min(best, (CACurrentMediaTime() - a) * 1000)
            }
            worst = max(worst, best)
        }
        print(String(format: "common sites: worst keystroke (search + inline) %.3f ms", worst))
        // Debug build, any machine: well under a millisecond in release (see the report).
        XCTAssertLessThan(worst, 4)
    }
}
