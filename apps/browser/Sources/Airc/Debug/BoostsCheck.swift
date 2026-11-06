// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script boosts` (both engines; BST-1): Boosts on pages from a loopback server. Site A is 127.0.0.1, site B is
/// localhost (the same server: another site to the browser).
///   - the Boost's CSS is there at first paint: the page's own head script, the first parsed elements and its first
///     animation frame already see it (no flash), also under a strict Content-Security-Policy;
///   - the font, the custom CSS and the custom JS apply, the JS once per page load and only on its own site;
///   - nothing applies on site B, and the top frame only (an iframe of site A keeps its own style);
///   - editing in the editor changes the open page at once, without a reload;
///   - Zap hides the element the click lands on, stores a selector, and the element is hidden from the first paint
///     of a reload; undoing it shows it again;
///   - Site Controls shows "Boosted" with its switch (a real click), the URL field shows the Boost icon; switching
///     off restores the page; on again, it's back;
///   - View → Boost This Site… opens the editor; the Boost is in Boosts.json;
///   - the editor's sections in a light and a dark theme (boosts-*.png), and Site Controls with a Boost.
extension SnapshotRunner {
    func boostsScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var tabID = ""
        var homeSpace = ""
        let page = { self.c.engineTab(for: tabID) }
        let center = { BoostCenter.shared }
        let siteA = "127.0.0.1", siteB = "localhost"
        let editor = { self.c.boostEditor?.model }
        func base(_ host: String) -> String { "http://\(host):\(port)" }

        let probe = """
            <script>
            (function () {
              var h = document.documentElement, s = getComputedStyle(h);
              window.__atStart = { filter: s.filter, tint: getComputedStyle(h, '::after').backgroundColor };
              requestAnimationFrame(function () {
                var hero = document.getElementById('hero'), ad = document.querySelector('.promo-banner');
                window.__firstFrame = { filter: getComputedStyle(document.documentElement).filter,
                  hero: hero ? getComputedStyle(hero).color : '', ad: ad ? getComputedStyle(ad).display : '' };
              });
            })();
            </script>
            """
        let body = """
            <h1 id="hero">Boost test page</h1>
            <script>window.__heroAtParse = getComputedStyle(document.getElementById('hero')).color;</script>
            <div class="promo-banner" style="height: 80px; background: #fc0">Subscribe to our newsletter</div>
            <script>window.__adAtParse = getComputedStyle(document.querySelector('.promo-banner')).display;</script>
            <p>Body text for the Boost test, with <code>code</code> in it.</p>
            """
        let style = "<style>body { font-family: Times; margin: 0; padding: 24px; background: #fff } #hero { color: rgb(10, 20, 30) }</style>"

        step { [self] done in
            server = LocalPageServer(responses: [
                "/boost": .init(body: "<!doctype html><html><head><title>boost</title>\(probe)\(style)</head><body>\(body)"
                                + "<iframe src=\"/frame\" style=\"width: 300px; height: 80px\"></iframe></body></html>"),
                "/other": .init(body: "<!doctype html><html><head><title>other</title>\(probe)\(style)</head><body>\(body)</body></html>"),
                "/frame": .init(body: "<!doctype html><html><head><title>frame</title>\(style)</head><body><h1 id=\"hero\">Frame</h1></body></html>"),
                "/csp": .init(headers: ["Content-Security-Policy": "style-src 'none'; script-src 'unsafe-inline'"],
                              body: "<!doctype html><html><head><title>csp</title>\(probe)</head><body>\(body)</body></html>"),
            ])
            guard let server else { check(false, "boosts: the loopback server starts"); return done() }
            server.start { p in
                guard let p else { self.check(false, "boosts: the loopback server starts"); return done() }
                port = p
                done()
            }
        }

        func open(_ url: @escaping () -> String, title: String) {
            run { [self] in
                guard port != 0, let t = try? c.store.openTab(url: url(), inSpace: c.currentSpaceID, title: title) else { return }
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
        func waitTitle(_ title: String) {
            step { [self] done in
                waitUntil({ page()?.title == title && page()?.isLoading == false }, timeout: 10) {
                    if page()?.title != title { self.check(false, "boosts (\(tag)): \(title) loads (\(page()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }
        func js(_ code: String, _ then: @escaping (String) -> Void) {
            step { done in
                guard let p = page() else { then("no page"); return done() }
                p.evaluate(code) { value in
                    then(value.map { "\($0)" } ?? "nil")
                    done()
                }
            }
        }
        func expectJS(_ code: String, _ what: String, _ ok: @escaping (String) -> Bool) {
            js(code) { [self] got in check(ok(got), "boosts (\(tag)): \(what) (page says \(got))") }
        }
        func waitJS(_ code: String, _ what: String, timeout: Double = 4, _ ok: @escaping (String) -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    guard let p = page() else { check(false, "boosts (\(tag)): \(what) (no page)"); return done() }
                    p.evaluate(code) { value in
                        let got = value.map { "\($0)" } ?? "nil"
                        if ok(got) { self.check(true, "boosts (\(tag)): \(what) (page says \(got))"); return done() }
                        if Date() > deadline { self.check(false, "boosts (\(tag)): \(what) (page says \(got))"); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
                    }
                }
                poll()
            }
        }
        /// The engine gets a new page script a moment after a change (PageScripts' throttle).
        func settle() { wait(0.6) }
        /// Reloads and waits for the new document (the title alone doesn't change).
        func reloadPage() {
            js("window.__beforeReload = 1; 'ok'") { _ in }
            run { page()?.reload() }
            waitJS("String(window.__beforeReload) + '|' + document.readyState", "the page reloads") { $0 == "undefined|complete" }
        }
        let unboosted = { (s: String) in s == "none" }

        open({ base(siteA) + "/other" }, title: "other")
        run { [self] in homeSpace = c.currentSpaceID }

        // 0. Before any Boost: the page is as it is, and the editor knows the site.
        expectJS("window.__atStart.filter", "an unboosted page has no filter", unboosted)
        run { [self] in
            check(c.boostsAvailable, "boosts (\(tag)): the engine has a page script for Boosts")
            c.showBoostEditor()
            check(editor()?.domain == siteA && editor()?.exists == false,
                  "boosts (\(tag)): the editor opens for the site on screen (\(editor()?.domain ?? "-")), with no Boost stored yet")
        }
        wait(0.4)
        capture("boosts-editor-new")

        // 1. A Boost for site A: colours, font, custom CSS and JS (as the editor stores them).
        run { [self] in
            c.closeBoostEditor(animated: false)
            center()?.update(domain: siteA) {
                $0.colors = BoostColors(hue: 0.58, tint: 0, brightness: 0.9, contrast: 1, invert: true)
                $0.font = BoostFont(family: .georgia, size: 0)
                $0.css = "#hero { color: rgb(1, 2, 3) !important; }"
                $0.js = "document.documentElement.dataset.boostJs = location.hostname;\nwindow.__boostRuns = (window.__boostRuns || 0) + 1;"
            }
        }
        settle()
        go({ base(siteA) + "/boost" }, title: "boost")
        expectJS("window.__atStart.filter", "the colours are on the page in its own first script (document start)") {
            $0.contains("invert(1)") && $0.contains("brightness(0.9)")
        }
        expectJS("window.__heroAtParse", "the custom CSS applies to the first parsed element") { $0 == "rgb(1, 2, 3)" }
        // The first animation frame, where the window draws (no frames while the screen is locked or it's covered).
        js("window.__firstFrame ? JSON.stringify(window.__firstFrame) : 'none'") { [self] got in
            if got == "none" { skip("boosts (\(tag)): the first animation frame (none ran: \(realEventsBlocked ?? inputBlocked ?? "the window isn't drawn"))") }
            else { check(got.contains("invert(1)") && got.contains("rgb(1, 2, 3)"), "boosts (\(tag)): the first animation frame is boosted (no flash) (page says \(got))") }
        }
        expectJS("getComputedStyle(document.body).fontFamily", "the font applies") { $0.contains("Georgia") }
        expectJS("getComputedStyle(document.querySelector('code')).fontFamily", "code keeps its own font") { !$0.contains("Georgia") }
        expectJS("getComputedStyle(document.querySelector('img, video, iframe')).filter", "frames and pictures are inverted back") {
            $0.contains("invert(1)")
        }
        waitJS("document.documentElement.dataset.boostJs + '/' + window.__boostRuns", "the custom JS runs on its site, once") { $0 == "127.0.0.1/1" }
        expectJS("document.querySelector('iframe').contentDocument.getElementById('hero') && getComputedStyle(document.querySelector('iframe').contentDocument.getElementById('hero')).color",
                 "an iframe keeps its own style (top frame only)") { $0 == "rgb(10, 20, 30)" }
        go({ base(siteA) + "/other" }, title: "other")
        waitJS("document.documentElement.dataset.boostJs + '/' + window.__boostRuns", "another page of the site runs it once too") { $0 == "127.0.0.1/1" }

        // 2. Site B: nothing applies, no code runs.
        open({ base(siteB) + "/boost" }, title: "boost")
        expectJS("JSON.stringify([window.__atStart.filter, window.__heroAtParse, getComputedStyle(document.body).fontFamily])",
                 "nothing of site A's Boost applies on another site") { $0 == #"["none","rgb(10, 20, 30)","Times"]"# }
        wait(1)
        expectJS("String(document.documentElement.dataset.boostJs) + '/' + String(window.__boostRuns)", "site A's code never runs on site B") {
            $0 == "undefined/undefined"
        }
        run { [self] in
            let elsewhere = center()?.scriptRuns.filter { $0.domain != siteA || $0.origin != siteA } ?? []
            check(elsewhere.isEmpty && center()?.scriptRuns.isEmpty == false,
                  "boosts (\(tag)): the app sent code only to site A's pages (\(center()?.scriptRuns.map { "\($0.domain)@\($0.origin)" } ?? []))")
        }

        // 3. A strict Content-Security-Policy (no styles, no eval) doesn't stop the Boost.
        go({ base(siteA) + "/csp" }, title: "csp")
        expectJS("JSON.stringify([window.__heroAtParse, window.__atStart.filter])", "the Boost applies under a strict CSP") {
            $0.contains("rgb(1, 2, 3)") && $0.contains("invert(1)")
        }
        waitJS("String(document.documentElement.dataset.boostJs)", "the custom JS runs under a strict CSP") { $0 == "127.0.0.1" }

        // 4. Live: the editor changes the open page without a reload.
        go({ base(siteA) + "/boost" }, title: "boost")
        js("window.__kept = 'same page'; 'ok'") { _ in }
        run { [self] in
            c.showBoostEditor()
            check(editor()?.exists == true && editor()?.boost.colors.invert == true, "boosts (\(tag)): the editor shows the stored Boost")
            editor()?.color(\.invert).wrappedValue = false
            editor()?.color(\.tint).wrappedValue = 0.6
        }
        waitJS("getComputedStyle(document.documentElement).filter + '|' + window.__kept", "turning invert off applies at once, without a reload") {
            !$0.contains("invert") && $0.hasSuffix("|same page")
        }
        waitJS("getComputedStyle(document.documentElement, '::after').backgroundColor", "the tint applies at once") {
            $0.hasPrefix("rgb(") && $0 != "rgba(0, 0, 0, 0)"
        }
        run { [self] in editor()?.setFamily(.menlo); editor()?.stepSize(1) }
        waitJS("getComputedStyle(document.body).fontFamily + '|' + getComputedStyle(document.body).zoom", "font and size change at once") {
            $0.contains("Menlo") && $0.hasSuffix("|1.1")
        }
        run { [self] in editor()?.section = .colors }
        wait(0.4)
        capture("boosts-editor-colors")

        // 5. Zap: a click on the page hides the element, and it stays hidden from the first paint of a reload.
        run { [self] in
            editor()?.stepSize(0)
            editor()?.section = .zap
            editor()?.setZapping(true)
        }
        wait(0.5)
        run { [self] in check(editor()?.zapping == true, "boosts (\(tag)): Zap mode is on") }
        zapClick(selector: ".promo-banner", chromium: chromium, tag: tag, page: page)
        step { [self] done in
            waitUntil({ (center()?.store.boost(domain: siteA)?.zaps.count ?? 0) > 0 }, timeout: 4) {
                let z = center()?.store.boost(domain: siteA)?.zaps.first
                self.check(z?.selector == "div.promo-banner" && z?.label == "Subscribe to our newsletter",
                           "boosts (\(tag)): the zapped element is stored with a robust selector (\(z?.selector ?? "-"), \"\(z?.label ?? "-")\")")
                done()
            }
        }
        expectJS("getComputedStyle(document.querySelector('.promo-banner')).display", "the zapped element is hidden") { $0 == "none" }
        wait(0.4)
        capture("boosts-editor-zap")
        run { [self] in editor()?.setZapping(false) }
        wait(0.3)
        run { [self] in check(editor()?.zapping == false, "boosts (\(tag)): Done Zapping ends Zap mode") }
        settle()
        reloadPage()
        expectJS("window.__adAtParse + '|' + (window.__firstFrame ? window.__firstFrame.ad : 'none')",
                 "the zap persists across a reload, hidden from the first parse (and first frame, where one ran)") { $0 == "none|none" }
        run { [self] in
            if let id = editor()?.boost.zaps.first?.id { editor()?.undoZap(id) }
        }
        waitJS("getComputedStyle(document.querySelector('.promo-banner')).display", "undoing the zap shows it again at once") { $0 == "block" }

        // 6. Code: Save applies the CSS live.
        run { [self] in
            editor()?.section = .code
            editor()?.codeKind = .css
            editor()?.css = "#hero { color: rgb(1, 2, 3) !important; }\nh1 { letter-spacing: 3px; }"
        }
        wait(0.3)
        run { [self] in check(editor()?.codeDirty == true, "boosts (\(tag)): edited code shows as unsaved") }
        capture("boosts-editor-code")
        run { [self] in editor()?.saveCode() }
        waitJS("getComputedStyle(document.getElementById('hero')).letterSpacing", "saved CSS applies at once") { $0 == "3px" }
        run { [self] in
            editor()?.section = .font
        }
        wait(0.3)
        capture("boosts-editor-font")
        run { [self] in c.closeBoostEditor(animated: false) }

        // 7. Site Controls: "Boosted" with its switch; the URL field's Boost icon; off restores the page.
        step { [self] done in
            let field = c.pageView(for: c.currentSpaceID)?.urlField
            waitUntil({ field?.siteIndicators.kinds.contains(.boost) == true }, timeout: 3) {
                self.check(field?.siteIndicators.kinds.contains(.boost) == true,
                           "boosts (\(tag)): the URL field shows the Boost icon (\(field?.siteIndicators.kinds.map(\.rawValue) ?? []))")
                done()
            }
        }
        run { [self] in if c.siteControls == nil { c.toggleSiteControls() } }
        step { [self] done in
            waitUntil({ self.c.siteControls?.model.boost != nil }, timeout: 2) {
                let m = self.c.siteControls?.model
                self.check(m?.boost?.enabled == true && TestAnchors.frames["site.boostState"] != nil,
                           "boosts (\(tag)): Site Controls shows the site as Boosted, with a switch")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
            }
        }
        captureSiteControls("boosts-sitecontrols")
        clickIn({ self.c.siteControls?.hostingView }, "site.boostSwitch")
        step { [self] done in
            waitUntil({ center()?.store.boost(domain: siteA)?.enabled == false }, timeout: 2) {
                var how = "a real click"
                if center()?.store.boost(domain: siteA)?.enabled != false {
                    if let why = self.realEventsBlocked { how = "the switch's binding (\(why))" } else { how = "the switch's binding (the click didn't land)" }
                    self.c.siteControls?.model.boostEnabled.wrappedValue = false
                }
                self.check(center()?.store.boost(domain: siteA)?.enabled == false, "boosts (\(tag)): the Site Controls switch turns the Boost off (\(how))")
                done()
            }
        }
        // The page ran the Boost's code, so it reloads to be itself again.
        waitJS("JSON.stringify([window.__atStart.filter, window.__heroAtParse, window.__adAtParse, String(document.documentElement.dataset.boostJs)])",
               "switching the Boost off restores the page") { $0 == #"["none","rgb(10, 20, 30)","block","undefined"]"# }
        run { [self] in
            let kinds = c.pageView(for: c.currentSpaceID)?.urlField.siteIndicators.kinds ?? []
            check(!kinds.contains(.boost), "boosts (\(tag)): the Boost icon goes when it's off")
            check(c.siteControls?.model.boost?.enabled == false || c.siteControls == nil, "boosts (\(tag)): Site Controls shows it off")
            c.closeSiteControls(animated: false)
        }
        run { [self] in center()?.setEnabled(true, domain: siteA, page: page()) }
        waitJS("getComputedStyle(document.getElementById('hero')).color + '|' + document.documentElement.dataset.boostJs + '/' + window.__boostRuns",
               "on again, the style is back at once and the code runs once") { $0 == "rgb(1, 2, 3)|127.0.0.1/1" }

        // 8. The menu item, and the file.
        run { [self] in
            let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
            let item = view?.items.first { $0.title == "Boost This Site…" }
            check(item != nil && item?.keyEquivalent == "", "boosts (\(tag)): View → Boost This Site… is in the menu, with no shortcut")
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            check(c.boostEditor?.model.domain == siteA, "boosts (\(tag)): the menu item opens the editor")
            c.closeBoostEditor(animated: false)
        }
        wait(1)
        run { [self] in
            let url = AppPaths.dataDirectory.appendingPathComponent("Boosts.json")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check(text.contains("\"domain\" : \"127.0.0.1\"") && text.contains("Menlo".lowercased()) && text.contains("letter-spacing"),
                  "boosts (\(tag)): the Boost is saved in Boosts.json (\(text.count) bytes)")
        }

        // 9. The editor in a light and a dark theme.
        for appearance in [Appearance.light, .dark] {
            run { [self] in
                try? c.store.updateSpace(homeSpace) { $0.theme.appearance = appearance }
                c.reloadAll(animated: false)
                c.showBoostEditor(section: .colors)
            }
            wait(0.5)
            capture("boosts-\(appearance.rawValue)")
            run { [self] in c.closeBoostEditor(animated: false) }
        }
        run { [self] in
            center()?.remove(domain: siteA, page: nil)
            server?.stop()
        }
    }

    /// Clicks the element `selector` on the page with the person's kind of click: on Chromium through the DevTools
    /// protocol's input (trusted events in the renderer, nothing on the owner's screen); on WebKit a posted click in our
    /// window. When that can't reach the page (a window that isn't drawn), a synthetic click, which this scripted run's
    /// page script accepts (BoostCenter: TRUST_SYNTHETIC only in `--script boosts`).
    private func zapClick(selector: String, chromium: Bool, tag: String, page: @escaping () -> EngineTab?) {
        var rect: [Double] = []
        step { done in
            page()?.evaluate("(function () { var r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()") { v in
                rect = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                done()
            }
        }
        step { [self] done in
            guard rect.count == 2, let p = page() else { check(false, "boosts (\(tag)): the element to zap is on the page"); return done() }
            let (x, y) = (rect[0], rect[1])
            #if canImport(AircCore)
            if chromium, let engine = app?.engine as? ChromiumEngine {
                let events: [[String: Any]] = [
                    ["type": "mouseMoved", "x": x, "y": y],
                    ["type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1],
                    ["type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1],
                ]
                func send(_ k: Int) {
                    guard k < events.count else { note("boosts (\(tag)): zap click through the DevTools protocol's input"); return done() }
                    engine.devToolsCall("Input.dispatchMouseEvent", params: events[k], in: p) { _, error in
                        if let error { self.note("boosts (\(tag)): Input.dispatchMouseEvent: \(error)") }
                        send(k + 1)
                    }
                }
                return send(0)
            }
            #endif
            let view = p.view
            guard let w = view.window else { return done() }
            let local = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
            note("boosts (\(tag)): zap click posted in our window")
            click(at: view.convert(local, to: nil), in: w, done)
        }
        step { [self] done in
            let center = BoostCenter.shared
            waitUntil({ (center?.store.all.first?.zaps.count ?? 0) > 0 }, timeout: 2) {
                if (center?.store.all.first?.zaps.count ?? 0) > 0 { return done() }
                self.note("boosts (\(tag)): the click didn't reach the page (\(self.realEventsBlocked ?? "window not key")); a synthetic click instead")
                page()?.evaluate("""
                    (function () { var e = document.querySelector('\(selector)'); var r = e.getBoundingClientRect();
                      var o = { bubbles: true, cancelable: true, button: 0, clientX: r.left + 5, clientY: r.top + 5 };
                      e.dispatchEvent(new MouseEvent('mousemove', o)); e.dispatchEvent(new MouseEvent('mousedown', o));
                      e.dispatchEvent(new MouseEvent('mouseup', o)); e.dispatchEvent(new MouseEvent('click', o)); return 'clicked' })()
                    """) { _ in done() }
            }
        }
    }
}
#endif
