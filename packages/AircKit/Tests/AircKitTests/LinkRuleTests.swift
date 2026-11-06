// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class LinkRuleTests: XCTestCase {
    private let url = { (s: String) in URL(string: s)! }

    func testContainsIsCaseInsensitiveOnTheWholeURL() {
        let r = LinkRule(match: .contains, pattern: "Figma.com/file", spaceID: "s")
        XCTAssertTrue(r.matches(url("https://www.figma.com/file/abc")))
        XCTAssertFalse(r.matches(url("https://www.figma.com/proto/abc")))
        XCTAssertTrue(LinkRule(match: .contains, pattern: "?utm=mail", spaceID: "s").matches(url("https://a.test/x?utm=mail")))
    }

    func testEqualsIgnoresSchemeCaseMissingSchemeAndTrailingSlash() {
        let r = LinkRule(match: .equals, pattern: "Example.org/", spaceID: "s")
        XCTAssertTrue(r.matches(url("https://example.org")))
        XCTAssertTrue(r.matches(url("HTTPS://EXAMPLE.ORG/")))
        XCTAssertFalse(r.matches(url("https://example.org/page")))
        XCTAssertFalse(r.matches(url("http://example.org")), "another scheme is another URL")
        let path = LinkRule(match: .equals, pattern: "https://a.test/Doc", spaceID: "s")
        XCTAssertFalse(path.matches(url("https://a.test/doc")), "the path keeps its case")
    }

    func testEmptyPatternMatchesNothing() {
        XCTAssertFalse(LinkRule(match: .contains, pattern: "  ", spaceID: "s").matches(url("https://a.test")))
        XCTAssertFalse(LinkRule(match: .equals, pattern: "", spaceID: "s").matches(url("https://a.test")))
    }

    func testFirstMatchingRuleWinsAndGoneSpacesArePassedOver() {
        let rules = [LinkRule(pattern: "github.com", spaceID: "gone"),
                     LinkRule(pattern: "github.com/work-org", spaceID: "work"),
                     LinkRule(pattern: "github.com", spaceID: "home")]
        let spaces: Set = ["work", "home"]
        XCTAssertEqual(LinkRouting.space(for: url("https://github.com/work-org/repo"), rules: rules, existingSpaces: spaces), "work")
        XCTAssertEqual(LinkRouting.space(for: url("https://github.com/other"), rules: rules, existingSpaces: spaces), "home")
        XCTAssertNil(LinkRouting.space(for: url("https://gitlab.com"), rules: rules, existingSpaces: spaces))
    }

    func testRulesRoundTripThroughJSON() throws {
        let rules = [LinkRule(id: "1", match: .equals, pattern: "a.test", spaceID: "s")]
        XCTAssertEqual(try JSONDecoder().decode([LinkRule].self, from: JSONEncoder().encode(rules)), rules)
        XCTAssertEqual(try JSONDecoder().decode(ExternalLinkTarget.self, from: Data("\"littleArc\"".utf8)), .littleArc)
    }
}
