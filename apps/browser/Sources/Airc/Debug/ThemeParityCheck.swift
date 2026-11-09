// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script themeparity` (both engines; P05: P07 + Q02) on loopback pages.
///   1. Arc's page palette: a page shows its own Space's `--arc-palette-*` values (exactly ThemePagePalette's), in two
///      windows with two profiles at once; when the engine hands the page script its tab's key at document start, the
///      values are there in the page's first script, else the time until they arrive is measured.
///   2. Live: a Space's new theme reaches its pages and nobody else's; the system appearance (the app's, here) turns an
///      automatic theme's palette dark; a tab moved to another Space takes that Space's palette; a page moved to another
///      window keeps its Space's; a private window's page has none.
///   3. Intensity 0 and 1 in light and dark: the palette's ink still reads on its background (≥ 4.5:1, ≥ 3:1).
///   4. Reduce Motion (AircMotion's override, the same switch every reader uses): a Space switch doesn't slide;
///      Reduce Transparency (posted as the system posts it): the background goes opaque.
///   5. The window at 1x and 2x in a light and a dark theme: theme-parity-<theme>-<scale>.png, with the tab title's
///      contrast measured from the pixels.
extension SnapshotRunner {
    func themeParityScenario() {
        let chromium = app?.engine.name.hasPrefix("Chromium") == true
        let tag = chromium ? "chromium" : "webkit"
        var server: LocalPageServer?
        var port: UInt16 = 0
        var home = "", homeB = "", other = "", tabA = "", tabB = "", tabMove = ""
        var w2: WindowController?
        var privateWindow: PrivateWindowController?
        // Window 1: the runner's `c` follows the window used last, which becomes window 2 once that opens.
        var w1Ref: WindowController?
        let w1 = { w1Ref ?? self.c! }
        let names = ThemePagePalette.palette(.neutral, systemDark: false).variables.map(\.name)
        func base(_ host: String = "127.0.0.1") -> String { "http://\(host):\(port)" }
        let page = """
            <!doctype html><html><head><title>palette</title><link rel="icon" href="data:,">
            <script>
            (function () {
              var root = document.documentElement, t0 = performance.now();
              function bg() { return getComputedStyle(root).getPropertyValue('--arc-palette-background').trim(); }
              window.__atStart = bg();
              (function poll() { if (bg()) { window.__arrived = Math.round(performance.now() - t0); return; } if (performance.now() - t0 < 4000) setTimeout(poll, 1); })();
              requestAnimationFrame(function () { window.__firstFrame = bg(); });
            })();
            </script>
            <style>
            html { background: var(--arc-palette-background, #cccccc); color: var(--arc-palette-foregroundPrimary, #333333); font: 17px -apple-system, sans-serif; }
            body { margin: 0; padding: 40px; }
            .card { background: var(--arc-palette-backgroundExtra, #dddddd); border: 2px solid var(--arc-palette-focus, #999999); border-radius: 14px; padding: 18px 22px; max-width: 520px; }
            .sub { color: var(--arc-palette-foregroundSecondary, #666666); }
            .bar { height: 36px; border-radius: 10px; margin-top: 18px; max-width: 564px;
                   background: linear-gradient(90deg, var(--arc-background-gradient-color0, #aaa), var(--arc-background-gradient-color1, #bbb), var(--arc-background-gradient-color2, #ccc)); }
            </style></head><body><h1>Space palette</h1><div class="card"><p>Primary text on this Space's colours.</p>
            <p class="sub">Secondary text, as Arc's --arc-palette-foregroundSecondary.</p></div><div class="bar"></div></body></html>
            """
        let valuesJS = "JSON.stringify(\(String(data: try! JSONSerialization.data(withJSONObject: names), encoding: .utf8)!).map(function (n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }))"

        func expected(_ spaceID: String) -> [String] {
            guard let s = self.app?.store.space(spaceID) else { return [] }
            return ThemePagePalette.palette(s.theme, systemDark: ThemePagePalette.isDark(NSApp.effectiveAppearance)).variables.map(\.value)
        }
        func values(_ tab: @escaping () -> EngineTab?, _ then: @escaping ([String]) -> Void) {
            step { done in
                guard let p = tab() else { then([]); return done() }
                p.evaluate(valuesJS) { v in
                    then((v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? [])
                    done()
                }
            }
        }
        /// Waits until `tab`'s page shows `want()` (all 19 values), then checks it.
        func expectPalette(_ tab: @escaping () -> EngineTab?, _ want: @escaping () -> [String], _ what: String, timeout: Double = 5) {
            step { [self] done in
                let deadline = Date().addingTimeInterval(timeout)
                func poll() {
                    guard let p = tab() else { check(false, "themeparity (\(tag)): \(what) (no page)"); return done() }
                    p.evaluate(valuesJS) { v in
                        let got = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
                        let w = want()
                        if got == w || Date() > deadline {
                            self.check(got == w && !w.isEmpty && (w.allSatisfy(\.isEmpty) || got.count == names.count),
                                       "themeparity (\(tag)): \(what) (background \(got.indices.contains(6) ? got[6] : "-"), want \(w.indices.contains(6) ? w[6] : "-"))")
                            return done()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                    }
                }
                poll()
            }
        }
        func waitTitle(_ tab: @escaping () -> EngineTab?, _ title: String) {
            step { [self] done in
                waitUntil({ tab()?.title == title && tab()?.isLoading == false }, timeout: 12) {
                    if tab()?.title != title { self.check(false, "themeparity (\(tag)): \(title) loads (\(tab()?.title ?? "-"))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        let pageA = { w1().engineTab(for: tabA) }
        let pageB = { w2?.engineTab(for: tabB) }

        step { [self] done in
            server = LocalPageServer(responses: ["/palette": .init(body: page)])
            server?.start { p in
                port = p ?? 0
                self.check(port != 0, "themeparity (\(tag)): the loopback server starts")
                done()
            }
        }
        // Space A: Mint (light) in this window's profile; Space A2: Lemon, same profile; Space B: Ocean (dark), another
        // profile, in a second window.
        step { [self] done in
            guard let app, port != 0 else { return done() }
            w1Ref = c
            let store = w1().store
            home = w1().currentSpaceID
            try? store.updateSpace(home) { $0.theme = DesignTheme.preset("mint")!.model }
            homeB = (try? store.createSpace(name: "Lemon", icon: .emoji("🍋"), theme: DesignTheme.preset("lemon")!.model,
                                            profileID: store.profile(ofSpace: home).id, after: home).id) ?? ""
            guard let p = try? app.profiles.createProfile(name: "Theme check", emoji: "🎨", color: nil),
                  let s = try? store.createSpace(name: "Ocean", icon: .emoji("🌊"), theme: DesignTheme.preset("ocean")!.model, profileID: p.id, after: homeB),
                  let a = try? store.openTab(url: base() + "/palette?a", inSpace: home, title: "palette"),
                  let m = try? store.openTab(url: base() + "/palette?move", inSpace: home, title: "palette"),
                  let b = try? store.openTab(url: base() + "/palette?b", inSpace: s.id, title: "palette") else {
                check(false, "themeparity (\(tag)): two profiles, three Spaces and their tabs")
                return done()
            }
            (other, tabA, tabMove, tabB) = (s.id, a.id, m.id, b.id)
            w1().reloadAll(animated: false)
            w1().show(tabA, focus: false)
            app.profiles.whenLoaded(p.id, { _ in
                w2 = app.openNewWindow(from: w1(), spaceID: s.id, tab: .id(tabB), commandBar: false)
                done()
            }, failed: { self.check(false, "themeparity (\(tag)): the second profile loads"); done() })
        }
        waitTitle(pageA, "palette")
        waitTitle(pageB, "palette")

        // 1. Each page shows its own Space's palette, in its own window and profile.
        expectPalette(pageA, { expected(home) }, "window 1, profile 1: the page shows Mint's palette")
        expectPalette(pageB, { expected(other) }, "window 2, profile 2: the page shows Ocean's, not Mint's")
        step { [self] done in
            guard let p = pageA() else { return done() }
            p.evaluate("JSON.stringify([window.__atStart || '', window.__arrived === undefined ? -1 : window.__arrived, window.__firstFrame === undefined ? 'none' : window.__firstFrame])") { v in
                let got = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] } ?? []
                let atStart = got.first as? String ?? "", arrived = (got.dropFirst().first as? NSNumber)?.intValue ?? -1
                let engineData = ThemePagePalette.shared?.document(of: p)?.engineData ?? false
                let e = expected(home), want = e.indices.contains(6) ? e[6] : "?"
                if engineData {
                    self.check(atStart == want, "themeparity (\(tag)): the engine handed the page its key: the palette is there in the page's first script (\(atStart))")
                } else {
                    self.skip("themeparity (\(tag)): before first paint: this engine hands the page script no per-tab data yet (engine ask). The first animation frame saw \(got.count > 2 ? "\(got[2])" : "?") (\"none\": no frame ran); a 1 ms timer saw the palette \(arrived) ms after the page's first script (an upper bound: a hidden window's timers are throttled)")
                    self.check(arrived >= 0, "themeparity (\(tag)): without engine data the palette still arrives (\(arrived) ms)")
                }
                done()
            }
        }
        capture("theme-parity-pages")

        // 2. Live: Space A's theme changes; B's page doesn't hear of it.
        var bBefore: [String] = []
        values(pageB) { bBefore = $0 }
        run { [self] in try? w1().store.updateSpace(home) { $0.theme = DesignTheme.preset("peach")!.model } }
        expectPalette(pageA, { expected(home) }, "a new theme for Space A reaches its page at once")
        values(pageB) { [self] now in check(now == bBefore && !now.isEmpty, "themeparity (\(tag)): Space B's page keeps its own palette") }

        // The system appearance (the app's own, so the owner's Mac isn't touched): an automatic theme turns dark.
        run { [self] in
            try? w1().store.updateSpace(home) { $0.theme = AircKit.SpaceTheme(colors: [RGBA(0.49, 0.71, 0.84, 1)], intensity: 0.81, grain: 0, appearance: .auto) }
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        expectPalette(pageA, { expected(home) }, "an automatic theme in light mode")
        var lightValues: [String] = []
        values(pageA) { lightValues = $0 }
        run { NSApp.appearance = NSAppearance(named: .darkAqua) }
        wait(0.4)
        expectPalette(pageA, { expected(home) }, "the system turning dark gives an automatic theme its dark palette")
        values(pageA) { [self] dark in check(dark != lightValues && dark.indices.contains(3) && dark[3] == "#ffffff",
                                             "themeparity (\(tag)): the dark palette's max-contrast colour is white (\(dark.indices.contains(3) ? dark[3] : "-"))") }
        run { NSApp.appearance = NSAppearance(named: .aqua) }
        wait(0.4)

        // A tab moved to another Space (Lemon, same profile) takes that Space's palette.
        run { [self] in w1().show(tabMove, focus: false) }
        waitTitle({ w1().engineTab(for: tabMove) }, "palette")
        expectPalette({ w1().engineTab(for: tabMove) }, { expected(home) }, "a second tab of Space A shows A's palette")
        run { [self] in _ = try? w1().store.moveTab(tabMove, toSpace: homeB) }
        expectPalette({ w1().engineTab(for: tabMove) ?? w2?.engineTab(for: tabMove) }, { expected(homeB) }, "moved to Lemon, it shows Lemon's palette, nothing of A's")

        // A page moved to another window keeps its own Space's palette.
        var w3: WindowController?
        run { [self] in w3 = app?.openNewWindow(from: c, spaceID: homeB, tab: .id(tabMove), commandBar: false) }
        wait(1.2)
        expectPalette({ w3?.engineTab(for: tabMove) ?? w1().engineTab(for: tabMove) }, { expected(homeB) }, "the page moved to a third window keeps Lemon's palette")
        run { w3?.window.performClose(nil) }

        // A private window's page: no Space, no palette.
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                w?.openPage(URL(string: base() + "/palette?private"))
                done()
            }
        }
        step { [self] done in
            waitUntil({ privateWindow?.shownPage?.title == "palette" && privateWindow?.shownPage?.isLoading == false }, timeout: 10) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
            }
        }
        expectPalette({ privateWindow?.shownPage }, { names.map { _ in "" } }, "a private window's page has no palette at all")
        run { privateWindow?.window.performClose(nil) }

        // 3. Intensity 0 and 1, light and dark: the palette on the page, and its ink on its background.
        for (preset, intensity) in [("mint", 0.0), ("mint", 1.0), ("ocean", 0.0), ("ocean", 1.0)] {
            run { [self] in try? w1().store.updateSpace(home) { var t = DesignTheme.preset(preset)!; t.intensity = intensity; $0.theme = t.model } }
            expectPalette(pageA, { expected(home) }, "\(preset) at intensity \(intensity) reaches the page")
            values(pageA) { [self] v in
                guard v.count == names.count, let fg = AircColor(hex: v[0]), let second = AircColor(hex: v[1]), let bg = AircColor(hex: v[6]) else {
                    return check(false, "themeparity (\(tag)): \(preset) i\(intensity) values")
                }
                check(fg.contrast(on: bg) >= 4.45 && second.contrast(on: bg) >= 2.95,
                      "themeparity (\(tag)): \(preset) at intensity \(intensity): primary \(String(format: "%.2f", fg.contrast(on: bg))):1, secondary \(String(format: "%.2f", second.contrast(on: bg))):1 on the page's background")
            }
        }

        // 4. Reduce Motion and Reduce Transparency, through the same switches the system's settings flip.
        run { [self] in MainActor.assumeIsolated {
            AircMotion.reduceMotionOverride = true
            w1().switchToSpace(homeB, animated: true)
            check(!w1().sidebar.pager.isTrackingOrSettling, "themeparity (\(tag)): with Reduce Motion a Space switch doesn't slide (settled at once)")
            w1().switchToSpace(home, animated: false)
            w1().switchToSpace(other, animated: true)
            check(!w1().sidebar.pager.isTrackingOrSettling, "themeparity (\(tag)): nor does a longer jump (two Spaces over)")
            w1().switchToSpace(home, animated: false)
            AircMotion.reduceMotionOverride = false
            w1().switchToSpace(homeB, animated: true)
            check(w1().sidebar.pager.isTrackingOrSettling, "themeparity (\(tag)): without it the same switch springs")
            AircMotion.reduceMotionOverride = nil
            note("themeparity (\(tag)): the Mac's own Reduce Motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), Reduce Transparency \(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        } }
        wait(0.8)
        run { [self] in MainActor.assumeIsolated {
            w1().switchToSpace(home, animated: false)
            let v = SpaceBackgroundView(theme: DesignTheme.preset("ocean")!.resolved(systemIsDark: false))
            v.translucency = .subtle
            v.isWindowActiveOverride = true
            let translucent = v.currentUnderlayOpacity
            AircTranslucency.reduceTransparencyOverride = true
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            let reduced = v.currentUnderlayOpacity
            AircTranslucency.reduceTransparencyOverride = nil
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
            check(translucent < 1 && reduced == 1 && v.currentUnderlayOpacity == translucent,
                  "themeparity (\(tag)): Reduce Transparency turns a translucent background opaque and back (\(translucent) → \(reduced) → \(v.currentUnderlayOpacity))")
        } }

        // 5. The window at 1x and 2x, light and dark, with the shown tab's title contrast from the pixels.
        for preset in ["mint", "ocean"] {
            run { [self] in
                try? w1().store.updateSpace(home) { $0.theme = DesignTheme.preset(preset)!.model }
                w1().reloadAll(animated: false)
                w1().show(tabA, focus: false)
            }
            wait(1.0)
            run { [self] in
                for scale in [1.0, 2.0] {
                    guard let rep = themeBitmap(w1().root, scale: scale) else { check(false, "themeparity (\(tag)): \(preset) \(Int(scale))x capture"); continue }
                    let png = rep.representation(using: .png, properties: [:])
                    try? png?.write(to: dir.appendingPathComponent("theme-parity-\(preset)-\(Int(scale))x.png"))
                    guard let field = w1().pageView(for: home)?.rows[tabA].flatMap({ ($0 as? TabRowView)?.titleField }) else {
                        skip("themeparity (\(tag)): \(preset) \(Int(scale))x title contrast (no row)"); continue
                    }
                    let rect = field.convert(field.bounds, to: w1().root)
                    let ratio = Self.inkContrast(rep, rect: rect, in: w1().root.bounds.size, scale: scale, flipped: w1().root.isFlipped)
                    let floor = scale >= 2 ? 4.2 : 3.0
                    check(ratio >= floor, "themeparity (\(tag)): \(preset) at \(Int(scale))x: the tab title measures \(String(format: "%.2f", ratio)):1 against its row (floor \(floor))")
                }
            }
        }
        run { [self] in
            w2?.window.performClose(nil)
            server?.stop()
        }
    }

    /// `view` drawn at `scale` pixels per point (1x or 2x, whatever the screen is).
    func themeBitmap(_ view: NSView, scale: Double) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        MainActor.assumeIsolated { AircSnapshot.withoutDuplicates(in: view) { view.cacheDisplay(in: view.bounds, to: rep) } }
        return rep
    }

    /// The contrast of the strongest ink in `rect` (points, view coordinates, origin bottom-left unless the view is
    /// flipped) against the most common colour there, from the pixels.
    static func inkContrast(_ rep: NSBitmapImageRep, rect: NSRect, in size: NSSize, scale: Double, flipped: Bool = true) -> Double {
        func lum(_ c: NSColor) -> Double {
            guard let s = c.usingColorSpace(.sRGB) else { return 0 }
            func ch(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * ch(s.redComponent) + 0.7152 * ch(s.greenComponent) + 0.0722 * ch(s.blueComponent)
        }
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(rep.pixelsWide - 1, Int(rect.maxX * scale))
        // Bitmap rows run top-down, like the window's (flipped) root view.
        let top = flipped ? rect.minY : size.height - rect.maxY
        let y0 = max(0, Int(top * scale)), y1 = min(rep.pixelsHigh - 1, Int((top + rect.height) * scale))
        guard x1 > x0, y1 > y0 else { return 0 }
        var lums: [Double] = []
        for y in y0...y1 { for x in x0...x1 { if let c = rep.colorAt(x: x, y: y) { lums.append(lum(c)) } } }
        guard !lums.isEmpty else { return 0 }
        // The background: the most common luminance bucket.
        var buckets: [Int: [Double]] = [:]
        for l in lums { buckets[Int(l * 200), default: []].append(l) }
        let bg = buckets.max { $0.value.count < $1.value.count }!.value.reduce(0, +) / Double(buckets.max { $0.value.count < $1.value.count }!.value.count)
        let sorted = lums.sorted()
        // The ink: the 2nd percentile darkest (light themes) or brightest (dark ones), past antialiasing noise.
        let darkInk = sorted[Int(Double(sorted.count - 1) * 0.02)], lightInk = sorted[Int(Double(sorted.count - 1) * 0.98)]
        let ink = abs(darkInk - bg) > abs(lightInk - bg) ? darkInk : lightInk
        return (max(ink, bg) + 0.05) / (min(ink, bg) + 0.05)
    }
}
#endif
