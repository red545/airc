// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// `--script darkfix` (both engines, a fresh data folder): Settings › Appearance › Airc sets the whole app.
/// Auto follows macOS; Light and Dark force it, for the window and sidebar, Settings and pages, live. Spaces follow it
/// unless they have their own Light or Dark.
///
/// macOS's own appearance is played by `AppAppearance.simulatedSystem` (the app's NSApp.appearance under Auto); the
/// Mac's real setting is never touched. Settings clicks are **real** (the UI driver, AIRC_REAL_KEYS=1); without the
/// driver they are set in code and the log says "posted".
///   fresh     a fresh profile: Airc is Auto, the first Space follows it, New Spaces start on Auto;
///   spaces    the fresh Space (neutral), an onboarding Space (the Mint preset as onboarding writes it), an imported
///             Arc Space (a cream Arc windowTheme with a "light" colour-scheme key) and a Space pinned Light;
///   auto      system light → dark under Auto: every following Space's sidebar and window colour, Settings, and pages
///             (shown, background, a new tab) turn dark, live; the pinned Space stays light;
///   light     a click on Light with the system dark: all light;
///   dark      a click on Dark with the system light: all dark (the reporter's case);
///   auto2     a click on Auto: back to the system's (light);
///   follow    "Follow Airc" on the pinned Space's row: it follows (dark under Dark);
///   migrate   a settings.json from before (only the New Spaces "Dark") opens as Airc Dark.
extension SnapshotRunner {
    func darkFixScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "darkfix (\(engine))"
        let real = UIDriverClient.available
        var server: LocalPageServer?
        var port: UInt16 = 0
        var home = "", onboarded = "", imported = "", pinned = ""
        var tabA = "", tabB = "", tabN = ""
        let fixture = """
            <!doctype html><html><head><meta name="color-scheme" content="light dark"><title>darkfix</title><link rel="icon" href="data:,">
            <style>:root { color-scheme: light dark; } body { margin: 0; padding: 32px; font: 17px -apple-system; background: rgb(250, 250, 250); color: rgb(20, 20, 20); }
            @media (prefers-color-scheme: dark) { body { background: rgb(18, 18, 18); color: rgb(236, 236, 236); } }
            #sys { background: Canvas; color: CanvasText; padding: 8px; }</style></head>
            <body><h1>Dark fix</h1><div id="sys">Canvas</div></body></html>
            """
        let readJS = "JSON.stringify({m: matchMedia('(prefers-color-scheme: dark)').matches, bg: getComputedStyle(document.body).backgroundColor, "
            + "sys: getComputedStyle(document.getElementById('sys')).backgroundColor, path: location.pathname})"
        func lightness(_ css: String) -> Double? {
            let n = css.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            return n.count >= 3 ? (n[0] + n[1] + n[2]) / 765 : nil
        }
        /// A page agrees with `dark`: prefers-color-scheme, its own colours and the Canvas system colour.
        func expectPage(_ what: String, _ page: @escaping () -> EngineTab?, dark: Bool, timeout: Double = 5) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                var last = "no read"
                func poll() {
                    guard let p = page(), !p.isClosed else {
                        last = "no page"
                        if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll); return }
                        self.check(false, "\(tag): \(what) is \(dark ? "dark" : "light") (\(last))")
                        return done()
                    }
                    p.evaluate(readJS) { v in
                        var ok = false
                        if let s = v as? String, let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
                            let m = o["m"] as? Bool ?? !dark, bg = o["bg"] as? String ?? "", sys = o["sys"] as? String ?? ""
                            let bgOK = dark ? bg.contains("18, 18, 18") : bg.contains("250, 250, 250")
                            let sysOK = lightness(sys).map { dark ? $0 < 0.4 : $0 > 0.6 } ?? false
                            ok = m == dark && bgOK && sysOK
                            last = "matches \(m), body \(bg), Canvas \(sys), \(o["path"] as? String ?? "")"
                        }
                        if ok { self.check(true, "\(tag): \(what) is \(dark ? "dark" : "light") (\(last))"); return done() }
                        guard Date() < deadline else { self.check(false, "\(tag): \(what) is \(dark ? "dark" : "light") (\(last))"); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                    }
                }
                poll()
            }
        }
        func settingsWindow() -> NSWindow? { app?.settingsWindow?.window }
        func isDark(_ a: NSAppearance?) -> Bool { a?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        /// The window chrome: the shown Space's sidebar page and the window colour, and the app's appearance.
        func expectChrome(_ when: String, space: @escaping () -> String, dark: Bool) {
            run { [self] in
                c.switchToSpace(space(), animated: false)
                c.root.layoutSubtreeIfNeeded()
            }
            wait(0.4)
            run { [self] in
                let s = space(), name = c.store.space(s)?.name ?? s
                let sidebar = c.pageView(for: s)?.palette.isDark, window = c.background.current.isDark, pal = c.currentPalette.isDark
                check(sidebar == dark && window == dark && pal == dark,
                      "\(tag): \(when): \(name)'s sidebar and window colour are \(dark ? "dark" : "light") (sidebar \(sidebar.map(String.init) ?? "-"), window \(window), palette \(pal))")
            }
        }
        func expectSettings(_ when: String, dark: Bool) {
            run { [self] in
                let w = settingsWindow()
                check(w != nil && isDark(w?.effectiveAppearance) == dark,
                      "\(tag): \(when): Settings is \(dark ? "dark" : "light") (\(w?.effectiveAppearance.name.rawValue ?? "no window"))")
            }
        }
        /// macOS's appearance as the app sees it (the real setting is never touched).
        func system(_ dark: Bool) {
            run { [self] in
                AppAppearance.simulatedSystem = dark
                AppAppearance.apply(app?.settings.values.appearance ?? .auto)
            }
            wait(0.6)
        }
        func showSettings() {
            run { [self] in
                app?.showSettings(page: .appearance)
                if let w = settingsWindow(), let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                    w.setFrame(NSRect(x: screen.minX + 60, y: screen.minY + 20, width: w.frame.width, height: min(900, screen.height - 40)), display: true)
                }
            }
            wait(0.8)
        }
        /// A real click at `fraction` of the anchor's width (the segmented control's thirds), or the value set in code.
        func click(_ anchor: @escaping () -> String, fraction: CGFloat, fallback: @escaping () -> Void, _ what: String,
                   onlyIf: @escaping () -> Bool = { true }) {
            showSettings()
            step { [self] done in
                guard onlyIf() else { return done() }
                guard real else {
                    note("\(tag): posted (no UI driver): \(what)")
                    fallback()
                    return DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
                guard let w = settingsWindow(), let v = w.contentView else { check(false, "\(tag): the Settings window"); return done() }
                v.layoutSubtreeIfNeeded()
                guard let a = TestAnchors.view(anchor(), in: v) else { check(false, "\(tag): \(anchor()) in Settings"); return done() }
                a.scrollToVisible(a.bounds.insetBy(dx: 0, dy: -60))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    v.layoutSubtreeIfNeeded()
                    let r = a.convert(a.bounds, to: nil)
                    let p = NSPoint(x: r.minX + r.width * fraction, y: r.midY)
                    NSApp.activate(ignoringOtherApps: true)
                    w.makeKeyAndOrderFront(nil)
                    self.waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 3) {
                        guard NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace else {
                            self.note("FAIL-ENV \(tag): Settings not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace))")
                            return done()
                        }
                        let g = w.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                        let hit = v.hitTest(v.convert(p, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
                        let under = NSWindow.windowNumber(at: g, belowWindowWithWindowNumber: 0) == w.windowNumber
                        UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { ok, out in
                            self.note("\(tag): real click: \(what) at \(Int(g.x)),\(Int(g.y)) (anchor \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)), hit \(hit), Settings on top \(under))" + (ok ? "" : " (driver refused: \(out))"))
                            if !ok { self.note("FAIL-ENV \(tag): the driver refused the click on \(anchor())") }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
                        }
                    }
                }
            }
        }
        /// The Settings window itself (capture() takes the browser window).
        func captureSettings(_ name: String) {
            run { [self] in
                guard let v = settingsWindow()?.contentView else { return note("\(tag): no Settings window for \(name)") }
                v.layoutSubtreeIfNeeded()
                guard let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { return note("\(tag): could not render \(name)") }
                try? png.write(to: dir.appendingPathComponent(name))
                note("wrote \(name)")
            }
        }
        func choose(_ a: Appearance) {
            let fraction: CGFloat
            switch a {
            case .auto: fraction = 1.0 / 6
            case .light: fraction = 0.5
            case .dark: fraction = 5.0 / 6
            }
            click({ "settings.appearance.app" }, fraction: fraction, fallback: { [self] in app?.settings.values.appearance = a }, "Airc › \(a.rawValue)")
            // A click that didn't register (the stored value unchanged) is tried once more, as the suite's checks do.
            click({ "settings.appearance.app" }, fraction: fraction, fallback: {}, "Airc › \(a.rawValue) (retry: the first click didn't register)",
                  onlyIf: { [self] in real && app?.settings.values.appearance != a })
            run { [self] in
                check(app?.settings.values.appearance == a && AppAppearance.applied == a,
                      "\(tag): Settings › Appearance › Airc is \(a.rawValue) (stored \(app?.settings.values.appearance.rawValue ?? "-"))")
            }
        }
        let pageA = { [self] in c.engineTab(for: tabA) }
        let pageB = { [self] in c.engineTab(for: tabB) }
        let pageN = { [self] in c.engineTab(for: tabN) }
        func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }
        /// Everything that follows the app: three Spaces' chrome, Settings and the pages (shown, background, new).
        func expectAll(_ when: String, dark: Bool, newTab: Bool = false) {
            let spaces: [(() -> String, String)] = [({ home }, "fresh"), ({ onboarded }, "onboarding"), ({ imported }, "Arc import")]
            for (s, label) in spaces {
                expectChrome("\(when) [\(label)]", space: s, dark: dark)
            }
            run { [self] in c.switchToSpace(home, animated: false); c.show(tabA, focus: false) }
            expectSettings(when, dark: dark)
            expectPage("\(when): the shown tab", pageA, dark: dark)
            expectPage("\(when): the background tab", pageB, dark: dark)
            if newTab {
                step { [self] done in
                    if let t = try? c.store.openTab(url: url("new-\(dark)"), inSpace: home, title: "darkfix") { tabN = t.id; c.show(tabN, focus: false) }
                    done()
                }
                expectPage("\(when): a new tab", pageN, dark: dark, timeout: 10)
                run { [self] in c.show(tabA, focus: false) }
            }
        }

        // Fixture pages and the Spaces.
        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                req.path == "/favicon.ico" ? .init(status: "404 Not Found", body: "") : .init(headers: ["Content-Type": "text/html"], body: fixture)
            }
            server?.start { p in port = p ?? 0; done() }
        }
        system(false)
        run { [self] in
            check(port != 0, "\(tag): the fixture server listens")
            let s = app?.settings
            check(s?.values.appearance == .auto && AppAppearance.applied == .auto,
                  "\(tag): fresh: Airc's appearance is Auto (\(s?.values.appearance.rawValue ?? "-"))")
            check(s?.defaultTheme.appearance == .auto, "\(tag): fresh: a new Space starts on Auto (follows Airc)")
            let store = c.store
            home = c.currentSpaceID
            check(store.space(home)?.theme.appearance == .auto, "\(tag): fresh: the first Space follows Airc (\(store.space(home)?.theme.appearance.rawValue ?? "-"))")
            // Onboarding's preset tap writes the preset's colours, grain and appearance (OnboardingViews.presets).
            var mint = store.space(home)?.theme ?? .neutral
            if let t = DesignTheme.preset("mint")?.model { mint.colors = t.colors; mint.grain = t.grain; mint.appearance = t.appearance }
            // An Arc windowTheme as Arc stores it: cream, with a light colour-scheme key (the old reader pinned it light).
            let arcJSON = #"{"colorScheme":"light","background":{"single":{"_0":{"style":{"color":{"_0":{"blendedSingleColor":{"_0":{"color":{"red":0.941,"green":0.918,"blue":0.898,"alpha":1},"modifiers":{"intensityFactor":0.81,"noiseFactor":0.2}}}}}}}}}}"#
            let arcTheme = ArcTheme.theme(from: try? JSONSerialization.jsonObject(with: Data(arcJSON.utf8)))
            check(arcTheme.appearance == .auto && !arcTheme.colors.isEmpty, "\(tag): an imported Arc theme follows Airc (\(arcTheme.appearance.rawValue), \(arcTheme.colors.count) colour)")
            check(mint.appearance == .auto, "\(tag): an onboarding preset (Mint) follows Airc (\(mint.appearance.rawValue))")
            let profile = store.profile(ofSpace: home).id
            guard let o = try? store.createSpace(name: "Onboarding", icon: .emoji("🌱"), theme: mint, profileID: profile, after: home),
                  let i = try? store.createSpace(name: "Arc import", icon: .emoji("🛬"), theme: arcTheme, profileID: profile, after: o.id),
                  let pn = try? store.createSpace(name: "Pinned light", icon: .emoji("☀️"),
                                                  theme: AircKit.SpaceTheme(colors: [RGBA(hex: "7EB6D5")!], appearance: .light), profileID: profile, after: i.id),
                  let a = try? store.openTab(url: url("a"), inSpace: home, title: "darkfix"),
                  let b = try? store.openTab(url: url("b"), inSpace: home, title: "darkfix") else {
                return check(false, "\(tag): the Spaces and tabs")
            }
            (onboarded, imported, pinned, tabA, tabB) = (o.id, i.id, pn.id, a.id, b.id)
            c.reloadAll(animated: false)
            c.show(tabB, focus: false)
        }
        expectPage("setup: tab B", pageB, dark: false, timeout: 10)
        run { [self] in c.show(tabA, focus: false) }
        expectPage("setup: tab A", pageA, dark: false, timeout: 10)
        showSettings()
        expectAll("Auto, system light", dark: false)
        capture("darkfix-auto-light")

        // Auto with the system dark (the report's first case): live, no relaunch.
        run { [self] in note("\(tag): redraws before the flip \(AppAppearance.redraws)") }
        system(true)
        expectAll("Auto, system dark", dark: true, newTab: true)
        capture("darkfix-auto-dark")
        expectChrome("Auto, system dark [pinned Light wins]", space: { pinned }, dark: false)
        capture("darkfix-pinned-light")
        run { [self] in check(AppAppearance.redraws >= 1, "\(tag): the flip redrew the windows (\(AppAppearance.redraws))") }
        showSettings()
        captureSettings("darkfix-settings-dark.png")

        // Light with the system dark.
        choose(.light)
        expectAll("Light, system dark", dark: false)

        // Dark with the system light (the report's second case).
        system(false)
        choose(.dark)
        expectAll("Dark, system light", dark: true, newTab: true)
        capture("darkfix-dark")
        showSettings()
        captureSettings("darkfix-settings-forced-dark.png")

        // Auto again: the system's (light).
        choose(.auto)
        expectAll("Auto again, system light", dark: false)

        // The pinned Space's row: Follow Airc.
        choose(.dark)
        expectChrome("Dark [pinned Light still wins]", space: { pinned }, dark: false)
        click({ "settings.appearance.follow." + pinned }, fraction: 0.5,
              fallback: { [self] in try? c.store.updateSpace(pinned) { $0.theme.appearance = .auto } }, "Pinned light › Follow Airc")
        run { [self] in check(c.store.space(pinned)?.theme.appearance == .auto, "\(tag): Follow Airc: the pinned Space follows now") }
        expectChrome("Dark [the Space that followed]", space: { pinned }, dark: true)
        capture("darkfix-follow")
        choose(.auto)

        // A settings.json from before: only the New Spaces "Dark" was chosen.
        run { [self] in
            let old = Data(#"{"defaultAppearance":"dark","translucency":"default"}"#.utf8)
            let v = try? JSONDecoder().decode(AppSettings.Values.self, from: old)
            check(v?.appearance == .dark && v?.defaultAppearance == .auto, "\(tag): migrate: an old New Spaces Dark opens as Airc Dark (\(v?.appearance.rawValue ?? "-"))")
            let fresh = try? JSONDecoder().decode(AppSettings.Values.self, from: Data(#"{"appearance":"light","defaultAppearance":"dark"}"#.utf8))
            check(fresh?.appearance == .light, "\(tag): migrate: a saved Airc appearance wins (\(fresh?.appearance.rawValue ?? "-"))")
        }

        run { [self] in
            AppAppearance.simulatedSystem = nil
            AppAppearance.apply(.auto)
            settingsWindow()?.close()
            server?.stop()
            note("\(tag): input \(real ? "real clicks (UI driver)" : "posted (no driver)")")
        }
        wait(0.5)
    }
}
#endif
