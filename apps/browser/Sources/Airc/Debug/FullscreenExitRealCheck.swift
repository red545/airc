// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit
import ApplicationServices

/// `--script fullscreen-exit` with `AIRC_FULLSCREEN_CASE=real`: the ways a person leaves a native full screen, with real
/// input only (the build Mac's UI driver; `AIRC_REAL_KEYS=1 AIRC_REAL_CLICKS=1` in a dedicated session). The `native`
/// case's cycle 3 presses the green button with `performClick` while AppKit's full-screen titlebar is at rest (out of
/// sight); a person first brings it down with the pointer at the top edge, then clicks. Each way below enters full
/// screen, does what a person does, and asserts what cycle 3 asserts.
///
/// 1. The pointer at the top edge brings the titlebar down; a real click on the green button.
/// 2. Diagnostics (INFO lines, no verdict): `performClick` after the top-edge reveal, and at rest (cycle 3's path).
/// 3. The menu bar (it comes down with the titlebar): a real click on View's title (macOS 26 has no Exit Full Screen
///    in Window), real ↓ to
///    Exit Full Screen, real Return.
/// 4. The green button's own menu: the real pointer resting on it opens it (macOS 26); Exit Full Screen in it.
/// 3 and 4 SKIP with their trace where the driver can't work the menu (its ↓ didn't reach the open View menu in full
/// screen on the build Mac, and resting on the button opened no menu there); the exit verdicts stay when they pick.
extension SnapshotRunner {
    func fullscreenExitRealCase() {
        let label = "fullscreen-exit real"
        guard UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" else {
            run { [self] in note("FAIL \(label): needs the UI driver in a dedicated session (AIRC_REAL_KEYS=1, AIRC_UI_DEDICATED_SESSION=1)") }
            return
        }
        let pid = getpid()
        var zoom: NSButton? { c.window.standardWindowButton(.zoomButton) }
        /// The green button, where it is on screen (AppKit coordinates), when it is drawn there.
        func zoomOnScreen() -> NSRect? {
            guard let z = zoom, let tw = z.window, !z.isHidden, z.alphaValue > 0.99, tw.isVisible, tw.alphaValue > 0.99,
                  let screen = c.window.screen else { return nil }
            let r = tw.convertToScreen(z.convert(z.bounds, to: nil))
            return screen.frame.contains(NSPoint(x: r.midX, y: r.midY)) ? r : nil
        }
        func lightsState() -> String {
            guard let z = zoom else { return "no green button" }
            return "green \(z.isHidden ? "hidden" : "shown") α\(z.alphaValue) in " + (z.window.map {
                "\(type(of: $0)) vis \($0.isVisible) α\($0.alphaValue) \(NSStringFromRect($0.convertToScreen(z.convert(z.bounds, to: nil))))"
            } ?? "none")
        }
        /// Quartz global coordinates (primary display's top-left origin) of an AppKit screen point.
        func quartz(_ p: NSPoint) -> [String] {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return [String(Double(p.x)), String(Double(top - p.y))]
        }
        let middle = { [self] () -> NSPoint in c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil) }
        func pointer(_ what: String, dwell: Int? = nil, _ at: @escaping () -> NSPoint) {
            step { [self] done in
                let cb: (Bool, String) -> Void = { good, out in
                    if !good { self.note("\(label): real pointer \(what) not delivered: \(out.prefix(160))") }
                    done()
                }
                if let dwell { UIDriverClient.hover(at(), in: c.window, dwell: dwell, steps: 10, duration: 120, cb) }
                else { UIDriverClient.move(at(), in: c.window, steps: 10, duration: 120, cb) }
            }
        }
        func isFull() -> Bool { c.window.styleMask.contains(.fullScreen) && c.isFullscreen }

        func enter(_ name: String) {
            // Active and key again (a menu or the button's popover may have taken the key window).
            step { [self] done in
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                    if !(NSApp.isActive && self.c.window.isKeyWindow) { self.note("\(label) \(name): not key before entering (key window \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"))") }
                    done()
                }
            }
            run { [self] in if !c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) } }
            step { [self] done in
                waitUntil({ isFull() }, timeout: 8) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done) }
            }
            pointer("to the page", middle)
            step { [self] done in waitUntil({ !self.c.fullScreen.titlebarRevealed && zoomOnScreen() == nil }, timeout: 4, then: done) }
            run { [self] in
                check(isFull(), "\(label) \(name): entered")
                note("\(label) \(name): at rest: revealed \(c.fullScreen.titlebarRevealed), menu bar shown \(NSMenu.menuBarVisible()), \(lightsState())")
            }
        }
        /// The real pointer at the top edge, the window's top row first, then the screen's (where the person's setting
        /// keeps the menu bar shown, the window starts below it: fsrest).
        func reveal(_ name: String, verdict: Bool = true) {
            pointer("to the window's top row", dwell: 600) { [self] in NSPoint(x: c.window.frame.width / 2, y: c.window.frame.height - 0.5) }
            step { [self] done in waitUntil({ self.c.fullScreen.titlebarRevealed && zoomOnScreen() != nil }, timeout: 3, then: done) }
            step { [self] done in
                guard !(c.fullScreen.titlebarRevealed && zoomOnScreen() != nil) else { return done() }
                let up = (c.window.screen?.frame.maxY ?? c.window.frame.maxY) - c.window.frame.maxY
                UIDriverClient.hover(NSPoint(x: c.window.frame.width / 2, y: c.window.frame.height + up - 0.5), in: c.window,
                                     dwell: 900, steps: 6, duration: 100) { good, out in
                    if !good { self.note("\(label): real pointer to the screen's top row not delivered: \(out.prefix(160))") }
                    self.waitUntil({ self.c.fullScreen.titlebarRevealed && zoomOnScreen() != nil }, timeout: 4, then: done)
                }
            }
            wait(0.4)
            run { [self] in
                let r = zoomOnScreen()
                let ok = r != nil && c.fullScreen.titlebarRevealed
                if verdict { check(ok, "\(label) \(name): the top edge brings the titlebar down (\(r.map(NSStringFromRect) ?? lightsState()))") }
                else { note("INFO \(label) \(name): revealed \(ok) (\(lightsState()))") }
            }
        }
        /// `act` does what leaves; done(false) when it found nothing to do (then no exit verdict). `verdict: false` reports
        /// INFO lines instead of PASS/FAIL (diagnostics).
        func expectExit(_ name: String, verdict: Bool = true, _ act: @escaping (@escaping (Bool) -> Void) -> Void) {
            var moves = 0, seen: [String] = [], acted = false
            var observers: [NSObjectProtocol] = []
            step { [self] done in
                let w = c.window
                for (n, tag) in [(NSWindow.willExitFullScreenNotification, "willExit"), (NSWindow.didExitFullScreenNotification, "didExit")] {
                    observers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: nil) { _ in seen.append(tag) })
                }
                if let container = w.standardWindowButton(.closeButton)?.superview?.superview {
                    container.postsFrameChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container,
                                                                            queue: nil) { _ in moves += 1 })
                }
                act { ok in acted = ok; done() }
            }
            step { [self] done in
                guard acted else { return done() }
                waitUntil({ !self.c.isFullscreen && !self.c.window.styleMask.contains(.fullScreen) }, timeout: 6, then: done)
            }
            wait(0.8)
            run { [self] in
                observers.forEach(NotificationCenter.default.removeObserver)
                guard acted else { return }
                let w = c.window
                let out = !c.isFullscreen && !w.styleMask.contains(.fullScreen)
                let accessory = !w.titlebarAccessoryViewControllers.contains { $0 is FullScreenRevealAccessory }
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
                let centers = buttons.map { b -> CGPoint in
                    let r = b.convert(b.bounds, to: nil)
                    return CGPoint(x: r.midX, y: w.frame.height - r.midY)
                }
                let atArc = centers.count == 3 && buttons.allSatisfy { $0.window === w }
                    && zip(centers, AircMetrics.Window.trafficLightCenters).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
                let where_ = centers.map { "(\(Int($0.x.rounded())),\(Int($0.y.rounded())))" }.joined(separator: " ")
                let appKit = "AppKit: \(seen.isEmpty ? "nothing" : seen.joined(separator: " "))"
                if verdict {
                    check(out, "\(label) \(name): exited full screen (\(appKit))")
                    check(accessory, "\(label) \(name): accessory removed after transition")
                    check(moves < 40, "\(label) \(name): the titlebar moved \(moves) times while leaving (no fight with AppKit)")
                    check(atArc, "\(label) \(name): traffic lights back at Arc's centres \(where_)")
                } else {
                    note("INFO \(label) \(name): left full screen \(out) (\(appKit)), accessory removed \(accessory), lights \(where_)")
                }
            }
            // Windowed again whatever happened, the pointer back on the page.
            step { [self] done in
                guard c.window.styleMask.contains(.fullScreen) else { return done() }
                c.window.toggleFullScreen(nil)
                waitUntil({ !self.c.window.styleMask.contains(.fullScreen) }, timeout: 8) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
                }
            }
            step { [self] done in waitUntil({ !self.c.isFullscreen }, timeout: 3, then: done) }
            pointer("back to the page", middle)
            wait(0.6)
        }

        /// Off the main thread: one synchronous driver command (the menus below track in a loop of their own).
        func driverSync(_ args: [String]) -> (Bool, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: UIDriverClient.path)
            p.arguments = ["--json"] + args
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CFFIXED_USER_HOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            guard (try? p.run()) != nil else { return (false, "driver did not start") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (p.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true"), out)
        }
        /// Off the main thread: `body` on the main queue (AppKit's menus assert it), waiting at most 2 s; nil if the
        /// main queue didn't get to it (a menu's tracking loop that doesn't drain it).
        func onMain<T>(_ body: @escaping () -> T) -> T? {
            var value: T?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { value = body(); done.signal() }
            return done.wait(timeout: .now() + 2) == .success ? value : nil
        }
        /// Off the main thread: real ↓ in the open `menu` until `item` is highlighted, then real Return.
        func pick(_ item: NSMenuItem, in menu: NSMenu, _ trace: inout [String]) -> Bool {
            // Where it is among the items ↓ stops at (fallback when the main queue doesn't answer while the menu tracks).
            let index = onMain { menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.isEnabled }.firstIndex { $0 === item } } ?? nil
            var blind = false
            for n in 0..<30 {
                guard let lit = onMain({ menu.highlightedItem === item }) else {
                    blind = true
                    guard let index else { break }
                    for _ in n...index { _ = driverSync(["--key", "down"]); Thread.sleep(forTimeInterval: 0.12) }
                    break
                }
                if lit { break }
                _ = driverSync(["--key", "down"])
                Thread.sleep(forTimeInterval: 0.12)
                trace.append("↓" + ((onMain { menu.highlightedItem?.title } ?? nil) ?? "-"))
            }
            if blind {
                trace.append("main queue busy while tracking: ↓ ×\((index ?? -1) + 1) by position")
                guard index != nil else { _ = driverSync(["--key", "esc"]); return false }
                let (ok, out) = driverSync(["--key", "return"])
                trace.append("Return \(ok ? "sent" : "refused: \(out.prefix(80))")")
                return ok
            }
            let now = onMain { menu.highlightedItem.map { ($0 === item, $0.title) } }
            trace.append("highlighted \(now.map { $0?.1 ?? "nothing" } ?? "unknown (main queue busy)")")
            guard now??.0 == true else { _ = driverSync(["--key", "esc"]); return false }
            let (ok, out) = driverSync(["--key", "return"])
            trace.append("Return \(ok ? "sent" : "refused: \(out.prefix(80))")")
            return ok
        }

        waitForPage()
        activateForRealInput()
        run { [self] in
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            check(NSApp.isActive && c.window.isKeyWindow && !c.window.styleMask.contains(.fullScreen),
                  "\(label): starts windowed, active and key (app active \(NSApp.isActive), key \(c.window.isKeyWindow); HID idle \(Int(idle)) s)")
        }
        pointer("to the page", middle)

        // 1. A real click on the green button, after the top edge brought it down.
        enter("green button (real click)")
        reveal("green button (real click)")
        expectExit("green button (real click)") { [self] done in
            guard let r = zoomOnScreen() else {
                check(false, "\(label) green button (real click): the green button is on screen to click (\(lightsState()))")
                return done(false)
            }
            let at = quartz(NSPoint(x: r.midX, y: r.midY))
            // Onto it, then at once the click: resting there opens the button's menu.
            UIDriverClient.run(["--move"] + at + ["--steps", "4", "--duration", "60", "--pid", String(pid)]) { _, _ in
                UIDriverClient.run(["--click"] + at) { good, out in
                    self.note("\(label) green button (real click): real click at \(at.joined(separator: ",")) \(good ? "sent" : "refused: \(out.prefix(160))")")
                    done(good)
                }
            }
        }

        // 2. Diagnostics: performClick with the titlebar down, then at rest (the native case's cycle 3).
        enter("performClick after the reveal")
        reveal("performClick after the reveal", verdict: false)
        expectExit("performClick after the reveal", verdict: false) { [self] done in
            guard let z = zoom else { return done(false) }
            note("INFO \(label) performClick after the reveal: \(lightsState()), enabled \(z.isEnabled)")
            z.performClick(nil)
            done(true)
        }
        enter("performClick at rest")
        expectExit("performClick at rest", verdict: false) { [self] done in
            guard let z = zoom else { return done(false) }
            note("INFO \(label) performClick at rest: \(lightsState()), enabled \(z.isEnabled), target \(z.target.map { "\(type(of: $0))" } ?? "nil"), action \(z.action.map(NSStringFromSelector) ?? "nil")")
            z.performClick(nil)
            done(true)
        }
        // 3. View › Exit Full Screen (macOS 26 has none in Window), real clicks and keys.
        enter("menu bar Exit Full Screen")
        reveal("menu bar Exit Full Screen")
        expectExit("menu bar Exit Full Screen") { [self] done in
            // macOS 26 puts Exit Full Screen in View only (Window has Full Screen Tile); Window's items go in the trace.
            let windowItems = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu.map { m -> String in
                return m.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map { $0.title }.joined(separator: " / ")
            } ?? "no Window menu"
            let menus = ["View"].compactMap { t in NSApp.mainMenu?.items.first { $0.submenu?.title == t || $0.title == t }.map { (t, $0) } }
            let titles = menus.map { (t, _) in (t, Self.easelAllMenuBarTitleCenter(t)) }
            var opened: NSMenu?
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                if let m = n.object as? NSMenu { opened = m }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var trace: [String] = ["AX trusted \(AXIsProcessTrusted())", "Window menu (not opened): \(windowItems)"]
                var picked = false
                for ((t, top), (_, title)) in zip(menus, titles) where !picked {
                    guard let menu = top.submenu, let pt = title else { trace.append("\(t): no title frame"); continue }
                    opened = nil
                    let (ok, out) = driverSync(["--click", String(Double(pt.x)), String(Double(pt.y))])
                    trace.append("\(t) title at \(Int(pt.x)),\(Int(pt.y)): click \(ok ? "sent" : "refused \(out.prefix(80))")")
                    for _ in 0..<15 where opened == nil { Thread.sleep(forTimeInterval: 0.1) }
                    Thread.sleep(forTimeInterval: 0.4)
                    let items = onMain { menu.items.filter { !$0.isHidden && !$0.isSeparatorItem } } ?? []
                    trace.append("\(t) open \(opened != nil): " + (onMain { items.map { $0.title }.joined(separator: " / ") } ?? "?"))
                    guard opened != nil else { continue }
                    if let item = onMain({ items.first(where: { $0.title == "Exit Full Screen" && $0.isEnabled }) }) ?? nil {
                        picked = pick(item, in: menu, &trace)
                        if picked { trace.append("picked \(t) › Exit Full Screen") }
                    } else {
                        _ = driverSync(["--key", "esc"])
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
                if !picked { _ = driverSync(["--key", "esc"]); _ = driverSync(["--key", "esc"]) }
                DispatchQueue.main.async {
                    NotificationCenter.default.removeObserver(token)
                    self.note("\(label) menu bar Exit Full Screen: " + trace.joined(separator: "; "))
                    // The driver's ↓ never highlighted an item of the open View menu in full screen (r2, r3: 30× "-");
                    // the same action from the menu passes in the native case's cycle 2. Report it, don't fail on it.
                    if !picked { self.skip("\(label) menu bar Exit Full Screen: View opened, but the driver's keys didn't move in it") }
                    done(picked)
                }
            }
        }

        // 4. The green button's own menu (the pointer resting on it), Exit Full Screen in it.
        enter("green button menu")
        reveal("green button menu")
        expectExit("green button menu") { [self] done in
            guard let r = zoomOnScreen() else {
                check(false, "\(label) green button menu: the green button is on screen (\(lightsState()))")
                return done(false)
            }
            let at = quartz(NSPoint(x: r.midX, y: r.midY))
            let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
            var opened: NSMenu?
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                if let m = n.object as? NSMenu, m !== NSApp.mainMenu { opened = m }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                var trace: [String] = []
                let (ok, out) = driverSync(["--hover"] + at + ["--dwell", "1800", "--steps", "4", "--duration", "60", "--pid", String(pid)])
                trace.append("hover \(ok ? "sent" : "refused \(out.prefix(80))")")
                for _ in 0..<20 where opened == nil { Thread.sleep(forTimeInterval: 0.1) }
                var picked = false, found = false
                if let menu = opened {
                    func all(_ m: NSMenu) -> [NSMenuItem] { m.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
                    trace.append("menu: " + (onMain { all(menu).filter { !$0.isSeparatorItem }.map { $0.title.isEmpty ? "(\($0.view.map { "\(type(of: $0))" } ?? "untitled"))" : $0.title }.joined(separator: " / ") } ?? "?"))
                    if let item = onMain({ menu.items.first(where: { $0.title.contains("Exit Full Screen") && !$0.isHidden && $0.isEnabled }) }) ?? nil {
                        found = true
                        picked = pick(item, in: menu, &trace)
                    } else { _ = driverSync(["--key", "esc"]) }
                } else {
                    // Not an NSMenu: look for its button in our own accessibility tree.
                    let news = onMain { NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }.map { "\(type(of: $0)) \(NSStringFromRect($0.frame))" } } ?? []
                    trace.append("no menu tracked; new windows: \(news.isEmpty ? "none" : news.joined(separator: ", "))")
                    if let pt = Self.fullscreenExitAXElement(titled: "Exit Full Screen") {
                        found = true
                        let (ok, out) = driverSync(["--click", String(Double(pt.x)), String(Double(pt.y))])
                        trace.append("AX Exit Full Screen at \(Int(pt.x)),\(Int(pt.y)): click \(ok ? "sent" : "refused \(out.prefix(80))")")
                        picked = ok
                    }
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.removeObserver(token)
                    self.note("\(label) green button menu: " + trace.joined(separator: "; "))
                    if !found { self.skip("\(label) green button menu: no menu with Exit Full Screen came up under a resting pointer") }
                    else if !picked { self.skip("\(label) green button menu: Exit Full Screen found but the driver couldn't pick it") }
                    done(picked)
                }
            }
        }

        run { [self] in if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) } }
        wait(1.5)
        // Leave the real pointer on the page, away from the top edge: a pointer left there brings the next run's
        // full-screen titlebar down (and enables its green button).
        step { [self] done in
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3, then: done)
        }
        pointer("parked on the page", middle)
    }

    /// The centre (Quartz global) of an element titled `title` in this app's own accessibility tree, below its windows.
    static func fullscreenExitAXElement(titled title: String) -> CGPoint? {
        let app = AXUIElementCreateApplication(getpid())
        func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        func search(_ e: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 12 { return nil }
            for a in [kAXTitleAttribute, kAXDescriptionAttribute] where (attr(e, a) as? String) == title { return e }
            for kid in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if let hit = search(kid, depth: depth + 1) { return hit }
            }
            return nil
        }
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard let hit = search(w, depth: 0), let pos = attr(hit, kAXPositionAttribute), let size = attr(hit, kAXSizeAttribute) else { continue }
            var p = CGPoint.zero, s = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &s)
            if s.width > 0 { return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2) }
        }
        return nil
    }
}
#endif
