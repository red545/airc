// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// The source tree's public suffix list (the app reads its bundled copy): every test that keys sites installs it.
enum TestSuffixes {
    static let list: PublicSuffixList = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/public_suffix_list.dat")
        guard let data = try? Data(contentsOf: url) else { fatalError("no public suffix list at \(url.path)") }
        return PublicSuffixList(data: data)
    }()

    static func install() { PublicSuffixList.use(list) }
}

final class PublicSuffixListTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestSuffixes.install()
    }

    /// Expected keys from an independent implementation of the list's algorithm (Python, on the same file).
    static let sites: [(String, String?)] = [
        // Private suffixes: every tenant is its own site (review1, finding 1).
        ("victim.duckdns.org", "victim.duckdns.org"), ("attacker.duckdns.org", "attacker.duckdns.org"),
        ("x.victim.duckdns.org", "victim.duckdns.org"), ("duckdns.org", "duckdns.org"),
        ("victim.uk.com", "victim.uk.com"), ("attacker.uk.com", "attacker.uk.com"), ("uk.com", "uk.com"),
        ("alice.github.io", "alice.github.io"), ("github.io", "github.io"),
        ("foo.blogspot.com", "foo.blogspot.com"), ("blogspot.com", "blogspot.com"),
        ("bucket.s3.amazonaws.com", "bucket.s3.amazonaws.com"), ("www.amazonaws.com", "amazonaws.com"),
        ("x.compute.amazonaws.com", "x.compute.amazonaws.com"),
        // Wildcards and their exceptions.
        ("a.b.ck", "a.b.ck"), ("x.a.b.ck", "a.b.ck"), ("b.ck", "b.ck"), ("www.ck", "www.ck"), ("a.www.ck", "www.ck"),
        ("ck", "ck"), ("a.b.kawasaki.jp", "a.b.kawasaki.jp"), ("city.kawasaki.jp", "city.kawasaki.jp"),
        ("www.city.kawasaki.jp", "city.kawasaki.jp"),
        // ICANN second levels.
        ("a.b.c.d.e.example.co.uk", "example.co.uk"), ("co.uk", "co.uk"), ("www.abc.net.au", "abc.net.au"),
        // Internationalised names: punycode, from Unicode or as the engine gives them.
        ("www.例子.中国", "xn--fsqu00a.xn--fiqs8s"), ("例子.公司.cn", "xn--fsqu00a.xn--55qx5d.cn"),
        ("www.例子.公司.cn", "xn--fsqu00a.xn--55qx5d.cn"), ("xn--fsqu00a.xn--55qx5d.cn", "xn--fsqu00a.xn--55qx5d.cn"),
        ("www.bücher.de", "xn--bcher-kva.de"),
        // Addresses, lone labels, unknown top-level domains (the list's default rule).
        ("::1", "::1"), ("[::1]", "::1"), ("[fe80::1]", "fe80::1"), ("192.168.0.1", "192.168.0.1"),
        ("localhost", "localhost"), ("a.localhost", "a.localhost"), ("b.a.localhost", "a.localhost"),
        ("my.lan", "my.lan"), ("nas.my.lan", "my.lan"),
    ]

    func testTheWholeListKeysSites() {
        XCTAssertGreaterThan(TestSuffixes.list.ruleCount, 9000, "ICANN and private sections")
        for (host, site) in Self.sites {
            XCTAssertEqual(BoostDomain.key(forHost: host), site, host)
        }
    }

    func testPunycode() {
        for (unicode, ace) in [("рф", "p1ai"), ("公司", "55qx5d"), ("中国", "fiqs8s"), ("例子", "fsqu00a"), ("ελ", "qxam"),
                               ("bücher", "bcher-kva"), ("münchen", "mnchen-3ya")] {
            XCTAssertEqual(PublicSuffixList.punycode(unicode), ace, unicode)
        }
        XCTAssertEqual(PublicSuffixList.ascii("www.例子.公司.cn"), "www.xn--fsqu00a.xn--55qx5d.cn")
        XCTAssertEqual(PublicSuffixList.ascii("plain.example"), "plain.example")
    }

    func testExactHostsAndTheRulesBeneathASite() {
        for exact in ["github.io", "duckdns.org", "co.uk", "localhost", "127.0.0.1", "::1", "b.ck"] {
            XCTAssertTrue(BoostDomain.isExactHost(exact), exact)
        }
        for site in ["nytimes.com", "victim.duckdns.org", "www.ck", "amazonaws.com", "app.localhost"] {
            XCTAssertFalse(BoostDomain.isExactHost(site), site)
        }
        XCTAssertTrue(BoostDomain.otherSitesBeneath("nytimes.com").isEmpty)
        let aws = BoostDomain.otherSitesBeneath("amazonaws.com")
        XCTAssertTrue(aws.contains("s3.amazonaws.com") && aws.contains("*.compute.amazonaws.com"), "\(aws.prefix(5))")
        XCTAssertTrue(BoostDomain.otherSitesBeneath("github.io").isEmpty, "an exact host has no subdomains to rule out")
        XCTAssertEqual(Set(TestSuffixes.list.rules(beneath: "ck")), ["*.ck", "!www.ck"])
    }

    func testLegacySharedKeys() {
        for shared in ["duckdns.org", "uk.com", "github.io", "b.ck", "amazonaws.com", "kawasaki.jp"] {
            XCTAssertTrue(BoostDomain.isSharedLegacyKey(shared), shared)
        }
        for own in ["nytimes.com", "127.0.0.1", "localhost", "victim.duckdns.org", "bbc.co.uk", "::1"] {
            XCTAssertFalse(BoostDomain.isSharedLegacyKey(own), own)
        }
    }

    /// No list in the app: never a shared site, every host its own.
    func testWithoutAListEveryHostIsItsOwnSite() {
        let none = PublicSuffixList(text: "")
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(BoostDomain.key(forHost: "www.nytimes.com", suffixes: none), "www.nytimes.com")
        XCTAssertEqual(BoostDomain.key(forHost: "victim.duckdns.org", suffixes: none), "victim.duckdns.org")
        XCTAssertTrue(BoostDomain.isExactHost("nytimes.com", suffixes: none))
        XCTAssertFalse(BoostDomain.isSharedLegacyKey("duckdns.org", suffixes: none))
    }

    func testParsingTheWholeListIsQuick() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/public_suffix_list.dat")
        let data = try Data(contentsOf: url)
        let start = Date()
        let list = PublicSuffixList(data: data)
        let ms = Date().timeIntervalSince(start) * 1000
        print("public suffix list: \(list.ruleCount) rules parsed in \(String(format: "%.1f", ms)) ms")
        XCTAssertEqual(list.registrableDomain("a.victim.duckdns.org"), "victim.duckdns.org")
        XCTAssertNil(list.registrableDomain("duckdns.org"))
    }
}
