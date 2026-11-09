// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class LinkSiteTests: XCTestCase {
    let psl = PublicSuffixList(text: "com\nuk\nco.uk\nio\ngithub.io\n")
    func testSiteIdentity() {
        let cases: [(String, String, Bool)] = [
            ("a.co.uk", "b.co.uk", false), ("www.a.co.uk", "a.co.uk", true),
            ("x.github.io", "y.github.io", false), ("www.x.github.io", "x.github.io", true),
            ("127.0.0.1", "127.0.0.2", false), ("127.0.0.1", "127.0.0.1", true),
            ("[::1]", "[::2]", false), ("[::1]", "[::1]", true),
            ("localhost", "localhost", true), ("a.localhost", "b.localhost", false),
            ("localhost", "other", false), ("bücher.com", "xn--bcher-kva.com", true),
            ("WWW.A.CO.UK.", "a.co.uk", true), ("x.github.io.", "y.github.io", false)
        ]
        for (a, b, same) in cases {
            XCTAssertEqual(LinkRouting.sameSite(URL(string: "https://" + a), URL(string: "http://" + b + ":8080/path")!, suffixes: psl), same, "\(a), \(b)")
        }
        XCTAssertFalse(LinkRouting.sameSite(nil, URL(string: "https://a.co.uk")!, suffixes: psl))
        XCTAssertFalse(LinkRouting.sameSite(URL(string: "about:blank"), URL(string: "file:///tmp/page")!, suffixes: psl))
        XCTAssertFalse(LinkRouting.sameSite(URL(string: "https://www.a.co.uk"), URL(string: "https://a.co.uk")!, suffixes: PublicSuffixList(text: "")))
    }

    func testExplicitRuleBeforePeekAndEngineFallback() {
        let origin = URL(string: "https://a.co.uk")!
        let rules = [LinkRule(pattern: "co.uk", spaceID: "gone"), LinkRule(pattern: "co.uk", spaceID: "design"), LinkRule(pattern: "co.uk", spaceID: "other")]
        func target(_ url: String, peek: Bool = true, fromPeek: Bool = false, gesture: Bool = true,
                    spaces: Set<String> = ["design", "other"]) -> LinkRouting.PageTarget {
            LinkRouting.pageTarget(from: origin, to: URL(string: url)!, userGesture: gesture, wantsPeek: peek, fromPeek: fromPeek,
                                   rules: rules, existingSpaces: spaces, suffixes: psl)
        }
        XCTAssertEqual(target("https://b.co.uk"), .space("design"))
        XCTAssertEqual(target("https://b.co.uk", peek: false), .engine, "Only Peek links consult the rules (Arc)")
        XCTAssertEqual(target("https://b.co.uk", peek: false, fromPeek: true), .space("design"), "A link inside Peek does")
        XCTAssertEqual(target("https://b.co.uk", spaces: []), .peek)
        XCTAssertEqual(target("https://b.co.uk", peek: false, spaces: []), .engine)
        XCTAssertEqual(target("https://www.a.co.uk", peek: false), .engine)
        XCTAssertEqual(target("https://www.a.co.uk"), .peek, "Explicit Shift-click stays Peek on the same site")
        XCTAssertEqual(target("https://b.co.uk", gesture: false), .engine)
        XCTAssertEqual(target("mailto:hello@b.co.uk"), .engine)
    }
}
