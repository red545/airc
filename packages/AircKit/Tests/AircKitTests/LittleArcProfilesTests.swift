// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class LittleArcProfilesTests: XCTestCase {
    func testDomainMemoryPersistencePrecedenceAndMissingProfiles() throws {
        let s = try makeStore()
        let recent = s.selectedSpace.id
        let p = try s.createProfile(name: "Other")
        let other = try s.createSpace(name: "Other", profileID: p.id)
        var memory = LittleArcProfiles()
        memory.remember(p.id, for: URL(string: "https://news.example.co.uk/article"))
        memory = try JSONDecoder().decode(LittleArcProfiles.self, from: JSONEncoder().encode(memory))
        let url = URL(string: "https://mail.example.co.uk/inbox")!
        XCTAssertEqual(memory.space(for: url, rules: [], spaces: s.orderedSpaces, recentSpaceID: recent), other.id)
        XCTAssertEqual(memory.space(for: url, rules: [LinkRule(pattern: "example.co.uk", spaceID: recent)],
                                    spaces: s.orderedSpaces, recentSpaceID: recent), recent)
        XCTAssertEqual(memory.space(for: url, rules: [], spaces: [s.selectedSpace], recentSpaceID: recent), recent)
        XCTAssertEqual(memory.space(for: URL(string: "https://elsewhere.co.uk")!, rules: [], spaces: s.orderedSpaces, recentSpaceID: recent), recent)
    }
    func testPrivateSuffixesAndNonWebURLs() throws {
        var m = LittleArcProfiles()
        m.remember("one", for: URL(string: "https://a.github.io"))
        m.remember("two", for: URL(string: "https://b.github.io"))
        m.remember("no", for: URL(string: "file:///tmp/example"))
        XCTAssertEqual(m.domains, ["a.github.io": "one", "b.github.io": "two"])
    }
}
