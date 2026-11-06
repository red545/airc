// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Which engine plays a page in the Chromium build (ProtectedMediaSites; docs/user/protected-media.md).
final class ProtectedMediaTests: XCTestCase {
    private let sites = ProtectedMediaSites()

    func testListedServicesOpenInWebKit() {
        for url in ["https://open.spotify.com/", "https://open.spotify.com/track/abc", "https://www.netflix.com/browse",
                    "https://netflix.com", "https://www.disneyplus.com/", "https://play.max.com/", "https://www.hbomax.com/",
                    "https://www.primevideo.com/", "https://www.hulu.com/", "https://www.paramountplus.com/",
                    "https://www.peacocktv.com/", "https://tv.apple.com/", "https://music.apple.com/us/browse",
                    "https://listen.tidal.com/", "https://www.deezer.com/de/", "https://deezer.com/",
                    "https://www.crunchyroll.com/", "https://www.joyn.de/", "https://joyn.at/", "https://www.joyn.ch/play",
                    "https://www.rakuten.tv/de", "HTTPS://OPEN.SPOTIFY.COM/album/x", "https://open.spotify.com./"] {
            XCTAssertEqual(sites.engine(for: url), .webKit, url)
        }
    }

    func testEverythingElseStaysInChromium() {
        for url in ["https://www.spotify.com/", "https://spotify.com/", "https://www.google.com/search?q=netflix.com",
                    "https://apple.com/", "https://www.apple.com/tv/", "https://developer.apple.com/", "https://tidal.com/",
                    "https://example.com/?u=https://open.spotify.com", "https://notnetflix.com/", "https://netflix.com.evil.example/",
                    "https://notjoyn.de/", "https://joyn.de.evil.com/", "about:blank", "chrome://settings", "file:///tmp/a.html",
                    "data:text/html,netflix.com", "", "not a url"] {
            XCTAssertEqual(sites.engine(for: url), .chromium, url)
        }
    }

    func testAmazonOnlyAtPrimeVideoAndMusic() {
        for url in ["https://www.amazon.com/gp/video/storefront", "https://amazon.com/gp/video", "https://www.amazon.de/gp/video/detail/B0",
                    "https://www.amazon.co.uk/gp/video/", "https://www.amazon.co.jp/gp/video/x", "https://music.amazon.com/",
                    "https://music.amazon.de/albums/x", "https://music.amazon.co.uk/", "https://music.amazon.com.au/"] {
            XCTAssertEqual(sites.engine(for: url), .webKit, url)
        }
        for url in ["https://www.amazon.com/", "https://www.amazon.com/dp/B0", "https://www.amazon.com/gp/videos",
                    "https://www.amazon.com/ap/signin?openid=x", "https://www.amazon.de/gp/cart", "https://amazon.evil.com/gp/video",
                    "https://amazon.com.evil.net/gp/video", "https://www.amazon.example/gp/videox", "https://aws.amazon.com/"] {
            XCTAssertEqual(sites.engine(for: url), .chromium, url)
        }
        XCTAssertEqual(sites.serviceName(for: "https://www.amazon.fr/gp/video/"), "Prime Video")
        XCTAssertEqual(sites.serviceName(for: "https://music.amazon.it/"), "Amazon Music")
    }

    func testSignInHostsFinishWhereTheyStarted() {
        for url in ["https://accounts.spotify.com/login", "https://login.tidal.com/authorize", "https://connect.deezer.com/oauth",
                    "https://account.deezer.com/"] {
            XCTAssertEqual(sites.engine(for: url), .chromium, "a page Airc opens: \(url)")
            XCTAssertNil(sites.handoff(from: .chromium, to: url), "a Chromium page's sign-in stays: \(url)")
            XCTAssertEqual(sites.engine(forAddressBar: url, current: .webKit), .webKit, "typed on a WebKit page: \(url)")
            XCTAssertEqual(sites.engine(forAddressBar: url, current: .chromium), .chromium, url)
        }
        // deezer.com is listed whole, its sign-in hosts aren't.
        XCTAssertEqual(sites.engine(for: "https://www.deezer.com/"), .webKit)
    }

    func testHandoffOnlyForAChromiumPagesGet() {
        XCTAssertEqual(sites.handoff(from: .chromium, to: "https://open.spotify.com/track/1"), .webKit)
        XCTAssertEqual(sites.handoff(from: .chromium, to: "https://open.spotify.com/track/1", method: "get"), .webKit)
        XCTAssertNil(sites.handoff(from: .chromium, to: "https://open.spotify.com/", method: "POST"), "a POST's body can't move")
        XCTAssertNil(sites.handoff(from: .chromium, to: "https://example.com/"))
        // A WebKit page stays WebKit for its own navigations, wherever they go.
        XCTAssertNil(sites.handoff(from: .webKit, to: "https://accounts.google.com/"))
        XCTAssertNil(sites.handoff(from: .webKit, to: "https://open.spotify.com/"))
    }

    func testTheAddressBarPicksAgain() {
        XCTAssertEqual(sites.engine(forAddressBar: "https://example.com/", current: .webKit), .chromium)
        XCTAssertEqual(sites.engine(forAddressBar: "https://www.netflix.com/", current: .chromium), .webKit)
        XCTAssertEqual(sites.engine(forAddressBar: "https://www.netflix.com/", current: .webKit), .webKit)
    }

    func testOffMeansChromiumEverywhere() {
        let off = ProtectedMediaSites(isEnabled: false)
        XCTAssertEqual(off.engine(for: "https://open.spotify.com/"), .chromium)
        XCTAssertNil(off.handoff(from: .chromium, to: "https://www.netflix.com/"))
        XCTAssertNil(off.serviceName(for: "https://www.netflix.com/"))
    }

    func testExtraHostsForTestsAndRemovals() {
        let test = ProtectedMediaSites(extraHosts: ["localhost", " Example.ORG/ ", "https://media.example.net/x"])
        XCTAssertEqual(test.engine(for: "http://localhost:8123/page.html"), .webKit)
        XCTAssertEqual(test.engine(for: "http://127.0.0.1:8123/page.html"), .chromium, "another site of the same server")
        XCTAssertEqual(test.engine(for: "https://www.example.org/"), .webKit)
        XCTAssertEqual(test.engine(for: "https://media.example.net/"), .webKit, "a URL adds its host")
        XCTAssertEqual(test.serviceName(for: "http://localhost:8123/"), "localhost", "an added host names itself")
        let removed = ProtectedMediaSites(removedHosts: ["netflix.com"])
        XCTAssertEqual(removed.engine(for: "https://www.netflix.com/"), .chromium)
        XCTAssertEqual(removed.engine(for: "https://www.disneyplus.com/"), .webKit)
        // No duplicates, nothing that isn't a host.
        let messy = ProtectedMediaSites(extraHosts: ["netflix.com", "", "  ", "a b", "x.com/?q"])
        XCTAssertEqual(messy.entries.count, ProtectedMediaSites.defaultEntries.count)
    }

    func testServiceNames() {
        XCTAssertEqual(sites.serviceName(for: "https://open.spotify.com/track/1"), "Spotify")
        XCTAssertEqual(sites.serviceName(for: "https://www.disneyplus.com/"), "Disney+")
        XCTAssertEqual(sites.serviceName(for: "https://www.joyn.at/"), "Joyn")
        XCTAssertNil(sites.serviceName(for: "https://example.com/"))
        for entry in ProtectedMediaSites.defaultEntries {
            XCTAssertNotNil(ProtectedMediaSites.serviceNames[entry], "every listed service has a name: \(entry)")
        }
    }

    func testChoosingAnEngineForASite() {
        // A listed site sent back to Chromium, then to WebKit again.
        var c = ProtectedMediaChoices().choosing(.chromium, for: "https://www.netflix.com/browse")
        XCTAssertEqual(c.removed, ["netflix.com"])
        XCTAssertEqual(ProtectedMediaSites(removedHosts: c.removed).engine(for: "https://www.netflix.com/"), .chromium)
        c = c.choosing(.webKit, for: "https://www.netflix.com/title/1")
        XCTAssertEqual(c.removed, [])
        XCTAssertEqual(c.added, [], "a listed site needs no entry of its own")
        // Another site that asked for Widevine, sent to WebKit and back.
        c = c.choosing(.webKit, for: "https://player.example.com/watch")
        XCTAssertEqual(c.added, ["player.example.com"])
        XCTAssertEqual(ProtectedMediaSites(extraHosts: c.added).engine(for: "https://player.example.com/x"), .webKit)
        c = c.choosing(.chromium, for: "https://player.example.com/watch")
        XCTAssertEqual(c.added, [])
        XCTAssertEqual(c.removed, [])
        // Not a web page: nothing changes.
        XCTAssertEqual(c.choosing(.webKit, for: "about:blank"), c)
    }

    func testChoicesFileRoundTripsAndToleratesOldFiles() throws {
        let c = ProtectedMediaChoices(added: ["a.example"], removed: ["netflix.com"]).telling("Spotify").telling("Spotify")
        XCTAssertEqual(c.told, ["Spotify"])
        let back = try JSONDecoder().decode(ProtectedMediaChoices.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let old = try JSONDecoder().decode(ProtectedMediaChoices.self, from: Data(#"{"told":["Netflix"]}"#.utf8))
        XCTAssertEqual(old, ProtectedMediaChoices(told: ["Netflix"]))
    }
}
