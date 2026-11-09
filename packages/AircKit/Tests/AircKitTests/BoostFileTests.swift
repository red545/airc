// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

final class BoostFileTests: XCTestCase {
    override class func setUp() { super.setUp(); TestSuffixes.install() }

    func fixture() -> BoostFile {
        BoostFile(boost: Boost(domain: "alice.github.io", colors: .init(tint: 0.2), font: .init(family: .charter, size: 1),
                               zaps: [.init(selector: ".ad", label: "Ad")], css: "body { color: purple }",
                               js: "document.title = 'Hello';", scriptHost: "www.alice.github.io",
                               created: Date(timeIntervalSince1970: 1700000000)), name: "Quiet reading")
    }
    func testCombiningMarksCannotBypassReviewTextLimits() throws {
        var f = fixture()
        f.name = "a" + String(repeating: "\u{301}", count: 121)
        XCTAssertThrowsError(try f.validated())
        f = fixture()
        f.zaps[0].label = "a" + String(repeating: "\u{301}", count: 81)
        XCTAssertThrowsError(try f.validated())
    }
    func testRoundTrip() throws {
        let f = fixture()
        XCTAssertEqual(try BoostFile.decode(f.encoded()), f)
        XCTAssertEqual(f.boost.scriptHost, "www.alice.github.io")
    }
    func testRejects() throws {
        let data = try fixture().encoded()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func rejects(_ edit: (inout [String: Any]) -> Void) throws {
            var object = base; edit(&object)
            XCTAssertThrowsError(try BoostFile.decode(JSONSerialization.data(withJSONObject: object)))
        }
        XCTAssertThrowsError(try BoostFile.decode(Data(repeating: 32, count: BoostFile.maximumBytes + 1)))
        try rejects { $0["version"] = 3 }
        try rejects { $0["extra"] = true }
        try rejects { $0["name"] = "A\nB" }
        try rejects { $0["createdAt"] = "yesterday" }
        try rejects { $0["zaps"] = [["selector": "body", "label": "all", "unknown": 1]] }
        try rejects { $0["colors"] = ["hue": NSNull(), "tint": 0, "brightness": 1, "contrast": 1, "invert": false] }
        try rejects { $0["colors"] = ["surprise": true] }
        try rejects { $0["font"] = ["size": 0, "unknown": 0] }
        try rejects { $0["js"] = String(repeating: "a", count: 128 * 1024 + 1) }
        try rejects { $0["scriptHost"] = "bob.github.io" }
        for site in ["github.io", "www.example.com", "localhost", "127.0.0.1", "https://example.com", "a..com", "-bad.com", "example.com/path"] {
            try rejects { $0["site"] = site }
        }
        try rejects { $0["colors"] = ["hue": 0, "tint": 8, "brightness": 1, "contrast": 1, "invert": false] }
        XCTAssertThrowsError(try BoostFile.decode(Data("not JSON".utf8)))
        // Code the review would show reordered (Trojan Source) or not at all.
        try rejects { $0["js"] = "var ok = true; /* \u{202E} } \u{2066}if (ok)\u{2069} \u{2066} */ steal();" }
        try rejects { $0["js"] = "a\u{0}b" }
        try rejects { $0["css"] = "body { color: red } /* \u{2067} */" }
        try rejects { $0["css"] = "body \u{200F}{ color: red }" }
        try rejects { $0["zaps"] = [["selector": ".ad", "label": "Ad\nHide the login form"]] }
        try rejects { $0["zaps"] = [["selector": ".ad", "label": "\u{202E}dA"]] }
        try rejects { $0["name"] = "Quiet \u{202E}gnidaer" }
    }

    func testCodeKeepsTabsLineBreaksAndOtherScripts() throws {
        var f = fixture()
        f.js = "document.title = 'שלום';\n\tconsole.log('👨‍👩‍👧');\r\n"
        f.css = "body::before {\n\tcontent: \"مرحبا\";\n}"
        XCTAssertEqual(try BoostFile.decode(f.encoded()), f)
    }
    func testReplacementRequiresConsentAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BoostStore(url: url)
        let f = fixture()
        store.update(domain: f.site) { $0.css = "old" }
        XCTAssertThrowsError(try store.install(f))
        XCTAssertEqual(store.boost(domain: f.site)?.css, "old")
        try store.install(f, replacing: true)
        XCTAssertEqual(store.all.count, 1)
        XCTAssertEqual(store.boost(domain: f.site)?.js, f.js)
        XCTAssertTrue(store.flush())
        XCTAssertEqual(BoostStore(url: url).boost(domain: f.site)?.name, f.name)
    }
}
