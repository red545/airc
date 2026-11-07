// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AircDesign
import AppKit
import AircKit
import WebKit

/// `--script fullscreen-exit` (owner P0, 2026-11-06: Airc quit right after leaving full screen). One case per launch
/// (`AIRC_FULLSCREEN_CASE`), under 50 s, with no screenshots, HID input or media devices. A real native full screen
/// takes the display over (it is a Space of its own), so it runs only after three minutes without the owner's keyboard
/// or mouse, stops as soon as they come back, and needs the app active (the investigator activates its scratch app).
///
/// The crash (fsexit, reproduced under LLDB): while AppKit left full screen, the windowed traffic-light layout
/// (WindowController.positionTrafficLights) resized the titlebar container AppKit was still tiling in its full-screen
/// titlebar window. `-[NSThemeFrame _updateTitlebarContainerViewFrameIfNecessary]` and `_syncToolbarPosition` then
/// called each other, once per move, until the main thread's stack overflowed (SIGSEGV, about 150 000 frames, too big
/// for macOS's crash reporter). It happens only in a real full screen, so here it shows as a run with no log; the
/// titlebar move count below shows a fight that a guard cut short.
///
/// Cases:
/// - `native`: five cycles, each left another way (Esc twice, View → Exit Full Screen, the green button,
///   `toggleFullScreen`, FullScreenController.exit); `native-rapid`: leave while entering, enter while leaving;
/// - `native-esc`: one Esc in full screen stays (Arc); with the focus in a Chromium page, on the window, in a
///   Safari's-engine page;
/// - `native-video`, `native-split`, `native-webkit` (a Safari's-engine page), `native-switch` (tab and Space switches
///   in full screen, then leave with the video in picture in picture);
/// - `little-over-native`: a Little Arc window over the browser's full screen (it joins the active Space, as for the
///   owner), then leave;
/// - HTML5 full screen, left by the API, Esc and the page's button: `html`, `split`, `little`, `pip` (then picture in
///   picture), `switch` (left by a tab or Space switch); `webkit` and `webkit-switch` on a Safari's-engine page.
extension SnapshotRunner {
    /// Scratch identities that may activate themselves for a real full screen (scripts/tests/fullscreen-investigate.py).
    /// Never the owner's (`org.airc.Airc*`).
    static let fullscreenInvestigatorIDs = ["org.airc.fscrash", "org.airc.fsexit"]

    func fullscreenExitCheck() {
        let activate = ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_ACTIVATE"] == "1"
        if activate {
            // Explicit opt-in for the overnight investigator, never the ship suite or owner's bundle.
            let id = Bundle.main.bundleIdentifier ?? ""
            guard Self.fullscreenInvestigatorIDs.contains(where: { id.hasPrefix($0) }),
                  !Self.screenLocked, FullscreenAttemptSafety.idle >= 180 else {
                skip("fullscreen investigator: activation denied by identity/idle/lock gate")
                return
            }
            step { [self] done in
                guard !Self.screenLocked, FullscreenAttemptSafety.idle >= 180 else { return done() }
                c.window.collectionBehavior.insert(.moveToActiveSpace)
                NSApp.activate(ignoringOtherApps: true)
                c.window.makeKeyAndOrderFront(nil)
                waitUntil({ self.c.window.isOnActiveSpace && self.c.window.isKeyWindow }, timeout: 3, then: done)
            }
        }
        step { [self] done in
            enqueueFullscreenExitChecks()
            done()
        }
    }

    private func enqueueFullscreenExitChecks() {
        let mode = ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_CASE"] ?? "native"
        func permitted() -> Bool {
            if let reason = inputBlocked { skip("fullscreen exit: \(reason)"); return false }
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            guard idle >= 180 else { skip("fullscreen exit: owner idle only \(Int(idle)) s (needs 180)"); return false }
            return true
        }
        // Exercise the exit-phase contract even in daytime suites, without entering a native Space.
        if mode == "native" {
            c.fullScreen.willEnter()
            c.fullScreen.willExit()
            check(c.isFullscreen, "native exit phase: keep fullscreen traffic-light layout until didExit")
            c.fullScreen.didExit()
            check(!c.isFullscreen, "native exit phase: restore windowed state after didExit")
            // AppKit gave up entering (another transition, an app that isn't active): the window stays windowed.
            c.fullScreen.willEnter()
            (c as NSWindowDelegate).windowDidFailToEnterFullScreen?(c.window)
            let (atArc, centers) = trafficLightsAtArc()
            check(!c.isFullscreen && atArc, "native failed enter: the windowed layout comes back (traffic lights \(centers))")
            if c.isFullscreen { c.fullScreen.didExit() }
            titlebarStackGuardCheck()
        }
        guard permitted() else { return }
        // The external debugger runner watches HID even while SIGSTOP suspends our main thread.
        if ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_DEBUG_PAUSE"] == "1" {
            try? String(ProcessInfo.processInfo.processIdentifier).write(to: dir.appendingPathComponent("debug-ready"), atomically: true, encoding: .utf8)
            raise(SIGSTOP)
        }
        guard permitted() else { return }
        let safety = FullscreenAttemptSafety { [weak self] in
            self?.note("SKIP fullscreen attempt aborted: hardware activity or screen locked")
            for window in NSApp.windows {
                window.orderOut(nil)
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
            self?.finish()
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) }
            note("FAIL fullscreen exit: exceeded the 44 s attempt budget")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish() }
        }
        // The runner gives a launch 53 s; this leaves time to write the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 44, execute: deadline)
        switch mode {
        case "native": fullscreenNativeCycles(permitted: permitted)
        case "native-rapid": fullscreenRapidToggles(permitted: permitted)
        default:
            #if canImport(AircCore)
            fullscreenPageChecks(mode: mode, permitted: permitted)
            #else
            skip("fullscreen exit \(mode): needs the Chromium build (DevTools user gestures, Safari's-engine pages)")
            #endif
        }
        run { [self] in
            deadline.cancel()
            safety.stop()
            // Never leave the display in full screen, whatever failed above.
            if c.window.styleMask.contains(.fullScreen) { c.window.toggleFullScreen(nil) }
        }
        wait(0.3)
    }

    /// The last guard (WindowController.trafficLightsMoved): a titlebar move reported from deep in the stack, as in
    /// AppKit's fight with the layout, isn't answered there, and the next turn puts the traffic lights back. No full
    /// screen needed: the move is posted from a stack 3 MB deep.
    private func titlebarStackGuardCheck() {
        guard let container = c.window.standardWindowButton(.closeButton)?.superview?.superview,
              !c.window.styleMask.contains(.fullScreen) else { return }
        var placed = NSRect.zero
        run { [self] in
            c.positionTrafficLights()
            placed = container.frame
            var moved = placed
            moved.origin.y -= 7
            moved.size.height += 7
            // Moved quietly, then reported from deep down: turning the notifications back on posts the move.
            container.postsFrameChangedNotifications = false
            container.frame = moved
            var depth = 0
            var there = NSRect.zero
            Self.onDeepStack(3 << 20) {
                depth = Self.stackInUse
                container.postsFrameChangedNotifications = true
                there = container.frame
            }
            check(there == moved, "titlebar guard: a move reported \(depth >> 10) KB deep in the stack (of "
                  + "\(pthread_get_stacksize_np(pthread_self()) >> 10) KB) isn't answered there (\(there == moved ? "left" : "put back"))")
        }
        wait(0.3)
        run { [self] in check(container.frame == placed, "titlebar guard: the next turn puts the traffic lights back (\(container.frame == placed))") }
    }

    /// How much of this thread's stack is in use (it grows down from its top).
    static var stackInUse: Int {
        var here = 0
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        return withUnsafeMutablePointer(to: &here) { Int(bitPattern: top &- UInt(bitPattern: $0)) }
    }

    /// Runs `body` with at least `bytes` of the stack in use.
    @inline(never) static func onDeepStack(_ bytes: Int, _ body: () -> Void) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1000) { pad in
            pad.initialize(repeating: 1)
            if stackInUse < bytes { onDeepStack(bytes, body) } else { body() }
            precondition(pad[999] == 1)
        }
    }

    /// AppKit enters a native full screen only for the active app (it answers willEnter, then didFailToEnter). The ship
    /// suite never activates its runs, so there this skips; the investigator activates its scratch app.
    private func appIsActive(_ what: String) -> Bool {
        if NSApp.isActive { return true }
        skip("\(what): the app isn't active (AppKit enters full screen only for the active app)")
        return false
    }

    /// The ways out of a native full screen. Each reaches AppKit's exit transition by another path.
    enum FullscreenExitWay: String, CaseIterable {
        case escape = "Esc pressed twice"
        case menu = "View menu"
        case button = "green button"
        case toggle = "toggleFullScreen"
        case controller = "FullScreenController.exit"
    }

    /// Leaves native full screen `way`. Keys go through the app's own event queue (no HID).
    private func leaveFullScreen(_ way: FullscreenExitWay) {
        let w = c.window
        switch way {
        case .escape:
            for delay in [0, 0.12] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Self.postEscape(to: w) }
            }
        case .menu:
            // On macOS 26 AppKit's own copy of the item comes first; both go to the window (FullScreenMenu).
            let view = NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu
            if let view, let item = view.items.first(where: { $0.action == FullScreenMenu.action }) {
                FullScreenMenu.shared.menuNeedsUpdate(view)
                // The item has no target: it goes to the key window, which a run that wasn't activated has none of.
                let sent = NSApp.sendAction(FullScreenMenu.action, to: item.target, from: item)
                note("fullscreen exit: View → \(item.title)" + (sent ? "" : " found no key window; toggling the window"))
                if !sent { w.toggleFullScreen(nil) }
            } else {
                note("fullscreen exit: no View menu item; toggling the window")
                w.toggleFullScreen(nil)
            }
        case .button:
            if let zoom = w.standardWindowButton(.zoomButton) { zoom.performClick(nil) } else { w.toggleFullScreen(nil) }
        case .toggle: w.toggleFullScreen(nil)
        case .controller: c.fullScreen.exit()
        }
    }

    static func postEscape(to w: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "\u{1b}",
                                        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.postEvent(e, atStart: false)
            }
        }
    }

    /// The traffic lights are at Arc's centres in the browser window itself (not AppKit's full-screen titlebar window).
    private func trafficLightsAtArc() -> (Bool, String) {
        let w = c.window
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { w.standardWindowButton($0) }
        let centers = buttons.map { b -> CGPoint in
            let r = b.convert(b.bounds, to: nil)
            return CGPoint(x: r.midX, y: w.frame.height - r.midY)
        }
        let ok = centers.count == 3 && buttons.allSatisfy { $0.window === w }
            && zip(centers, AircMetrics.Window.trafficLightCenters).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
        return (ok, centers.map { "(\(Int($0.x.rounded())),\(Int($0.y.rounded())))" }.joined(separator: " "))
    }

    /// Native full-screen cycles, one per `ways` entry. `inFullScreen` runs while the window is in full screen, before
    /// it is left (cycle number, done).
    private func fullscreenNativeCycles(_ tag: String = "native", ways: [FullscreenExitWay] = FullscreenExitWay.allCases,
                                        permitted: @escaping () -> Bool,
                                        inFullScreen: ((Int, @escaping () -> Void) -> Void)? = nil) {
        for (i, way) in ways.enumerated() {
            let name = "\(tag) fullscreen cycle \(i + 1) (\(way.rawValue))"
            var entered = false
            var moves = 0
            var observer: NSObjectProtocol?
            var transitions: [NSObjectProtocol] = []
            var seen: [String] = []
            var before = ""
            run { [self] in
                guard permitted(), appIsActive(name) else { return }
                entered = true
                // What AppKit said, for a failed enter: the notifications seen, and the window's state before it.
                let w = c.window
                for (n, tag) in [(NSWindow.willEnterFullScreenNotification, "willEnter"), (NSWindow.didEnterFullScreenNotification, "didEnter"),
                                 (NSWindow.willExitFullScreenNotification, "willExit"), (NSWindow.didExitFullScreenNotification, "didExit")] {
                    transitions.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: nil) { _ in seen.append(tag) })
                }
                before = "app active \(NSApp.isActive), key \(w.isKeyWindow), on the active Space \(w.isOnActiveSpace), "
                    + "visible \(w.occlusionState.contains(.visible)), primary \(w.collectionBehavior.contains(.fullScreenPrimary))"
                w.toggleFullScreen(nil)
            }
            step { [self] done in
                guard entered else { return done() }
                waitUntil({ self.c.window.styleMask.contains(.fullScreen) && self.c.isFullscreen }, timeout: 6, then: done)
            }
            wait(1)
            if let inFullScreen {
                step { done in entered ? inFullScreen(i + 1, done) : done() }
            }
            run { [self] in
                guard entered else { return }
                let inFull = c.isFullscreen && c.window.styleMask.contains(.fullScreen)
                check(inFull, "\(name): entered" + (inFull ? "" : " (AppKit: \(seen.isEmpty ? "nothing" : seen.joined(separator: " ")); \(before))"))
                seen = []
                // Every move of the titlebar container while leaving, AppKit's and ours. The crash was a fight over it
                // that never ended; a few dozen moves mean a guard had to cut one short.
                if let container = c.window.standardWindowButton(.closeButton)?.superview?.superview {
                    container.postsFrameChangedNotifications = true
                    observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container,
                                                                      queue: nil) { _ in moves += 1 }
                }
                leaveFullScreen(way)
            }
            step { [self] done in
                guard entered else { return done() }
                waitUntil({ !self.c.isFullscreen && !self.c.window.styleMask.contains(.fullScreen) }, timeout: 6, then: done)
            }
            wait(0.8)
            run { [self] in
                observer.map(NotificationCenter.default.removeObserver)
                transitions.forEach(NotificationCenter.default.removeObserver)
                guard entered else { return }
                if !seen.isEmpty, seen != ["willExit", "didExit"] { note("\(name): AppKit while leaving: \(seen.joined(separator: " "))") }
                let w = c.window
                check(!c.isFullscreen && !w.styleMask.contains(.fullScreen), "\(name): exited and still alive")
                check(!w.titlebarAccessoryViewControllers.contains { $0 is FullScreenRevealAccessory },
                      "\(name): accessory removed after transition")
                check(moves < 40, "\(name): the titlebar moved \(moves) times while leaving (no fight with AppKit)")
                let (atArc, centers) = trafficLightsAtArc()
                check(atArc, "\(name): traffic lights back at Arc's centres \(centers)")
            }
            // The next cycle starts windowed, whatever failed.
            step { [self] done in
                guard c.window.styleMask.contains(.fullScreen) else { return done() }
                c.window.toggleFullScreen(nil)
                waitUntil({ !self.c.window.styleMask.contains(.fullScreen) }, timeout: 6, then: done)
            }
        }
    }

    /// A double ⌃⌘F, or Esc Esc then ⌃⌘F: requests that land in the middle of AppKit's transitions.
    private func fullscreenRapidToggles(permitted: @escaping () -> Bool) {
        let w = { self.c.window }
        let settled = { self.c.isFullscreen == w().styleMask.contains(.fullScreen) }
        var go = false
        func settle(_ name: String) {
            wait(1.5)
            step { [self] done in waitUntil(settled, timeout: 6, then: done) }
            wait(1)
            run { [self] in
                guard go else { return }
                check(settled(), "native-rapid \(name): settled with the window and the layout agreeing "
                      + "(window \(w().styleMask.contains(.fullScreen) ? "full screen" : "windowed"), layout \(c.isFullscreen ? "full screen" : "windowed"))")
            }
            step { [self] done in
                guard w().styleMask.contains(.fullScreen) else { return done() }
                w().toggleFullScreen(nil)
                waitUntil({ !w().styleMask.contains(.fullScreen) && !self.c.isFullscreen }, timeout: 6, then: done)
            }
            wait(0.8)
            run { [self] in
                guard go else { return }
                let (atArc, centers) = trafficLightsAtArc()
                check(!w().styleMask.contains(.fullScreen) && !c.isFullscreen && atArc,
                      "native-rapid \(name): windowed and alive afterwards, traffic lights \(centers)")
            }
        }
        // 1. Leave while still entering.
        run { go = permitted() && self.appIsActive("native-rapid"); if go { w().toggleFullScreen(nil) } }
        wait(0.15)
        run { if go { w().toggleFullScreen(nil) } }
        settle("leave while entering")
        // 2. Enter again while still leaving.
        run { go = permitted() && self.appIsActive("native-rapid"); if go { w().toggleFullScreen(nil) } }
        step { [self] done in waitUntil({ !go || (w().styleMask.contains(.fullScreen) && self.c.isFullscreen) }, timeout: 6, then: done) }
        wait(1)
        run { [self] in if go { c.fullScreen.exit() } }
        wait(0.15)
        run { if go { w().toggleFullScreen(nil) } }
        settle("enter while leaving")
        // 3. Leave twice at once: Esc Esc, ⌃⌘F and the controller's exit together. Only the first counts.
        run { go = permitted() && self.appIsActive("native-rapid"); if go { w().toggleFullScreen(nil) } }
        step { [self] done in waitUntil({ !go || (w().styleMask.contains(.fullScreen) && self.c.isFullscreen) }, timeout: 6, then: done) }
        wait(1)
        run { [self] in
            guard go else { return }
            c.fullScreen.exit()
            c.fullScreen.exit()
            Self.postEscape(to: w())
            Self.postEscape(to: w())
        }
        settle("several exits at once")
    }

    #if canImport(AircCore)
    /// The cases with a loopback page: a muted synthetic video (canvas stream, no device) and a box with an Exit button.
    private func fullscreenPageChecks(mode: String, permitted: @escaping () -> Bool) {
        guard let engine = app?.engine as? ChromiumEngine else { skip("fullscreen exit \(mode): Chromium unavailable"); return }
        let webKit = mode.hasPrefix("webkit") || mode == "native-webkit"
        var server: LocalPageServer?
        var page: EngineTab?
        var little: LittleArcController?
        var entered = false
        app?.settings.values.pipAutomatic = true
        var originalTab = ""
        let originalSpace = c.currentSpaceID
        var otherSpace = ""
        var otherTab = ""
        let littleJoined = LittleArcController.joinsActiveSpace
        let html = """
        <title>Fullscreen fixture</title><div id="box"><button id="leave" onclick="document.exitFullscreen()">Exit</button></div>
        <canvas id="canvas" width="160" height="90"></canvas><video id="video" muted playsinline></video>
        <script>
        const ctx=canvas.getContext('2d');let n=0;
        setInterval(()=>{ctx.fillStyle=`hsl(${n++%360},70%,50%)`;ctx.fillRect(0,0,160,90)},40);
        video.srcObject=canvas.captureStream(25);
        addEventListener('keydown',e=>{if(e.key==='Escape')window.__esc=(window.__esc||0)+1});
        </script>
        """
        if webKit || mode == "native-esc" { ProtectedMedia.shared.testHosts = ["localhost"] }
        step { [self] done in
            server = LocalPageServer(responses: ["/fullscreen": .init(body: html)])
            server?.start { port in
                guard let port else { self.check(false, "fullscreen: loopback fixture starts"); return done() }
                // "localhost" plays a listed service (Safari's engine); 127.0.0.1 is the same server as Chromium's site.
                let url = "http://\(webKit ? "localhost" : "127.0.0.1"):\(port)/fullscreen"
                if mode == "little" {
                    // As in the owner's build: Little Arc joins the active Space and may sit over full screen.
                    LittleArcController.joinsActiveSpace = true
                    little = self.app?.openLittleArc(url: URL(string: url), spaceID: self.c.currentSpaceID)
                    page = little?.page
                    if ProcessInfo.processInfo.environment["AIRC_FULLSCREEN_ACTIVATE"] == "1" {
                        little?.window.makeKeyAndOrderFront(nil)
                    }
                } else if let tab = try? self.c.store.openTab(url: url, inSpace: self.c.currentSpaceID, activate: false) {
                    if mode == "split" || mode == "native-split",
                       let second = try? self.c.store.openTab(url: url, inSpace: self.c.currentSpaceID, activate: false) {
                        _ = try? self.c.store.createSplit([tab.id, second.id], inSpace: self.c.currentSpaceID, focused: tab.id)
                    }
                    originalTab = tab.id
                    if mode == "switch" || mode == "native-switch" || mode == "webkit-switch" {
                        otherTab = (try? self.c.store.openTab(url: "about:blank", inSpace: originalSpace, activate: false))?.id ?? ""
                        otherSpace = (try? self.c.store.createSpace(name: "Fullscreen other", icon: nil, theme: self.c.store.selectedSpace.theme,
                            profileID: self.c.store.defaultProfile.id, after: originalSpace))?.id ?? ""
                        // A Space with a tab, as people have them. (Switching to an empty Space activates no tab, and a
                        // page in HTML5 full screen stays so, hidden, until it is shown again: fsexit's report.)
                        if !otherSpace.isEmpty { _ = try? self.c.store.openTab(url: "about:blank", inSpace: otherSpace, activate: true) }
                    }
                    self.c.reloadAll(animated: false)
                    self.c.show(tab.id, focus: true)
                    page = self.c.engineTab(for: tab.id)
                }
                self.waitUntil({ page?.title == "Fullscreen fixture" && page?.isLoading == false }, timeout: 6) {
                    if webKit {
                        self.check(ProtectedMedia.isWebKitPage(page), "fullscreen \(mode): the fixture is a Safari's-engine page")
                    }
                    done()
                }
            }
        }
        /// A script's Bool result. Chromium: DevTools with a user gesture, promises awaited. WebKit: evaluateJavaScript
        /// (WebKit counts it as a user gesture), no promises: pass a synchronous expression.
        func evaluate(_ expression: String, on target: EngineTab? = nil, _ completion: @escaping (Bool) -> Void) {
            guard let p = target ?? page else { return completion(false) }
            if ProtectedMedia.isWebKitPage(p) {
                p.evaluate(expression) { completion(($0 as? Bool) ?? (($0 as? NSNumber)?.boolValue ?? false)) }
                return
            }
            engine.devToolsCall("Runtime.evaluate", params: ["expression": expression, "userGesture": true,
                "awaitPromise": true, "returnByValue": true], in: p) { reply, _ in
                completion((reply?["result"] as? [String: Any])?["value"] as? Bool == true)
            }
        }
        /// Polls `expression` until it is true (or `timeout`), then calls `done` with the last result.
        func poll(_ expression: String, timeout: Double, on target: EngineTab? = nil, _ done: @escaping (Bool) -> Void) {
            let deadline = Date().addingTimeInterval(timeout)
            func again() {
                evaluate(expression, on: target) { ok in
                    if ok || Date() > deadline { return done(ok) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: again)
                }
            }
            again()
        }
        func playVideo(_ tag: String) {
            step { [self] done in
                if ProtectedMedia.isWebKitPage(page) {
                    evaluate("video.play();true") { _ in poll("!video.paused", timeout: 3) { ok in self.check(ok, "\(tag): muted synthetic video playing"); done() } }
                } else {
                    evaluate("video.play().then(()=>!video.paused)") { ok in self.check(ok, "\(tag): muted synthetic video playing"); done() }
                }
            }
        }
        func pictureInPicture(_ p: EngineTab?) -> Bool { p.flatMap { PiPEngineOverlay.state($0, in: engine) } != nil }
        func cleanUp() {
            run { [self] in
                if let little { little.window.performClose(nil) }
                if let page { engine.closePictureInPicture(page) }
                LittleArcController.joinsActiveSpace = littleJoined
                server?.stop()
            }
        }

        switch mode {
        case "native-video", "native-split", "native-webkit":
            playVideo("\(mode)")
            fullscreenNativeCycles(mode, ways: [.escape, .menu, .controller], permitted: permitted)
            cleanUp()
            return
        case "native-switch":
            // In full screen: another tab, another Space and back. Automatic picture in picture needs audible
            // playback (Chrome), which a muted test video isn't, so cycle 2 opens it itself and leaves full screen
            // with the picture in picture still open.
            playVideo(mode)
            fullscreenNativeCycles(mode, ways: [.menu, .escape], permitted: permitted) { [self] cycle, done in
                let pip: (@escaping () -> Void) -> Void = { next in
                    guard cycle == 2 else { return next() }
                    evaluate("video.requestPictureInPicture().then(()=>document.pictureInPictureElement===video)") { ok in
                        self.check(ok, "native-switch cycle 2: the video in picture in picture, in full screen")
                        next()
                    }
                }
                pip { [self] in
                    c.show(otherTab, focus: false)
                    waitUntil({ pictureInPicture(page) }, timeout: 2.5) { [self] in
                        note("native-switch cycle \(cycle): another tab in full screen, picture in picture \(pictureInPicture(page) ? "open" : "not open")")
                        c.switchToSpace(otherSpace, animated: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                            c.switchToSpace(originalSpace, animated: false)
                            if cycle == 1 { c.show(originalTab, focus: false) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                                check(c.isFullscreen, "native-switch cycle \(cycle): still in full screen after the tab and Space switches")
                                done()
                            }
                        }
                    }
                }
            }
            run { [self] in
                c.show(originalTab, focus: false)
                note("native-switch: back on the video tab, picture in picture \(pictureInPicture(page) ? "open" : "closed")")
            }
            wait(0.6)
            cleanUp()
            return
        case "native-esc":
            // Arc (arc_behavior_spec "Full screen"): one Esc goes to the page; only Esc twice or held leaves. One Esc
            // with the focus in a Chromium page, on no page (the window itself), and in a Safari's-engine page.
            var webTab = ""
            run { [self] in
                let url = (page?.url?.absoluteString ?? "").replacingOccurrences(of: "127.0.0.1", with: "localhost")
                webTab = (try? c.store.openTab(url: url, inSpace: c.currentSpaceID, activate: false))?.id ?? ""
                c.reloadAll(animated: false)
            }
            let places = ["a Chromium page", "the window, no page focused", "a Safari's-engine page"]
            fullscreenNativeCycles(mode, ways: [.controller, .controller, .controller], permitted: permitted) { [self] cycle, done in
                c.show(cycle == 3 ? webTab : originalTab, focus: false)
                // The page exists once its tab is shown.
                let target: EngineTab? = cycle == 3 ? c.engineTab(for: webTab) : page
                waitUntil({ target?.title == "Fullscreen fixture" && target?.isLoading == false }, timeout: 6) { [self] in
                    if cycle == 2 { c.window.makeFirstResponder(nil) } else { target?.focus() }
                    let responder = c.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                    evaluate("(window.__esc=0,true)", on: target) { _ in
                        let before = self.c.fullScreen.exitRequests
                        Self.postEscape(to: self.c.window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            evaluate("window.__esc===1", on: target) { seen in
                                let stayed = self.c.window.styleMask.contains(.fullScreen) && self.c.isFullscreen
                                self.check(stayed, "native-esc (\(places[cycle - 1])): one Esc stays in full screen (the page saw it \(seen), "
                                           + "exit requests \(self.c.fullScreen.exitRequests - before), first responder \(responder), "
                                           + "WebKit page \(ProtectedMedia.isWebKitPage(target)))")
                                guard !stayed else { return done() }
                                // One Esc left: back into full screen for the cycle's own exit.
                                self.waitUntil({ !self.c.isFullscreen && !self.c.window.styleMask.contains(.fullScreen) }, timeout: 6) {
                                    self.c.window.toggleFullScreen(nil)
                                    self.waitUntil({ self.c.window.styleMask.contains(.fullScreen) && self.c.isFullscreen }, timeout: 6) {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: done)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            cleanUp()
            return
        case "little-over-native":
            // The owner's Little Arc joins the active Space (also a full screen's) as an auxiliary window.
            fullscreenNativeCycles(mode, ways: [.menu, .controller], permitted: permitted) { [self] cycle, done in
                LittleArcController.joinsActiveSpace = true
                little = app?.openLittleArc(url: page?.url, spaceID: c.currentSpaceID)
                little?.window.makeKeyAndOrderFront(nil)
                let lp = little?.page
                waitUntil({ lp?.title == "Fullscreen fixture" && lp?.isLoading == false }, timeout: 6) {
                    let aux = little?.window.collectionBehavior.contains(.fullScreenAuxiliary) == true
                    self.note("little-over-native cycle \(cycle): Little Arc open, auxiliary \(aux), on the active Space \(little?.window.isOnActiveSpace == true)")
                    evaluate("(async()=>{await box.requestFullscreen();const a=document.fullscreenElement===box;await document.exitFullscreen();return a})()", on: lp) { ok in
                        self.check(ok, "little-over-native cycle \(cycle): HTML5 full screen in Little Arc over the browser's")
                        // Cycle 1 closes Little Arc before leaving; cycle 2 leaves with it open.
                        if cycle == 1 { little?.window.performClose(nil); little = nil }
                        self.c.window.makeKeyAndOrderFront(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                    }
                }
            }
            cleanUp()
            return
        default: break
        }

        let webKitFullscreen = { (page as? WebKitTab)?.webView.fullscreenState }
        var escapeTo = ""
        let exits = mode == "switch" || mode == "webkit-switch" ? ["tab", "space"] : ["api", "escape", "button"]
        for target in ["box", "video"] {
            for exit in exits {
                let name = "HTML5 \(mode)/\(target)/\(exit)"
                step { [self] done in
                    guard permitted() else { entered = false; return done() }
                    if ProtectedMedia.isWebKitPage(page) {
                        evaluate("video.play();window.__fs='asked';\(target).requestFullscreen().then(()=>{__fs='in'},e=>{__fs='refused: '+e.message});true") { _ in
                            poll("document.fullscreenElement===\(target)", timeout: 4) { ok in
                                entered = ok
                                page?.evaluate("window.__fs") { state in
                                    self.check(ok, "\(name): entered (\(state ?? "-"), WebKit full screen \(String(describing: webKitFullscreen().map { $0.rawValue })))")
                                    // WebKit's own window animates in; leave it once it is there.
                                    self.waitUntil({ webKitFullscreen() == .inFullscreen }, timeout: 3) { done() }
                                }
                            }
                        }
                    } else {
                        evaluate("(async()=>{await video.play();await \(target).requestFullscreen();return document.fullscreenElement===\(target)})()") { ok in
                            entered = ok
                            self.check(ok, "\(name): entered")
                            done()
                        }
                    }
                }
                wait(0.4)
                step { [self] done in
                    guard entered, let page else { return done() }
                    switch exit {
                    case "tab":
                        c.show(otherTab, focus: false)
                        done()
                    case "space":
                        c.switchToSpace(otherSpace, animated: false)
                        done()
                    case "escape":
                        // Chromium: DevTools Input would go straight to the renderer, past the browser's exclusive-access
                        // Esc handler, so Esc goes through the app's event loop (no HID). WebKit: to its full-screen window.
                        guard let window = ProtectedMedia.isWebKitPage(page) ? (NSApp.keyWindow ?? page.view.window) : page.view.window else {
                            self.check(false, "\(name): page has no window")
                            return done()
                        }
                        if !ProtectedMedia.isWebKitPage(page) { page.focus() }
                        // AppKit gives a key to the key window, as a real Esc pressed in this page is. A run that isn't
                        // active has none, and a posted key doesn't reach a page whose window isn't key, whatever window
                        // it names (Little Arc's page never saw it in the ship gate). So that window gets it itself then,
                        // as AppKit delivers it once the window is key.
                        let viaApp = NSApp.keyWindow === window
                        escapeTo = viaApp ? "the app (key window)" : "its window (key window: \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"))"
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: false, keyCode: 53) {
                                if viaApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
                            }
                        }
                        done()
                    default:
                        let js = exit == "button" ? "(leave.click(),true)"
                            : ProtectedMedia.isWebKitPage(page) ? "(document.exitFullscreen(),true)" : "document.exitFullscreen().then(()=>true)"
                        evaluate(js) { _ in done() }
                    }
                }
                wait(0.4)
                step { [self] done in
                    guard entered else { return done() }
                    func finished(_ ok: Bool) {
                        let home = page?.view.window === (little?.window ?? c.window)
                        let fs = webKitFullscreen().map { " WebKit full screen \($0.rawValue)," } ?? ""
                        check(ok && (home || exit == "tab" || exit == "space"),
                              "\(name): exited, video still playing, browser alive (\(fs) page in its window \(home))")
                        if !ok, let page {
                            page.evaluate("JSON.stringify({fullscreen:!!document.fullscreenElement,paused:video.paused,pip:!!document.pictureInPictureElement,hidden:document.hidden,escSeen:window.__esc|0})") { v in
                                self.note("fullscreen exit state: \(v ?? "unavailable")" + (exit == "escape" ? ", Esc sent through \(escapeTo)" : ""))
                            }
                        }
                        // Cleanup even on failed exit; the next request must start windowed.
                        let leave = ProtectedMedia.isWebKitPage(page) ? "(document.fullscreenElement&&document.exitFullscreen(),true)"
                            : "(async()=>{if(document.fullscreenElement)await document.exitFullscreen();return true})()"
                        evaluate(leave) { _ in
                            if exit == "tab" || exit == "space" {
                                self.c.switchToSpace(originalSpace, animated: false)
                                self.c.show(originalTab, focus: false)
                            }
                            guard mode == "pip" else {
                                return self.waitUntil({ webKitFullscreen().map { $0 == .notInFullscreen } ?? true }, timeout: 4) {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                                }
                            }
                            evaluate("video.requestPictureInPicture().then(()=>document.pictureInPictureElement===video)") { pip in
                                self.check(pip, "HTML5 exit to explicit PiP: video entered picture in picture")
                                evaluate("(async()=>{if(document.pictureInPictureElement)await document.exitPictureInPicture();return !document.pictureInPictureElement})()") { exited in
                                    self.check(exited, "HTML5 exit to explicit PiP: closed without crashing")
                                    done()
                                }
                            }
                        }
                    }
                    if ProtectedMedia.isWebKitPage(page) {
                        poll("!document.fullscreenElement && !video.paused", timeout: 4) { ok in
                            self.waitUntil({ webKitFullscreen() == .notInFullscreen }, timeout: 4) { finished(ok) }
                        }
                    } else {
                        evaluate("!document.fullscreenElement && !video.paused", finished)
                    }
                }
            }
        }
        cleanUp()
    }
    #endif
}

/// Main-loop guard; the external lldb harness independently enforces the same gate during debugger stops.
private final class FullscreenAttemptSafety {
    static var idle: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
    private var previous = FullscreenAttemptSafety.idle
    private var timer: Timer?
    init(abort: @escaping () -> Void) {
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Self.idle
            if SnapshotRunner.screenLocked || now < 180 || now + 0.1 < previous {
                stop()
                abort()
            } else { previous = now }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { stop() }
}
#endif
