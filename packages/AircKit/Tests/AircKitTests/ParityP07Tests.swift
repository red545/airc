// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// P07a, Arc's Site Search: templates, Chromium's percent-encoding of the query, validation, per-profile lists and
/// what Tab or Space starts.
final class ParityP07Tests: XCTestCase {
    private func site(_ template: String, keyword: String = "t", name: String = "Test") -> SiteSearch {
        SiteSearch(id: "t", name: name, keyword: keyword, template: template)
    }

    // MARK: Encoding (Chromium's TemplateURLRef: EscapeQueryParamValue after "?", EscapePath before it)

    func testQueryValueEncodingMatchesChromium() {
        let s = site("https://www.amazon.com/s?k=%s")
        XCTAssertEqual(s.url(for: "wool socks")?.absoluteString, "https://www.amazon.com/s?k=wool+socks")
        // Everything but letters, digits and !'()*-._~ is escaped, "+" and "&" and "=" and "#" included.
        XCTAssertEqual(s.url(for: "a+b&c=d#e?f/g%h")?.absoluteString, "https://www.amazon.com/s?k=a%2Bb%26c%3Dd%23e%3Ff%2Fg%25h")
        XCTAssertEqual(s.url(for: "it's (1)*-._~!")?.absoluteString, "https://www.amazon.com/s?k=it's+(1)*-._~!")
        XCTAssertEqual(s.url(for: "\"<>[]{}|\\^`@$,;:")?.absoluteString,
                       "https://www.amazon.com/s?k=%22%3C%3E%5B%5D%7B%7D%7C%5C%5E%60%40%24%2C%3B%3A")
    }

    func testUnicodeIsUTF8Escaped() {
        let s = site("https://www.youtube.com/results?search_query=%s")
        XCTAssertEqual(s.url(for: "東京 天気")?.absoluteString,
                       "https://www.youtube.com/results?search_query=%E6%9D%B1%E4%BA%AC+%E5%A4%A9%E6%B0%97")
        XCTAssertEqual(s.url(for: "北京")?.absoluteString, "https://www.youtube.com/results?search_query=%E5%8C%97%E4%BA%AC")
        XCTAssertEqual(s.url(for: "café 🎵")?.absoluteString, "https://www.youtube.com/results?search_query=caf%C3%A9+%F0%9F%8E%B5")
        // Decoding gives the query back.
        let u = URLComponents(url: s.url(for: "東京 天気")!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(u.percentEncodedQueryItems?.first?.value?.replacingOccurrences(of: "+", with: " ").removingPercentEncoding, "東京 天気")
    }

    func testPathAndFragmentEncoding() {
        // Spotify (/search/%s) and Gmail (#apps/%s) have no "?" before the query: path escaping, space as %20.
        XCTAssertEqual(site("https://open.spotify.com/search/%s").url(for: "AC/DC live & loud")?.absoluteString,
                       "https://open.spotify.com/search/AC/DC%20live%20&%20loud")
        XCTAssertEqual(site("https://open.spotify.com/search/%s").url(for: "50% off? #1")?.absoluteString,
                       "https://open.spotify.com/search/50%25%20off%3F%20%231")
        XCTAssertEqual(site("https://mail.google.com/mail/ca/u/0/#apps/%s").url(for: "from:ana")?.absoluteString,
                       "https://mail.google.com/mail/ca/u/0/#apps/from%3Aana")
        XCTAssertEqual(site("https://www.google.com/maps/search/%s").url(for: "Wien Hbf")?.absoluteString,
                       "https://www.google.com/maps/search/Wien%20Hbf")
    }

    func testEveryPlaceholderAndTrimmedQuery() {
        let s = site("https://example.com/?q=%s&again=%s")
        XCTAssertEqual(s.url(for: "  two words ")?.absoluteString, "https://example.com/?q=two+words&again=two+words")
        XCTAssertNil(s.url(for: "   "))
        XCTAssertNil(s.url(for: ""))
    }

    // MARK: Validation

    func testTemplatesAccepted() throws {
        XCTAssertEqual(try SiteSearchTemplate.normalize("https://www.amazon.com/s?k=%s").get(), "https://www.amazon.com/s?k=%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("  amazon.com/s?k=%s  ").get(), "https://amazon.com/s?k=%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("HTTPS://Example.com/find?q=%s").get(), "https://Example.com/find?q=%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("https://example.com/search?q={searchTerms}").get(), "https://example.com/search?q=%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("localhost:8080/?q=%s").get(), "https://localhost:8080/?q=%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("http://127.0.0.1:3000/search/%s").get(), "http://127.0.0.1:3000/search/%s")
        XCTAssertEqual(try SiteSearchTemplate.normalize("https://de.wikipedia.org/w/index.php?search=%s&title=Spezial%3ASuche").get(),
                       "https://de.wikipedia.org/w/index.php?search=%s&title=Spezial%3ASuche")
        for d in SiteSearchSettings.defaults { XCTAssertTrue(SiteSearchTemplate.isValid(d.template), d.name) }
    }

    func testMalformedTemplatesRejected() {
        let cases: [(String, SiteSearchTemplate.Problem)] = [
            ("", .empty), ("   ", .empty),
            ("https://www.amazon.com/s?k=", .noPlaceholder),
            ("https://www.amazon.com/s?k=%S", .noPlaceholder),
            ("javascript:alert(%s)", .notWeb), ("data:text/html,%s", .notWeb), ("file:///tmp/%s", .notWeb),
            ("mailto:%s", .notWeb), ("ftp://example.com/%s", .notWeb), ("chrome://history/?q=%s", .notWeb),
            ("https://exa mple.com/?q=%s", .spaces),
            ("https://%s.example.com/", .placeholderInHost), ("https://example.%s/", .placeholderInHost),
            ("https://user:%s@example.com/", .placeholderInHost),
            ("https:///search?q=%s", .noHost), ("https:example.com/?q=%s", .noHost),
            ("https://exa_mple..com/?q=%s", .invalid), ("https://ex<am>ple.com/?q=%s", .invalid),
            (String(repeating: "a", count: 2050) + "%s", .tooLong),
        ]
        for (template, expected) in cases {
            XCTAssertEqual(SiteSearchTemplate.normalize(template).failure, expected, template)
        }
        // A tab inside the address (not at its ends) is a space too.
        XCTAssertEqual(SiteSearchTemplate.normalize("https://example.com/?q=\t%s").failure, .spaces)
        // Trailing whitespace and newlines are trimmed, not refused.
        XCTAssertEqual(SiteSearchTemplate.normalize("https://example.com/?q=%s\n").success, "https://example.com/?q=%s")
        XCTAssertFalse(SiteSearchTemplate.isValid("javascript:alert(%s)"))
    }

    func testFieldChecks() {
        let s = SiteSearchSettings()
        XCTAssertEqual(s.check(name: " ", keyword: "k", template: "https://e.com/?q=%s", for: "p").failure?.field, .name)
        XCTAssertEqual(s.check(name: "E", keyword: "", template: "https://e.com/?q=%s", for: "p").failure?.field, .keyword)
        XCTAssertEqual(s.check(name: "E", keyword: "two words", template: "https://e.com/?q=%s", for: "p").failure?.field, .keyword)
        XCTAssertEqual(s.check(name: "E", keyword: "/e", template: "https://e.com/?q=%s", for: "p").failure?.field, .keyword)
        // A default's shortcut is taken, ignoring case.
        XCTAssertEqual(s.check(name: "E", keyword: "YT", template: "https://e.com/?q=%s", for: "p").failure?.message, "YouTube already uses YT.")
        XCTAssertEqual(s.check(name: "E", keyword: "e", template: "e.com", for: "p").failure?.field, .template)
        let ok = s.check(name: "  Example   Docs ", keyword: " ed ", template: "e.com/?q=%s", for: "p")
        XCTAssertEqual(ok.success?.name, "Example Docs")
        XCTAssertEqual(ok.success?.keyword, "ed")
        XCTAssertEqual(ok.success?.template, "https://e.com/?q=%s")
    }

    // MARK: Profiles

    func testProfilesAreSeparate() {
        var s = SiteSearchSettings()
        XCTAssertEqual(s.searches(for: "work"), SiteSearchSettings.defaults)
        XCTAssertNotNil(s.add(name: "Jira", keyword: "j", template: "https://acme.atlassian.net/issues/?jql=text~%s", to: "work").success)
        s.remove("default.youtube", from: "work")
        s.setSpaceTriggers(true, for: "work")
        XCTAssertTrue(s.searches(for: "work").contains { $0.keyword == "j" })
        XCTAssertFalse(s.searches(for: "work").contains { $0.id == "default.youtube" })
        XCTAssertTrue(s.spaceTriggers(for: "work"))
        // The other profile is untouched: the defaults, Tab only, no Jira.
        XCTAssertEqual(s.searches(for: "personal"), SiteSearchSettings.defaults)
        XCTAssertFalse(s.spaceTriggers(for: "personal"))
        XCTAssertNil(SiteSearchIndex(s.searches(for: "personal")).match("j"))
        XCTAssertEqual(SiteSearchIndex(s.searches(for: "work")).match("j")?.name, "Jira")
        // The same shortcut can be used by two profiles.
        XCTAssertNotNil(s.add(name: "Jira Home", keyword: "j", template: "https://home.example/?q=%s", to: "personal").success)
        XCTAssertNotNil(s.add(name: "Again", keyword: "J", template: "https://x.example/?q=%s", to: "work").failure)
        s.forget(profileID: "work")
        XCTAssertEqual(s.searches(for: "work"), SiteSearchSettings.defaults)
        s.prune(keeping: [])
        XCTAssertTrue(s.profiles.isEmpty)
    }

    func testEditRestoreAndCodableRoundTrip() throws {
        var s = SiteSearchSettings()
        let jira = try XCTUnwrap(s.add(name: "Jira", keyword: "j", template: "https://acme.example/?q=%s", to: "p").success)
        XCTAssertNotNil(s.update(jira.id, name: "Jira", keyword: "yt", template: "https://acme.example/?q=%s", in: "p").failure)
        XCTAssertNotNil(s.update(jira.id, name: "Tickets", keyword: "tk", template: "acme.example/find/%s", in: "p").success)
        XCTAssertEqual(s.searches(for: "p").first { $0.id == jira.id }?.template, "https://acme.example/find/%s")
        s.remove("default.github", from: "p")
        s.restoreDefaults(for: "p")
        XCTAssertTrue(s.searches(for: "p").contains { $0.id == "default.github" })
        XCTAssertTrue(s.searches(for: "p").contains { $0.id == jira.id })
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SiteSearchSettings.self, from: data), s)
    }

    func testDecodingDropsMalformedEntriesOnly() throws {
        let json = """
        {"profiles": {"p": {"searches": [
            {"id": "a", "name": "A", "keyword": "a", "template": "https://a.example/?q=%s"},
            {"id": "b", "name": "B", "keyword": "b", "template": "javascript:alert(%s)"},
            {"id": "c", "name": "C"},
            {"id": "d", "name": "D", "keyword": "d", "template": "https://d.example/?q=%s"}
        ], "spaceTriggers": true}, "q": 7}}
        """
        let s = try JSONDecoder().decode(SiteSearchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.searches(for: "p").map(\.id), ["a", "d"])
        XCTAssertTrue(s.spaceTriggers(for: "p"))
        // Something else entirely: an empty settings value, never a failure.
        XCTAssertEqual(try JSONDecoder().decode(SiteSearchSettings.self, from: Data(#"{"profiles": 3}"#.utf8)), SiteSearchSettings())
    }

    // MARK: What Tab and Space start

    func testTabMatchesShortcutHostThenUniqueName() {
        let index = SiteSearchIndex(SiteSearchSettings.defaults)
        XCTAssertEqual(index.match("yt")?.name, "YouTube")
        XCTAssertEqual(index.match("YT ")?.name, "YouTube")
        XCTAssertEqual(index.match("you")?.name, "YouTube")
        XCTAssertEqual(index.match("google m")?.name, "Google Maps")
        XCTAssertEqual(index.match("gma")?.name, "Gmail")
        // A completion's host picks its site even when the name doesn't ("li" completes to linkedin.com).
        XCTAssertEqual(index.match("li", host: "https://www.linkedin.com/feed/")?.name, "LinkedIn")
        XCTAssertEqual(index.match("ama", host: "https://www.amazon.com/")?.name, "Amazon")
        XCTAssertEqual(index.match("x")?.name, "X")
        // Several names start with it: nothing, so Tab still accepts the completion.
        XCTAssertNil(index.match("goo"))
        XCTAssertNil(index.match("google"))
        XCTAssertNil(index.match("s"))
        // One letter of a longer name, actions, nothing.
        XCTAssertNil(index.match("y"))
        XCTAssertNil(index.match("/yt"))
        XCTAssertNil(index.match(""))
        XCTAssertNil(index.match("qxqxq wvwvw"))
        // google.com is not Google Maps (www.google.com/maps/search/%s), google.com/maps is.
        XCTAssertNil(index.match("goo", host: "https://www.google.com/"))
        XCTAssertEqual(index.match("google.com/m", host: "https://www.google.com/maps")?.name, "Google Maps")
        XCTAssertEqual(index.match("open.sp", host: "open.spotify.com")?.name, "Spotify")
        XCTAssertEqual(index.match("en.wi", host: "https://en.wikipedia.org/wiki/Lisbon")?.name, "Wikipedia")
        XCTAssertEqual(index.match("mail.g", host: "https://mail.google.com/mail/u/0/")?.name, "Gmail")
    }

    func testSpaceOnlyAfterAWholeShortcut() {
        let index = SiteSearchIndex(SiteSearchSettings.defaults)
        XCTAssertEqual(index.spaceMatch("yt ")?.name, "YouTube")
        XCTAssertEqual(index.spaceMatch("GH ")?.name, "GitHub")
        XCTAssertNil(index.spaceMatch("you "))
        XCTAssertNil(index.spaceMatch("yt"))
        XCTAssertNil(index.spaceMatch("yt  "))
        XCTAssertNil(index.spaceMatch("yt cats "))
        XCTAssertNil(index.spaceMatch(" "))
        // An ideographic space (a Japanese input method's) is not Space.
        XCTAssertNil(index.spaceMatch("yt\u{3000}"))
    }

    func testWhichPagesBelongToASite() {
        let d = Dictionary(uniqueKeysWithValues: SiteSearchSettings.defaults.map { ($0.name, $0) })
        XCTAssertTrue(d["Wikipedia"]!.covers("https://en.wikipedia.org/wiki/Lisbon"))
        XCTAssertTrue(d["YouTube"]!.covers("https://www.youtube.com/watch?v=x"))
        XCTAssertTrue(d["YouTube"]!.covers("https://m.youtube.com/watch?v=x"))
        XCTAssertFalse(d["YouTube"]!.covers("https://notyoutube.com/"))
        XCTAssertTrue(d["Google Maps"]!.covers("https://www.google.com/maps/place/Lisbon"))
        XCTAssertFalse(d["Google Maps"]!.covers("https://www.google.com/search?q=maps"))
        XCTAssertFalse(d["Google Maps"]!.covers("https://docs.google.com/document/d/1"))
        XCTAssertTrue(d["Google Docs"]!.covers("https://docs.google.com/document/d/1"))
        XCTAssertFalse(d["Google Docs"]!.covers("https://docs.google.com/spreadsheets/d/1"))
        XCTAssertFalse(d["GitHub"]!.covers("not a url at all"))
    }

    func testDefaultsAreArcsSeededSites() {
        let d = SiteSearchSettings.defaults
        XCTAssertEqual(d.count, 18)
        XCTAssertEqual(Set(d.map(\.id)).count, d.count)
        XCTAssertEqual(Set(d.map { $0.keyword.lowercased() }).count, d.count)
        XCTAssertEqual(d.first { $0.name == "YouTube" }?.template, "https://www.youtube.com/results?search_query=%s")
        XCTAssertEqual(d.first { $0.name == "Spotify" }?.host, "open.spotify.com")
        XCTAssertEqual(d.first { $0.name == "YouTube" }?.homeURL, "https://www.youtube.com/")
    }
}

private extension Result {
    var success: Success? { if case .success(let v) = self { v } else { nil } }
    var failure: Failure? { if case .failure(let e) = self { e } else { nil } }
}
