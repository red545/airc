// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script autodark` (both engines): web pages prefer the colour scheme of the mode their Space draws in, and follow
/// it live (PageColorScheme.swift), as when macOS switches between light and dark (Appearance: Auto).
/// The system appearance is the app's own (`NSApp.appearance`; the Mac's setting is never touched): its effective
/// appearance changes exactly as on the real switch, which is what the app observes. The theme-changed notification
/// path is checked with that observation muted, the notification delivered to the app's observer only.
/// A loopback fixture uses `color-scheme: light dark`, a `prefers-color-scheme: dark` rule and a matchMedia change
/// listener; each read gives `matches`, the body's colours, a `Canvas` system colour and the change events so far.
///   pages     the shown tab, a background tab of the same Space, a Peek over the shown tab, Little Airc (target: the
///             same Space), and a tab of a dark Space (its theme pinned dark);
///   flips     light → dark → light: every page of the automatic Space follows at once (colours, `matches`); visible
///             pages get one change event per flip, the background tab gets it when it's shown (a hidden page runs no
///             rendering steps, in both engines and in Chrome/Safari); the dark Space's page stays dark, no event;
///   new       a page opened while dark starts dark (its first script sees `matches`), no change event;
///   space     the shown tab's Space pinned dark under a light system turns its pages dark, back to auto light;
///   moved     a tab moved to the dark Space turns dark;
///   notify    the theme notification alone (KVO muted) brings the pages along.
extension SnapshotRunner {
    func autoDarkScenario() {
        let tag = "autodark (\(app?.engine is WebKitEngine ? "WebKit" : "Chromium"))"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var home = "", darkSpace = "", tabA = "", tabB = "", tabD = "", tabN = ""
        var little: LittleArcController?
        let fixture = """
            <!doctype html><html><head><meta name="color-scheme" content="light dark"><title>autodark</title>
            <link rel="icon" href="data:,">
            <style>
            :root { color-scheme: light dark; }
            body { margin: 0; padding: 32px; font: 17px -apple-system, sans-serif; background: rgb(250, 250, 250); color: rgb(20, 20, 20); }
            @media (prefers-color-scheme: dark) { body { background: rgb(18, 18, 18); color: rgb(236, 236, 236); } }
            #sys { background: Canvas; color: CanvasText; padding: 8px; }
            </style>
            <script>
            (function () {
              var q = matchMedia('(prefers-color-scheme: dark)');
              window.__initial = q.matches;
              window.__log = [];
              q.addEventListener('change', function (e) { window.__log.push(e.matches ? 'dark' : 'light'); });
            })();
            </script></head><body><h1>Auto dark</h1><p>Text on the page's own colours.</p><div id="sys">Canvas</div>
            <input id="f" placeholder="a form control"></body></html>
            """
        let readJS = "JSON.stringify({m: matchMedia('(prefers-color-scheme: dark)').matches, bg: getComputedStyle(document.body).backgroundColor, "
            + "sys: getComputedStyle(document.getElementById('sys')).backgroundColor, log: window.__log || [], initial: !!window.__initial, path: location.pathname})"

        struct State { var dark: Bool; var bg: String; var sys: String; var log: [String]; var initial: Bool; var path: String
            /// Body colour and the Canvas system colour agree with `dark`.
            var coloursMatch: Bool {
                let bgDark = bg.contains("18, 18, 18"), bgLight = bg.contains("250, 250, 250")
                let sysDark = Self.lightness(sys).map { $0 < 0.4 } ?? false, sysLight = Self.lightness(sys).map { $0 > 0.6 } ?? false
                return dark ? (bgDark && sysDark) : (bgLight && sysLight)
            }
            static func lightness(_ css: String) -> Double? {
                let n = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
                return n.count >= 3 ? (n[0] + n[1] + n[2]) / 765 : nil
            }
            var summary: String { "matches \(dark), body \(bg), Canvas \(sys), events \(log)" }
        }
        func read(_ page: EngineTab?, _ then: @escaping (State?) -> Void) {
            guard let page, !page.isClosed else { return then(nil) }
            page.evaluate(readJS) { v in
                guard let s = v as? String, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return then(nil) }
                then(State(dark: o["m"] as? Bool ?? false, bg: o["bg"] as? String ?? "", sys: o["sys"] as? String ?? "",
                           log: o["log"] as? [String] ?? [], initial: o["initial"] as? Bool ?? false, path: o["path"] as? String ?? ""))
            }
        }
        /// Reads `page` until `accept` takes its state or `timeout` passes, then checks it.
        func expect(_ what: String, _ page: @escaping () -> EngineTab?, timeout: Double = 4, _ accept: @escaping (State) -> Bool) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                var last: State?
                func poll() {
                    read(page()) { s in
                        last = s ?? last
                        if let s, accept(s) {
                            self.check(true, "\(tag): \(what) (\(s.summary))")
                            return done()
                        }
                        guard Date() < deadline else {
                            self.check(false, "\(tag): \(what) (\(last?.summary ?? "no read: page \(page() == nil ? "missing" : "didn't answer")"))")
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
                    }
                }
                poll()
            }
        }
        func scheme(_ dark: Bool) -> String { dark ? "dark" : "light" }
        let pageA = { [self] in c.engineTab(for: tabA) }
        let pageB = { [self] in c.engineTab(for: tabB) }
        let pageD = { [self] in c.engineTab(for: tabD) }
        let pageP = { [self] in c.peek?.page }
        let pageL = { little?.page }
        var events: [String: Int] = [:]
        /// Pages of the automatic Space: `scheme` at once, colours included; visible ones (A, Peek, Little Airc) one
        /// more change event within the timeout.
        func expectAll(_ dark: Bool, _ when: String, visibleEvent: Bool) {
            for (name, page) in [("shown tab", pageA), ("Peek", pageP), ("Little Airc", pageL)] {
                expect("\(when): the \(name) is \(scheme(dark))" + (visibleEvent ? " and got one change event" : ""), page) { s in
                    s.dark == dark && s.coloursMatch && (!visibleEvent || (s.log.count == (events[name] ?? 0) + 1 && s.log.last == scheme(dark)))
                }
                step { done in read(page()) { s in if let s { events[name] = s.log.count }; done() } }
            }
            expect("\(when): the background tab (same Space, hidden) is \(scheme(dark)) at once: matches and colours", pageB) { s in
                s.dark == dark && s.coloursMatch
            }
            expect("\(when): the dark Space's tab stays dark, no change event", pageD) { s in s.dark && s.coloursMatch && s.log.isEmpty }
        }
        func flip(_ dark: Bool) { run { NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) } }

        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                req.path == "/favicon.ico" ? .init(status: "404 Not Found", body: "") : .init(headers: ["Content-Type": "text/html"], body: fixture)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        run { [self] in check(port != 0, "\(tag): the fixture server listens") }
        func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }

        // Setup: the system light, this Space automatic (neutral), a second Space pinned dark; tabs A and B here, D there.
        run { NSApp.appearance = NSAppearance(named: .aqua) }
        step { [self] done in
            let store = c.store
            home = c.currentSpaceID
            try? store.updateSpace(home) { $0.theme = .neutral }
            guard let d = try? store.createSpace(name: "Night", icon: .emoji("🌙"),
                                                 theme: AircKit.SpaceTheme(colors: [RGBA(hex: "7EB6D5")!], appearance: .dark),
                                                 profileID: store.profile(ofSpace: home).id, after: home),
                  let a = try? store.openTab(url: url("a"), inSpace: home, title: "autodark"),
                  let b = try? store.openTab(url: url("b"), inSpace: home, title: "autodark"),
                  let t = try? store.openTab(url: url("d"), inSpace: d.id, title: "autodark") else {
                check(false, "\(tag): two Spaces and their tabs")
                return done()
            }
            (darkSpace, tabA, tabB, tabD) = (d.id, a.id, b.id, t.id)
            c.reloadAll(animated: false)
            c.switchToSpace(darkSpace, animated: false)
            c.show(tabD, focus: false)
            done()
        }
        expect("setup: the dark Space's tab loads dark under a light system", pageD, timeout: 10) { s in s.path == "/d" && s.dark && s.coloursMatch && s.initial }
        run { [self] in c.switchToSpace(home, animated: false); c.show(tabB, focus: false) }
        expect("setup: tab B loads light", pageB, timeout: 10) { s in s.path == "/b" && !s.dark && s.coloursMatch && s.initial == false }
        run { [self] in c.show(tabA, focus: false) }
        expect("setup: tab A loads light", pageA, timeout: 10) { s in s.path == "/a" && !s.dark && s.coloursMatch }
        step { [self] done in
            guard let opener = pageA() else { check(false, "\(tag): a page to Peek from"); return done() }
            c.openPeek(URL(string: url("peek"))!, from: opener)
            little = app?.openLittleArc(url: URL(string: url("little")), spaceID: home)
            little?.window.orderFront(nil)
            done()
        }
        expect("setup: the Peek loads light", pageP, timeout: 10) { s in s.path == "/peek" && !s.dark && s.coloursMatch }
        expect("setup: Little Airc loads light", pageL, timeout: 10) { s in s.path == "/little" && !s.dark && s.coloursMatch }
        run { [self] in
            let w = c.window, l = little?.window
            note("\(tag): window visible \(w.occlusionState.contains(.visible)), on active Space \(w.isOnActiveSpace); Little Airc visible \(l?.occlusionState.contains(.visible) ?? false)")
            if !w.occlusionState.contains(.visible) { note("FAIL-ENV \(tag): the window is covered, so its pages run no rendering steps (change events wait)") }
        }
        capture("autodark-light")

        // Phase 1, with the Peek and Little Airc open: light → dark → light.
        flip(true)
        expectAll(true, "system → dark", visibleEvent: true)
        capture("autodark-dark")
        flip(false)
        expectAll(false, "system → light", visibleEvent: true)

        // The Space's own mode: pinned dark under a light system, then automatic again.
        run { [self] in try? c.store.updateSpace(home) { $0.theme = AircKit.SpaceTheme(colors: [], appearance: .dark) } }
        expectAll(true, "Space pinned dark (system light)", visibleEvent: true)
        run { [self] in try? c.store.updateSpace(home) { $0.theme = .neutral } }
        expectAll(false, "Space automatic again (system light)", visibleEvent: true)

        // The theme notification alone, with the appearance observation muted.
        if PageColorScheme.shared != nil {
            run { PageColorScheme.shared?.ignoresAppearanceKVO = true; NSApp.appearance = NSAppearance(named: .darkAqua) }
            wait(0.6)
            expect("notify: with the appearance observation muted, nothing changed yet", pageA, timeout: 0.5) { s in !s.dark }
            run { PageColorScheme.shared?.simulateThemeNotification() }
            expectAll(true, "notify: the theme notification brings the pages along", visibleEvent: true)
            run { PageColorScheme.shared?.ignoresAppearanceKVO = false; NSApp.appearance = NSAppearance(named: .aqua) }
            expectAll(false, "notify: back to light", visibleEvent: true)
        } else {
            run { [self] in note("\(tag): before arm (AIRC_PAGE_SCHEME_OFF=1): no PageColorScheme; the notify case is the fix's own") }
        }
        run { [self] in c.closePeek(); little?.window.orderOut(nil) }
        wait(0.6)

        // Phase 2: the background tab gets its change event when it's shown (a hidden page runs no rendering steps).
        var bEvents = 0
        for dark in [true, false] {
            step { done in read(pageB()) { s in bEvents = s?.log.count ?? 0; done() } }
            flip(dark)
            expect("system → \(scheme(dark)): the hidden background tab is \(scheme(dark)) at once", pageB) { s in s.dark == dark && s.coloursMatch }
            run { [self] in c.show(tabB, focus: false) }
            expect("system → \(scheme(dark)): the background tab, once shown, got its change event", pageB) { s in
                s.dark == dark && s.log.count > bEvents && s.log.last == scheme(dark)
            }
            run { [self] in c.show(tabA, focus: false) }
            if dark {
                // A new page opened while dark starts dark.
                step { [self] done in
                    guard let t = try? c.store.openTab(url: url("new"), inSpace: home, title: "autodark") else { check(false, "\(tag): a new tab"); return done() }
                    tabN = t.id
                    c.show(tabN, focus: false)
                    done()
                }
                expect("dark: a new page starts dark (its first script saw matches), no change event", { [self] in c.engineTab(for: tabN) }, timeout: 10) { s in
                    s.path == "/new" && s.dark && s.initial && s.coloursMatch && s.log.isEmpty
                }
                run { [self] in c.show(tabA, focus: false) }
            }
        }

        // A tab moved to the dark Space turns dark.
        run { [self] in _ = try? c.store.moveTab(tabB, toSpace: darkSpace) }
        expect("moved: the tab moved to the dark Space turns dark", pageB) { s in s.dark && s.coloursMatch }
        run { [self] in note("\(tag): PageColorScheme log: \(PageColorScheme.shared?.log.suffix(12).joined(separator: " | ") ?? "- (off)")") }

        run {
            little?.closeWindow()
            NSApp.appearance = nil
            server?.stop()
        }
        wait(0.5)
    }
}
#endif
