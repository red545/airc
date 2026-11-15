// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import ApplicationServices
import AircKit

/// A real WindowServer second display, supplied by infra/w10 (never created by the app).
/// write/read/fallback are separate launches against the same synthetic data directory.
extension SnapshotRunner {
    func parityW10Scenario() {
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: dir.appendingPathComponent("pid.txt"), atomically: true, encoding: .utf8)
        let source = c!
        func displayID(_ screen: NSScreen?) -> UInt32 {
            (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        }
        let targetID = UInt32(ProcessInfo.processInfo.environment["AIRC_W10_DISPLAY_ID"] ?? "") ?? 0
        let target = NSScreen.screens.first { displayID($0) == targetID }
        if script == "parityw10-fallback" {
            run { [self] in
                check(target == nil, "w10 fallback: virtual display absent")
                check(!(app?.controllers.isEmpty ?? true), "w10 fallback: session restored")
                for w in app?.controllers ?? [] {
                    check(displayID(w.window.screen) == CGMainDisplayID(), "w10 fallback: window on main display; frame=\(w.window.frame)")
                }
            }
            if let main = NSScreen.screens.first(where: { displayID($0) == CGMainDisplayID() }) {
                parityW10PiP(on: main, source: source, fallback: true)
            }
            return
        }
        guard let target else { note("FAIL-ENV w10: virtual display \(targetID) absent"); return }
        note("w10: target=\(targetID) frame=\(target.frame) visible=\(target.visibleFrame)")
        if script == "parityw10-read" {
            run { [self] in
                let windows = app?.controllers ?? []
                check(windows.count >= 2, "w10 relaunch: several windows restored")
                check(windows.contains { displayID($0.window.screen) == targetID }, "w10 relaunch: window restored to second display")
                check(windows.contains { displayID($0.window.screen) == CGMainDisplayID() }, "w10 relaunch: window restored to main display")
            }
            return
        }
        var tab = ""
        var detached: WindowController?
        run { [self] in
            guard let main = NSScreen.screens.first(where: { displayID($0) == CGMainDisplayID() }) else { return }
            source.window.setFrame(NSRect(x: main.visibleFrame.minX + 30, y: main.visibleFrame.minY + 40, width: 800, height: 600), display: true)
            tab = (try? source.store.openTab(url: "data:text/html,<title>W10 synthetic tab</title>", inSpace: source.currentSpaceID))?.id ?? ""
            source.reloadAll(animated: false)
            source.show(tab)
            note("w10 input: pid=\(ProcessInfo.processInfo.processIdentifier), active=\(NSApp.isActive), key=\(source.window.isKeyWindow), space=\(source.window.isOnActiveSpace), locked=\(Self.screenLocked)")
        }
        step { [self] done in
            guard !Self.screenLocked else { return done() }
            waitUntil({ NSApp.isActive && source.window.isKeyWindow }, timeout: 3, then: done)
        }
        wait(1)
        step { [self] done in
            guard !Self.screenLocked, source.window.isOnActiveSpace else {
                note("FAIL-ENV w10 drag: pid=\(ProcessInfo.processInfo.processIdentifier), locked=\(Self.screenLocked), activeSpace=\(source.window.isOnActiveSpace)")
                return done()
            }
            guard let page = source.pageView(for: source.currentSpaceID), let row = todayRow(tab, in: page) else {
                check(false, "w10 drag: synthetic tab has a sidebar row"); return done()
            }
            let start = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let drop = NSPoint(x: target.visibleFrame.midX, y: target.visibleFrame.midY)
            let end = source.window.convertPoint(fromScreen: drop)
            let area = target.visibleFrame
            let size = NSSize(width: min(source.window.frame.width, area.width), height: min(source.window.frame.height, area.height))
            let expected = NSRect(x: min(max(drop.x - start.x, area.minX), area.maxX - size.width),
                                  y: min(max(drop.y - start.y, area.minY), area.maxY - size.height), width: size.width, height: size.height)
            let before = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            // Use WindowServer input when already authorized, without requesting permissions.
            // Otherwise keep AppKit tracking coverage, but leave the real-input gate red.
            let systemInput = CGPreflightPostEventAccess()
            if !systemInput { note("FAIL-ENV w10 real drag: CGPreflightPostEventAccess=false; supplemental AppKit events only") }
            let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
            let originalPointer = NSEvent.mouseLocation
            func systemEvent(_ type: CGEventType, _ point: NSPoint) {
                let global = source.window.convertPoint(toScreen: point)
                CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: CGPoint(x: global.x, y: mainTop - global.y), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: source.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            var tick = 0
            let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                tick += 1
                let f = min(1, CGFloat(tick) / 25)
                let point = NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                if systemInput { systemEvent(tick >= 30 ? .leftMouseUp : .leftMouseDragged, point) }
                else if let e = event(tick >= 30 ? .leftMouseUp : .leftMouseDragged, point) { NSApp.postEvent(e, atStart: false) }
                if tick >= 30 { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            if systemInput { systemEvent(.leftMouseDown, start) }
            else if let e = event(.leftMouseDown, start) { source.window.sendEvent(e) }
            waitUntil({ (self.app?.controllers.count ?? 0) > before.count }, timeout: 4) {
                if systemInput { CGWarpMouseCursorPosition(CGPoint(x: originalPointer.x, y: mainTop - originalPointer.y)) }
                detached = self.app?.controllers.first { !before.contains(ObjectIdentifier($0)) }
                self.check(detached != nil && displayID(detached?.window.screen) == targetID && detached?.window.frame.contains(drop) == true,
                           "w10 drag: native row drag opens on target at drop=\(drop), frame=\(String(describing: detached?.window.frame))")
                if let frame = detached?.window.frame {
                    self.check(abs(frame.minX - expected.minX) <= 1 && abs(frame.minY - expected.minY) <= 1,
                               "w10 drag: preserves grabbed offset, clamped to target; expected=\(expected), actual=\(frame)")
                }
                done()
            }
        }
        step { [self] done in
            guard !NSApp.isActive else { return done() }
            note("w10: activation lost after drag; requesting dedicated-runner preflight before key-window assertions")
            try? "activate".write(to: dir.appendingPathComponent("activation.txt"), atomically: true, encoding: .utf8)
            waitUntil({ NSApp.isActive }, timeout: 5, then: done)
        }
        run { [self] in
            guard let w = detached else { return }
            // Explicitly establish a key window; do not synthesize a delegate callback.
            w.window.makeKey()
            if !NSApp.isActive {
                note("FAIL-ENV w10 key window: activation lost; pid=\(ProcessInfo.processInfo.processIdentifier), active=false, space=\(w.window.isOnActiveSpace), locked=\(Self.screenLocked)")
            } else {
                check(w.window.isKeyWindow, "w10: second-display window becomes key")
            }
            let next = app?.openNewWindow(from: nil, commandBar: false)
            check(displayID(next?.window.screen) == targetID, "w10: new window follows key display")
            let little = app?.openLittleArc(url: nil)
            check(displayID(little?.window.screen) == targetID, "w10: Little Arc follows key display")
            little?.window.close()
            next?.window.close()
        }
        step { [self] done in
            guard let w = detached else { return done() }
            guard NSApp.isActive, w.window.isOnActiveSpace, !Self.screenLocked else {
                note("FAIL-ENV w05: native fullscreen requires active app; active=\(NSApp.isActive), space=\(w.window.isOnActiveSpace), locked=\(Self.screenLocked)"); return done()
            }
            var entered = false
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: w.window, queue: .main) { _ in entered = true }
            w.window.toggleFullScreen(nil)
            waitUntil({ entered }, timeout: 10) {
                NotificationCenter.default.removeObserver(observer)
                if !entered || !w.window.styleMask.contains(.fullScreen) {
                    self.note("FAIL-ENV w05: no completed native entry on virtual display \(targetID); pid=\(ProcessInfo.processInfo.processIdentifier), active=\(NSApp.isActive), key=\(w.window.isKeyWindow), space=\(w.window.isOnActiveSpace)")
                    if w.window.styleMask.contains(.fullScreen) { w.window.toggleFullScreen(nil) }
                    return done()
                }
                self.check(displayID(w.window.screen) == targetID, "w05: native fullscreen on second display")
                // Give the completed native Space one settled frame before leaving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    w.window.toggleFullScreen(nil)
                    self.waitUntil({ !w.window.styleMask.contains(.fullScreen) && !w.isFullscreen }, timeout: 10) {
                        self.check(!w.window.styleMask.contains(.fullScreen) && !w.isFullscreen, "w05: exits native fullscreen")
                        done()
                    }
                }
            }
        }
        parityW10PiP(on: target, source: source)
        run { [self] in app?.saveSession() }
    }
    private func parityW10PiP(on target: NSScreen, source: WindowController, fallback: Bool = false) {
        var video: EngineTab?
        var server: LocalPageServer?
        let html = """
        <!doctype html><title>W10 synthetic video</title><canvas id=c width=640 height=360></canvas><video id=v muted autoplay playsinline></video>
        <script>const ctx=c.getContext('2d');setInterval(()=>{ctx.fillStyle='#487fad';ctx.fillRect(0,0,640,360)},40);v.srcObject=c.captureStream(25);v.play();</script>
        """
        step { [self] done in
            server = LocalPageServer(pages: ["/video": html])
            server?.start { port in
                guard let port, let tab = try? source.store.openTab(url: "http://127.0.0.1:\(port)/video", inSpace: source.currentSpaceID) else {
                    self.check(false, "w10 PiP: fixture starts"); return done()
                }
                source.show(tab.id)
                video = source.engineTab(for: tab.id)
                self.waitUntil({ video?.isLoading == false }, timeout: 8, then: done)
            }
        }
        wait(2)
        step { [self] done in
            guard let video else { check(false, "w10 PiP: no video page"); return done() }
            app?.engine.enterPictureInPictureForHost(video) { route, opened in
                self.note("w10 PiP: entry route=\(route), opened=\(opened)")
                if self.app?.engine is WebKitEngine {
                    self.check(route == "requested" || route == "already", "w10 PiP WebKit: native entry accepted (\(route))")
                }
                done()
            }
        }
        wait(2)
        #if canImport(AircCore)
        var pip: NSWindow?
        var placed = NSRect.zero
        run { [self] in
            guard let chromium = app?.engine as? ChromiumEngine, let video else { return }
            pip = PiPEngineOverlay.state(video, in: chromium)?["window"] as? NSWindow
            guard let pip else { check(false, "w10 PiP: native window exists"); return }
            let area = target.visibleFrame.insetBy(dx: 20, dy: 20)
            if fallback {
                check(pip.screen == target && abs(pip.frame.maxX - area.maxX) < 3 && abs(pip.frame.minY - area.minY) < 3,
                      "w10 PiP: removed display falls back to main bottom-right corner; frame=\(pip.frame)")
            }
            placed = NSRect(x: area.maxX - pip.frame.width, y: area.minY, width: pip.frame.width, height: pip.frame.height)
            pip.setFrame(placed, display: true)
        }
        wait(1)
        run { [self] in
            guard let chromium = app?.engine as? ChromiumEngine, let video else { return }
            check(pip?.screen == target && pip?.frame == placed, "w10 PiP: window moves to second display corner")
            note("w10 PiP: saved after move=\(chromium.pictureInPictureFrame(video.profile))")
            chromium.closePictureInPicture(video)
            note("w10 PiP: saved after close=\(chromium.pictureInPictureFrame(video.profile))")
        }
        wait(1)
        step { [self] done in
            guard let chromium = app?.engine as? ChromiumEngine, let video else { return done() }
            chromium.enterPictureInPictureForHost(video) { _, _ in done() }
        }
        wait(2)
        run { [self] in
            guard let chromium = app?.engine as? ChromiumEngine, let video else { return }
            let restored = PiPEngineOverlay.state(video, in: chromium)?["window"] as? NSWindow
            check(restored?.screen == target && abs((restored?.frame.maxX ?? 0) - placed.maxX) < 3 && abs((restored?.frame.minY ?? 0) - placed.minY) < 3,
                  "w10 PiP: reopen retains display and bottom-right corner; frame=\(String(describing: restored?.frame))")
            chromium.closePictureInPicture(video)
        }
        // Document PiP retains the same display/corner policy but site-requested viewport size.
        var documentCorner = NSPoint.zero
        for (index, size) in [NSSize(width: 640, height: 400), NSSize(width: 360, height: 240)].enumerated() {
            step { [self] done in
                guard let chromium = app?.engine as? ChromiumEngine, let video else { return done() }
                let js = "documentPictureInPicture.requestWindow({width:\(Int(size.width)),height:\(Int(size.height)),preferInitialWindowPlacement:true}).then(w=>{window.w10pip=w;w.document.body.textContent='W10 synthetic document';return true})"
                chromium.devToolsCall("Runtime.evaluate", params: ["expression": js, "userGesture": true, "awaitPromise": true, "returnByValue": true], in: video) { _, _ in done() }
            }
            wait(2)
            run { [self] in
                guard let chromium = app?.engine as? ChromiumEngine, let video else { return }
                let state = PiPEngineOverlay.state(video, in: chromium)
                guard let window = state?["window"] as? NSWindow else { check(false, "w10 Document PiP: native window exists"); return }
                check(state?["kind"] as? String == "document", "w10 Document PiP: document window kind")
                let area = target.visibleFrame.insetBy(dx: 20, dy: 20)
                if index == 0 {
                    if fallback {
                        check(window.screen == target && abs(window.frame.maxX - area.maxX) < 3 && abs(window.frame.minY - area.minY) < 3,
                              "w10 Document PiP: removed display falls back to main corner; frame=\(window.frame)")
                    }
                    window.setFrameOrigin(NSPoint(x: area.maxX - window.frame.width, y: area.minY))
                    documentCorner = NSPoint(x: window.frame.maxX, y: window.frame.minY)
                } else {
                    check(window.screen == target && abs(window.frame.maxX - documentCorner.x) < 3 && abs(window.frame.minY - documentCorner.y) < 3,
                          "w10 Document PiP: reopen retains display/corner; frame=\(window.frame)")
                }
            }
            step { [self] done in
                guard app?.engine is ChromiumEngine, let video else { return done() }
                video.evaluate("JSON.stringify([w10pip.innerWidth,w10pip.innerHeight])") { value in
                    self.check(value as? String == "[\(Int(size.width)),\(Int(size.height))]", "w10 Document PiP: honors requested viewport \(size); actual=\(String(describing: value))")
                    done()
                }
            }
            wait(1)
            run { [self] in
                guard let chromium = app?.engine as? ChromiumEngine, let video else { return }
                chromium.closePictureInPicture(video)
            }
            wait(1)
        }
        #endif
        var systemWindow: AXUIElement?
        var systemCorner = CGPoint.zero
        func point(_ window: AXUIElement) -> CGPoint? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var p = CGPoint.zero
            guard AXValueGetValue(value as! AXValue, .cgPoint, &p) else { return nil }
            return p
        }
        func pipAgentWindow() -> AXUIElement? {
            guard let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.PIPAgent" }) else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(agent.processIdentifier), kAXWindowsAttribute as CFString, &value)
            return error == .success ? (value as? [AXUIElement])?.first : nil
        }
        run { [self] in
            guard app?.engine is WebKitEngine else { return }
            guard AXIsProcessTrusted() else {
                note("FAIL-ENV w10 PiP WebKit: AXIsProcessTrusted=false; external PIPAgent cannot be moved/inspected without Accessibility authorization")
                return
            }
            systemWindow = pipAgentWindow()
            guard let window = systemWindow else { check(false, "w10 PiP WebKit: PIPAgent window exists"); return }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID() else { check(false, "w10 PiP WebKit: window size readable"); return }
            var size = CGSize.zero
            AXValueGetValue(value as! AXValue, .cgSize, &size)
            let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
            let area = target.visibleFrame.insetBy(dx: 20, dy: 20)
            systemCorner = CGPoint(x: area.maxX - size.width, y: mainHeight - area.minY - size.height)
            var corner = systemCorner
            let error = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &corner)!)
            check(error == .success, "w10 PiP WebKit: move PIPAgent to second display; AX error=\(error.rawValue)")
        }
        wait(2)
        run { [self] in
            guard app?.engine is WebKitEngine, let window = systemWindow else { return }
            let p = point(window)
            check(p != nil && abs(p!.x - systemCorner.x) < 4 && abs(p!.y - systemCorner.y) < 4,
                  "w10 PiP WebKit: retains second-display corner after move; position=\(String(describing: p))")
        }
        run { [self] in
            if app?.engine is WebKitEngine {
                video?.evaluate("document.pictureInPictureElement ? document.exitPictureInPicture() : document.querySelector('video')?.webkitSetPresentationMode('inline')") { _ in }
            }
            server?.stop()
        }
    }

}
#endif
