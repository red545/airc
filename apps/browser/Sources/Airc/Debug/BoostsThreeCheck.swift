// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script boosts3`: the Boost follow-ups, on loopback pages only.
///   1. Private windows: a boosted site's page in a private window has none of its Boost from its first script on (no
///      flash), says nothing to the app, isn't zoomed, and doesn't take live edits; the same page in a normal window
///      has it all (the engine's third install argument on Chromium, WebKit's private session on WebKit).
///   2. Zap in frames: Zap mode reaches the page's same-site frame; an element zapped there is a frame zap (hidden in
///      the frame, not on the page, whose element of the same selector stays); another site's frame is zapped whole
///      from the page; Esc inside the frame ends Zap mode; a reload keeps all three; the editor marks the frame's zap.
///   3. Chromium only: a page the Chromium build plays in WebKit (DRM services; `localhost` stands in) gets the
///      frames script: its same-site frame takes the frame style and zaps inside itself; in a private window, nothing.
extension SnapshotRunner {
    func boostsThreeScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        final class Box { var port: UInt16 = 0 }
        let box = Box()
        var server: LocalPageServer?
        var tabID = ""
        var privateWindow: PrivateWindowController?
        let page = { self.c.engineTab(for: tabID) }
        let privatePage = { privateWindow?.shownPage }
        let center = { BoostCenter.shared }
        let ip = "127.0.0.1"
        func url(_ host: String, _ path: String) -> String { "http://\(host):\(box.port)\(path)" }

        // The page: a first-script and first-frame probe, a #banner of its own, a frame of its own origin (whose
        // #banner is another element) and a frame of another site (localhost is another site than 127.0.0.1).
        func topPage(sameHost: String, otherHost: String) -> String {
            """
            <!doctype html><html><head><title>page</title><link rel="icon" href="data:,">
            <script>
            function boosted() { return getComputedStyle(document.documentElement).getPropertyValue('--boosted').trim() || 'none'; }
            window.__atStart = boosted();
            requestAnimationFrame(function () { window.__firstFrame = boosted(); });
            </script>
            <style>body { font-family: Times; margin: 0; padding: 12px } #hero { color: rgb(10, 20, 30) }
            #banner { height: 30px; background: #fc9 } iframe { display: block; width: 320px; height: 110px; border: 0; margin: 8px 0 }</style>
            </head><body><h1 id="hero">Top</h1><div id="banner">the page's banner</div>
            <iframe id="inner" src="\(url(sameHost, "/inner"))"></iframe>
            <iframe id="ad" src="\(url(otherHost, "/ad"))"></iframe>
            <script>
            window.__probes = {};
            addEventListener('message', function (e) { if (e.data && e.data.kind === 'probe') window.__probes[e.data.n] = e.data; });
            function probeAll() { for (var i = 0; i < frames.length; i++) frames[i].postMessage('probe', '*'); }
            function tell(cmd) { for (var i = 0; i < frames.length; i++) frames[i].postMessage({ cmd: cmd }, '*'); }
            </script></body></html>
            """
        }
        let inner = """
            <!doctype html><html><head><title>inner</title>
            <style>body { font-family: Times; margin: 0 } #banner { height: 44px; background: #9cf } .keep { height: 20px }</style>
            </head><body><div id="banner">the frame's banner</div><div class="keep">kept</div>
            <script>
            function report() {
              parent.postMessage({ kind: 'probe', n: 'inner', banner: getComputedStyle(document.getElementById('banner')).display,
                keep: getComputedStyle(document.querySelector('.keep')).display, zapping: !!document.querySelector('airc-zap'),
                font: getComputedStyle(document.body).fontFamily }, '*');
            }
            addEventListener('message', function (e) {
              if (e.data === 'probe') return report();
              var cmd = e.data && e.data.cmd;
              if (cmd === 'synthzap') {
                var el = document.getElementById('banner'), r = el.getBoundingClientRect();
                var o = { bubbles: true, cancelable: true, button: 0, clientX: r.left + 6, clientY: r.top + 6 };
                el.dispatchEvent(new MouseEvent('mousemove', o)); el.dispatchEvent(new MouseEvent('mousedown', o));
                el.dispatchEvent(new MouseEvent('mouseup', o)); el.dispatchEvent(new MouseEvent('click', o));
              } else if (cmd === 'esc') {
                window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
              }
            });
            addEventListener('load', report);
            </script></body></html>
            """
        let ad = """
            <!doctype html><html><head><title>ad</title></head><body style="margin: 0; background: #c9f">
            <script>addEventListener('message', function (e) { if (e.data === 'probe') parent.postMessage({ kind: 'probe', n: 'ad',
              zapping: !!document.querySelector('airc-zap') }, '*'); });</script>another site's frame</body></html>
            """
        func answer(_ path: String) -> LocalPageServer.Page? {
            switch path.components(separatedBy: "?").first ?? path {
            case "/page": return .init(body: topPage(sameHost: ip, otherHost: "localhost"))
            case "/wk": return .init(body: topPage(sameHost: "localhost", otherHost: ip))
            case "/inner": return .init(body: inner)
            case "/ad": return .init(body: ad)
            default: return nil
            }
        }

        func waitLoaded(_ p: @escaping () -> EngineTab?, _ what: String) {
            step { [self] done in
                waitUntil({ p()?.title == "page" && p()?.isLoading == false }, timeout: 15) {
                    if p()?.title != "page" { self.check(false, "boosts3 (\(tag)): \(what) loads (\(p()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
                }
            }
        }
        /// Evaluates `code` in `p` until `ok` (or the timeout), then checks it.
        func expectJS(_ p: @escaping () -> EngineTab?, _ code: String, _ what: String, timeout: Double = 5, _ ok: @escaping (String) -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    guard let tab = p() else { check(false, "boosts3 (\(tag)): \(what) (no page)"); return done() }
                    tab.evaluate(code) { v in
                        let got = v.map { "\($0)" } ?? "nil"
                        if ok(got) || Date() > deadline { self.check(ok(got), "boosts3 (\(tag)): \(what) (\(got))"); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                    }
                }
                poll()
            }
        }
        /// The frame `n`'s report, as JSON text ("none" until it answers).
        func probe(_ n: String) -> String { "(probeAll(), window.__probes['\(n)'] ? JSON.stringify(window.__probes['\(n)']) : 'none')" }
        /// A click at the page's point (x, y): on Chromium through the DevTools protocol's input (the person's kind of
        /// click, into whatever frame is there); elsewhere, or when that doesn't take, `fallback` in the page.
        func clickAt(_ p: @escaping () -> EngineTab?, point js: String, fallback: String, until: @escaping () -> Bool, _ what: String) {
            var xy: [Double] = []
            step { done in
                p()?.evaluate(js) { v in xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []; done() }
            }
            step { [self] done in
                guard xy.count == 2, let tab = p() else { check(false, "boosts3 (\(tag)): \(what): on the page"); return done() }
                #if canImport(AircCore)
                if chromium, !(tab is WebKitTab), let engine = app?.engine as? ChromiumEngine {
                    let events: [[String: Any]] = [
                        ["type": "mouseMoved", "x": xy[0], "y": xy[1]],
                        ["type": "mousePressed", "x": xy[0], "y": xy[1], "button": "left", "clickCount": 1],
                        ["type": "mouseReleased", "x": xy[0], "y": xy[1], "button": "left", "clickCount": 1],
                    ]
                    func send(_ k: Int) {
                        guard k < events.count else { note("boosts3 (\(tag)): \(what): a click through the DevTools protocol's input"); return done() }
                        engine.devToolsCall("Input.dispatchMouseEvent", params: events[k], in: tab) { _, _ in send(k + 1) }
                    }
                    return send(0)
                }
                #endif
                done()
            }
            step { [self] done in
                waitUntil(until, timeout: 2) {
                    if until() { return done() }
                    self.note("boosts3 (\(tag)): \(what): synthetic events instead (this scripted run's page script takes them)")
                    p()?.evaluate(fallback) { _ in done() }
                }
            }
        }
        func zaps(_ domain: String) -> [BoostZap] { center()?.store.boost(domain: domain)?.zaps ?? [] }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = answer
            guard let server else { check(false, "boosts3: the loopback server starts"); return done() }
            server.start { p in
                box.port = p ?? 0
                self.check(box.port != 0, "boosts3 (\(tag)): the loopback server starts")
                done()
            }
        }
        run {
            center()?.update(domain: ip) {
                $0.css = ":root { --boosted: yes; } #hero { color: rgb(1, 2, 3) !important; }"
                $0.font = BoostFont(family: .georgia, size: 1)
                $0.zaps = []
            }
        }
        wait(0.7)

        // MARK: 1. Private windows

        run { [self] in
            guard box.port != 0, let t = try? c.store.openTab(url: url(ip, "/page?n=1"), inSpace: c.currentSpaceID, title: "page") else { return }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        waitLoaded(page, "the normal window's page")
        expectJS(page, "window.__atStart + '|' + getComputedStyle(document.getElementById('hero')).color",
                 "a normal window: the Boost is there in the page's first script, and styles it") { $0 == "yes|rgb(1, 2, 3)" }
        let zoom = BoostFont(size: 1).scale
        step { [self] done in
            waitUntil({ abs((page()?.zoomFactor ?? 1) - zoom) < 0.01 }, timeout: 4) {
                self.check(abs((page()?.zoomFactor ?? 1) - zoom) < 0.01 && page().flatMap { center()?.document(of: $0) } != nil,
                           "boosts3 (\(tag)): a normal window: the Boost's size zooms it (\(page()?.zoomFactor ?? 0)) and the app knows its document")
                done()
            }
        }
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                w?.openPage(URL(string: url(ip, "/page?n=private")))
                done()
            }
        }
        waitLoaded(privatePage, "the private window's page")
        expectJS(privatePage, "[window.__atStart, getComputedStyle(document.getElementById('hero')).color, document.adoptedStyleSheets.length, getComputedStyle(document.body).fontFamily].join('|')",
                 "a private window: none of the Boost from the first script on, no sheet adopted, the page's own font") {
            $0.hasPrefix("none|rgb(10, 20, 30)|0|") && !$0.contains("Georgia")
        }
        run { [self] in
            guard let p = privatePage() else { return check(false, "boosts3 (\(tag)): the private page") }
            check(center()?.document(of: p) == nil && center()?.frameDocumentCount(p) == 0 && abs(p.zoomFactor - 1) < 0.01,
                  "boosts3 (\(tag)): a private window: the app keeps no document for the page or its frames, and it isn't zoomed (\(p.zoomFactor))")
            center()?.update(domain: ip) { $0.css += " #hero { letter-spacing: 3px !important; }" }
        }
        expectJS(page, "getComputedStyle(document.getElementById('hero')).letterSpacing", "a live edit reaches the normal window's page") { $0 == "3px" }
        expectJS(privatePage, "getComputedStyle(document.getElementById('hero')).letterSpacing + '|' + document.adoptedStyleSheets.length",
                 "…and not the private window's") { $0 == "normal|0" }
        run { privateWindow?.window.close(); privateWindow = nil }
        wait(0.5)

        // MARK: 2. Zap in frames

        expectJS(page, probe("inner"), "the page's same-site frame takes the frame style (the Boost's font)") { $0.contains("Georgia") }
        run { [self] in
            guard let p = page() else { return }
            check((center()?.frameDocumentCount(p) ?? 0) >= 1, "boosts3 (\(tag)): the app knows the page's same-site frame document")
            center()?.setZapping(true, tab: p, domain: ip)
        }
        expectJS(page, probe("inner"), "Zap mode reaches the page's same-site frame") { $0.contains("\"zapping\":true") }
        expectJS(page, probe("ad"), "…and not another site's frame (it has no Boost part)") { $0.contains("\"zapping\":false") }
        clickAt(page, point: "(function () { var r = document.getElementById('inner').getBoundingClientRect(); return [r.left + 24, r.top + 18]; })()",
                fallback: "tell('synthzap')", until: { zaps(ip).contains { $0.frame } }, "a click on the frame's banner")
        step { [self] done in
            waitUntil({ zaps(ip).contains { $0.frame } }, timeout: 3) {
                let z = zaps(ip).first { $0.frame }
                self.check(z?.selector == "#banner", "boosts3 (\(tag)): the element zapped in the frame is a frame zap (\(z?.selector ?? "none"), \"\(z?.label ?? "")\")")
                done()
            }
        }
        expectJS(page, probe("inner"), "the frame's banner is hidden, the rest of the frame kept") { $0.contains("\"banner\":\"none\"") && $0.contains("\"keep\":\"block\"") }
        expectJS(page, "getComputedStyle(document.getElementById('banner')).display", "the page's own #banner stays: a frame's zap is the frames' only") { $0 == "block" }
        clickAt(page, point: "(function () { var r = document.getElementById('ad').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()",
                fallback: """
                    (function () { var f = document.getElementById('ad'), r = f.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
                      var el = document.elementFromPoint(x, y) || document.body, o = { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y };
                      el.dispatchEvent(new MouseEvent('mousemove', o)); el.dispatchEvent(new MouseEvent('mousedown', o));
                      el.dispatchEvent(new MouseEvent('mouseup', o)); el.dispatchEvent(new MouseEvent('click', o)); return el.localName })()
                    """,
                until: { zaps(ip).contains { !$0.frame && $0.selector.contains("ad") } }, "a click on another site's frame")
        step { [self] done in
            waitUntil({ zaps(ip).contains { !$0.frame && $0.selector.contains("ad") } }, timeout: 3) {
                let z = zaps(ip).first { !$0.frame }
                self.check(z?.selector == "#ad", "boosts3 (\(tag)): another site's frame is zapped whole, as the page's (\(z?.selector ?? "none"))")
                done()
            }
        }
        expectJS(page, "getComputedStyle(document.getElementById('ad')).display", "that frame is hidden on the page") { $0 == "none" }
        run { [self] in check(center()?.isZapping(page()) == true, "boosts3 (\(tag)): still zapping") }
        run { page()?.evaluate("tell('esc')") { _ in } }
        step { [self] done in
            waitUntil({ center()?.isZapping(page()) == false }, timeout: 3) {
                self.check(center()?.isZapping(page()) == false, "boosts3 (\(tag)): Esc inside the frame ends Zap mode")
                done()
            }
        }
        expectJS(page, probe("inner"), "…in the frame too") { $0.contains("\"zapping\":false") }
        run { page()?.reload() }
        waitLoaded(page, "the reloaded page")
        expectJS(page, probe("inner") + " + '|' + getComputedStyle(document.getElementById('banner')).display + '|' + getComputedStyle(document.getElementById('ad')).display",
                 "after a reload: the frame's banner hidden from its first paint, the page's kept, the other site's frame hidden") {
            $0.contains("\"banner\":\"none\"") && $0.hasSuffix("|block|none")
        }
        run { [self] in c.showBoostEditor(domain: ip, page: page(), section: .zap) }
        wait(1.0)
        run { [self] in
            check(TestAnchors.frames["boost.undoZap.frame.#banner"] != nil && TestAnchors.frames["boost.undoZap.#ad"] != nil,
                  "boosts3 (\(tag)): the editor lists the frame's zap as one in a frame, and the page's")
        }
        capture("boosts3-editor-frame-zap")
        run { [self] in _ = c.closeBoostEditor(animated: false) }

        // MARK: 3. WebKit-routed pages (Chromium only)

        if chromium {
            run {
                ProtectedMedia.shared.testHosts = ["localhost"]
                center()?.update(domain: "localhost") {
                    $0.css = ":root { --boosted: yes; }"
                    $0.font = BoostFont(family: .georgia)
                    $0.zaps = []
                }
            }
            wait(0.7)
            run { [self] in
                guard let t = try? c.store.openTab(url: url("localhost", "/wk?n=wk"), inSpace: c.currentSpaceID, title: "page") else { return }
                tabID = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            waitLoaded(page, "the WebKit-routed page")
            run { [self] in check(page() is WebKitTab, "boosts3 (\(tag)): localhost plays in WebKit inside the Chromium build (as a DRM service would)") }
            expectJS(page, "window.__atStart", "a WebKit-routed page has its Boost in its first script") { $0 == "yes" }
            expectJS(page, probe("inner"), "its same-site frame takes the frame style (frames script on the WebKit path)") { $0.contains("Georgia") }
            run { [self] in
                guard let p = page() else { return }
                check((center()?.frameDocumentCount(p) ?? 0) >= 1, "boosts3 (\(tag)): the app knows that frame's document")
                center()?.setZapping(true, tab: p, domain: "localhost")
            }
            expectJS(page, probe("inner"), "Zap mode reaches that frame") { $0.contains("\"zapping\":true") }
            run { page()?.evaluate("tell('synthzap')") { _ in } }
            step { [self] done in
                waitUntil({ zaps("localhost").contains { $0.frame } }, timeout: 3) {
                    self.check(zaps("localhost").first { $0.frame }?.selector == "#banner", "boosts3 (\(tag)): a zap inside the WebKit page's frame is a frame zap")
                    done()
                }
            }
            expectJS(page, probe("inner"), "…and hides the frame's banner") { $0.contains("\"banner\":\"none\"") }
            run { [self] in if let p = page() { center()?.setZapping(false, tab: p, domain: "localhost") } }
            step { [self] done in
                guard let app else { return done() }
                PrivateBrowsing.shared.open(app: app) { w in
                    privateWindow = w
                    w?.openPage(URL(string: url("localhost", "/wk?n=private")))
                    done()
                }
            }
            waitLoaded(privatePage, "the private window's WebKit-routed page")
            expectJS(privatePage, "[window.__atStart, document.adoptedStyleSheets.length, getComputedStyle(document.body).fontFamily].join('|')",
                     "a private window's WebKit-routed page: no Boost (WebKit's private session)") { $0.hasPrefix("none|0|") && !$0.contains("Georgia") }
            run { [self] in
                check(privatePage() is WebKitTab && privatePage().flatMap { center()?.document(of: $0) } == nil,
                      "boosts3 (\(tag)): …in WebKit, and the app keeps no document for it")
                privateWindow?.window.close(); privateWindow = nil
                ProtectedMedia.shared.testHosts = []
            }
        }

        run {
            server?.stop()
            for d in [ip, "localhost"] { center()?.remove(domain: d, page: nil) }
        }
    }
}
#endif
