// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

/// BST-2: what a `.airc-boost` file may hold (256 KB besides its picture, no code from elsewhere), that a Boost with
/// JavaScript is installed off, and the review's syntax colouring.
final class BoostImportRulesTests: XCTestCase {
    override class func setUp() { super.setUp(); TestSuffixes.install() }

    func fixture(js: String = "document.documentElement.dataset.boost = 'on';", css: String = "h1 { color: plum }") -> BoostFile {
        var f = BoostFile(boost: Boost(domain: "example.com", css: css, js: js, created: Date(timeIntervalSince1970: 1700000000)),
                          name: "Plum headings")
        f.id = "7d3c1f0e-5b2a-4c8d-9e6f-0a1b2c3d4e5f"; f.revision = 1; f.author = "Someone"
        return f
    }

    private func json(_ f: BoostFile) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.boosts.encode(f)) as? [String: Any])
    }
    private func decode(_ object: [String: Any]) throws -> BoostFile {
        try BoostFile.decode(JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Size

    func testContentCapIs256KBNotCountingThePicture() throws {
        // 100 KB of CSS and 100 KB of JS: fine. 130 + 130 KB of code passes each field's 128 KB... no: over 256 KB in all.
        XCTAssertNoThrow(try BoostFile.decode(fixture(js: "// " + String(repeating: "a", count: 100 * 1024),
                                                      css: "/* " + String(repeating: "b", count: 100 * 1024) + " */").encoded()))
        var object = try json(fixture(js: "//" + String(repeating: "a", count: 127 * 1024), css: "/*" + String(repeating: "b", count: 127 * 1024) + "*/"))
        object["about"] = String(repeating: "c", count: 200)
        object["name"] = String(repeating: "N", count: 100)
        // 254 KB of code plus the rest: under 256 KB…
        XCTAssertNoThrow(try decode(object))
        // …and a zap list that takes it past 256 KB is refused as too large.
        object["zaps"] = (0..<200).map { ["selector": ".z\($0)-" + String(repeating: "q", count: 40), "label": String(repeating: "L", count: 60)] }
        XCTAssertThrowsError(try decode(object)) { XCTAssertEqual($0 as? BoostFile.Invalid, .size) }
        // A picture doesn't count toward 256 KB: 200 KB of picture beside 200 KB of code is a valid file.
        var withPicture = fixture(js: "//" + String(repeating: "a", count: 100 * 1024), css: "/*" + String(repeating: "b", count: 100 * 1024) + "*/")
        withPicture.preview = Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 7, count: 200 * 1024)).base64EncodedString()
        let data = try withPicture.encoded()
        XCTAssertGreaterThan(data.count, 256 * 1024)
        XCTAssertEqual(try BoostFile.decode(data).previewData?.count, 200 * 1024 + 3)
    }

    func testOversizedFileIsRefusedBeforeParsing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boost-rules-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("huge.airc-boost")
        try Data(repeating: 0x20, count: BoostFile.maximumBytes + 1).write(to: url)
        XCTAssertThrowsError(try BoostFile.read(url)) { XCTAssertEqual($0 as? BoostFile.Invalid, .size) }
        XCTAssertEqual(BoostFile.Invalid.size.errorDescription, "This Boost is too large. A Boost may be at most 256 KB, not counting its picture.")
    }

    func testMalformedFilesAreRefused() throws {
        for text in ["", "{", "[]", "{\"version\":2}", "{\"version\":\"2\"}", "null", "{\"version\":99}"] {
            XCTAssertThrowsError(try BoostFile.decode(Data(text.utf8)), text)
        }
        var object = try json(fixture()); object["js"] = 42
        XCTAssertThrowsError(try decode(object)) { XCTAssertEqual($0 as? BoostFile.Invalid, .format) }
    }

    // MARK: Remote code

    func testRemoteScriptsAreRefused() throws {
        let refused = [
            "const s = document.createElement('script'); s.textContent = 'x'; document.head.append(s);",
            "document.createElementNS('http://www.w3.org/1999/xhtml', \"script\")",
            "document.body.insertAdjacentHTML('beforeend', '<script src=x></script>')",
            "import('https://cdn.example.net/x.js').then(m => m.run())",
            "import { run } from \"https://cdn.example.net/lib.mjs\";\nrun();",
            "import \"//cdn.example.net/side-effect.js\";",
            "importScripts('worker.js')",
            "new Worker('w.js')",
            "navigator.serviceWorker.register('/sw.js')",
            "const src = 'https://cdn.example.net/app.min.js?v=3';",
            "const src = \"//cdn.example.net/app.js\";",
            "location.href = 'javascript:alert(1)'",
        ]
        for js in refused {
            XCTAssertNotNil(BoostFile.remoteScript(js: js, css: ""), js)
            XCTAssertThrowsError(try fixture(js: js).validated(), js) { XCTAssertEqual($0 as? BoostFile.Invalid, .remoteScript) }
            var object = try json(fixture()); object["js"] = js
            XCTAssertThrowsError(try decode(object), js) { XCTAssertEqual($0 as? BoostFile.Invalid, .remoteScript) }
        }
        for css in ["a { background: url('javascript:alert(1)') }", "p { width: expression(alert(1)) }", "b { -moz-binding: url(x.xml#y) }"] {
            XCTAssertNotNil(BoostFile.remoteScript(js: "", css: css), css)
        }
        // Ordinary page code is fine, including addresses that aren't scripts and words that only look like them.
        let allowed = [
            "document.querySelectorAll('a[href$=\".pdf\"]').forEach(a => a.target = '_blank');",
            "const api = 'https://example.com/data.json'; // not a script",
            "const important = 1; // import nothing",
            "document.title = 'scripts and workers'",
            "const tag = document.createElement('style'); tag.textContent = 'h1{}'; document.head.append(tag);",
            "",
        ]
        for js in allowed { XCTAssertNil(BoostFile.remoteScript(js: js, css: "h1 { behaviour-like: none; color: red }"), js) }
        XCTAssertNoThrow(try fixture(js: allowed[0]).encoded())
    }

    func testExportRefusesWhatImportWouldRefuse() {
        XCTAssertThrowsError(try fixture(js: "import('https://cdn.example.net/x.js')").encoded()) {
            XCTAssertEqual($0 as? BoostFile.Invalid, .remoteScript)
        }
    }

    // MARK: Installed off

    func testBoostWithJavaScriptIsInstalledOff() throws {
        let store = BoostStore(url: nil)
        try store.install(fixture())
        let b = try XCTUnwrap(store.boost(domain: "example.com"))
        XCTAssertFalse(b.enabled, "its code runs only once the person turns it on")
        XCTAssertFalse(b.isLive)
        XCTAssertEqual(b.js, fixture().js, "the reviewed code is stored as it was")
        // Turned on, then an update that changes only its style keeps it on.
        store.update(domain: "example.com") { $0.enabled = true }
        var styleOnly = fixture(css: "h1 { color: teal }"); styleOnly.revision = 2
        try store.install(styleOnly, replacing: true)
        XCTAssertEqual(store.boost(domain: "example.com")?.enabled, true)
        // An update that changes the code is off again.
        var newCode = fixture(js: "document.title = 'changed';"); newCode.revision = 3
        try store.install(newCode, replacing: true)
        XCTAssertEqual(store.boost(domain: "example.com")?.enabled, false)
    }

    func testStyleOnlyBoostIsInstalledOn() throws {
        let store = BoostStore(url: nil)
        try store.install(fixture(js: ""))
        XCTAssertEqual(store.boost(domain: "example.com")?.enabled, true)
    }

    func testRoundTripThroughAFileKeepsCodeAndMetadata() throws {
        let f = fixture()
        let back = try BoostFile.decode(f.encoded())
        XCTAssertEqual(back.js, f.js); XCTAssertEqual(back.css, f.css)
        XCTAssertEqual(back.site, "example.com"); XCTAssertEqual(back.author, "Someone"); XCTAssertEqual(back.version, BoostFile.version)
    }

    // MARK: Syntax colouring

    func testTokensCoverEveryCharacterInOrder() {
        let js = "// say hi\nconst s = \"a\\\"b\"; fetch(`/x`); /* c */ let n = 42;\nif (true) eval('1')"
        let t = BoostCodeTokens.tokens(js, .javaScript)
        XCTAssertEqual(t.map(\.text).joined(), js)
        XCTAssertEqual(t.first, .init(kind: .comment, text: "// say hi"))
        XCTAssertTrue(t.contains(.init(kind: .keyword, text: "const")))
        XCTAssertTrue(t.contains(.init(kind: .string, text: "\"a\\\"b\"")))
        XCTAssertTrue(t.contains(.init(kind: .sensitive, text: "fetch")))
        XCTAssertTrue(t.contains(.init(kind: .sensitive, text: "eval")))
        XCTAssertTrue(t.contains(.init(kind: .string, text: "`/x`")))
        XCTAssertTrue(t.contains(.init(kind: .comment, text: "/* c */")))
        XCTAssertTrue(t.contains(.init(kind: .number, text: "42")))
        // Hidden text can't hide here: the file was already refused for it.
        let css = "@media (min-width: 600px) { h1 { color: plum; } } /* end */ a::after { content: 'x' }"
        let c = BoostCodeTokens.tokens(css, .css)
        XCTAssertEqual(c.map(\.text).joined(), css)
        XCTAssertTrue(c.contains(.init(kind: .atRule, text: "@media")))
        XCTAssertTrue(c.contains(.init(kind: .property, text: "color")))
        XCTAssertTrue(c.contains(.init(kind: .number, text: "600px")))
        XCTAssertFalse(c.contains(.init(kind: .property, text: "a")), "selectors outside a block aren't properties")
        XCTAssertTrue(c.contains(.init(kind: .comment, text: "/* end */")))
        // Unterminated strings and comments end at the text's end, never past it.
        for broken in ["'abc", "/* open", "`tpl", "\"\\"] {
            XCTAssertEqual(BoostCodeTokens.tokens(broken, .javaScript).map(\.text).joined(), broken)
        }
    }
}
