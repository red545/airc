// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import JavaScriptCore
import XCTest
@testable import AircKit

final class BoostTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestSuffixes.install()
    }

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

    /// The page never decides a site with a list of its own: for every host, the entry it takes from the app's map is
    /// the app's key for that host when the app has a Boost there, and none otherwise.
    func testThePageTakesTheAppsSite() throws {
        let keys = ["victim.duckdns.org", "amazonaws.com", "github.io", "www.ck", "a.b.ck", "example.co.uk", "nytimes.com",
                    "xn--fsqu00a.xn--55qx5d.cn", "127.0.0.1", "localhost", "app.localhost", "::1", "city.kawasaki.jp"]
        let script = try Self.composed(keys.map { Boost(domain: $0, css: "h1 { color: red }") })
        let hosts = Self.hosts.map(\.0) + PublicSuffixListTests.sites.map(\.0) + [
            "www.victim.duckdns.org", "attacker.duckdns.org", "bucket.s3.amazonaws.com", "console.amazonaws.com",
            "x.compute.amazonaws.com", "alice.github.io", "a.www.ck", "x.a.b.ck", "c.b.ck", "news.example.co.uk",
            "www.nytimes.com", "nytimes.com.evil.test", "www.xn--fsqu00a.xn--55qx5d.cn", "a.app.localhost", "b.localhost",
            "www.city.kawasaki.jp", "x.kawasaki.jp", "127.0.0.2",
        ]
        for host in hosts where !host.isEmpty && !host.contains("..") {
            // A browser's location.hostname: lowercase ASCII (punycode), an IPv6 address in brackets.
            let ascii = PublicSuffixList.ascii(host.lowercased()) ?? host
            let hostname = ascii.contains(":") && !ascii.hasPrefix("[") ? "[\(ascii)]" : ascii
            let page = try Self.page(script, protocol: "https:", hostname: hostname, origin: "https://" + hostname)
            let chose = page.evaluateScript("ready().d")
            let want = BoostDomain.key(forHost: host).flatMap { keys.contains($0) ? $0 : nil }
            XCTAssertEqual(chose?.isNull == true ? nil : chose?.toString(), want, host)
            XCTAssertNil(page.exception, "\(host): \(page.exception!)")
        }
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
        XCTAssertFalse(css.contains("zoom"), "the size is the page's zoom, never CSS zoom (it made 100vh layouts overflow)")
        b.font = BoostFont(family: nil, size: 99)
        XCTAssertEqual(b.font.scale, 1.5, "out-of-range steps clamp")
        XCTAssertFalse(BoostStyle.generated(for: b).contains("font-family"))
        XCTAssertEqual(BoostStyle.generated(for: b), "", "a size alone adds no CSS")
        XCTAssertFalse(b.isEmpty, "but it's still a Boost")
    }

    func testTextCaseAndSaturation() {
        var b = Boost(domain: "example.com")
        b.font = BoostFont(textCase: .uppercase)
        let css = BoostStyle.generated(for: b)
        XCTAssertTrue(css.contains("text-transform: uppercase !important"), css)
        XCTAssertTrue(css.contains("input, textarea"), "fields and code keep their case")
        b.font.textCase = "smallcaps"
        XCTAssertFalse(BoostStyle.generated(for: b).contains("text-transform"), "an unknown case keeps the site's")
        XCTAssertTrue(b.font.isDefault)
        b.colors = BoostColors(saturation: 0.4)
        XCTAssertTrue(BoostStyle.generated(for: b).contains("filter: saturate(0.4) !important"), BoostStyle.generated(for: b))
        XCTAssertFalse(b.colors.isDefault)
    }

    /// A frame of a page on the same site adds what a frame adds itself: its page's filter and tint already cover it,
    /// and the invert its page takes back for frames is put on again.
    func testFrameStyleAddsNoSecondFilterOrTint() {
        var b = Boost(domain: "example.com")
        b.colors = BoostColors(hue: 0.3, tint: 0.4, brightness: 0.8, contrast: 1.2, saturation: 0.5, invert: false)
        b.font = BoostFont(family: .charter)
        b.zaps = [BoostZap(selector: ".ad", label: "Ad")]
        let frame = BoostStyle.generated(for: b, frame: true)
        XCTAssertFalse(frame.contains("filter") || frame.contains("::after"), frame)
        XCTAssertTrue(frame.contains("Charter") && frame.contains(".ad { display: none"), frame)
        b.colors.invert = true
        let inverted = BoostStyle.generated(for: b, frame: true)
        XCTAssertTrue(inverted.contains("html { filter: invert(1) hue-rotate(180deg) !important; }"), inverted)
        XCTAssertFalse(inverted.contains("brightness") || inverted.contains(":where(html)"), inverted)
        let script = BoostPageScript.source(boosts: [b], version: 1)
        XCTAssertTrue(script.contains("\"gf\""), "the map carries the frame's style when it differs")
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
        XCTAssertFalse(source.contains("%MAP%") || source.contains("%VERSION%"))
        let held = Boost(domain: "duckdns.org", css: "p { color: green }", needsSite: true)
        XCTAssertFalse(BoostPageScript.source(boosts: [held], version: 1).contains("color: green"), "a held Boost isn't carried")
        XCTAssertFalse(BoostPageScript.source(boosts: [held], version: 1).contains("public_suffix"), "no list in the page")

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

    func testTheRunnerChecksTheOriginAndRunsOnce() throws {
        let src = BoostPageScript.runner(origin: "https://www.example.com", domain: "example.com",
                                         code: "window.count = (window.count || 0) + 1", token: "t1")
        func page(_ origin: String) throws -> JSContext {
            let js = try XCTUnwrap(JSContext())
            js.evaluateScript("var window = this; window.top = window; var location = { origin: '\(origin)' };"
                              + "var document = { readyState: 'complete' }; var console = { error: function () {} };")
            return js
        }
        let home = try page("https://www.example.com")
        home.evaluateScript(src)
        home.evaluateScript(src)
        XCTAssertNil(home.exception, "\(home.exception!)")
        XCTAssertEqual(home.evaluateScript("window.count")?.toInt32(), 1, "once per page load")
        // Only the exact origin the engine reported: not another host of the site, another scheme, or a lookalike.
        for other in ["https://example.com", "http://www.example.com", "https://www.example.com:8443",
                      "https://www.example.com.evil.test", "https://attacker.example.org", "null"] {
            let p = try page(other)
            p.evaluateScript(src)
            XCTAssertTrue(p.evaluateScript("window.count")?.isUndefined == true, other)
        }
    }

    func testApplyAndZapMessagesCarryTheDocumentsToken() throws {
        let off = Boost(domain: "example.com", enabled: false, css: "a{}")
        let held = Boost(domain: "example.com", css: "a{}", needsSite: true)
        for b in [off, held, nil] {
            let m = BoostPageScript.applyMessage(for: b, domain: "example.com", token: "tok", version: 4)
            let v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any])
            XCTAssertEqual(v["d"] as? String, "example.com")
            XCTAssertEqual(v["t"] as? String, "tok")
            XCTAssertEqual(v["v"] as? Int, 4)
            XCTAssertEqual(v["g"] as? String, "")
            XCTAssertEqual(v["c"] as? String, "", "an off, held or deleted Boost restores the page")
        }
        let z = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(BoostPageScript.zapMessage(true, token: "tok").utf8)) as? [String: Any])
        XCTAssertEqual(z["t"] as? String, "tok")
        XCTAssertEqual(z["on"] as? Bool, true)
    }

    // MARK: The page script in a page

    /// Just enough of a page for the Boost page script in JavaScriptCore: install, style sheets, ready and receive.
    static let fakePage = """
        var window = this; window.top = window; var posted = [];
        function EventTarget() {}
        EventTarget.prototype.addEventListener = function (t, f) { (this.__l = this.__l || {})[t] = f; };
        EventTarget.prototype.removeEventListener = function () {};
        function CSSStyleSheet() { this.text = ''; this.cssRules = []; }
        CSSStyleSheet.prototype.replaceSync = function (t) { this.text = t; };
        CSSStyleSheet.prototype.insertRule = function (t) { this.text += t; };
        function Document() {}
        Document.prototype = Object.create(EventTarget.prototype);
        // A browser's getter and setter are native: these copy with plain loops, so a test can poison Array.prototype.
        var adopted = [];
        function copy(a) { var c = []; for (var i = 0; i < a.length; i++) c[i] = a[i]; return c; }
        Object.defineProperty(Document.prototype, 'adoptedStyleSheets', {
          get: function () { return copy(adopted); }, set: function (v) { adopted = copy(v); } });
        var document = new Document(); document.readyState = 'loading';
        var getComputedStyle = function () { return { backgroundColor: 'rgba(0, 0, 0, 0)' }; };
        var crypto = { getRandomValues: function (a) { for (var i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 4294967296); return a; } };
        // Just enough of URL, fetch, Response and Headers for the imports: `served` is what the fake origin answers.
        var served = {}, fetched = [];
        function URL(u, base) {
          var m = new RegExp('^(https?:)//([^/?#]+)(.*)$').exec(u);
          if (!m && /^[a-z][a-z0-9+.-]*:/i.test(u)) { this.protocol = u.slice(0, u.indexOf(':') + 1).toLowerCase(); this.origin = 'null'; this.href = u; return; }
          if (!m) {
            var b = new RegExp('^(https?:)//([^/?#]+)(/[^?#]*)?').exec(base || '');
            if (!b) throw new TypeError('Invalid URL');
            if (u.slice(0, 2) === '//') return URL.call(this, b[1] + u, base);
            var dir = u.charAt(0) === '/' ? '' : (b[3] || '/').replace(/[^/]*$/, '');
            m = [null, b[1], b[2], (u.charAt(0) === '/' ? '' : dir) + u];
          }
          this.protocol = m[1]; this.host = m[2]; this.origin = m[1] + '//' + m[2]; this.href = m[1] + '//' + m[2] + (m[3] || '/');
        }
        function Headers(h) { this.h = h; }
        Headers.prototype.get = function (k) { return this.h[k.toLowerCase()] || null; };
        function Response(body, type, ok) { this.body = body; this.ok = ok; this.headers = new Headers({ 'content-type': type }); }
        Response.prototype.text = function () { return Promise.resolve(this.body); };
        function fetch(href, init) {
          fetched.push(href + ' ' + init.mode + ' ' + init.credentials);
          var s = served[href];
          return s ? Promise.resolve(new Response(s[0], s[1], s[2] !== false)) : Promise.reject(new TypeError('Failed to fetch'));
        }
        function atob(s) {
          var abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/', out = '', bits = 0, n = 0;
          for (var i = 0; i < s.length; i++) {
            var v = abc.indexOf(s.charAt(i)); if (v < 0) continue;
            bits = (bits << 6) | v; n += 6;
            if (n >= 8) { n -= 8; out += String.fromCharCode((bits >> n) & 255); }
          }
          return out;
        }
        function failures() { return posted.filter(function (p) { return p[0] === 'boost.importFailed'; }).map(function (p) { return JSON.parse(p[1]); }); }
        function styles() { return adopted.map(function (s) { return s.text; }).join(''); }
        function ready() {
          for (var i = posted.length - 1; i >= 0; i--) if (posted[i][0] === 'boost.ready') return JSON.parse(posted[i][1]);
          return null;
        }
        """

    /// The engine's page script with the Boosts part, as the app composes it.
    static func composed(_ boosts: [Boost], version: Int = 1) throws -> String {
        try XCTUnwrap(PageScriptComposer.compose(parts: [("boost", BoostPageScript.source(boosts: boosts, version: version))], base: nil))
    }

    static func page(_ script: String, protocol scheme: String, hostname: String, origin: String,
                     href: String? = nil, frameIn pageOrigin: String? = nil, served: [String: (String, String)] = [:]) throws -> JSContext {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(fakePage)
        var loc: [String: Any] = ["protocol": scheme, "hostname": hostname, "origin": origin, "href": href ?? origin + "/"]
        if let pageOrigin {
            loc["ancestorOrigins"] = [pageOrigin]
            js.evaluateScript("window.top = {};")
        }
        js.evaluateScript("var location = \(BoostPageScript.json(loc));")
        for (url, answer) in served { js.evaluateScript("served[\(BoostPageScript.json(url))] = \(BoostPageScript.json([answer.0, answer.1]));") }
        js.evaluateScript("var receive = (\(script))(function (kind, json) { posted.push([kind, json]); });")
        XCTAssertNil(js.exception, "\(js.exception!)")
        return js
    }

    /// review1's boost-probe, in JavaScriptCore: a blob: document in a tab the app still had down as a boosted site,
    /// which poisons Object.prototype, gets nothing through the composer; and a page that poisons the builtins after
    /// install can't intercept the app's message to it, or take one meant for another document.
    func testReview1ProbeAPoisonedPageCantInterceptStyle() throws {
        var bank = Boost(domain: "bank.example", css: ".private-note { color: red }")
        bank.zaps = [BoostZap(selector: "#account-123", label: "Account")]
        let script = try Self.composed([bank])
        let payload = { (token: String) in
            BoostPageScript.applyMessage(for: bank, domain: "bank.example", token: token, version: 2)
        }

        // The blob: document: it says ready with no site and has no receiver for the Boost part.
        let blob = try Self.page(script, protocol: "blob:", hostname: "", origin: "https://attacker.example")
        XCTAssertEqual(blob.evaluateScript("posted.length")?.toInt32(), 1)
        XCTAssertTrue(blob.evaluateScript("ready().d")?.isNull == true)
        XCTAssertTrue(blob.evaluateScript("ready().t")?.isUndefined == true, "no token: the app registers nothing to send to")
        let blobToken = "a-guess"
        blob.evaluateScript("""
            Object.prototype.hasOwnProperty = function () { return true; };
            Object.prototype.boost = function (kind, json) { globalThis.stolen = json; };
            """)
        blob.objectForKeyedSubscript("receive").call(withArguments: ["boost.apply", payload(blobToken)])
        XCTAssertTrue(blob.evaluateScript("globalThis.stolen")?.isUndefined == true, "the composer never routes to an inherited receiver")
        XCTAssertEqual(blob.evaluateScript("styles()")?.toString(), "")

        // A page of the site: poisoned after install, it gets the app's message only through its own receiver.
        let page = try Self.page(script, protocol: "https:", hostname: "www.bank.example", origin: "https://www.bank.example")
        XCTAssertEqual(page.evaluateScript("ready().d")?.toString(), "bank.example")
        XCTAssertTrue(page.evaluateScript("styles()")?.toString().contains("#account-123") == true, "the style from the first script")
        let token = try XCTUnwrap(page.evaluateScript("ready().t")?.toString())
        XCTAssertGreaterThanOrEqual(token.count, 16)
        let other = try Self.page(script, protocol: "https:", hostname: "bank.example", origin: "https://bank.example")
        XCTAssertNotEqual(token, other.evaluateScript("ready().t")?.toString(), "every document has its own token")
        page.evaluateScript("""
            var steal = function (what) { var s = globalThis.stolen || (globalThis.stolen = []); s[s.length] = what; };
            Object.prototype.hasOwnProperty = function () { steal('hasOwnProperty'); return true; };
            Object.prototype.boost = function (k, j) { steal(j); };
            Object.prototype.t = 'forged';
            Function.prototype.call = function () { steal('call'); };
            Function.prototype.apply = function () { steal('apply'); };
            Function.prototype.bind = function () { steal('bind'); };
            Array.prototype.indexOf = function () { steal('indexOf'); return -1; };
            Array.prototype.concat = function () { steal('concat'); return []; };
            Array.prototype.slice = function () { steal('slice'); return []; };
            String.prototype.indexOf = function () { steal('String.indexOf'); return 0; };
            String.prototype.slice = function () { steal('String.slice'); return 'boost'; };
            JSON.parse = function () { steal('parse'); return {}; };
            Object.create = function () { steal('create'); return {}; };
            """)
        let receive = page.objectForKeyedSubscript("receive")
        receive?.call(withArguments: ["boost.apply", payload("forged")])
        receive?.call(withArguments: ["boost.apply", payload(blobToken)])
        receive?.call(withArguments: ["boost.apply", #"{"d":"bank.example","g":"x{}","c":"","f":false}"#])
        XCTAssertTrue(page.evaluateScript("styles()")?.toString().contains("#account-123") == true, "another document's token, a forged one or none: nothing changes")
        var fresh = bank
        fresh.css = ".fresh { color: blue }"
        receive?.call(withArguments: ["boost.apply", BoostPageScript.applyMessage(for: fresh, domain: "bank.example", token: token, version: 3)])
        XCTAssertTrue(page.evaluateScript("styles()")?.toString().contains(".fresh") == true, "its own token: applied")
        XCTAssertTrue(page.evaluateScript("globalThis.stolen")?.isUndefined == true,
                      "no poisoned builtin was called: \(page.evaluateScript("JSON.stringify(globalThis.stolen)")?.toString() ?? "")")
        XCTAssertNil(page.exception, "\(page.exception!)")
    }

    /// A page of another version (back from the back-forward cache, or made from the old script just before the
    /// engine had the new one) says so in ready; the app's empty apply clears it, and ready says the new version after.
    func testAnEmptyApplyClearsAndReadyReportsTheShownVersion() throws {
        let b = Boost(domain: "example.com", colors: BoostColors(invert: true))
        let page = try Self.page(try Self.composed([b], version: 5), protocol: "https:", hostname: "example.com",
                                 origin: "https://example.com")
        XCTAssertEqual(page.evaluateScript("ready().v")?.toInt32(), 5)
        XCTAssertTrue(page.evaluateScript("styles()")?.toString().contains("invert") == true)
        let token = try XCTUnwrap(page.evaluateScript("ready().t")?.toString())
        page.objectForKeyedSubscript("receive").call(withArguments: [
            "boost.apply", BoostPageScript.applyMessage(for: nil, domain: "example.com", token: token, version: 6)])
        XCTAssertEqual(page.evaluateScript("styles()")?.toString(), "", "deleted: no style left")
        page.evaluateScript("window.__l.pageshow({ persisted: true })")
        XCTAssertEqual(page.evaluateScript("ready().v")?.toInt32(), 6, "restored, it reports the version it shows")
        XCTAssertTrue(page.evaluateScript("ready().d")?.isNull == true, "and that it shows no site's style")
        XCTAssertEqual(page.evaluateScript("ready().restored")?.toBool(), true)
    }

    func testTheComposerKeepsPartsAndTheBaseApart() throws {
        let part = "(function () { return function (post) { post('hi', '{}'); return function (k, j) { globalThis.got = k + ' ' + j; }; }; })()"
        let base = "(function () { return function (post) { return function (k, j) { globalThis.base = k; }; }; })()"
        let src = try XCTUnwrap(PageScriptComposer.compose(parts: [("one", part), ("two", "(function () { return function () {}; })()")], base: base))
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript("var posted = []; var receive = (\(src))(function (k, j) { posted.push(k); });")
        XCTAssertEqual(js.evaluateScript("posted[0]")?.toString(), "one.hi", "a part's posts carry its name")
        js.evaluateScript("receive('one.ping', '1')")
        XCTAssertEqual(js.evaluateScript("globalThis.got")?.toString(), "ping 1")
        js.evaluateScript("receive('two.ping', '2')")
        XCTAssertTrue(js.evaluateScript("globalThis.base")?.isUndefined == true, "a part's message never goes to the base")
        js.evaluateScript("receive('constructor.x', '3')")
        XCTAssertEqual(js.evaluateScript("globalThis.got")?.toString(), "ping 1", "no inherited name reaches a part")
        XCTAssertEqual(js.evaluateScript("globalThis.base")?.toString(), "constructor.x", "other names go to the base")
        js.evaluateScript("receive('plain', '5')")
        XCTAssertEqual(js.evaluateScript("globalThis.base")?.toString(), "plain")
        XCTAssertNil(js.exception, "\(js.exception!)")
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
            $0.scriptHost = "www.example.com"
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
            return "\(b.domain) \(b.enabled) \(b.colors) \(b.font) \(b.zaps.map { [$0.id, $0.selector, $0.label] }) \(b.css) \(b.js) "
                + "\(b.scriptHost ?? "-") \(b.needsSite)"
        }
        XCTAssertEqual(content(again.boost(domain: "example.com")), content(store.boost(domain: "example.com")))
        XCTAssertEqual(again.boost(domain: "example.com")?.colors.tint, 0.4)
        XCTAssertEqual(again.boost(domain: "example.com")?.zaps.first?.selector, "#ad")
        XCTAssertLessThan(abs((again.boost(domain: "example.com")?.modified.timeIntervalSinceNow) ?? 99), 5)
        XCTAssertEqual(again.boost(forHost: "www.example.com")?.font.knownFamily, .charter)
        XCTAssertNil(again.boost(forHost: "example.org"))
        XCTAssertEqual(again.boost(domain: "example.com")?.scriptHost, "www.example.com")
        XCTAssertTrue(again.boost(domain: "example.com")?.scriptRuns(onHost: "www.example.com") == true)
        XCTAssertFalse(again.boost(domain: "example.com")?.scriptRuns(onHost: "shop.example.com") == true, "its host only")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"version\" : 2"))

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

    // MARK: Migration

    /// A version 1 file: a Boost whose key may have been shared by different owners is held (no style, no code) until
    /// the person picks its site; every other Boost keeps its whole site, code included.
    func testVersionOneSharedSuffixBoostsAreHeld() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Boosts.json")
        func entry(_ d: String, js: String = "", css: String = "") -> String {
            #"{"domain": "\#(d)", "js": "\#(js)", "css": "\#(css)", "colors": {"invert": true}}"#
        }
        let v1 = #"{"version": 1, "boosts": ["# + [
            entry("duckdns.org", js: "steal()"), entry("uk.com", css: "a{}"), entry("github.io", js: "x()"),
            entry("amazonaws.com", js: "y()"), entry("nytimes.com", js: "z()"), entry("127.0.0.1", js: "w()"),
            entry("localhost"), entry("bbc.co.uk"),
        ].joined(separator: ", ") + "]}"
        try Data(v1.utf8).write(to: url)
        let store = BoostStore(url: url)
        let held = Set(store.all.filter(\.needsSite).map(\.domain))
        XCTAssertEqual(held, ["duckdns.org", "uk.com", "github.io", "amazonaws.com"])
        XCTAssertTrue(store.isDirty, "written back as version 2")
        for d in held {
            let b = try XCTUnwrap(store.boost(domain: d))
            XCTAssertFalse(b.isLive)
            XCTAssertFalse(b.scriptRuns(onHost: d), "\(d): its code doesn't run")
            XCTAssertFalse(BoostPageScript.carries(b), "\(d): its style isn't carried")
        }
        let nyt = try XCTUnwrap(store.boost(domain: "nytimes.com"))
        XCTAssertNil(nyt.scriptHost, "a Boost from before hosts keeps its whole site")
        XCTAssertTrue(nyt.scriptRuns(onHost: "cooking.nytimes.com"))
        XCTAssertTrue(store.boost(domain: "127.0.0.1")?.scriptRuns(onHost: "127.0.0.1") == true)
        let source = BoostPageScript.source(boosts: store.all, version: 1)
        XCTAssertFalse(source.contains("\"duckdns.org\"") || source.contains("\"uk.com\"") || source.contains("\"github.io\""))
        XCTAssertTrue(source.contains("\"nytimes.com\""))

        // The held Boost shows on the pages it may be for, and moves to the one the person picks.
        XCTAssertEqual(store.heldBoost(coveringHost: "www.victim.duckdns.org")?.domain, "duckdns.org")
        XCTAssertEqual(store.heldBoost(coveringHost: "duckdns.org")?.domain, "duckdns.org")
        XCTAssertNil(store.heldBoost(coveringHost: "duckdns.org.evil.test"))
        XCTAssertNil(store.heldBoost(coveringHost: "nytimes.com"))
        var changed: [String] = []
        store.onChange = { changed.append($0) }
        XCTAssertTrue(store.adopt(held: "duckdns.org", to: "victim.duckdns.org", host: "www.victim.duckdns.org"))
        XCTAssertEqual(changed, ["duckdns.org", "victim.duckdns.org"])
        XCTAssertNil(store.boost(domain: "duckdns.org"))
        let moved = try XCTUnwrap(store.boost(domain: "victim.duckdns.org"))
        XCTAssertFalse(moved.needsSite)
        XCTAssertEqual(moved.js, "steal()")
        XCTAssertEqual(moved.scriptHost, "www.victim.duckdns.org", "its code on the page's host only, until the person picks all of the site")
        XCTAssertTrue(moved.scriptRuns(onHost: "www.victim.duckdns.org"))
        XCTAssertFalse(moved.scriptRuns(onHost: "victim.duckdns.org"))
        // A site with a Boost of its own isn't overwritten.
        store.update(domain: "alice.github.io") { $0.css = "b{}" }
        XCTAssertFalse(store.adopt(held: "github.io", to: "alice.github.io", host: "alice.github.io"))
        // Kept for the suffix's own host: no longer held, and not held again once it's a version 2 file.
        XCTAssertTrue(store.adopt(held: "github.io", to: "github.io", host: "github.io"))
        XCTAssertNil(store.boost(domain: "github.io")?.scriptHost, "an exact host's code needs no host")
        XCTAssertTrue(store.flush())
        let again = BoostStore(url: url)
        XCTAssertEqual(Set(again.all.filter(\.needsSite).map(\.domain)), ["uk.com", "amazonaws.com"])
        XCTAssertFalse(again.isDirty)
        XCTAssertEqual(again.boost(domain: "github.io")?.needsSite, false)
    }
}
