// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// The FairPlay bridge's sites, routing and input checks (docs/design/fairplay-bridge.md).
final class FairPlayBridgeTests: XCTestCase {
    func testOrigins() {
        // Spotify plays in WebKit (owner, 2026-11-20): its player takes FairPlay only through Safari's own API.
        XCTAssertEqual(FairPlayBridgeSites.origins, [])
        XCTAssertFalse(FairPlayBridgeSites.routedOrigins.contains("https://open.spotify.com"))
        for o in FairPlayBridgeSites.routedOrigins { XCTAssertEqual(FairPlayBridgeSites.origin(of: o), o, "exact origins only") }
        XCTAssertEqual(FairPlayBridgeSites.origin(of: "https://Open.Spotify.com/track/x?si=1"), "https://open.spotify.com")
        XCTAssertEqual(FairPlayBridgeSites.origin(of: "https://open.spotify.com:443/"), "https://open.spotify.com")
        XCTAssertEqual(FairPlayBridgeSites.origin(of: "https://open.spotify.com:8443/"), "https://open.spotify.com:8443")
        XCTAssertEqual(FairPlayBridgeSites.origin(of: "http://localhost:4321/x"), "http://localhost:4321")
        XCTAssertNil(FairPlayBridgeSites.origin(of: "data:text/html,x"))
        let listed = ["https://open.spotify.com"]
        XCTAssertTrue(FairPlayBridgeSites.serves(origin: "https://open.spotify.com", in: listed))
        for o in ["http://open.spotify.com", "https://spotify.com", "https://accounts.spotify.com", "https://open.spotify.com:8443",
                  "https://open.spotify.com.example.com", "https://evil.example", "", "null"] {
            XCTAssertFalse(FairPlayBridgeSites.serves(origin: o, in: listed), o)
        }
    }

    func testRoutingOffIsTodaysRules() {
        let sites = ProtectedMediaSites()
        XCTAssertTrue(sites.chromiumOrigins.isEmpty)
        XCTAssertEqual(sites.engine(for: "https://open.spotify.com/track/x"), .webKit)
    }

    func testRoutingOnKeepsOnlyTheExactOriginInChromium() {
        var sites = ProtectedMediaSites()
        sites.chromiumOrigins = ["https://open.spotify.com"]
        XCTAssertEqual(sites.engine(for: "https://open.spotify.com/track/x"), .chromium)
        XCTAssertNil(sites.handoff(from: .chromium, to: "https://open.spotify.com/album/y"))
        // Another scheme or port, and the other services, keep today's rules.
        XCTAssertEqual(sites.engine(for: "https://open.spotify.com:8443/"), .webKit)
        XCTAssertEqual(sites.engine(for: "https://www.netflix.com/browse"), .webKit)
        XCTAssertEqual(sites.engine(for: "https://www.disneyplus.com/"), .webKit, "only the listed origins: this test lists Spotify's")
        // Setting "Play DRM sites with Safari's engine" off: Chromium as before.
        sites.isEnabled = false
        XCTAssertEqual(sites.engine(for: "https://www.netflix.com/browse"), .chromium)
    }

    func testThePersonsWebKitChoiceIsKeptPerOrigin() {
        var c = ProtectedMediaChoices().choosing(.webKit, for: "https://www.netflix.com/watch/1")
        XCTAssertEqual(c.webKitOrigins, ["https://www.netflix.com"])
        XCTAssertEqual(c.added, [], "a listed site isn't added again")
        c = c.choosing(.webKit, for: "https://www.netflix.com/browse")
        XCTAssertEqual(c.webKitOrigins, ["https://www.netflix.com"], "once")
        let data = try! JSONEncoder().encode(c)
        XCTAssertEqual(try! JSONDecoder().decode(ProtectedMediaChoices.self, from: data), c)
        c = c.choosing(.chromium, for: "https://www.netflix.com/")
        XCTAssertEqual(c.webKitOrigins, [])
        XCTAssertEqual(ProtectedMediaChoices().choosing(.webKit, for: "https://open.spotify.com/").webKitOrigins, [],
                       "Spotify isn't a bridge site: nothing to remember")
        // A file from before the bridge reads with none.
        let old = try! JSONDecoder().decode(ProtectedMediaChoices.self, from: Data(#"{"added":[],"removed":[],"told":["Spotify"]}"#.utf8))
        XCTAssertEqual(old.webKitOrigins, [])
        XCTAssertEqual(old.telling("Netflix").webKitOrigins, [])
        XCTAssertEqual(ProtectedMediaChoices().choosing(.webKit, for: "https://example.com/").webKitOrigins, [])
    }

    func testPlaylistsNameOnlyRemoteMedia() {
        let good = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://abc",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXT-X-MAP:URI="https://audio.example.com/init.mp4"
        #EXTINF:10,
        https://audio.example.com/seg1.mp4
        """
        XCTAssertTrue(FairPlayBridgeSites.isRemotePlaylist(good))
        XCTAssertEqual(FairPlayBridgeSites.keyURI(in: good), "skd://abc")
        for bad in [good.replacingOccurrences(of: "https://audio.example.com/seg1", with: "file:///etc/passwd"),
                    good.replacingOccurrences(of: "https://audio.example.com/seg1", with: "http://audio.example.com/seg1"),
                    good.replacingOccurrences(of: "https://audio.example.com/init", with: "skd://init"),
                    good.replacingOccurrences(of: "https://audio.example.com/seg1.mp4", with: "seg1.mp4"),
                    good.replacingOccurrences(of: "#EXTM3U", with: "#EXT"),
                    good.replacingOccurrences(of: "init.mp4\"", with: "init.mp4"),
                    "#EXTM3U\n" + String(repeating: "#", count: FairPlayBridgeSites.maxPlaylist)] {
            XCTAssertFalse(FairPlayBridgeSites.isRemotePlaylist(bad), bad.prefix(200).description)
        }
        // A test's loopback origin may serve plain http segments, and only that origin.
        let local = "#EXTM3U\n#EXTINF:4,\nhttp://localhost:4321/a.aac\n"
        XCTAssertFalse(FairPlayBridgeSites.isRemotePlaylist(local))
        XCTAssertTrue(FairPlayBridgeSites.isRemotePlaylist(local, allowing: ["http://localhost:4321"]))
        XCTAssertFalse(FairPlayBridgeSites.isRemotePlaylist(local, allowing: ["http://localhost:4322"]))
        XCTAssertFalse(FairPlayBridgeSites.isRemotePlaylist("#EXTM3U\nhttp://localhost:43210/a\n", allowing: ["http://localhost:4321"]))
        XCTAssertNil(FairPlayBridgeSites.keyURI(in: local))
    }

    /// The user doc names exactly the bridge's sites.
    func testUserDocListsTheOrigins() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/user/protected-media.md"), encoding: .utf8)
        guard let start = doc.range(of: "<!-- fairplay-bridge-origins -->"), let end = doc.range(of: "<!-- /fairplay-bridge-origins -->") else {
            return XCTFail("docs/user/protected-media.md has no fairplay-bridge-origins list")
        }
        let listed = doc[start.upperBound..<end.lowerBound].components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`,.")) }.filter { $0.hasPrefix("https://") }
        XCTAssertEqual(listed, FairPlayBridgeSites.routedOrigins)
    }
}
