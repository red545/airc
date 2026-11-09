// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import JavaScriptCore
import XCTest
@testable import AircKit

/// P07/P05: Arc's page palette as CSS, and the page script part that puts it on pages.
final class ThemeCSSTests: XCTestCase {
    static let names = ["foregroundPrimary", "foregroundSecondary", "foregroundTertiary", "maxContrastColor", "minContrastColor",
                        "backgroundExtra", "background", "focus", "hover", "cutoutColor", "title", "subtitle"]

    static func palette(_ bg: String) -> ThemeCSS.Palette {
        ThemeCSS.Palette(palette: names.map { ($0, $0 == "background" ? bg : "#101010") }, simple: bg,
                         gradient: ["#aa0000", "#00aa00", "#0000aa"], overlay: ["rgba(1, 2, 3, 0.5)", "rgba(1, 2, 3, 0.5)", "rgba(1, 2, 3, 0.5)"])
    }

    func testArcsNamesAndValues() {
        let css = Self.palette("#f4efe9").css
        XCTAssertTrue(css.hasPrefix(":where(:root) { "), "a page's own :root value of the same name wins")
        for n in Self.names { XCTAssertTrue(css.contains("--arc-palette-\(n): "), n) }
        XCTAssertTrue(css.contains("--arc-palette-background: #f4efe9;"))
        XCTAssertTrue(css.contains("--arc-background-simple-color: #f4efe9;"))
        for i in 0..<3 {
            XCTAssertTrue(css.contains("--arc-background-gradient-color\(i): "), "\(i)")
            XCTAssertTrue(css.contains("--arc-background-gradient-overlay-color\(i): rgba("), "\(i)")
        }
        XCTAssertEqual(Self.palette("#fff").variables.count, 12 + 1 + 3 + 3)
        XCTAssertFalse(css.contains("{ --") && css.contains("}\n"), "one rule")
    }

    func testColoursAndKeys() {
        XCTAssertEqual(ThemeCSS.color(red: 1, green: 0.5, blue: 0), "#ff8000")
        XCTAssertEqual(ThemeCSS.color(red: 0, green: 0, blue: 0, alpha: 0.5), "rgba(0, 0, 0, 0.5)")
        XCTAssertEqual(ThemeCSS.color(red: 2, green: -1, blue: 0.2, alpha: 1), "#ff0033", "clamped")
        XCTAssertEqual(ThemeCSS.key(0), "pa")
        XCTAssertEqual(ThemeCSS.key(25), "pz")
        XCTAssertEqual(ThemeCSS.key(26), "pba")
        for n in [0, 1, 25, 26, 675, 676, 100_000] { XCTAssertTrue(ThemeCSS.isKey(ThemeCSS.key(n)), "\(n)") }
        XCTAssertEqual(Set((0..<2000).map(ThemeCSS.key)).count, 2000, "every key is its own")
        for bad in ["", "Pa", "p1", "p-a", String(repeating: "a", count: 17), "pä"] { XCTAssertFalse(ThemeCSS.isKey(bad), bad) }
    }

    // MARK: The page script part

    static func page(_ palettes: [String: ThemeCSS.Palette], data: Any?, top: Bool = true, scheme: String = "https:") throws -> JSContext {
        let script = try XCTUnwrap(PageScriptComposer.compose(parts: [(ThemeCSS.part, ThemeCSS.source(palettes: palettes))], base: nil))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(BoostTests.fakePage)
        if !top { js.evaluateScript("window.top = {};") }
        js.evaluateScript("var location = \(ThemeCSS.json(["protocol": scheme, "hostname": "example.com", "origin": "https://example.com"]));")
        let arg = data.map { ThemeCSS.json($0) } ?? "undefined"
        js.evaluateScript("var receive = (\(script))(function (kind, json) { posted.push([kind, json]); }, \(arg));")
        XCTAssertNil(js.exception, "\(js.exception!)")
        return js
    }

    static func ready(_ js: JSContext) -> [String: Any] {
        let s = js.evaluateScript("(function () { for (var i = posted.length - 1; i >= 0; i--) if (posted[i][0] === 'theme.ready') return posted[i][1]; return 'null'; })()")?.toString() ?? "null"
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    func testTheEnginesKeyGivesThePaletteAtDocumentStart() throws {
        let palettes = ["pa": Self.palette("#111111"), "pb": Self.palette("#eeeeee")]
        let js = try Self.page(palettes, data: "pb")
        XCTAssertTrue(js.evaluateScript("styles()")?.toString().contains("--arc-palette-background: #eeeeee") == true,
                      "the tab's own palette, adopted before the page's scripts run")
        XCTAssertEqual(Self.ready(js)["k"] as? String, "pb")
        XCTAssertEqual(Self.ready(js)["d"] as? Bool, true)
        XCTAssertGreaterThanOrEqual((Self.ready(js)["t"] as? String)?.count ?? 0, 16)
    }

    func testWithoutTheEnginesKeyThePageWaitsForTheApp() throws {
        let palettes = ["pa": Self.palette("#111111")]
        for data: Any? in [nil, "", "zz", 5] {
            let js = try Self.page(palettes, data: data)
            XCTAssertEqual(js.evaluateScript("styles()")?.toString(), "", "no palette guessed (\(String(describing: data)))")
            XCTAssertEqual(Self.ready(js)["k"] as? String, "")
        }
        let js = try Self.page(palettes, data: nil)
        XCTAssertEqual(Self.ready(js)["d"] as? Bool, false)
        let token = try XCTUnwrap(Self.ready(js)["t"] as? String)
        let receive = try XCTUnwrap(js.objectForKeyedSubscript("receive"))
        // Another document's token, or none: dropped.
        receive.call(withArguments: ["theme.palette", ThemeCSS.message(token: "nope", key: "pa", css: palettes["pa"]!.css)])
        XCTAssertEqual(js.evaluateScript("styles()")?.toString(), "")
        receive.call(withArguments: ["theme.palette", ThemeCSS.message(token: token, key: "pa", css: palettes["pa"]!.css)])
        XCTAssertTrue(js.evaluateScript("styles()")?.toString().contains("#111111") == true)
        // A Space's new theme, then no Space at all (moved to a private window): the palette goes.
        receive.call(withArguments: ["theme.palette", ThemeCSS.message(token: token, key: "pa", css: Self.palette("#222222").css)])
        XCTAssertTrue(js.evaluateScript("styles()")?.toString().contains("#222222") == true)
        XCTAssertFalse(js.evaluateScript("styles()")?.toString().contains("#111111") == true, "one sheet, replaced")
        receive.call(withArguments: ["theme.palette", ThemeCSS.message(token: token, key: "", css: "")])
        XCTAssertEqual(js.evaluateScript("styles()")?.toString(), "")
    }

    func testFramesAndOtherDocumentsTakeNothing() throws {
        let palettes = ["pa": Self.palette("#111111")]
        let frame = try Self.page(palettes, data: "pa", top: false)
        XCTAssertEqual(frame.evaluateScript("posted.length")?.toInt32(), 0)
        XCTAssertEqual(frame.evaluateScript("styles()")?.toString(), "")
        for scheme in ["blob:", "about:", "data:", "file:"] {
            let other = try Self.page(palettes, data: "pa", scheme: scheme)
            XCTAssertEqual(other.evaluateScript("posted.length")?.toInt32(), 0, scheme)
            XCTAssertEqual(other.evaluateScript("styles()")?.toString(), "", scheme)
        }
    }

    func testTheComposerPassesTheEnginesDataToEveryPart() throws {
        let part = "(function () { return function (post, data) { post('seen', String(data)); return null; }; })()"
        let script = try XCTUnwrap(PageScriptComposer.compose(parts: [("one", part), ("two", part)], base: nil))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("var posted = []; (\(script))(function (k, j) { posted.push(k + '=' + j); }, 'pq');")
        XCTAssertEqual(js.evaluateScript("posted.join(',')")?.toString(), "one.seen=pq,two.seen=pq")
    }
}
