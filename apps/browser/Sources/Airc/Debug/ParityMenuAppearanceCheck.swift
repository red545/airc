// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// `--script paritymenuappearance` (TH-3, both engines; paritysweep): the sidebar takes its Space's light or dark
/// (WindowController.applySidebarAppearance), so a row's native context menu matches the Space, not the app:
///   1. app Light, a dark Space (Appearance Dark): the sidebar is dark, the page card stays light;
///   2. a real ⌃-click (UI driver) on a sidebar tab row opens its menu, drawn dark (the menu's appearance while it's
///      tracking, the menu window's, and its text drawn light), then a real Esc closes it;
///   3. a light Space in the same window: the sidebar inherits again (no override) and the menu is light;
///   4. app Dark, the light Space: the sidebar is light (override), the card dark; the dark Space: inherits.
/// Needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1 for 2–3; without them those steps are
/// FAIL-ENV and 1 and 4 still run. Zero-guard: the run fails if it made too few assertions.
extension SnapshotRunner {
    @MainActor func parityMenuAppearanceScenario() {
        let tag = "paritymenuappearance (\(app?.engine is WebKitEngine ? "WebKit" : "Chromium"))"
        var asserted = 0
        func expect(_ ok: Bool, _ what: String) { asserted += 1; check(ok, "\(tag): \(what)") }
        func dark(_ a: NSAppearance?) -> Bool { a?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        func name(_ a: NSAppearance?) -> String { a.map { $0.name.rawValue } ?? "nil" }
        var before: Appearance = .auto
        var darkSpace = "", lightSpace = "", darkTab = "", lightTab = ""
        let real = UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"

        func appAppearance(_ a: Appearance) {
            run { [self] in app?.settings.values.appearance = a }
            wait(0.8)
        }
        func show(_ sid: @escaping () -> String) {
            run { [self] in c.switchToSpace(sid(), animated: false); c.reloadAll(animated: false) }
            wait(0.6)
        }
        func rowPoint(_ space: String, _ id: String) -> NSPoint? {
            guard let pg = c.pageView(for: space) else { return nil }
            pg.layoutSubtreeIfNeeded()
            guard let v = pg.rows[id], v.window === c.window else { return nil }
            v.scrollToVisible(v.bounds)
            let pt = v.convert(NSPoint(x: min(60, v.bounds.width / 2), y: v.bounds.midY), to: nil)
            guard let hit = c.window.contentView?.hitTest(pt), hit === v || hit.isDescendant(of: v) else { return nil }
            return pt
        }
        /// A real ⌃-click on the row; while its menu tracks, what it's drawn with; then a real Esc.
        func menuCase(_ what: String, space: @escaping () -> String, tab: @escaping () -> String, wantDark: Bool) {
            step { [self] done in
                guard real else {
                    note("FAIL-ENV \(tag): \(what): a real ⌃-click needs AIRC_REAL_KEYS=1, the stable UI driver and AIRC_UI_DEDICATED_SESSION=1")
                    return done()
                }
                guard let p = rowPoint(space(), tab()) else { expect(false, "\(what): the tab row is on screen"); return done() }
                var seen: (menu: NSAppearance?, window: NSAppearance?, items: Int, lum: Double?)?
                var token: NSObjectProtocol?
                var finished = false
                func finish() {
                    guard !finished else { return }
                    finished = true
                    if let token { NotificationCenter.default.removeObserver(token) }
                    // Always called on the main queue (main.async / asyncAfter below).
                    MainActor.assumeIsolated {
                        if let s = seen {
                            let lum = s.lum.map { String(format: "%.2f", $0) } ?? "unread"   // the text's brightness
                            note("\(tag): \(what): menu \(name(s.menu)), menu window \(name(s.window)), text brightness \(lum), \(s.items) items")
                            expect(dark(s.menu) == wantDark && (s.window == nil || dark(s.window) == wantDark)
                                   && (s.lum == nil || (s.lum! > 0.5) == wantDark),
                                   "\(what): the row's menu (real ⌃-click) is drawn \(wantDark ? "dark" : "light") (menu \(name(s.menu)), window \(name(s.window)), text brightness \(lum))")
                        } else {
                            expect(false, "\(what): a real ⌃-click on the tab row opens its menu")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
                }
                token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                    guard seen == nil, let m = n.object as? NSMenu, m.supermenu == nil, !m.items.isEmpty else { return }
                    // Read once it's drawn (common modes run during tracking), then a real Esc closes it.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
                        let sem = DispatchSemaphore(value: 0)
                        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                            MainActor.assumeIsolated {
                                let w = NSApp.windows.first { $0.isVisible && $0 !== self.c.window && NSStringFromClass(type(of: $0)).contains("Menu") }
                                // What's drawn: cacheDisplay leaves out the menu's vibrant backdrop, so the opaque pixels are its
                                // text and glyphs: light text is a dark menu (r3: 1.00 dark, 0.00 light). nil: unread.
                                var lum: Double?
                                if let v = w?.contentView, v.bounds.width > 4, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                    v.cacheDisplay(in: v.bounds, to: rep)
                                    var sum = 0.0, n = 0
                                    for y in stride(from: 2, to: rep.pixelsHigh - 2, by: 3) {
                                        for x in stride(from: 2, to: rep.pixelsWide - 2, by: 3) {
                                            if let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), col.alphaComponent > 0.5 {
                                                sum += 0.2126 * col.redComponent + 0.7152 * col.greenComponent + 0.0722 * col.blueComponent; n += 1
                                            }
                                        }
                                    }
                                    if n > 50 { lum = sum / Double(n) }
                                }
                                seen = (m.effectiveAppearance, w?.effectiveAppearance, m.items.count, lum)
                            }
                            sem.signal()
                        }
                        CFRunLoopWakeUp(CFRunLoopGetMain())
                        _ = sem.wait(timeout: .now() + 2)
                        // A real Esc, run here (UIDriverClient.run answers on the main queue, which waits while the
                        // menu tracks). Then a common-modes block closes a menu the Esc missed, so this never hangs.
                        let pr = Process()
                        pr.executableURL = URL(fileURLWithPath: UIDriverClient.path)
                        pr.arguments = ["--json", "--key", "esc"]
                        var env = ProcessInfo.processInfo.environment
                        env.removeValue(forKey: "CFFIXED_USER_HOME")
                        pr.environment = env
                        pr.standardOutput = FileHandle.nullDevice; pr.standardError = FileHandle.nullDevice
                        if (try? pr.run()) != nil { pr.waitUntilExit() }
                        Thread.sleep(forTimeInterval: 0.3)
                        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated { m.cancelTracking() } }
                        CFRunLoopWakeUp(CFRunLoopGetMain())
                        DispatchQueue.main.async { finish() }
                    }
                }
                UIDriverClient.click(p, in: c.window, mods: "ctrl") { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag): \(what): driver: \(out)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if seen == nil { finish() } }
                }
            }
        }

        run { [self] in
            before = app?.settings.values.appearance ?? .auto
            do {
                let pid = c.store.state.spaces[c.currentSpaceID]?.profileID
                let d = try c.store.createSpace(name: "Night", theme: SpaceTheme(colors: [RGBA(0.10, 0.12, 0.22)], appearance: .dark), profileID: pid)
                let l = try c.store.createSpace(name: "Day", theme: SpaceTheme(colors: [RGBA(0.96, 0.90, 0.78)], appearance: .light), profileID: pid)
                darkSpace = d.id; lightSpace = l.id
                darkTab = try c.store.openTab(url: "https://example.com/night", inSpace: d.id, activate: false, title: "Night tab").id
                lightTab = try c.store.openTab(url: "https://example.com/day", inSpace: l.id, activate: false, title: "Day tab").id
            } catch { expect(false, "fixture: \(error)") }
        }
        appAppearance(.light)
        show { darkSpace }
        run { [self] in
            expect(!dark(NSApp.effectiveAppearance), "1. fixture: the app is light (\(name(NSApp.effectiveAppearance)))")
            expect(dark(c.sidebar.effectiveAppearance) && c.sidebar.appearance != nil,
                   "1. a dark Space in a light app: the sidebar is dark (\(name(c.sidebar.effectiveAppearance)))")
            expect(!dark(c.card.effectiveAppearance), "1. the page card keeps the app's light (\(name(c.card.effectiveAppearance)))")
        }
        if real {
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 5) {
                    self.note("\(tag): real input: key \(self.c.window.isKeyWindow), active \(NSApp.isActive)")
                    done()
                }
            }
        }
        menuCase("2. dark Space, light app", space: { darkSpace }, tab: { darkTab }, wantDark: true)
        show { lightSpace }
        run { [self] in
            expect(c.sidebar.appearance == nil && !dark(c.sidebar.effectiveAppearance),
                   "3. a light Space in a light app: the sidebar inherits (\(name(c.sidebar.appearance)))")
        }
        wait(Double(NSEvent.doubleClickInterval) + 0.2)
        menuCase("3. light Space, light app", space: { lightSpace }, tab: { lightTab }, wantDark: false)
        appAppearance(.dark)
        show { lightSpace }
        run { [self] in
            expect(dark(NSApp.effectiveAppearance), "4. fixture: the app is dark")
            expect(!dark(c.sidebar.effectiveAppearance) && c.sidebar.appearance != nil,
                   "4. a light Space in a dark app: the sidebar is light (\(name(c.sidebar.effectiveAppearance)))")
            expect(dark(c.card.effectiveAppearance), "4. the page card keeps the app's dark")
        }
        show { darkSpace }
        run { [self] in
            expect(c.sidebar.appearance == nil && dark(c.sidebar.effectiveAppearance),
                   "4. a dark Space in a dark app: the sidebar inherits (\(name(c.sidebar.appearance)))")
        }
        appAppearance(before)
        run { [self] in
            let need = real ? 10 : 8
            expect(asserted + 1 >= need, "zero-guard: \(asserted + 1) assertions (\(need) expected)")
        }
    }
}
#endif
