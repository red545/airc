// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import JavaScriptCore
import XCTest
@testable import AircKit

final class BoostTests: XCTestCase {
    // MARK: Sites

    static let hosts: [(String, String?)] = [
        ("nytimes.com", "nytimes.com"), ("www.nytimes.com", "nytimes.com"), ("cooking.nytimes.com", "nytimes.com"),
        ("a.b.c.example.org", "example.org"), ("WWW.Example.COM.", "example.com"),
        ("bbc.co.uk", "bbc.co.uk"), ("www.bbc.co.uk", "bbc.co.uk"), ("news.bbc.co.uk", "bbc.co.uk"), ("co.uk", "co.uk"),
        ("alice.github.io", "alice.github.io"), ("bob.github.io", "bob.github.io"), ("x.alice.github.io", "alice.github.io"),
        ("github.io", "github.io"), ("github.com", "github.com"), ("gist.github.com", "github.com"),
        ("bucket.s3.amazonaws.com", "bucket.s3.amazonaws.com"), ("s3.amazonaws.com", "s3.amazonaws.com"),
        ("orf.at", "orf.at"), ("wien.gv.at", "wien.gv.at"), ("www.abc.net.au", "abc.net.au"),
        ("127.0.0.1", "127.0.0.1"), ("localhost", "localhost"), ("app.localhost", "app.localhost"),
        ("a.app.localhost", "app.localhost"), ("[::1]", "::1"), ("::1", "::1"), ("intranet", "intranet"),
        ("", nil), ("a..b", "a..b"),
    ]

    func testSitesAreRegistrableDomains() {
        for (host, site) in Self.hosts {
            XCTAssertEqual(BoostDomain.key(forHost: host), site, host)
        }
        XCTAssertEqual(BoostDomain.key(for: URL(string: "https://www.nytimes.com/section/world")), "nytimes.com")
        XCTAssertEqual(BoostDomain.key(for: URL(string: "http://127.0.0.1:8080/x")), "127.0.0.1")
        XCTAssertNil(BoostDomain.key(for: URL(string: "file:///Users/x/a.html")), "Boosts are for websites")
        XCTAssertNil(BoostDomain.key(for: URL(string: "about:blank")))
        XCTAssertNil(BoostDomain.key(for: URL(string: "chrome://settings")))
    }

    /// The page computes its own site with the JavaScript copy of the rule: both must agree for every host.
    func testThePageScriptFindsTheSameSite() throws {
        let js = try XCTUnwrap(JSContext())
        let f = try XCTUnwrap(js.evaluateScript("(\(BoostPageScript.registrableFunction))"))
        for (host, site) in Self.hosts {
            let got = f.call(withArguments: [host])
            XCTAssertEqual(got?.isNull == true ? nil : got?.toString(), site, host)
        }
        XCTAssertNil(js.exception, "\(js.exception!)")
    }

    // MARK: Style

    func testAnEmptyBoostAddsNoStyle() {
        let b = Boost(domain: "example.com")
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(BoostStyle.generated(for: b), "")
        XCTAssertFalse(BoostPageScript.source(boosts: [b], version: 1).contains("\"example.com\""), "nothing to carry")
    }

    func testColoursMakeOneFilterAndATint() {
        var b = Boost(domain: "example.com")
        b.colors = BoostColors(hue: 0.5, tint: 0.5, brightness: 0.9, contrast: 1.2, invert: true)
        let css = BoostStyle.generated(for: b)
        XCTAssertTrue(css.contains("html { filter: invert(1) hue-rotate(180deg) brightness(0.9) contrast(1.2) !important; }"), css)
        XCTAssertTrue(css.contains("img, video"), "pictures are inverted back")
        XCTAssertTrue(css.contains(":where(html) { background-color: #fff; }"), "a page without a background is filtered too")
        XCTAssertTrue(css.contains("html::after"), css)
        XCTAssertTrue(css.contains("hsl(180 75% 82%)"), css)
        XCTAssertTrue(css.contains("mix-blend-mode: multiply"))

        b.colors = BoostColors(brightness: 1.1)
        let dim = BoostStyle.generated(for: b)
        XCTAssertTrue(dim.contains("filter: brightness(1.1) !important"), dim)
        XCTAssertFalse(dim.contains("invert"), dim)
        XCTAssertFalse(dim.contains("html::after"), "no tint")
    }

    func testFontAndSizeKeepIconsAndCode() {
        var b = Boost(domain: "example.com")
        b.font = BoostFont(family: .georgia, size: 1)
        let css = BoostStyle.generated(for: b)
        XCTAssertTrue(css.contains("font-family: Georgia, \"Times New Roman\", serif !important"), css)
        XCTAssertTrue(css.contains("pre, pre *, code, code *"), "code keeps its face")
        XCTAssertTrue(css.contains(".material-icons"), "icon fonts keep their face")
        XCTAssertTrue(css.contains("body { zoom: 1.1 !important; }"), css)
        b.font = BoostFont(family: nil, size: 99)
        XCTAssertEqual(b.font.scale, 1.5, "out-of-range steps clamp")
        XCTAssertFalse(BoostStyle.generated(for: b).contains("font-family"))
    }

    func testEachZapIsItsOwnRuleAndBadSelectorsAreDropped() {
        var b = Boost(domain: "example.com")
        b.zaps = [BoostZap(selector: "#ad", label: "Ad"), BoostZap(selector: "div.x } body { display: none", label: "bad"),
                  BoostZap(selector: "main > div.promo:nth-of-type(2)", label: "Promo")]
        let css = BoostStyle.generated(for: b)
        XCTAssertTrue(css.contains("#ad { display: none !important; }"))
        XCTAssertTrue(css.contains("main > div.promo:nth-of-type(2) { display: none !important; }"))
        XCTAssertFalse(css.contains("body { display"), "a selector can't end its rule")
        XCTAssertTrue(BoostZap.isValidSelector("#\\31 23"), "CSS.escape's output is fine")
        XCTAssertFalse(BoostZap.isValidSelector("a@import"))
        XCTAssertFalse(BoostZap.isValidSelector("a\nb"))
    }

    // MARK: Page script

    func testThePageScriptCarriesOnlyEnabledStyleAndNeverScripts() throws {
        var on = Boost(domain: "example.com", css: "h1 { color: red }", js: "window.secret = 'example-only'")
        on.colors.invert = true
        let off = Boost(domain: "off.example", enabled: false, css: "p { color: blue }")
        let source = BoostPageScript.source(boosts: [on, off], version: 7)
        XCTAssertTrue(source.contains("h1 { color: red }"))
        XCTAssertFalse(source.contains("example-only"), "custom JavaScript never goes to every page")
        XCTAssertFalse(source.contains("p { color: blue }"), "an off Boost isn't carried")
        XCTAssertTrue(source.contains("var VERSION = 7;"))
        XCTAssertTrue(source.contains("var TRUST_SYNTHETIC = false;"), "real builds take only real clicks")
        XCTAssertFalse(source.contains("%MAP%") || source.contains("%REGISTRABLE%"))

        // It parses, and it evaluates to the install function.
        let js = try XCTUnwrap(JSContext())
        let install = js.evaluateScript(source)
        XCTAssertNil(js.exception, "\(js.exception!)")
        XCTAssertTrue(install?.isObject == true && install?.toObject() != nil)
        XCTAssertEqual(js.evaluateScript("typeof (\(source))")?.toString(), "function")
    }

    func testStyleThatLooksLikeScriptOrPlaceholdersStaysData() throws {
        let b = Boost(domain: "example.com", css: "/* %MAP% %VERSION% \u{2028} */ a::before { content: \"\\\"});alert(1)//\" }")
        let source = BoostPageScript.source(boosts: [b], version: 1)
        let js = try XCTUnwrap(JSContext())
        _ = js.evaluateScript(source)
        XCTAssertNil(js.exception, "\(js.exception!)")
        XCTAssertTrue(source.contains("%MAP% %VERSION%"), "user text isn't treated as a placeholder")
        XCTAssertFalse(source.contains("\u{2028}"))
    }

    func testTheRunnerChecksTheSiteAndRunsOnce() throws {
        let src = BoostPageScript.runner(domain: "example.com", code: "window.count = (window.count || 0) + 1", token: "t1")
        func page(_ host: String) throws -> JSContext {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript("var window = this; window.top = window; var location = { hostname: '\(host)' };"
                              + "var document = { readyState: 'complete' }; var console = { error: function () {} };")
            return js
        }
        let home = try page("www.example.com")
        home.evaluateScript(src)
        home.evaluateScript(src)
        XCTAssertNil(home.exception, "\(home.exception!)")
        XCTAssertEqual(home.evaluateScript("window.count")?.toInt32(), 1, "once per page load")
        let other = try page("example.org")
        other.evaluateScript(src)
        XCTAssertTrue(other.evaluateScript("window.count")?.isUndefined == true, "never on another site")
        let lookalike = try page("example.com.evil.test")
        lookalike.evaluateScript(src)
        XCTAssertTrue(lookalike.evaluateScript("window.count")?.isUndefined == true)
    }

    func testApplyMessageForOffAndMissingBoostsRestoresThePage() throws {
        let off = Boost(domain: "example.com", enabled: false, css: "a{}")
        for m in [BoostPageScript.applyMessage(for: off, domain: "example.com"), BoostPageScript.applyMessage(for: nil, domain: "example.com")] {
            let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any])
            XCTAssertEqual(v["d"] as? String, "example.com")
            XCTAssertEqual(v["g"] as? String, "")
            XCTAssertEqual(v["c"] as? String, "")
        }
    }

    // MARK: Store

    func testTheStoreRoundTripsAndIgnoresUnknownFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Boosts.json")
        let store = BoostStore(url: url)
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        store.update(domain: "example.com") {
            $0.colors.tint = 0.4
            $0.font = BoostFont(family: .charter, size: -1)
            $0.zaps.append(BoostZap(selector: "#ad", label: "Ad"))
            $0.js = "console.log(1)"
        }
        store.update(domain: "example.com") { _ in }   // no change, no notice
        XCTAssertEqual(changed, ["example.com"])
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(store.flush())
        XCTAssertFalse(store.isDirty)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let again = BoostStore(url: url)
        // Dates are written to the second (ISO 8601), so the rest is compared.
        func content(_ b: Boost?) -> String {
            guard let b else { return "-" }
            return "\(b.domain) \(b.enabled) \(b.colors) \(b.font) \(b.zaps.map { [$0.id, $0.selector, $0.label] }) \(b.css) \(b.js)"
        }
        XCTAssertEqual(content(again.boost(domain: "example.com")), content(store.boost(domain: "example.com")))
        XCTAssertEqual(again.boost(domain: "example.com")?.colors.tint, 0.4)
        XCTAssertEqual(again.boost(domain: "example.com")?.zaps.first?.selector, "#ad")
        XCTAssertLessThan(abs((again.boost(domain: "example.com")?.modified.timeIntervalSinceNow) ?? 99), 5)
        XCTAssertEqual(again.boost(forHost: "www.example.com")?.font.knownFamily, .charter)
        XCTAssertNil(again.boost(forHost: "example.org"))

        // A newer build's file: unknown keys and font names are ignored, missing ones take their defaults.
        let newer = #"{"version": 3, "boosts": [{"domain": "a.test", "future": 1, "font": {"family": "comic", "size": 2},"#
            + #" "colors": {"invert": true, "glow": 0.3}}]}"#
        try Data(newer.utf8).write(to: url)
        let n = BoostStore(url: url)
        let a = try XCTUnwrap(n.boost(domain: "a.test"))
        XCTAssertTrue(a.enabled)
        XCTAssertTrue(a.colors.invert)
        XCTAssertEqual(a.colors.brightness, 1)
        XCTAssertNil(a.font.knownFamily)
        XCTAssertEqual(a.font.size, 2)
        XCTAssertEqual(a.font.family, "comic", "kept for the build that knows it")

        n.remove(domain: "a.test")
        XCTAssertTrue(n.flush())
        XCTAssertNil(BoostStore(url: url).boost(domain: "a.test"))
    }

    func testAnUnreadableFileIsKeptAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Boosts.json")
        try Data("not json".utf8).write(to: url)
        let store = BoostStore(url: url)
        XCTAssertTrue(store.all.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("Boosts.unreadable-") }
        XCTAssertEqual(kept.count, 1)
        store.update(domain: "example.com") { $0.css = "a{}" }
        XCTAssertTrue(store.flush())
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(kept[0]), encoding: .utf8), "not json")
    }
}
