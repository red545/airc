// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// PK-1 / AT-1 on the bundled Public Suffix List: which links leave their site (Peek from a pinned tab or Favorite), and
/// which of those Air Traffic Control sends to a Space.
final class PeekRulesTests: XCTestCase {
    let psl = TestSuffixes.list

    /// (from, to, same site). Hosts as a page gives them; the URLs add schemes, ports and paths.
    static let sites: [(String, String, Bool)] = [
        // One registrable domain under an ordinary suffix.
        ("docs.google.com", "mail.google.com", true), ("google.com", "www.google.com", true),
        ("docs.google.com", "docs.google.co.uk", false), ("google.com", "goog.le", false),
        // Multi-label ICANN suffixes.
        ("bbc.co.uk", "news.bbc.co.uk", true), ("a.co.uk", "b.co.uk", false), ("www.a.co.uk", "a.co.uk", true),
        ("a.co.uk", "a.org.uk", false),
        // Private suffixes: every tenant is its own site.
        ("foo.github.io", "bar.github.io", false), ("www.foo.github.io", "foo.github.io", true),
        ("github.io", "foo.github.io", false), ("github.com", "foo.github.io", false),
        ("alice.blogspot.com", "bob.blogspot.com", false), ("www.alice.blogspot.com", "alice.blogspot.com", true),
        ("app-a.vercel.app", "app-b.vercel.app", false), ("a.pages.dev", "x.a.pages.dev", true),
        ("x.appspot.com", "y.appspot.com", false), ("victim.duckdns.org", "attacker.duckdns.org", false),
        // Wildcards and their exceptions ("*.ck", "!www.ck").
        ("a.b.ck", "c.b.ck", false), ("x.a.b.ck", "a.b.ck", true), ("www.ck", "x.www.ck", true),
        // Internationalised names: Unicode and punycode are the same host; IDN suffixes count.
        ("bücher.de", "www.xn--bcher-kva.de", true), ("XN--BCHER-KVA.DE", "shop.bücher.de", true),
        ("例子.中国", "www.例子.中国", true), ("例子.公司.cn", "其他.公司.cn", false), ("www.例子.公司.cn", "xn--fsqu00a.xn--55qx5d.cn", true),
        // Trailing dots and case.
        ("example.com.", "www.example.com", true), ("WWW.Example.COM", "example.com.", true), ("x.github.io.", "y.github.io", false),
        // Addresses compare whole.
        ("127.0.0.1", "127.0.0.1", true), ("127.0.0.1", "127.0.0.2", false), ("10.0.0.1", "10.0.0.1", true),
        ("192.168.1.1", "10.168.1.1", false), ("[::1]", "[::1]", true), ("[::1]", "[::2]", false),
        ("[fe80::1]", "fe80.example.com", false), ("127.0.0.1", "localhost", false),
        // localhost and lone labels compare whole.
        ("localhost", "localhost", true), ("localhost", "app.localhost", false), ("intranet", "intranet", true),
        ("intranet", "wiki", false),
    ]

    func testRegistrableDomainTable() {
        XCTAssertGreaterThan(psl.ruleCount, 9000)
        for (a, b, same) in Self.sites {
            // Ports and schemes don't change a site; the order of the two doesn't either.
            let left = URL(string: "https://" + a + "/page")
            let right = URL(string: "http://" + b + ":8080/other?q=1")!
            XCTAssertEqual(LinkRouting.sameSite(left, right, suffixes: psl), same, "\(a) → \(b)")
            XCTAssertEqual(LinkRouting.sameSite(right, URL(string: "https://" + a + ":8443/")!, suffixes: psl), same, "\(b) → \(a)")
        }
    }

    func testRegistrableDomains() {
        let keys: [(String, String)] = [
            ("docs.google.com", "google.com"), ("news.bbc.co.uk", "bbc.co.uk"), ("foo.github.io", "foo.github.io"),
            ("github.io", "github.io"), ("www.alice.blogspot.com", "alice.blogspot.com"), ("shop.bücher.de", "xn--bcher-kva.de"),
            ("example.com..", "example.com"), ("127.0.0.1", "127.0.0.1"), ("[::1]", "::1"), ("localhost", "localhost"),
            ("a.b.ck", "a.b.ck"), ("x.www.ck", "www.ck"),
        ]
        for (host, site) in keys { XCTAssertEqual(BoostDomain.key(forHost: host, suffixes: psl), site, host) }
        XCTAssertNil(psl.registrableDomain("co.uk"))
        XCTAssertNil(psl.registrableDomain("github.io"))
        XCTAssertEqual(psl.registrableDomain("a.co.uk"), "a.co.uk")
    }

    func testNonWebPagesAreNeverTheSameSite() {
        let page = URL(string: "https://a.example.com/")!
        XCTAssertFalse(LinkRouting.sameSite(nil, page, suffixes: psl))
        XCTAssertFalse(LinkRouting.sameSite(URL(string: "about:blank"), page, suffixes: psl))
        XCTAssertFalse(LinkRouting.sameSite(URL(string: "file:///tmp/a.example.com"), page, suffixes: psl))
        XCTAssertFalse(LinkRouting.sameSite(page, URL(string: "mailto:me@a.example.com")!, suffixes: psl))
    }

    // MARK: Air Traffic Control

    let origin = URL(string: "https://www.bbc.co.uk/news")!
    let rules = [LinkRule(pattern: "figma.com", spaceID: "design"),
                 LinkRule(match: .equals, pattern: "news.bbc.co.uk/sport", spaceID: "sport"),
                 LinkRule(pattern: "github.io", spaceID: "gone"),
                 LinkRule(pattern: "foo.github.io", spaceID: "code")]
    let spaces: Set<String> = ["design", "sport", "code"]

    func target(_ to: String, from: URL? = nil, peek: Bool, explicit: Bool = false, fromPeek: Bool = false,
                gesture: Bool = true) -> LinkRouting.PageTarget {
        LinkRouting.pageTarget(from: from ?? origin, to: URL(string: to)!, userGesture: gesture, wantsPeek: peek, explicitPeek: explicit,
                               fromPeek: fromPeek, rules: rules, existingSpaces: spaces, suffixes: psl)
    }

    func testRulesRouteLinksThatWouldOpenInPeek() {
        // A cross-site link from a pinned tab or Favorite: the rule's Space, else Peek.
        XCTAssertEqual(target("https://www.figma.com/file/1", peek: true), .space("design"))
        XCTAssertEqual(target("https://bar.example.org/", peek: true), .peek)
        // The first matching rule whose Space exists ("gone" is passed over).
        XCTAssertEqual(target("https://foo.github.io/x", peek: true), .space("code"))
        XCTAssertEqual(target("https://bar.github.io/x", peek: true), .peek, "github.io matches only a gone Space")
        // A link followed inside Peek consults the rules too; without a match Peek keeps it.
        XCTAssertEqual(target("https://figma.com/", peek: false, fromPeek: true), .space("design"))
        XCTAssertEqual(target("https://bar.example.org/", peek: false, fromPeek: true), .engine)
    }

    func testSameSiteAndOrdinaryLinksNeverConsultTheRules() {
        // Same registrable domain: in place, even when a rule matches it.
        XCTAssertEqual(target("https://news.bbc.co.uk/sport", peek: false), .engine)
        // ⇧-click asked for Peek on the same site: Peek, not the rule's Space.
        XCTAssertEqual(target("https://news.bbc.co.uk/sport", peek: true), .peek)
        // An ordinary tab's link, or a new-tab link (no Peek): the engine, as in Arc.
        XCTAssertEqual(target("https://www.figma.com/file/1", peek: false), .engine)
        // Script navigations and non-web links.
        XCTAssertEqual(target("https://www.figma.com/file/1", peek: true, gesture: false), .engine)
        XCTAssertEqual(target("mailto:hi@example.com", peek: true), .engine)
        // a.co.uk → b.co.uk is cross-site, so a rule for it applies; www.a.co.uk → a.co.uk is not.
        let uk = [LinkRule(pattern: "co.uk", spaceID: "design")]
        let a = URL(string: "https://www.a.co.uk")!
        XCTAssertEqual(LinkRouting.pageTarget(from: a, to: URL(string: "https://b.co.uk")!, userGesture: true, wantsPeek: true,
                                              rules: uk, existingSpaces: spaces, suffixes: psl), .space("design"))
        XCTAssertEqual(LinkRouting.pageTarget(from: a, to: URL(string: "https://a.co.uk/x")!, userGesture: true, wantsPeek: false,
                                              rules: uk, existingSpaces: spaces, suffixes: psl), .engine)
    }

    func testMeetingLinksSkipPeek() {
        // A pinned tab's call link opens in a new tab, as in Arc; ⇧-click still Peeks; a rule still wins.
        XCTAssertEqual(target("https://meet.google.com/abc-defg-hij", peek: true), .newTab)
        XCTAssertEqual(target("https://us02web.zoom.us/j/123456789", peek: true), .newTab)
        XCTAssertEqual(target("https://teams.microsoft.com/l/meetup-join/19%3a", peek: true), .newTab)
        XCTAssertEqual(target("https://meet.google.com/abc-defg-hij", peek: true, explicit: true), .peek)
        XCTAssertEqual(target("https://zoom.us/pricing", peek: true), .peek, "only meeting links")
        XCTAssertEqual(target("https://meet.google.com/abc-defg-hij", peek: false), .engine)
        let zoom = [LinkRule(pattern: "zoom.us/j/", spaceID: "design")]
        XCTAssertEqual(LinkRouting.pageTarget(from: origin, to: URL(string: "https://zoom.us/j/1")!, userGesture: true, wantsPeek: true,
                                              rules: zoom, existingSpaces: spaces, suffixes: psl), .space("design"))
    }

    func testRuleMatching() {
        func m(_ match: LinkRule.Match, _ pattern: String, _ url: String) -> Bool {
            LinkRule(match: match, pattern: pattern, spaceID: "s").matches(URL(string: url)!)
        }
        XCTAssertTrue(m(.contains, "FIGMA.com", "https://www.figma.com/file"))
        XCTAssertTrue(m(.contains, "localhost:3000", "http://localhost:3000/app"))
        XCTAssertFalse(m(.contains, "localhost:3000", "http://localhost:4000/app"))
        XCTAssertTrue(m(.contains, "xn--bcher-kva", "https://xn--bcher-kva.de/"))
        XCTAssertTrue(m(.equals, "news.bbc.co.uk/sport", "https://news.bbc.co.uk/sport/"))
        XCTAssertTrue(m(.equals, "News.BBC.co.uk/sport", "https://news.bbc.co.uk/sport"))
        XCTAssertFalse(m(.equals, "news.bbc.co.uk/sport", "https://news.bbc.co.uk/Sport"))
        XCTAssertFalse(m(.equals, "news.bbc.co.uk", "https://news.bbc.co.uk/sport"))
        XCTAssertTrue(m(.equals, "http://127.0.0.1:8080/", "http://127.0.0.1:8080"))
        XCTAssertFalse(m(.contains, " ", "https://a.test"))
    }

    // MARK: WebKit's clicks named as Chromium names them

    func testWebKitDispositions() {
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: false, command: false, shift: false), "current_tab")
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: true, command: false, shift: false), "foreground_tab")
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: false, command: false, shift: true), "window", "⇧-click: Peek")
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: true, command: false, shift: true), "window")
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: false, command: true, shift: false), "background_tab")
        XCTAssertEqual(LinkRouting.webKitDisposition(newFrame: false, command: true, shift: true), "foreground_tab")
    }
}
