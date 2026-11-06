// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// MEM-3's never-unload list (KeepLoadedSites): which pages of pinned tabs and Favorites stay loaded.
final class KeepLoadedSitesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestSuffixes.install()
    }

    private func keeps(_ url: String, extra: [String] = []) -> Bool {
        KeepLoadedSites.keepsLoaded(URL(string: url), extra: extra, suffixes: TestSuffixes.list)
    }

    func testListedSitesAndHosts() {
        for url in [
            "https://mail.google.com/mail/u/0/#inbox", "https://calendar.google.com/calendar/u/0/r",
            "https://app.slack.com/client/T0/C0", "https://acme.slack.com/messages", "https://slack.com/",
            "https://discord.com/channels/@me", "https://ptb.discord.com/app", "https://web.whatsapp.com/",
            "https://teams.microsoft.com/v2/", "https://teams.live.com/", "https://outlook.office.com/mail/",
            "https://outlook.live.com/mail/0/", "https://outlook.office365.com/owa/", "https://www.messenger.com/t/1",
            "https://linear.app/acme/inbox", "https://meet.google.com/abc-defg-hij", "https://web.telegram.org/a/",
            "http://mail.google.com/", "https://MAIL.Google.COM./mail", "https://mail.google.com:443/",
        ] {
            XCTAssertTrue(keeps(url), url)
        }
    }

    /// Other pages of a listed host's site, look-alikes, and other kinds of address stay on the timer.
    func testOtherPagesUnload() {
        for url in [
            "https://www.google.com/search?q=mail", "https://google.com/", "https://docs.google.com/document/d/1",
            "https://www.youtube.com/", "https://whatsapp.com/", "https://www.whatsapp.com/download", "https://microsoft.com/",
            "https://www.microsoft.com/teams", "https://office.com/", "https://live.com/",
            "https://notslack.com/", "https://slack.com.example.io/", "https://mail.google.com.example.com/",
            "https://example.com/mail.google.com", "https://evil-discord.com/", "https://discord.gg/abc",
            "file:///Users/me/mail.google.com.html", "data:text/html,slack.com", "about:blank", "chrome://settings",
            "https://127.0.0.1/", "http://localhost:8080/", "",
        ] {
            XCTAssertFalse(keeps(url), url)
        }
        XCTAssertFalse(KeepLoadedSites.keepsLoaded(nil, suffixes: TestSuffixes.list))
    }

    /// A tenant of a private suffix is its own site, never its neighbour's (the reason the list goes through the PSL).
    func testPrivateSuffixTenantsAreTheirOwnSites() {
        let extra = ["alice.github.io", "victim.duckdns.org"]
        XCTAssertTrue(keeps("https://alice.github.io/inbox", extra: extra))
        XCTAssertTrue(keeps("https://x.victim.duckdns.org/", extra: extra))
        XCTAssertFalse(keeps("https://bob.github.io/", extra: extra))
        XCTAssertFalse(keeps("https://attacker.duckdns.org/", extra: extra))
        XCTAssertFalse(keeps("https://github.io/", extra: extra))
    }

    /// The scripted checks list a loopback host: a lone label and an address are their own sites, exactly.
    func testExtraLoopbackHosts() {
        XCTAssertTrue(keeps("http://localhost:51234/chat", extra: ["localhost"]))
        XCTAssertFalse(keeps("http://127.0.0.1:51234/chat", extra: ["localhost"]))
        XCTAssertTrue(keeps("http://127.0.0.1:51234/chat", extra: ["127.0.0.1"]))
        XCTAssertFalse(keeps("http://localhost:51234/chat", extra: ["127.0.0.1"]))
        // The built-in entries still apply alongside the extra ones.
        XCTAssertTrue(keeps("https://mail.google.com/", extra: ["localhost"]))
    }

    /// Every built-in entry is a site, or a host beneath its site; none is a public suffix (which would cover every
    /// tenant under it) or an address, and none repeats.
    func testEntriesAreSitesOrHostsBeneathThem() {
        let list = TestSuffixes.list
        XCTAssertEqual(Set(KeepLoadedSites.entries).count, KeepLoadedSites.entries.count)
        for e in KeepLoadedSites.entries {
            XCTAssertEqual(e, e.lowercased(), e)
            XCTAssertFalse(list.isPublicSuffix(e), "\(e) is a public suffix")
            XCTAssertFalse(BoostDomain.isAddress(e), e)
            guard let site = BoostDomain.key(forHost: e, suffixes: list) else { return XCTFail("\(e): no site") }
            XCTAssertTrue(e == site || e.hasSuffix("." + site), "\(e) isn't beneath its site \(site)")
            XCTAssertTrue(keeps("https://" + e + "/"), e)
        }
    }

    func testListedSite() {
        XCTAssertEqual(KeepLoadedSites.listedSite(URL(string: "https://acme.slack.com/x"), suffixes: TestSuffixes.list), "slack.com")
        XCTAssertEqual(KeepLoadedSites.listedSite(URL(string: "https://mail.google.com/"), suffixes: TestSuffixes.list), "google.com")
        XCTAssertNil(KeepLoadedSites.listedSite(URL(string: "https://www.google.com/"), suffixes: TestSuffixes.list))
    }

    /// Without a suffix list every host is its own site: only the exact listed hosts match (never more than listed).
    func testWithoutAList() {
        let none = PublicSuffixList(text: "")
        XCTAssertTrue(KeepLoadedSites.keepsLoaded(URL(string: "https://mail.google.com/"), suffixes: none))
        XCTAssertTrue(KeepLoadedSites.keepsLoaded(URL(string: "https://slack.com/"), suffixes: none))
        XCTAssertFalse(KeepLoadedSites.keepsLoaded(URL(string: "https://www.google.com/"), suffixes: none))
        XCTAssertFalse(KeepLoadedSites.keepsLoaded(URL(string: "https://slack.com.example.io/"), suffixes: none))
    }
}
