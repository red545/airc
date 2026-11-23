// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// oauthapps: signing in to a desktop app through Airc as the browser it hands its sign-in to, on both engines, as in
/// Chrome. Synthetic only: the provider, the consent page and the app are scripts/tests/oauthapps/FakeDesktopApp.swift
/// ("Fake Desktop App", scheme `airc-oauthtest`), which serves accounts.example and app.example on one loopback port
/// (AIRC_OAUTHAPPS_PORT, default 47811), and opens each sign-in's auth URL at this app with Launch Services (a GURL
/// Apple event from another app, exactly what the default browser gets). Never a real account or a real sign-in.
/// Chromium: `--host-resolver-rules=MAP *.example 127.0.0.1 --disable-features=HttpsUpgrades
/// --unsafely-treat-insecure-origin-as-secure=http://app.example:<port>` (the fixture has no TLS; that last switch
/// makes its callback a secure origin, which Chrome's "Always allow" needs). WebKit: AIRC_TEST_WEBKIT_PROXY=<port>:
/// accounts.example,app.example (the profile's CONNECT proxy from launch) and the same switch.
///   `--script oauthapps` (AIRC_OAUTHAPPS_FAKE_APP=<the .app>; launches it itself):
///     a) the https-callback pattern (an IDE): link → Little Airc in the external-link profile → consent page loads
///        (cookies, storage, scripts, a frame) → Allow → callback page → it opens `airc-oauthtest://` → "Open “Fake
///        Desktop App”?" with "Always allow" → Open → the app gets the code (PKCE checked) and nothing is stuck; again
///        with Always allow ticked; a third time opens the app without asking.
///     b) the loopback pattern (gcloud, gh, CLIs): redirect to http://127.0.0.1:<port>/callback, never upgraded or
///        blocked; the app gets the code.
///     c) window.close(): a callback that closes itself in a tab opened from outside (one history entry, like Chrome's
///        rule) closes Little Airc; a web app's popup posts the code to its opener and closes.
///   `--script oauthapps-cold`: Airc wasn't running; the fake app's sign-in launched it (runner:
///     scripts/tests/oauthapps/run-checks.sh): the consent page shows in Little Airc, the handoff works as in (a).
/// Clicks are real (the UI driver) with AIRC_REAL_CLICKS=1 in a dedicated session, otherwise posted to the window;
/// labelled [real] / [posted]. AIRC_EXTERNAL_APPS_BEFORE=1 is the before arm (no prompt: the old behaviour).
extension SnapshotRunner {
    func oauthAppsScenario() {
        // Its steps hold it (each captures it), so it lives as long as the run.
        OAuthAppsCheck(runner: self).start()
    }
}

final class OAuthAppsCheck {
    let r: SnapshotRunner
    let cold: Bool
    let engine: String
    let env = ProcessInfo.processInfo.environment
    let port: Int
    let log: URL
    let before: Bool
    var logOffset = 0
    var state = ""
    var little: LittleArcController?
    var answeredBefore = 0
    var originalExternalLinks: ExternalLinkTarget?
    var popupOpener: String?
    var sampler: Timer?

    init(runner: SnapshotRunner) {
        r = runner
        cold = runner.script == "oauthapps-cold"
        engine = runner.app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        port = Int(ProcessInfo.processInfo.environment["AIRC_OAUTHAPPS_PORT"] ?? "") ?? 47811
        log = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AIRC_OAUTHAPPS_LOG"]
                  ?? FileManager.default.temporaryDirectory.appendingPathComponent("airc-oauthtest.log").path)
        before = ProcessInfo.processInfo.environment["AIRC_EXTERNAL_APPS_BEFORE"] == "1"
    }

    var real: Bool {
        env["AIRC_REAL_CLICKS"] == "1" && env["AIRC_UI_DEDICATED_SESSION"] == "1" && UIDriverClient.available
    }
    var mode: String { real ? "[real]" : "[posted]" }
    var app: AppDelegate? { r.app }
    func label(_ s: String) -> String { "oauthapps \(engine)\(cold ? " cold" : "")\(before ? " before" : ""): " + s }
    func check(_ ok: Bool, _ s: String) { r.check(ok, label(s)) }
    func note(_ s: String) { r.note(label(s)) }

    // MARK: The fake app's log

    func events(since offset: Int? = nil) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.dropFirst(offset ?? logOffset).split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }
    func event(_ name: String, where match: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        events().first { $0["event"] as? String == name && match($0) }
    }
    func mark() { logOffset = (try? Data(contentsOf: log))?.count ?? 0 }
    func token(via: String) -> [String: Any]? {
        event("token") { $0["via"] as? String == via && (via == "popup" || $0["state"] as? String == state) }
    }

    // MARK: Driving

    /// GET on the fake app's control port (127.0.0.1 only).
    func control(_ path: String, _ done: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(json) }
        }.resume()
    }

    /// The fake app starts a sign-in: it opens its auth URL at this app through Launch Services.
    func startSignIn(_ flow: String) {
        r.step { [self] done in
            mark()
            answeredBefore = app?.promptCenter?.answered.count ?? 0
            control("/__start?flow=\(flow)\(real ? "&activate=1" : "")") { json in
                self.state = json?["state"] as? String ?? ""
                self.check(!self.state.isEmpty, "\(flow): the fake app starts a sign-in and opens its auth URL with Launch Services")
                done()
            }
        }
    }

    /// The newest Little Airc window shows the consent page, loaded.
    func expectConsent(_ what: String, timeout: Double = 20) {
        r.step { [self] done in
            r.waitUntil({ self.app?.littleArcs.last?.page.map { $0.title.hasPrefix("Consent ready") && !$0.isLoading } == true },
                        timeout: timeout) {
                self.little = self.app?.littleArcs.last
                let page = self.little?.page
                let title = page?.title ?? "-"
                self.check(page?.url?.host == "accounts.example" && title.hasPrefix("Consent ready"),
                           "\(what): the link opens in Little Airc and the consent page loads (\(self.app?.littleArcs.count ?? 0) "
                           + "window(s), \(page?.url.map { "\($0.host ?? "")\($0.path)" } ?? "no page"), \"\(title)\")")
                let flags = ["storage=true", "cookie=true", "script=true", "frame=true"]
                self.check(flags.allSatisfy(title.contains),
                      "\(what): nothing on the accounts host is blocked: its storage, cookie, script and frame work (\(title))")
                let opened = self.event("open") { $0["state"] as? String == self.state }
                let auth = self.event("authorize") { $0["ok"] as? Bool == true }
                self.check(opened?["ok"] as? Bool == true && auth?["prompt"] as? String == "consent" && auth?["offline"] as? Bool == true,
                      "\(what): the provider saw a valid PKCE request with prompt=consent and offline access")
                // AT-1: an external link goes to the profile the external-link rules pick (here no rule: the Space
                // shown in the browser window, so its profile).
                if let l = self.little, let store = self.app?.store {
                    let expected = store.profile(ofSpace: store.selectedSpace.id).id
                    self.check(l.profileID == expected, "\(what): Little Airc uses the external-link profile (\(l.profileID ?? "-") = \(expected))")
                }
                done()
            }
        }
    }

    /// A click on the page element `id`, at its centre: real (the UI driver) or posted to the window. A posted click
    /// that changes nothing in 3 s (the window wasn't ready for it) is sent again as page input: on Chromium through
    /// DevTools' Input domain (a browser-side input event, which also re-arms Chrome's external-protocol flood guard,
    /// as a person's click does), on WebKit as the element's click(); labelled [posted, fallback].
    func clickPage(_ page: @escaping () -> EngineTab?, _ id: String, _ what: String) {
        r.step { [self] done in
            guard let p = page(), let w = p.view.window else { check(false, "\(what): the page is in a window"); return done() }
            let js = "(function(){var e=document.getElementById('\(id)');if(!e)return null;e.scrollIntoView({block:'center'});"
                + "var r=e.getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2];})()"
            p.evaluate(js) { v in
                let xy = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                guard xy.count == 2 else { self.check(false, "\(what): #\(id) is on the page"); return done() }
                let view = p.view
                let before = (p.url?.absoluteString ?? "") + "|" + p.title
                let shown = self.r.c?.shownTabID
                let point = { view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : view.bounds.height - xy[1]), to: nil) }
                self.click(point(), in: w, what) {
                    if self.real {
                        // A real click that changed nothing (the window was still settling): a person clicks again.
                        return self.r.waitUntil({ (p.url?.absoluteString ?? "") + "|" + p.title != before || p.isLoading || self.r.c?.shownTabID != shown },
                                                timeout: 3) {
                            guard (p.url?.absoluteString ?? "") + "|" + p.title == before, !p.isLoading, self.r.c?.shownTabID == shown else { return done() }
                            self.note("\(what): the real click changed nothing in 3 s; clicking again [real, second click]")
                            self.click(point(), in: w, what, done)
                        }
                    }
                    self.r.waitUntil({ (p.url?.absoluteString ?? "") + "|" + p.title != before || p.isLoading || self.r.c?.shownTabID != shown },
                                     timeout: 3) {
                        guard (p.url?.absoluteString ?? "") + "|" + p.title == before, !p.isLoading, self.r.c?.shownTabID == shown else { return done() }
                        self.note("\(what): the posted click changed nothing in 3 s; sent again as page input [posted, fallback]")
                        #if canImport(AircCore)
                        if let chromium = self.app?.engine as? ChromiumEngine, p is ChromiumTab {
                            func mouse(_ type: String, _ then: @escaping () -> Void) {
                                chromium.devToolsCall("Input.dispatchMouseEvent", params: ["type": type, "x": xy[0], "y": xy[1], "button": "left",
                                                                                           "clickCount": 1], in: p) { _, _ in then() }
                            }
                            return mouse("mousePressed") { mouse("mouseReleased") { done() } }
                        }
                        #endif
                        p.evaluate("document.getElementById('\(id)').click()") { _ in done() }
                    }
                }
            }
        }
    }

    /// A click on the prompt card's control `anchor`.
    func clickPrompt(_ anchor: String, _ what: String) {
        r.step { [self] done in
            guard let l = little, let b = l.prompts.bubble else { check(false, "\(what): the card is up"); return done() }
            b.layoutSubtreeIfNeeded()
            guard let p = r.anchorPoint(anchor, in: b.hostingView) else { check(false, "\(what): \(anchor) is on the card"); return done() }
            click(p, in: l.window, what, done)
        }
    }

    private func click(_ p: NSPoint, in w: NSWindow, _ what: String, _ done: @escaping () -> Void) {
        guard real else {
            // Posted: the window has to be the key one (a posted press on another window only orders it in).
            if w.isKeyWindow { return r.click(at: p, in: w, done) }
            w.makeKeyAndOrderFront(nil)
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.r.click(at: p, in: w, done) }
        }
        func go() {
            guard let primary = NSScreen.screens.first else { return done() }
            let s = w.convertPoint(toScreen: p)
            // The driver refuses an empty --mods: a plain click passes none.
            UIDriverClient.run(["--click", String(Double(s.x)), String(Double(primary.frame.maxY - s.y))]) { ok, out in
                if !ok { self.note("FAIL-ENV \(what): the UI driver's click failed (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            }
        }
        if NSApp.isActive, w.isKeyWindow { return go() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        r.waitUntil({ NSApp.isActive && w.isKeyWindow }, timeout: 4) {
            if !(NSApp.isActive && w.isKeyWindow) { self.note("FAIL-ENV \(what): the window isn't key for a real click") }
            go()
        }
    }

    func externalPrompt() -> PagePrompt.ExternalApp? {
        if case .externalApp(let e)? = little?.prompts.shown?.prompt { return e }
        return nil
    }

    /// The callback page asks to open the app: Airc's card, not a silent block and not an early launch.
    func expectAppPrompt(_ what: String) {
        r.step { [self] done in
            r.waitUntil({ self.externalPrompt() != nil && self.little?.prompts.bubble != nil }, timeout: 12) {
                let page = self.little?.page
                let e = self.externalPrompt()
                self.check(page?.url?.host == "app.example" && page?.url?.path == "/oauth-callback",
                           "\(what): consent goes on to the app's https-style callback page (\(page?.url?.path ?? "none"), \"\(page?.title ?? "-")\")")
                if self.before {
                    // The old behaviour, for the record: no card; did the app get anything?
                    self.r.waitUntil({ self.event("scheme") != nil }, timeout: 4) {
                        self.note("before: card \(e != nil), the app got the link \(self.event("scheme") != nil)")
                        self.check(e != nil, "\(what): the callback page's app link asks \"Open “Fake Desktop App”?\" (before: no card)")
                        done()
                    }
                    return
                }
                self.check(e?.app == "Fake Desktop App" && e?.scheme == "airc-oauthtest",
                           "\(what): the app link asks \"Open “\(e?.app ?? "-")”?\" in Little Airc's card (scheme \(e?.scheme ?? "-"))")
                self.check(e?.origin == "http://app.example:\(self.port)" && e?.canRemember == true,
                           "\(what): the card names the asking site and offers Always allow, as Chrome does for a secure site (\(e?.origin ?? "-"), \(e?.canRemember == true))")
                self.check(self.event("scheme") == nil, "\(what): nothing is launched before the person answers")
                if let b = self.little?.prompts.bubble, let l = self.little {
                    self.check(b.superview === l.root && l.root.bounds.contains(b.frame) && b.frame.height > 60,
                               "\(what): the card is on screen in Little Airc (\(NSStringFromRect(b.frame)))")
                }
                done()
            }
        }
    }

    /// The app got the code over `via`, and its PKCE exchange passed.
    func expectToken(_ via: String, _ what: String, timeout: Double = 12) {
        r.step { [self] done in
            r.waitUntil({ self.token(via: via) != nil }, timeout: timeout) {
                let t = self.token(via: via)
                self.check(t?["ok"] as? Bool == true && t?["pkce"].map { $0 as? Bool == true } != false,
                           "\(what): the app gets the code and its PKCE exchange passes (\(t.map { "via \($0["via"] ?? "-"), ok \($0["ok"] ?? "-")" } ?? "nothing arrived"))")
                done()
            }
        }
    }

    // MARK: The scenario

    func start() {
        if r.script == "oauthapps-google" { return googleScenario() }
        guard let fakePath = env["AIRC_OAUTHAPPS_FAKE_APP"] ?? (cold ? "" : nil),
              cold || FileManager.default.fileExists(atPath: fakePath) else {
            r.run { [self] in r.skip(label("needs AIRC_OAUTHAPPS_FAKE_APP (scripts/tests/oauthapps/build-fake-app.sh)")) }
            return
        }
        r.run { [self] in
            if engine == "Chromium" {
                let args = ProcessInfo.processInfo.arguments
                check(args.contains { $0.hasPrefix("--host-resolver-rules=") && $0.contains("*.example") },
                      "Chromium launched with --host-resolver-rules for *.example")
            } else {
                check(env["AIRC_TEST_WEBKIT_PROXY"]?.contains("accounts.example") == true, "WebKit launched with AIRC_TEST_WEBKIT_PROXY for the fixture hosts")
            }
            originalExternalLinks = app?.settings.values.externalLinks
        }
        if cold { return coldScenario() }
        if real { r.activateForRealInput() }
        // The fake app (a separate process): its provider, its scheme handler, its loopback listener.
        r.step { [self] done in
            mark()
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            c.promptsUserIfNeeded = false
            c.arguments = ["--port", String(port), "--log", log.path, "--airc", Bundle.main.bundleURL.path]
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: env["AIRC_OAUTHAPPS_FAKE_APP"]!), configuration: c) { _, error in
                DispatchQueue.main.async {
                    self.r.waitUntil({ self.event("server") != nil }, timeout: 15) {
                        let s = self.event("server")
                        self.check(error == nil && s?["ok"] as? Bool == true,
                                   "the fake desktop app runs, with its provider on 127.0.0.1:\(self.port) (\(error.map { "\($0)" } ?? "server ok \(s?["ok"] ?? "-")"))")
                        done()
                    }
                }
            }
        }
        r.closeLittleArcs()
        r.run { [self] in app?.settings.values.externalLinks = .littleArc }

        // a) The https callback page hands off to the app's scheme.
        startSignIn("scheme")
        expectConsent("a1 \(mode)")
        clickPage({ self.little?.page }, "allow", "a1 Allow \(mode)")
        expectAppPrompt("a1")
        if !before {
            // Little Airc's own window (capture() draws the browser window): the card over the callback page.
            r.step { [self] done in
                guard let w = little?.window else { return done() }
                r.captureWindow(w, name: "oauthapps-prompt-\(engine.lowercased())", rounded: 0, done)
            }
            clickPrompt("prompt.open", "a1 Open \(mode)")
            expectToken("scheme", "a1 \(mode)")
            r.step { [self] done in
                r.waitUntil({ self.little?.prompts.shown == nil }, timeout: 2) {
                    let last = self.app?.promptCenter?.answered.last
                    self.check(last?.answer == .open(remember: false), "a1: Open answers the card (\(last.map { "\($0.label): \($0.answer)" } ?? "none"))")
                    let l = self.little
                    self.check(l?.window.isVisible == true && l?.page?.url?.path == "/oauth-callback" && l?.page?.isLoading == false
                               && l?.prompts.shown == nil,
                               "a1: afterwards Little Airc shows the finished callback page, no card, nothing stuck")
                    done()
                }
            }
            // Always allow, then the next sign-in opens the app without asking.
            r.closeLittleArcs()
            startSignIn("scheme")
            expectConsent("a2 \(mode)")
            clickPage({ self.little?.page }, "allow", "a2 Allow \(mode)")
            expectAppPrompt("a2")
            clickPrompt("prompt.remember", "a2 Always allow \(mode)")
            r.run { [self] in
                check(little?.prompts.bubble?.model.rememberApp == true, "a2: the click ticks Always allow")
            }
            clickPrompt("prompt.open", "a2 Open \(mode)")
            expectToken("scheme", "a2 (Always allow) \(mode)")
            r.run { [self] in
                let last = app?.promptCenter?.answered.last
                check(last?.answer == .open(remember: true), "a2: the card's answer keeps Always allow (\(last.map { "\($0.answer)" } ?? "none"))")
            }
            r.closeLittleArcs()
            startSignIn("scheme")
            expectConsent("a3 \(mode)")
            var sawCard = false
            r.step { [self] done in
                // Sampled while the handoff runs: the card must never come up.
                let t = Timer(timeInterval: 0.05, repeats: true) { _ in if self.externalPrompt() != nil { sawCard = true } }
                RunLoop.main.add(t, forMode: .common)
                sampler = t
                done()
            }
            clickPage({ self.little?.page }, "allow", "a3 Allow \(mode)")
            expectToken("scheme", "a3 (remembered) \(mode)")
            r.run { [self] in
                sampler?.invalidate()
                let asked = (app?.promptCenter?.answered.count ?? 0) - answeredBefore
                var remembered = "Chromium's profile"
                if engine == "WebKit" { remembered = "remembered \(WebKitExternalApps.launches.last?.remembered == true)" }
                check(!sawCard && asked == 0, "a3: after Always allow the site opens the app without asking (card seen \(sawCard), answers \(asked), \(remembered))")
            }
        }

        // b) Loopback: http://127.0.0.1:<port>/callback, never upgraded or blocked.
        r.closeLittleArcs()
        startSignIn("loopback")
        expectConsent("b \(mode)")
        clickPage({ self.little?.page }, "allow", "b Allow \(mode)")
        expectToken("loopback", "b (loopback) \(mode)")
        r.step { [self] done in
            r.waitUntil({ self.little?.page?.title == "Loopback done" }, timeout: 8) {
                let u = self.little?.page?.url
                let hit = self.event("loopback")
                self.check(u?.scheme == "http" && u?.host == "127.0.0.1" && u?.path == "/callback" && self.little?.page?.title == "Loopback done",
                           "b: the loopback redirect loads as http://127.0.0.1 (no HTTPS upgrade, no block) and shows the app's page (\(u?.absoluteString.prefix(40) ?? "none"), \"\(self.little?.page?.title ?? "-")\")")
                self.check((hit?["host"] as? String)?.hasPrefix("127.0.0.1:") == true, "b: the app's loopback listener got the request")
                done()
            }
        }

        // c1) A callback that closes itself, in a tab opened from outside with one history entry (prompt=none: the
        // provider sends it straight back): window.close() closes Little Airc, as Chrome closes such a tab.
        r.closeLittleArcs()
        var sawClosePage = false
        startSignIn("close")
        r.step { [self] done in
            r.waitUntil({
                if self.app?.littleArcs.last?.page?.title.hasPrefix("Close callback") == true { sawClosePage = true }
                return sawClosePage && self.app?.littleArcs.isEmpty == true
            }, timeout: 15) {
                let t = self.token(via: "close")
                self.check(t?["ok"] as? Bool == true, "c1: the prompt=none sign-in comes back to the app's callback with a valid code")
                self.check(sawClosePage && self.app?.littleArcs.isEmpty == true,
                           "c1: the callback page's window.close() closes Little Airc (page seen \(sawClosePage), windows left \(self.app?.littleArcs.count ?? -1))")
                done()
            }
        }

        // c2) A web app's popup sign-in: the popup's callback posts the code to its opener and closes.
        var webTab = ""
        r.run { [self] in
            guard let c = r.c, let t = try? c.store.openTab(url: "http://app.example:\(port)/web", inSpace: c.currentSpaceID, title: "web") else {
                return check(false, "c2: the web app tab opens")
            }
            webTab = t.id
            c.show(t.id, focus: true)
            popupOpener = t.id
        }
        r.step { [self] done in
            r.waitUntil({ self.r.c.engineTab(for: webTab)?.title == "Web app fixture" }, timeout: 15) {
                self.check(self.r.c.engineTab(for: webTab)?.title == "Web app fixture", "c2: the web app page loads")
                done()
            }
        }
        r.run { [self] in mark(); if real { NSApp.activate(ignoringOtherApps: true); r.c.window.makeKeyAndOrderFront(nil) } }
        clickPage({ self.r.c.engineTab(for: webTab) }, "signin", "c2 Sign in \(mode)")
        var popupID: String?
        r.step { [self] done in
            r.waitUntil({
                guard let c = self.r.c, let shown = c.shownTabID, shown != webTab, let p = c.engineTab(for: shown) else { return false }
                popupID = shown
                return p.title.hasPrefix("Consent ready") && !p.isLoading
            }, timeout: 15) {
                let opener = self.r.c.engineTab(for: webTab)?.title ?? "-"
                let p = popupID.flatMap { self.r.c.engineTab(for: $0) }
                self.check(opener == "web opened popup" && p?.url?.host == "accounts.example" && p?.title.hasPrefix("Consent ready") == true,
                           "c2: a click opens the provider's popup, not blocked, and its consent page loads (opener \"\(opener)\", popup \"\(p?.title ?? "-")\")")
                done()
            }
        }
        clickPage({ popupID.flatMap { self.r.c.engineTab(for: $0) } }, "allow", "c2 Allow in the popup \(mode)")
        r.step { [self] done in
            r.waitUntil({ (self.r.c.engineTab(for: webTab)?.title ?? "").contains("closed=") }, timeout: 15) {
                let title = self.r.c.engineTab(for: webTab)?.title ?? "-"
                let gone = popupID.map { self.r.c.store.tab($0) == nil } ?? false
                self.check(title.hasPrefix("web got code") && title.hasSuffix("closed=true"),
                           "c2: the popup's callback posts the code to its opener and window.close() closes it (\"\(title)\")")
                self.check(gone && self.r.c.shownTabID == webTab, "c2: the popup's tab is gone and the web app is shown again")
                let t = self.token(via: "popup")
                self.check(t?["ok"] as? Bool == true, "c2: the popup's code is valid (PKCE)")
                done()
            }
        }
        r.capture("oauthapps-\(engine.lowercased())")
        r.run { [self] in
            if !webTab.isEmpty { _ = try? r.c.store.closeTab(webTab) }
            if let o = originalExternalLinks { app?.settings.values.externalLinks = o }
        }
        r.closeLittleArcs()
        r.step { [self] done in control("/__quit") { _ in done() } }
    }

    /// `--script oauthapps-google` (AIRC_OAUTHAPPS_REAL_URL, from the runner, never in the repo): the real provider's
    /// consent URL, signed out, arriving as a link from another app. No sign-in: it only has to render the provider's
    /// sign-in page, with no Airc block, no redirect loop and no "unsupported browser" / "may not be secure" page.
    private func googleScenario() {
        guard let raw = env["AIRC_OAUTHAPPS_REAL_URL"], let url = URL(string: raw) else {
            r.run { [self] in r.skip(label("google: needs AIRC_OAUTHAPPS_REAL_URL")) }
            return
        }
        r.closeLittleArcs()
        r.run { [self] in
            app?.settings.values.externalLinks = .littleArc
            let failure = SnapshotRunner.sendGetURLEvent(url)
            check(failure == nil, "google: the consent URL arrives as a link from another app (a GURL Apple event)")
        }
        var commits = 0, lastURL = ""
        r.step { [self] done in
            let start = Date()
            r.waitUntil({
                guard let p = self.app?.littleArcs.last?.page else { return false }
                let u = p.url?.absoluteString ?? ""
                if u != lastURL { commits += 1; lastURL = u }
                return !p.isLoading && !p.title.isEmpty && Date().timeIntervalSince(start) > 6
            }, timeout: 40) { done() }
        }
        r.wait(2)
        r.step { [self] done in
            guard let p = app?.littleArcs.last?.page else { check(false, "google: Little Airc opens the link"); return done() }
            p.evaluate("(document.body && document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 400)") { v in
                let text = (v as? String) ?? ""
                let lower = text.lowercased()
                let u = p.url
                self.note("google: final \(u?.host ?? "-")\(u?.path ?? ""), title \"\(p.title)\", \(commits) URL change(s), text: \(text.prefix(240))")
                self.check(u?.host == "accounts.google.com" && !p.isLoading,
                           "google: the consent URL loads the provider's own page (\(u?.host ?? "-")\(u?.path ?? ""))")
                let refused = ["may not be secure", "browser or app may not be secure", "unsupported browser", "browser is no longer supported",
                               "couldn't sign you in", "too many redirects", "err_too_many_redirects"].filter { lower.contains($0) }
                self.check(refused.isEmpty, "google: no \"may not be secure\", unsupported-browser or redirect-loop page (\(refused))")
                self.check(lower.contains("sign in") || lower.contains("email or phone") || lower.contains("choose an account"),
                           "google: the sign-in page renders (title \"\(p.title)\")")
                self.check(commits < 15, "google: no redirect loop (\(commits) address changes)")
                done()
            }
        }
        r.step { [self] done in
            guard let w = app?.littleArcs.last?.window else { return done() }
            r.captureWindow(w, name: "oauthapps-google-\(engine.lowercased())", rounded: 0, done)
        }
        r.run { [self] in if let o = originalExternalLinks { app?.settings.values.externalLinks = o } }
        r.closeLittleArcs()
    }

    /// Launched by the fake app's sign-in (Airc wasn't running): the link is the launch's.
    private func coldScenario() {
        r.step { [self] done in
            r.waitUntil({ self.app?.littleArcs.last?.page.map { $0.title.hasPrefix("Consent ready") && !$0.isLoading } == true }, timeout: 40) {
                let opened = self.events(since: 0).first { $0["event"] as? String == "open" }
                self.state = opened?["state"] as? String ?? ""
                // Launch Services' answer to the fake app's open: the process it launched for the link is this one. (The
                // link can arrive just after did-finish-launching, so LaunchEvent's own flag isn't always set.)
                let launched = (opened?["pid"] as? NSNumber)?.int32Value
                self.check(launched == getpid(),
                           "the sign-in link launched this Airc (Launch Services launched pid \(launched ?? 0), we are \(getpid()); "
                           + "link during launch \(LaunchEvent.shared.linkDuringLaunch))")
                done()
            }
        }
        expectConsent("cold \(mode)", timeout: 5)
        clickPage({ self.little?.page }, "allow", "cold Allow \(mode)")
        expectAppPrompt("cold")
        if !before {
            clickPrompt("prompt.open", "cold Open \(mode)")
            expectToken("scheme", "cold \(mode)")
        }
        // Little Airc's window: a link launch has no browser window (capture() draws that one).
        r.step { [self] done in
            guard let w = little?.window else { return done() }
            r.captureWindow(w, name: "oauthapps-cold-\(engine.lowercased())", rounded: 0, done)
        }
    }
}
#endif
