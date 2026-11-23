// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit

/// `--script fsrest` (WIN-3, parity rank 5): Arc's full screen at rest, with real input only (the build Mac's UI driver,
/// `AIRC_REAL_KEYS=1` in a dedicated session: scripts/tests/fsrest/run-checks.sh).
///
/// - Real ⌃⌘F in; while the pointer is away from the top the traffic lights (AppKit's full-screen titlebar window) are
///   above the screen, and the sidebar's toggle is at its full-screen place.
/// - A real pointer at the top edge brings them down with the menu bar; moving away sends them back up.
/// - A simulated notch (`FullScreenController.simulatedSafeAreaTop`; the build Mac has none) keeps every Airc view out of
///   the camera-housing band: sidebar header row, address field, ✦, the page, the Library and the floating sidebar. A
///   second cycle enters and leaves with the notch already set.
/// - Every transition is sampled each frame: the lights leave the screen once going in and come back once going out
///   (no flash), and the toggle changes place at most once each way.
extension SnapshotRunner {
    func fullScreenRestScenario() {
        let label = "fsrest \(app?.engine.name ?? "?")"
        func ok(_ b: Bool, _ s: String) { check(b, "\(label): \(s)") }
        let notch: CGFloat = 37   // a 14"/16" MacBook Pro's camera-housing band, in points
        var buttons: [NSButton] { [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { c.window.standardWindowButton($0) } }
        /// The traffic lights, where they are on screen: nil when hidden, ordered out or wholly off the screen.
        func lightsOnScreen() -> NSRect? {
            let bs = buttons
            guard bs.count == 3, bs.allSatisfy({ !$0.isHidden && $0.alphaValue > 0 }), let w = bs[0].window, w.isVisible,
                  w.alphaValue > 0, let screen = c.window.screen else { return nil }
            let r = bs.map { w.convertToScreen($0.convert($0.bounds, to: nil)) }.reduce(NSRect.null) { $0.union($1) }
            let seen = r.intersection(screen.frame)
            return seen.height >= 1 && seen.width >= 1 ? r : nil
        }
        func lightsState() -> String {
            buttons.map { b in "\(b.isHidden ? "hidden" : "shown") α\(b.alphaValue) in \(b.window.map { "\(type(of: $0)) vis \($0.isVisible) α\($0.alphaValue) \(NSStringFromRect($0.convertToScreen(b.convert(b.bounds, to: nil))))" } ?? "none")" }
                .joined(separator: " | ")
        }
        /// The window server's view of the titlebar window (kCGWindowIsOnscreen and its bounds, top-left origin).
        func serverBounds() -> String {
            guard let w = buttons.first?.window, w !== c.window,
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]])?.first
            else { return "no titlebar window" }
            let on = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let b = (info[kCGWindowBounds as String] as? [String: CGFloat]) ?? [:]
            return "server onscreen \(on), y \(b["Y"] ?? .nan), h \(b["Height"] ?? .nan)"
        }
        func serverAboveScreen() -> Bool {
            guard let w = buttons.first?.window, w !== c.window,
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(w.windowNumber)) as? [[String: Any]])?.first
            else { return true }
            guard (info[kCGWindowIsOnscreen as String] as? Bool) == true, let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return true }
            let top = (c.window.screen?.frame.maxY).map { (NSScreen.screens.first?.frame.maxY ?? 0) - $0 } ?? 0
            return (b["Y"] ?? 0) + (b["Height"] ?? 0) <= top + 0.5
        }

        // Each frame of a transition: the lights on screen, and the toggle's full-screen place.
        var samples: [(lights: Bool, toggleAside: Bool)] = []
        var sampler: Timer?
        func startSampling() {
            samples = []
            sampler?.invalidate()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                samples.append((lightsOnScreen() != nil, self.c.sidebar.header.fullscreen))
            }
            RunLoop.main.add(t, forMode: .common)
            sampler = t
        }
        func changes(_ values: [Bool]) -> Int { zip(values, values.dropFirst()).filter { $0 != $1 }.count }
        func stopSampling(_ what: String, lightsEnd: Bool) {
            sampler?.invalidate(); sampler = nil
            let lights = samples.map { $0.lights }, aside = samples.map { $0.toggleAside }
            note("\(label): \(what): \(samples.count) samples, lights changed \(changes(lights))×, toggle \(changes(aside))×")
            ok(samples.count >= 20 && changes(lights) <= 1 && lights.last == lightsEnd,
               "\(what): the traffic lights change \(changes(lights))× (≤ 1, no flash) and end \(lightsEnd ? "on" : "off") screen")
            ok(changes(aside) <= 1 && aside.last == !lightsEnd, "\(what): the sidebar toggle moves \(changes(aside))× (≤ 1)")
        }

        let pid = getpid()
        var menuBarShown = false
        func press(_ combo: String, repeatCount: Int = 1, _ what: String) {
            step { [self] done in
                UIDriverClient.run(["--key", combo, "--repeat", String(repeatCount), "--pid", String(pid)]) { good, out in
                    if !good { self.note("FAIL \(label): real \(what) not delivered: \(out.prefix(160))") }
                    done()
                }
            }
        }
        func pointer(_ what: String, hover dwell: Int? = nil, _ at: @escaping () -> NSPoint) {
            step { [self] done in
                let p = at()
                let move: (@escaping (Bool, String) -> Void) -> Void = { cb in
                    if let dwell { UIDriverClient.hover(p, in: self.c.window, dwell: dwell, steps: 12, duration: 150, cb) }
                    else { UIDriverClient.move(p, in: self.c.window, steps: 12, duration: 150, cb) }
                }
                move { good, out in
                    if !good { self.note("FAIL \(label): real pointer \(what) failed: \(out.prefix(160))") }
                    done()
                }
            }
        }
        let middle = { [self] () -> NSPoint in c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil) }
        // The window's very top row is the screen's top edge in full screen.
        let topEdge = { [self] () -> NSPoint in NSPoint(x: c.window.frame.width / 2, y: c.window.frame.height - 0.5) }
        func settle(fullScreen: Bool) {
            step { [self] done in
                waitUntil({ self.c.window.styleMask.contains(.fullScreen) == fullScreen && self.c.isFullscreen == fullScreen }, timeout: 8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done)
                }
            }
        }

        /// No view of ours in the top `band` points of the window (root coordinates, flipped), and the named controls
        /// below it.
        func bandIsClear(_ band: CGFloat, _ what: String) {
            let root = c.root
            let strip = NSRect(x: 0, y: 0, width: root.bounds.width, height: band)
            var offenders: [String] = []
            func walk(_ v: NSView) {
                guard !v.isHidden, v.alphaValue > 0.01 else { return }
                if v === c.background { return }
                let r = v.convert(v.bounds, to: root)
                if v !== root, v.subviews.isEmpty || v is NSControl, r.intersects(strip), r.width > 0, r.height > 0,
                   r.intersection(root.bounds).height > 0 {
                    offenders.append("\(type(of: v)) \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))")
                }
                if v is NSControl { return }
                v.subviews.forEach(walk)
            }
            walk(root)
            ok(offenders.isEmpty, "\(what): nothing in the top \(Int(band)) pt (\(offenders.isEmpty ? "clear" : offenders.prefix(4).joined(separator: "; ")))")
            let h = c.sidebar.header
            let pager = c.sidebar.pager
            let page = pager.pages.first { !$0.isHidden && $0.convert($0.bounds, to: pager).intersects(pager.bounds) }
            var named: [(String, NSView?)] = [("toggle", h.toggle), ("back", h.back), ("forward", h.forward),
                                             ("reload", h.reload), ("✦", h.agent.glyph), ("address field", page?.urlField)]
            if let t = c.pageToolbar { named.append(("page toolbar", t)) }
            let tops = named.map { (n, v) in (n, v.map { $0.convert($0.bounds, to: root).minY }) }
            let low = tops.filter { $0.1 == nil || $0.1! < band - 0.01 }
            // In root coordinates: revealed, the sidebar lives inside the floating view.
            let sidebarTop = c.sidebar.convert(c.sidebar.bounds, to: root).minY
            ok(c.card.frame.minY >= band && sidebarTop >= band - 0.01 && low.isEmpty,
               "\(what): page top \(Int(c.card.frame.minY)), sidebar top \(Int(sidebarTop)), "
               + tops.map { "\($0.0) \($0.1.map { String(Int($0)) } ?? "missing")" }.joined(separator: ", ") + " (all ≥ \(Int(band)))")
        }

        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL \(label): needs the UI driver in a dedicated session (AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1)") }
            return
        }
        waitForPage()
        activateForRealInput()
        run { [self] in
            FullScreenController.simulatedSafeAreaTop = nil
            ok(!c.window.styleMask.contains(.fullScreen) && NSApp.isActive && c.window.isKeyWindow,
               "starts windowed, active and key (app active \(NSApp.isActive), key \(c.window.isKeyWindow))")
            ok(c.fullScreen.topSafeInset == 0 && c.sidebar.frame.minY == 0, "windowed: no top inset (sidebar top \(c.sidebar.frame.minY))")
        }
        pointer("to the page", middle)

        // 1. In with a real ⌃⌘F; at rest.
        run { startSampling() }
        press("ctrl+cmd+f", "⌃⌘F (enter)")
        settle(fullScreen: true)
        run { [self] in
            stopSampling("entering", lightsEnd: false)
            let screen = c.window.screen?.frame ?? .zero
            let tw = buttons.first?.window
            ok(c.window.styleMask.contains(.fullScreen), "the window is in native full screen")
            menuBarShown = NSMenu.menuBarVisible()
            note("\(label): menu bar \(menuBarShown ? "kept shown (this Mac's setting)" : "hidden") at rest, window top "
                 + "\(screen.maxY - c.window.frame.maxY) pt below the screen's; lights: \(lightsState()); \(serverBounds()), above the screen \(serverAboveScreen())")
            // Visible means drawn (button and window alpha) and on the screen; the window server's bounds don't know alpha.
            let overContent = buttons.contains { b in b.window.map { $0.convertToScreen(b.convert(b.bounds, to: nil)).intersects(c.window.frame) && $0.alphaValue > 0 && b.alphaValue > 0 } ?? false }
            ok(lightsOnScreen() == nil && !overContent && !c.fullScreen.titlebarRevealed,
               "at rest the traffic lights are off screen (titlebar window \(tw.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" } ?? "none"), "
               + "screen \(NSStringFromRect(screen)), \(serverBounds()))")
            ok(buttons.count == 3 && buttons.allSatisfy { !$0.isHidden } && tw !== c.window,
               "the lights stay available in AppKit's titlebar window (unhidden), for the top-edge reveal")
            ok(c.sidebar.header.fullscreen, "at rest the sidebar toggle is at the very left (Arc's full-screen place)")
            ok(c.fullScreen.topSafeInset == 0 && c.sidebar.frame.minY == 0 && c.card.frame.minY == AircMetrics.Window.cardInset,
               "no notch here: the full-screen layout is unchanged (sidebar top \(c.sidebar.frame.minY), page top \(c.card.frame.minY))")
        }
        wait(1.0)
        run { [self] in ok(lightsOnScreen() == nil, "still off screen 1 s later, the pointer resting on the page") }
        step { [self] done in captureWindow(c.window, name: "fsrest-01-at-rest", rounded: 0) { done() } }

        // 2. The top edge brings them down; away sends them up. The window's top row first; where the menu bar stays
        // shown (the window starts below it) the screen's top row next.
        pointer("to the top edge", hover: 900, topEdge)
        step { [self] done in waitUntil({ self.c.fullScreen.titlebarRevealed && lightsOnScreen() != nil }, timeout: 4, then: done) }
        step { [self] done in
            guard !(c.fullScreen.titlebarRevealed && lightsOnScreen() != nil) else { note("\(label): revealed from the window's top row"); return done() }
            note("\(label): the window's top row didn't reveal (lights: \(lightsState())); trying the screen's top row")
            let up = (c.window.screen?.frame.maxY ?? c.window.frame.maxY) - c.window.frame.maxY
            UIDriverClient.hover(NSPoint(x: c.window.frame.width / 2, y: c.window.frame.height + up - 0.5), in: c.window, dwell: 900, steps: 6, duration: 100) { good, out in
                if !good { self.note("FAIL \(label): real pointer to the screen's top failed: \(out.prefix(160))") }
                self.waitUntil({ self.c.fullScreen.titlebarRevealed && lightsOnScreen() != nil }, timeout: 4) {
                    self.note("\(label): screen's top row: revealed \(self.c.fullScreen.titlebarRevealed); lights: \(lightsState())")
                    done()
                }
            }
        }
        wait(0.5)
        run { [self] in
            let r = lightsOnScreen()
            ok(r != nil && c.fullScreen.titlebarRevealed, "the pointer at the top edge brings the lights down (\(r.map(NSStringFromRect) ?? "not on screen: " + lightsState()))")
            ok(!c.sidebar.header.fullscreen, "while they are down the toggle steps right of them")
        }
        pointer("back to the page", middle)
        step { [self] done in waitUntil({ !self.c.fullScreen.titlebarRevealed && lightsOnScreen() == nil }, timeout: 5, then: done) }
        wait(0.5)
        run { [self] in
            ok(lightsOnScreen() == nil && !c.fullScreen.titlebarRevealed && c.sidebar.header.fullscreen,
               "away from the top they go back up and the toggle returns (\(serverBounds()))")
        }

        // 3. A simulated notch while in full screen.
        run { [self] in
            // Measured from the window's top: where the person's setting keeps the menu bar shown, the full-screen
            // window starts below it, and a real notch's band is never deeper than that menu bar.
            let below = (c.window.screen?.frame.maxY ?? c.window.frame.maxY) - c.window.frame.maxY
            FullScreenController.simulatedSafeAreaTop = notch + max(0, below)
            note("\(label): simulated notch band \(notch + max(0, below)) pt from the screen top (window top \(below) pt below it)")
            c.root.needsLayout = true
            c.root.layoutSubtreeIfNeeded()
            ok(c.fullScreen.topSafeInset == notch, "simulated notch: top inset \(c.fullScreen.topSafeInset) pt")
            bandIsClear(notch, "simulated notch")
        }
        step { [self] done in captureWindow(c.window, name: "fsrest-02-notch", rounded: 0) { done() } }
        // The sidebar hidden: the page and the floating sidebar keep clear too.
        press("cmd+s", "⌘S (hide the sidebar)")
        step { [self] done in waitUntil({ self.c.sidebarHidden && self.c.sidebarFraction <= 0.001 }, timeout: 3, then: done) }
        wait(0.3)
        run { [self] in
            ok(c.sidebarHidden && c.card.frame.minY >= notch, "simulated notch, sidebar hidden: page top \(c.card.frame.minY)")
        }
        // The reveal arms on a pointer moving inside the strip, not on one that only arrives there.
        pointer("into the left strip") { [self] in NSPoint(x: 5, y: c.window.frame.height / 2) }
        step { [self] done in
            UIDriverClient.hover(NSPoint(x: 1, y: c.window.frame.height / 2 + 24), in: c.window, dwell: 900, steps: 6, duration: 120) { good, out in
                if !good { self.note("FAIL \(label): real pointer inside the left strip failed: \(out.prefix(160))") }
                done()
            }
        }
        step { [self] done in waitUntil({ self.c.revealController?.isRevealed == true }, timeout: 4) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
        } }
        run { [self] in
            ok(c.revealController?.isRevealed == true, "the left edge reveals the floating sidebar (dwell verdicts \(c.revealController?.dwellVerdicts.suffix(3).map { $0.map { "\($0)" } ?? "reveal" } ?? []))")
            bandIsClear(notch, "simulated notch, floating sidebar")
        }
        pointer("back to the page", middle)
        wait(0.8)
        press("cmd+s", "⌘S (show the sidebar)")
        step { [self] done in waitUntil({ !self.c.sidebarHidden && self.c.sidebarFraction >= 1 }, timeout: 3, then: done) }
        wait(0.3)
        run { [self] in ok(!c.sidebarHidden, "the sidebar is docked again") }

        // 4. Out with Esc twice (real), the notch still set: no flash, and the windowed layout has no inset.
        run { startSampling() }
        press("esc", repeatCount: 2, "Esc twice")
        settle(fullScreen: false)
        run { [self] in
            stopSampling("leaving", lightsEnd: true)
            let w = c.window
            let centers = buttons.map { b -> CGPoint in
                let r = b.convert(b.bounds, to: nil)
                return CGPoint(x: r.midX, y: w.frame.height - r.midY)
            }
            let atArc = centers.count == 3 && zip(centers, AircMetrics.Window.trafficLightCenters).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
            ok(!w.styleMask.contains(.fullScreen) && atArc, "Esc twice leaves; the lights are back at Arc's centres \(centers)")
            ok(c.fullScreen.topSafeInset == 0 && c.sidebar.frame.minY == 0 && c.card.frame.minY == AircMetrics.Window.cardInset,
               "windowed with the simulated notch: no inset (sidebar top \(c.sidebar.frame.minY), page top \(c.card.frame.minY))")
        }

        // 5. Second cycle, entering with the notch already set.
        run { startSampling() }
        press("ctrl+cmd+f", "⌃⌘F (enter, notch set)")
        settle(fullScreen: true)
        run { [self] in
            stopSampling("entering with the notch", lightsEnd: false)
            ok(lightsOnScreen() == nil, "at rest again: lights off screen (\(serverBounds()))")
            bandIsClear(notch, "entered with the simulated notch")
        }
        run { startSampling() }
        press("ctrl+cmd+f", "⌃⌘F (leave)")
        settle(fullScreen: false)
        run { [self] in
            stopSampling("leaving with ⌃⌘F", lightsEnd: true)
            ok(!c.window.styleMask.contains(.fullScreen) && c.sidebar.frame.minY == 0, "⌃⌘F leaves; windowed layout without inset")
        }
        // Never leave the display in full screen or the simulation on, whatever failed above.
        run { [self] in
            sampler?.invalidate()
            FullScreenController.simulatedSafeAreaTop = nil
            if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) }
        }
        wait(1.5)
    }
}
#endif
