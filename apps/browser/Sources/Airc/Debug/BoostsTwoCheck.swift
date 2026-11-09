// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import WebKit

/// `--script boosts2` (both engines; BST-3) on loopback pages: two servers (ports A and B) on 127.0.0.1, localhost as
/// another site, and on Chromium a registrable domain through the engine's resolver rule
/// (`MAP *.airc-boosts.example 127.0.0.1`, build-app.sh; WebKit loads that one as a simulated page).
///   1. Frames: a frame of the page's own origin and one of another origin on the same site (port B) take the Boost's
///      style for frames (font, CSS, zaps, invert, no second filter), live edits reach them, the custom JavaScript stays
///      in the top frame, and a frame of another site (localhost) keeps its own look; on Chromium, a registrable
///      domain's frame on another host too.
///   2. @import: the page's own origin (and a nested import) and data: load; another origin is never requested (the
///      server's log), a non-CSS answer and a Content-Security-Policy that blocks the fetch are reported, with data: still
///      applied; the editor lists what loads.
///   3. The size: a 100vh layout fits the window at 125 % (the page's zoom, no CSS zoom), back to 100 % when the size
///      goes, the person's own zoom is left alone, and another site in the tab isn't zoomed.
///   4. Sharing: a link review offers Try It On (style only: its code doesn't run), Cancel takes it back; installing keeps
///      the origin; a higher revision is an update, a lower one older; the share sheet saves a file with the author,
///      a new id for a Boost installed from someone, and its screenshot; a link from another app and a page at a Boost
///      link both open the review, with no request for the link.
///   5. The gallery window, a gallery Boost reviewed and added, marked as added.
extension SnapshotRunner {
    func boostsTwoScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        final class Box { var a: UInt16 = 0; var b: UInt16 = 0; var log: [String] = []; let lock = NSLock() }
        let ports = Box()
        var serverA: LocalPageServer?, serverB: LocalPageServer?
        var tabID = ""
        let page = { self.c.engineTab(for: tabID) }
        let center = { BoostCenter.shared }
        let editor = { self.c.boostEditor?.model }
        let ip = "127.0.0.1", reg = "airc-boosts.example"
        func a(_ path: String, host: String = "127.0.0.1") -> String { "http://\(host):\(ports.a)\(path)" }
        func requested(_ path: String) -> Bool { ports.lock.lock(); defer { ports.lock.unlock() }; return ports.log.contains { $0.hasPrefix(path) } }

        let style = "<style>body { font-family: Times; margin: 0; padding: 16px } #hero { color: rgb(10, 20, 30) } iframe { width: 260px; height: 90px }</style>"
        let probe = """
            <script>
            function report() {
              var h = document.getElementById('hero'), cs = getComputedStyle(h), p = document.querySelector('.promo');
              parent.postMessage({ kind: 'probe', n: new URLSearchParams(location.search).get('n'), hero: cs.color,
                font: getComputedStyle(document.body).fontFamily, filter: getComputedStyle(document.documentElement).filter,
                promo: p ? getComputedStyle(p).display : '', js: String(document.documentElement.dataset.boostJs) }, '*');
            }
            addEventListener('message', function (e) { if (e.data === 'probe') report(); });
            addEventListener('load', report);
            </script>
            """
        func framesPage(_ frames: [(String, String)]) -> String {
            "<!doctype html><html><head><title>frames</title><link rel=\"icon\" href=\"data:,\">\(style)</head><body><h1 id=\"hero\">Top</h1>"
                + "<div class=\"promo\">promo</div>"
                + frames.map { "<iframe id=\"\($0.0)\" src=\"\($0.1)\"></iframe>" }.joined()
                + "<script>window.__probes = {}; addEventListener('message', function (e) { if (e.data && e.data.kind === 'probe') "
                + "window.__probes[e.data.n] = e.data; }); function probeAll() { for (var i = 0; i < frames.length; i++) frames[i].postMessage('probe', '*'); }</script>"
                + "</body></html>"
        }
        let framePage = "<!doctype html><html><head><title>frame</title>\(style)</head><body><h1 id=\"hero\">Frame</h1><div class=\"promo\">promo</div>\(probe)</body></html>"
        let tall = """
            <!doctype html><html><head><title>tall</title><link rel="icon" href="data:,"><style>
            html, body { margin: 0; height: 100%; font: 16px Times }
            .app { height: 100vh; display: flex; flex-direction: column }
            .main { flex: 1; overflow: auto; padding: 12px } .foot { height: 40px; background: #f99 }
            </style></head><body><div class="app"><div class="main"><h1 id="hero">Tall</h1></div><div class="foot">footer</div></div></body></html>
            """
        let imports = "<!doctype html><html><head><title>imports</title><link rel=\"icon\" href=\"data:,\">\(style)</head><body><h1 id=\"hero\">Imports</h1>"
            + "<p class=\"nested-mark\">nested</p></body></html>"
        let sharePage = "<!doctype html><html><head><title>share</title><link rel=\"icon\" href=\"data:,\">\(style)</head><body><h1 id=\"hero\">A page to share a Boost on</h1>"
            + "<p>Some text, for the screenshot.</p></body></html>"
        func answer(_ path: String) -> LocalPageServer.Page? {
            ports.lock.lock(); ports.log.append(path); ports.lock.unlock()
            let p = path.components(separatedBy: "?").first ?? path
            switch p {
            case "/frames":
                return .init(body: framesPage([("same", "/frame?n=same"), ("port", "http://127.0.0.1:\(ports.b)/frame?n=port"),
                                               ("cross", "http://localhost:\(ports.a)/frame?n=cross")]))
            case "/frames-reg":
                return .init(body: framesPage([("reg", "http://cdn.\(reg):\(ports.a)/frame?n=reg"),
                                               ("regcross", "http://other-boosts.example:\(ports.a)/frame?n=regcross")]))
            case "/frame": return .init(body: framePage)
            case "/tall": return .init(body: tall)
            case "/imports": return .init(body: imports)
            case "/csp-import": return .init(headers: ["Content-Security-Policy": "connect-src 'none'"], body: imports)
            case "/imp/site.css": return .init(headers: ["Content-Type": "text/css"], body: "@import 'nested.css';\n#hero { letter-spacing: 3px !important; }")
            case "/imp/nested.css": return .init(headers: ["Content-Type": "text/css"], body: ".nested-mark { letter-spacing: 5px !important; }")
            case "/imp/notcss.css": return .init(body: "<html>not css</html>")
            case "/imp/evil.css": return .init(headers: ["Content-Type": "text/css"], body: "#hero { color: red !important; }")
            case "/share": return .init(body: sharePage)
            case "/cards":
                return .init(body: "<!doctype html><html><head><title>cards</title><link rel=\"icon\" href=\"data:,\">\(style)</head><body><h1 id=\"hero\">Cards</h1>"
                             + (1...3).map { "<div class=\"card promo-card\">Sponsored \($0)</div>" }.joined() + "<div class=\"card-note\">kept</div></body></html>")
            default: return nil
            }
        }

        step { [self] done in
            serverA = LocalPageServer(responses: [:])
            serverB = LocalPageServer(responses: [:])
            serverA?.handler = answer
            serverB?.handler = answer
            guard let serverA, let serverB else { check(false, "boosts2: the loopback servers start"); return done() }
            serverA.start { p in
                ports.a = p ?? 0
                serverB.start { q in
                    ports.b = q ?? 0
                    self.check(ports.a != 0 && ports.b != 0, "boosts2 (\(tag)): two loopback servers (ports A and B)")
                    done()
                }
            }
        }

        func open(_ url: @escaping () -> String, title: String) {
            run { [self] in
                guard ports.a != 0, let t = try? c.store.openTab(url: url(), inSpace: c.currentSpaceID, title: title) else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            waitTitle(title)
        }
        func go(_ url: @escaping () -> String, title: String) {
            run { if let u = URL(string: url()) { page()?.load(u) } }
            waitTitle(title)
        }
        /// WebKit has no resolver rule: a registrable domain's page is a simulated load at its address.
        func goSimulated(_ url: @escaping () -> String, html: String, title: String) {
            run { [self] in
                guard let u = URL(string: url()) else { return }
                if chromium { page()?.load(u) } else { (page() as? WebKitTab)?.webView.loadSimulatedRequest(URLRequest(url: u), responseHTML: html) }
            }
            waitTitle(title)
        }
        func waitTitle(_ title: String) {
            step { [self] done in
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 12) {
                    if page()?.title != title { self.check(false, "boosts2 (\(tag)): \(title) loads (\(page()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
            }
        }
        func waitJS(_ code: String, _ what: String, timeout: Double = 5, _ ok: @escaping (String) -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    guard let p = page() else { check(false, "boosts2 (\(tag)): \(what) (no page)"); return done() }
                    p.evaluate(code) { value in
                        let got = value.map { "\($0)" } ?? "nil"
                        if ok(got) { self.check(true, "boosts2 (\(tag)): \(what) (page says \(got))"); return done() }
                        if Date() > deadline { self.check(false, "boosts2 (\(tag)): \(what) (page says \(got))"); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                    }
                }
                poll()
            }
        }
        func settle() { wait(0.7) }
        func probeJS(_ n: String) -> String {
            "(probeAll(), window.__probes['\(n)'] ? JSON.stringify(window.__probes['\(n)']) : 'none')"
        }

        // 1. Frames.
        run { [self] in
            center()?.update(domain: ip) {
                $0.colors = BoostColors(brightness: 0.9, invert: true)
                $0.font = BoostFont(family: .georgia)
                $0.css = "#hero { color: rgb(1, 2, 3) !important; }"
                $0.zaps = [BoostZap(selector: ".promo", label: "Promo")]
                $0.js = "document.documentElement.dataset.boostJs = 'ran';"
                $0.scriptHost = nil
            }
        }
        settle()
        open({ a("/frames") }, title: "frames")
        waitJS("document.documentElement.dataset.boostJs + '|' + getComputedStyle(document.getElementById('hero')).color", "the top frame is boosted, its code ran") {
            $0 == "ran|rgb(1, 2, 3)"
        }
        waitJS(probeJS("same"), "a frame of the page's own origin takes the frame style (font, CSS, zap, invert only), never the code") {
            $0.contains("rgb(1, 2, 3)") && $0.contains("Georgia") && $0.contains("\"promo\":\"none\"") && $0.contains("invert(1)")
                && !$0.contains("brightness") && $0.contains("\"js\":\"undefined\"")
        }
        waitJS(probeJS("port"), "a frame of another origin on the same site (port B) takes it too") {
            $0.contains("rgb(1, 2, 3)") && $0.contains("Georgia") && $0.contains("\"promo\":\"none\"") && $0.contains("\"js\":\"undefined\"")
        }
        waitJS(probeJS("cross"), "a frame of another site (localhost) keeps its own look") {
            $0.contains("rgb(10, 20, 30)") && $0.contains("Times") && $0.contains("\"promo\":\"block\"") && $0.contains("\"filter\":\"none\"")
        }
        run { [self] in
            let n = page().map { center()?.frameDocumentCount($0) ?? -1 } ?? -1
            check(n == 2, "boosts2 (\(tag)): the app holds the two same-site frames' documents, not the other site's (\(n))")
            center()?.update(domain: ip) { $0.font = BoostFont(family: .menlo) }
        }
        waitJS(probeJS("port"), "a live edit reaches a same-site frame of another origin") { $0.contains("Menlo") }
        waitJS(probeJS("same"), "and the same-origin frame") { $0.contains("Menlo") }
        waitJS(probeJS("cross"), "but not the other site's frame") { $0.contains("Times") && !$0.contains("Menlo") }
        capture("boosts2-frames")
        if chromium {
            run { [self] in
                center()?.update(domain: reg) { $0.font = BoostFont(family: .georgia); $0.css = "#hero { color: rgb(4, 5, 6) !important; }" }
            }
            settle()
            go({ a("/frames-reg", host: "www.\(reg)") }, title: "frames")
            waitJS(probeJS("reg"), "a registrable domain's frame on another host (cdn.) takes its page's Boost") { $0.contains("rgb(4, 5, 6)") && $0.contains("Georgia") }
            waitJS(probeJS("regcross"), "a frame of another registrable site keeps its own look") { $0.contains("rgb(10, 20, 30)") && $0.contains("Times") }
            run { [self] in center()?.remove(domain: reg, page: nil) }
        } else {
            run { [self] in skip("boosts2 (\(tag)): a registrable domain's frames (WebKit has no resolver rule; JavaScriptCore tests cover it)") }
        }

        // 2. @import.
        run { [self] in
            center()?.update(domain: ip) {
                $0 = Boost(domain: ip, css: """
                    @import url(/imp/site.css);
                    @import url("data:text/css,%23hero%7Btext-indent%3A7px%20!important%7D");
                    @import url(http://localhost:\(ports.a)/imp/evil.css);
                    @import "/imp/notcss.css";
                    .nested-mark { color: rgb(9, 9, 9) !important; }
                    """)
            }
        }
        settle()
        go({ a("/imports") }, title: "imports")
        waitJS("getComputedStyle(document.getElementById('hero')).textIndent", "a data: import applies") { $0 == "7px" }
        waitJS("getComputedStyle(document.getElementById('hero')).letterSpacing", "an import from the page's own origin applies") { $0 == "3px" }
        waitJS("getComputedStyle(document.querySelector('.nested-mark')).letterSpacing + '|' + getComputedStyle(document.querySelector('.nested-mark')).color",
               "its nested import too, and the rest of the CSS after the imports") { $0 == "5px|rgb(9, 9, 9)" }
        waitJS("getComputedStyle(document.getElementById('hero')).color", "the other origin's CSS never applies") { $0 == "rgb(10, 20, 30)" }
        step { [self] done in
            waitUntil({ center()?.importFailures[ip]?.count ?? 0 >= 2 }, timeout: 4) {
                let f = center()?.importFailures[ip] ?? [:]
                self.check(f["http://localhost:\(ports.a)/imp/evil.css"] == "origin" && f["/imp/notcss.css"] == "type",
                           "boosts2 (\(tag)): the page reports the other origin and the non-CSS answer (\(f))")
                self.check(!requested("/imp/evil.css") && requested("/imp/site.css") && requested("/imp/nested.css"),
                           "boosts2 (\(tag)): the other origin's CSS was never requested; the site's and its nested one were")
                done()
            }
        }
        run { [self] in
            c.showBoostEditor(section: .code)
            editor()?.codeKind = .css
        }
        wait(0.5)
        run { [self] in
            let lines = editor()?.importLines ?? []
            check(lines.count == 4 && lines.filter { !$0.ok }.count == 2 && TestAnchors.frames["boost.imports"] != nil,
                  "boosts2 (\(tag)): the editor lists the imports, two skipped (\(lines.map { "\($0.url)=\($0.ok)" }))")
        }
        capture("boosts2-imports")
        run { [self] in c.closeBoostEditor(animated: false) }
        go({ a("/csp-import") }, title: "imports")
        waitJS("getComputedStyle(document.getElementById('hero')).textIndent + '|' + getComputedStyle(document.getElementById('hero')).letterSpacing",
               "under connect-src 'none' the data: import still applies and the fetch doesn't") { $0 == "7px|normal" }
        step { [self] done in
            waitUntil({ center()?.importFailures[ip]?["/imp/site.css"] == "blocked" }, timeout: 4) {
                self.check(center()?.importFailures[ip]?["/imp/site.css"] == "blocked",
                           "boosts2 (\(tag)): the blocked fetch is reported (\(center()?.importFailures[ip] ?? [:]))")
                done()
            }
        }

        // 3. The size: the page's zoom.
        var before = 0.0, viewWidth = 0.0
        run { [self] in center()?.update(domain: ip) { $0 = Boost(domain: ip) } }
        go({ a("/tall") }, title: "tall")
        step { [self] done in
            page()?.evaluate("innerWidth") { v in before = (v as? Double) ?? Double((v as? Int) ?? 0); done() }
        }
        run { [self] in
            viewWidth = Double(page()?.view.bounds.width ?? 0)
            check(BoostZoom.near(page()?.zoomFactor ?? 0, 1), "boosts2 (\(tag)): the page starts at 100 % (\(page()?.zoomFactor ?? 0))")
            center()?.update(domain: ip) { $0.font.size = 2 }
        }
        step { [self] done in
            waitUntil({ BoostZoom.near(page()?.zoomFactor ?? 0, 1.25) }, timeout: 3) {
                self.check(BoostZoom.near(page()?.zoomFactor ?? 0, 1.25), "boosts2 (\(tag)): size 125 % is the page's zoom (\(page()?.zoomFactor ?? 0))")
                done()
            }
        }
        waitJS("JSON.stringify([innerHeight, document.scrollingElement.scrollHeight, Math.round(document.querySelector('.foot').getBoundingClientRect().bottom), getComputedStyle(document.body).zoom, innerWidth])",
               "a 100vh layout still fits the window at 125 %: no page scroll, the footer at the bottom, no CSS zoom") { got in
            guard let d = got.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d) as? [Any], v.count == 5,
                  let h = (v[0] as? NSNumber)?.doubleValue, let sh = (v[1] as? NSNumber)?.doubleValue, let foot = (v[2] as? NSNumber)?.doubleValue,
                  let w = (v[4] as? NSNumber)?.doubleValue else { return false }
            return sh <= h + 1 && abs(foot - h) <= 1 && "\(v[3])" == "1" && w < before * 0.85 && w > before * 0.75
        }
        run { [self] in note("boosts2 (\(tag)): view \(Int(viewWidth)) pt wide; innerWidth \(Int(before)) at 100 %") }
        capture("boosts2-tall-125")
        go({ a("/tall", host: "localhost") }, title: "tall")
        step { [self] done in
            waitUntil({ BoostZoom.near(page()?.zoomFactor ?? 0, 1) }, timeout: 3) {
                self.check(BoostZoom.near(page()?.zoomFactor ?? 0, 1), "boosts2 (\(tag)): another site in the tab is at 100 % (\(page()?.zoomFactor ?? 0))")
                done()
            }
        }
        go({ a("/tall") }, title: "tall")
        step { [self] done in
            waitUntil({ BoostZoom.near(page()?.zoomFactor ?? 0, 1.25) }, timeout: 3) {
                self.check(BoostZoom.near(page()?.zoomFactor ?? 0, 1.25), "boosts2 (\(tag)): back on the site, 125 % again (\(page()?.zoomFactor ?? 0))")
                // The person zooms in themselves (⌘+): 150 %. Removing the size leaves their zoom.
                page()?.zoom(step: 1)
                done()
            }
        }
        wait(0.3)
        run { [self] in
            check(BoostZoom.near(page()?.zoomFactor ?? 0, 1.5), "boosts2 (\(tag)): ⌘+ zooms to 150 % (\(page()?.zoomFactor ?? 0))")
            center()?.update(domain: ip) { $0.font.size = 0 }
        }
        wait(0.5)
        run { [self] in
            check(BoostZoom.near(page()?.zoomFactor ?? 0, 1.5), "boosts2 (\(tag)): the person's own zoom stays when the size goes (\(page()?.zoomFactor ?? 0))")
            page()?.zoom(step: 0)
            center()?.update(domain: ip) { $0.font.size = 1 }
        }
        wait(0.5)
        run { [self] in
            check(BoostZoom.near(page()?.zoomFactor ?? 0, 1.1), "boosts2 (\(tag)): at 100 % again it takes the size (\(page()?.zoomFactor ?? 0))")
            center()?.remove(domain: ip, page: page())
        }
        wait(0.5)
        run { [self] in
            check(BoostZoom.near(page()?.zoomFactor ?? 0, 1), "boosts2 (\(tag)): deleting the Boost puts the page back to 100 % (\(page()?.zoomFactor ?? 0))")
            check(center()?.store.zoomedHosts.isEmpty == true, "boosts2 (\(tag)): and the app forgets the zoom it set (\(center()?.store.zoomedHosts ?? [:]))")
        }

        // 3b. Zap all like it (Arc's "Zap all related elements"): ⌥-click hides every element of the kind clicked.
        go({ a("/cards") }, title: "cards")
        run { [self] in
            c.showBoostEditor(section: .zap)
            editor()?.setZapping(true)
        }
        wait(0.5)
        waitJS("(document.querySelectorAll('.card')[1].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, altKey: true, button: 0 })), "
               + "Array.prototype.map.call(document.querySelectorAll('.card, .card-note'), function (e) { return getComputedStyle(e).display; }).join(','))",
               "⌥-click in Zap hides all three cards like it, not the note") { $0 == "none,none,none,block" }
        run { [self] in
            let z = center()?.store.boost(domain: ip)?.zaps.last
            check(z?.selector == "div.card.promo-card" && z?.label.hasPrefix("All 3 like") == true,
                  "boosts2 (\(tag)): the zap is stored for every card (\(z?.selector ?? "-"), \(z?.label ?? "-"))")
            editor()?.setZapping(false)
            c.closeBoostEditor(animated: false)
            center()?.remove(domain: ip, page: page())
        }

        // 4. Sharing, on a registrable site (WebKit: a simulated page there).
        let shareURL = { "http://www.\(reg):\(ports.a)/share" }
        var file = BoostFile(boost: Boost(domain: reg, colors: BoostColors(hue: 0.1, tint: 0.3), font: BoostFont(family: .charter),
                                          css: "#hero { color: rgb(70, 30, 110) !important; }",
                                          js: "document.documentElement.dataset.tried = 'ran';"), name: "Plum headings")
        file.id = "7d3c1f0e-5b2a-4c8d-9e6f-0a1b2c3d4e5f"
        file.revision = 1
        file.author = "Someone Else"
        func review() -> BoostImportReview? { BoostImportReview.active[ObjectIdentifier(self.c.window)] }
        goSimulated(shareURL, html: sharePage, title: "share")
        run { [self] in
            guard let link = try? BoostLink.url(for: file) else { return check(false, "boosts2 (\(tag)): the Boost fits in a link") }
            check(BoostSharing.open(link, on: c.window) && review()?.relation == .new && center()?.store.boost(domain: reg) == nil,
                  "boosts2 (\(tag)): a link opens the review, nothing installed yet")
            check(TestAnchors.frames["boost.import.author"] != nil && TestAnchors.frames["boost.import.tryOn"] != nil,
                  "boosts2 (\(tag)): the review names the (unverified) author and offers Try It On")
            review()?.setTryOn(true)
        }
        waitJS("getComputedStyle(document.getElementById('hero')).color + '|' + document.documentElement.dataset.tried",
               "Try It On shows its style on the page, and its code doesn't run") { $0 == "rgb(70, 30, 110)|undefined" }
        step { [self] done in
            guard let sheet = review()?.sheet else { return done() }
            captureWindow(sheet, name: "boosts2-review-tryon", rounded: 12, done)
        }
        run { [self] in review()?.cancel() }
        waitJS("getComputedStyle(document.getElementById('hero')).color", "Cancel takes it off again") { $0 == "rgb(10, 20, 30)" }
        run { [self] in
            check(center()?.store.boost(domain: reg) == nil && center()?.previews.isEmpty == true, "boosts2 (\(tag)): and installs nothing")
            if let link = try? BoostLink.url(for: file) { BoostSharing.open(link, on: c.window) }
            review()?.install()
            let b = center()?.store.boost(domain: reg)
            check(b?.origin?.kind == .installed && b?.origin?.revision == 1 && b?.origin?.author == "Someone Else" && b?.name == "Plum headings",
                  "boosts2 (\(tag)): installed with its origin (revision 1, the author's name)")
        }
        waitJS("getComputedStyle(document.getElementById('hero')).color + '|' + document.documentElement.dataset.tried",
               "installed, its style applies and its reviewed code runs") { $0 == "rgb(70, 30, 110)|ran" }
        run { [self] in
            var next = file
            next.revision = 2
            next.css = "#hero { color: rgb(20, 90, 60) !important; }"
            let url = dir.appendingPathComponent("plum-2.airc-boost")
            try? next.encoded().write(to: url)
            check(BoostSharing.open(url, on: c.window) && review()?.relation == .update(from: 1, to: 2) && TestAnchors.frames["boost.import.update"] != nil,
                  "boosts2 (\(tag)): revision 2 of the same Boost is an update (version 1 → 2)")
        }
        step { [self] done in
            guard let sheet = review()?.sheet else { return done() }
            captureWindow(sheet, name: "boosts2-review-update", rounded: 12, done)
        }
        run { [self] in
            review()?.install()
            check(center()?.store.boost(domain: reg)?.origin?.revision == 2, "boosts2 (\(tag)): the update is installed (revision 2)")
            let url = dir.appendingPathComponent("plum-1.airc-boost")
            try? file.encoded().write(to: url)
            check(BoostSharing.open(url, on: c.window) && review()?.relation == .older(have: 2, file: 1), "boosts2 (\(tag)): revision 1 now says it's older")
            review()?.cancel()
        }
        waitJS("getComputedStyle(document.getElementById('hero')).color", "the update's style applies") { $0 == "rgb(20, 90, 60)" }
        // The share sheet: the person shares the Boost they installed (a new Boost of theirs) with a screenshot.
        var share: BoostShareSheet?
        run { [self] in
            share = center().flatMap { BoostShareSheet(domain: reg, parent: c.window, controller: c, center: $0) }
            share?.author = "Check Author"
            share?.about = "Plum headings for the check."
            share?.present()
        }
        step { [self] done in
            waitUntil({ share?.screenshot != nil }, timeout: 4) {
                if share?.screenshot == nil { self.skip("boosts2 (\(tag)): the share sheet's screenshot (no picture of the page: \(self.realEventsBlocked ?? self.inputBlocked ?? "the window isn't drawn"))") }
                done()
            }
        }
        step { [self] done in
            guard let sheet = share?.sheet else { return done() }
            captureWindow(sheet, name: "boosts2-share", rounded: 12, done)
        }
        run { [self] in
            let url = dir.appendingPathComponent("shared.airc-boost")
            do {
                try share?.saveForCheck(to: url)
                let f = try BoostFile.read(url)
                check(f.id != nil && f.id != file.id && f.revision == 1 && f.author == "Check Author" && f.name == "Plum headings",
                      "boosts2 (\(tag)): the saved file is a new Boost of the sharer's, signed (\(f.id ?? "-"), r\(f.revision ?? 0), \(f.author ?? "-"))")
                if share?.screenshot != nil { check(f.previewData != nil, "boosts2 (\(tag)): with its screenshot (\(f.previewData?.count ?? 0) bytes)") }
                check(center()?.store.boost(domain: reg)?.origin?.kind == .shared && center()?.store.boost(domain: reg)?.origin?.id == f.id,
                      "boosts2 (\(tag)): the Boost now remembers it's the person's shared one")
                // A link from another app (the Apple event path) opens the same review: their own Boost.
                if let link = try? BoostLink.url(for: f) { app?.application(NSApp, open: [link]) }
            } catch { check(false, "boosts2 (\(tag)): the share sheet saves a file (\(error))") }
        }
        wait(0.5)
        run { [self] in
            check(review()?.relation == .own, "boosts2 (\(tag)): a link from another app opens the review (\(String(describing: review()?.relation)))")
            review()?.cancel()
        }
        wait(0.3)
        // A page at a Boost link (typed, or a link clicked in a page): the review opens over it, and nothing asked aircbrowser.com.
        run { [self] in
            guard let link = try? BoostLink.url(for: file) else { return }
            if chromium { page()?.load(link) } else { (page() as? WebKitTab)?.webView.loadSimulatedRequest(URLRequest(url: link), responseHTML: "<title>link</title>") }
        }
        step { [self] done in
            waitUntil({ review() != nil }, timeout: 6) {
                self.check(review()?.file.id == file.id, "boosts2 (\(tag)): a page at a Boost link opens its review (\(page()?.url?.host ?? "-"))")
                review()?.cancel()
                done()
            }
        }

        // 5. The gallery.
        run { [self] in
            guard let app else { return }
            BoostGalleryWindow.show(app: app)
            check(BoostGalleryWindow.shared?.window.isVisible == true, "boosts2 (\(tag)): the gallery window opens")
        }
        wait(1)
        step { [self] done in
            guard let w = BoostGalleryWindow.shared?.window else { return done() }
            captureWindow(w, name: "boosts2-gallery", rounded: 12, done)
        }
        run { [self] in
            guard let entry = BoostGallery.entries.first(where: { $0.file.site == "ycombinator.com" }) else { return }
            BoostGalleryWindow.shared?.get(entry)
            check(review()?.source.isGallery == true && review()?.file.id == entry.id, "boosts2 (\(tag)): Get opens its review in the browser window")
            // Not the real site in a check: no window to open it in.
            review()?.controller = nil
            review()?.install()
            let b = center()?.store.boost(domain: "ycombinator.com")
            check(b?.origin?.gallery == true && b?.origin?.id == entry.id && b?.js.isEmpty == true,
                  "boosts2 (\(tag)): the gallery Boost is added, from the gallery, with no code")
            check(BoostGalleryView.installedByID()[entry.id] != nil, "boosts2 (\(tag)): the gallery shows it as added")
            center()?.remove(domain: "ycombinator.com", page: nil)
            center()?.remove(domain: reg, page: nil)
            BoostGalleryWindow.shared?.window.close()
            serverA?.stop(); serverB?.stop()
        }
    }
}
#endif
