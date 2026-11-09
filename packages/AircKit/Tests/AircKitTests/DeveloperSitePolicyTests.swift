// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class DeveloperSitePolicyTests: XCTestCase {
    func testASiteIsTheHostWhateverThePortPathOrScheme() {
        XCTAssertEqual(DeveloperSitePolicy.site(of: "http://user:secret@LocalHost.:3000/a?q=1#x"), "localhost")
        XCTAssertEqual(DeveloperSitePolicy.site(of: "https://[::1]:8443/path"), "::1")
        XCTAssertEqual(DeveloperSitePolicy.site(of: "https://Staging.Example.com/app"), "staging.example.com")
        for url in ["file://localhost/x", "ftp://localhost/x", "about:blank", "data:text/html,x", "localhost:3000", "javascript:1"] {
            XCTAssertNil(DeveloperSitePolicy.site(of: url), url)
        }
    }

    func testLoopbackHostsAreAutomaticAsInArc() {
        for host in ["localhost", "app.localhost", "a.b.localhost", "127.0.0.1", "127.12.0.9", "::1", "::ffff:127.0.0.1", "[::1]"] {
            XCTAssertTrue(DeveloperSitePolicy.isAutomatic(site: host), host)
        }
        for host in [".localhost", "localhost.com", "mylocalhost", "10.0.0.2", "192.168.1.20", "app.test", "server.local", "::2", "example.com"] {
            XCTAssertFalse(DeveloperSitePolicy.isAutomatic(site: host), host)
        }
        let p = DeveloperSitePolicy()
        XCTAssertTrue(p.isOn("http://localhost:3000/"))
        XCTAssertTrue(p.isOn("http://api.localhost:8080/v1"))
        XCTAssertTrue(p.isAutomaticallyOn("http://127.0.0.1:5173/"))
        XCTAssertFalse(p.isOn("https://example.com/"))
        XCTAssertFalse(p.isOn("http://localhost:3000/", automatic: false), "Settings' automatic switch off")
    }

    func testTurningASiteOnOrOffFollowsTheHostEverywhereAndPersists() throws {
        var p = DeveloperSitePolicy()
        XCTAssertEqual(p.set("https://staging.example.com/login", on: true), "staging.example.com")
        XCTAssertTrue(p.isOn("http://staging.example.com:8080/other"), "every port and path of the host")
        XCTAssertFalse(p.isOn("https://example.com/"), "not its parent")
        XCTAssertFalse(p.isOn("https://www.staging.example.com/"), "nor its subdomains")
        XCTAssertFalse(p.isAutomaticallyOn("https://staging.example.com/"))
        // An automatic host turned off stays off on every port, and back on clears that.
        p.set("http://localhost:3000/", on: false)
        XCTAssertFalse(p.isOn("http://localhost:5173/"))
        XCTAssertEqual(p.disabledDefaultHosts, ["localhost"])
        XCTAssertEqual(p.toggle("http://localhost:4000/"), true)
        XCTAssertTrue(p.isOn("http://localhost:3000/") && p.disabledDefaultHosts.isEmpty && !p.enabledHosts.contains("localhost"))
        // With the automatic switch off, turning localhost on pins it on by hand.
        p.set("http://localhost:3000/", on: true, automatic: false)
        XCTAssertTrue(p.isOn("http://localhost:3000/", automatic: false))
        XCTAssertEqual(p.sites, ["localhost", "staging.example.com"])
        // Persisted as sorted lists; read back the same.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(p)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"disabledDefaultHosts":[],"enabledHosts":["localhost","staging.example.com"]}"#)
        XCTAssertEqual(try JSONDecoder().decode(DeveloperSitePolicy.self, from: data), p)
        // With automatic off, turning localhost off just forgets the hand-on: automatic back on, it's on again.
        var q = p
        q.set("http://localhost:3000/", on: false, automatic: false)
        XCTAssertTrue(q.disabledDefaultHosts.isEmpty && !q.enabledHosts.contains("localhost"))
        XCTAssertTrue(q.isOn("http://localhost:3000/"))
        // Remove in Settings: back to the default.
        p.forget(site: "staging.example.com")
        XCTAssertFalse(p.isOn("https://staging.example.com/"))
        XCTAssertNil(p.set("about:blank", on: true))
        XCTAssertNil(p.toggle("data:text/html,x"))
    }

    func testOlderOrNewerFilesStillRead() throws {
        let empty = try JSONDecoder().decode(DeveloperSitePolicy.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
        let odd = try JSONDecoder().decode(DeveloperSitePolicy.self, from: Data(#"{"enabledHosts":["Example.COM.","[::1]",""],"disabledDefaultHosts":7,"later":true}"#.utf8))
        XCTAssertEqual(odd.enabledHosts, ["example.com", "::1"])
        XCTAssertTrue(odd.disabledDefaultHosts.isEmpty)
    }
}
