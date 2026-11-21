// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import Carbon
import AircKit

/// `--script littlearcstage` (both engines; a dedicated UI session under the UI lock, `AIRC_UI_DEDICATED_SESSION=1`,
/// `AIRC_REAL_KEYS=1`, `AIRC_LA_AS_OWNER=1`): every Little Airc window that a window list shows comes forward and takes
/// the key when it's chosen there, and one that's closed or hidden isn't listed.
///   1. an ordinary Little Airc and 2. one that opened as a panel over a full-screen app and became an ordinary window
///      again (`settleOverFullScreen`, what happens when that app leaves full screen), each with another app in front:
///      - the window server's front request for that window, the way Stage Manager, Mission Control and the Dock's
///        window list ask (SkyLight's front-process request with the window, its key-window event records, AX raise);
///      - a real click on its row;
///      - real ⌘` (the physical key, keycode 50) from the browser window (FAIL-ENV when the system hotkey doesn't fire for the
///        driver: the app then gets the raw key, which the hotkey never delivers);
///      - the Window menu, with real clicks on the menu title and on its item;
///      each time: Airc active, the window key and in front;
///   3. closed with real ⌘W: not in the Window menu, not on screen, gone from the app's list;
///   4. (Chromium) the mini player: closed while a video plays, the hidden window is out of the Window menu and the
///      screen and ⌘` never reaches it; the picture in picture is a floating, cycle-ignoring window (never in Stage
///      Manager's strip or ⌘`); a stray order-front of the hidden window ends the mini player (it's the window again).
/// After each case, every window the Window menu lists can be brought forward (visible or minimised, can be key, opaque).
/// `AIRC_LAS_BEFORE=1` turns the fixes off (the "before" arm, same build).
extension SnapshotRunner {
    private final class LittleArcStageState {
        var server: LocalPageServer?
        var base = ""
        var real = false
        weak var little: LittleArcController?
    }

    private var lasTag: String { "littlearcstage \(app?.engine is WebKitEngine ? "webkit" : "chromium")" }

    // MARK: The window server's front request (Stage Manager, Mission Control, the Dock)

    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    /// What choosing a window in Stage Manager's strip, Mission Control or the Dock's window list sends an app: the
    /// process to the front with that window (user generated), the window made key by the window server's event records,
    /// and the window raised. Our own process and window only; no Apple events.
    private func lasFrontRequest(_ window: NSWindow) -> (desc: String, keyed: Bool) {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let carbon = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
        guard let f = dlsym(sky, "_SLPSSetFrontProcessWithOptions"), let e = dlsym(sky, "SLPSPostEventRecordTo"),
              let g = dlsym(carbon, "GetProcessForPID") else { return ("SkyLight calls missing", false) }
        let setFront = unsafeBitCast(f, to: SetFrontProcess.self)
        let post = unsafeBitCast(e, to: PostEventRecord.self)
        let psnFor = unsafeBitCast(g, to: ProcessForPID.self)
        var psn = ProcessSerialNumber()
        guard psnFor(getpid(), &psn) == noErr else { return ("no process serial number", false) }
        var wid = UInt32(window.windowNumber)
        let front = setFront(&psn, wid, 0x200)
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: &wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        let key1 = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        bytes[0x08] = 0x02
        let key2 = bytes.withUnsafeMutableBufferPointer { post(&psn, $0.baseAddress!) }
        var raised = "no AX window"
        let axApp = AXUIElementCreateApplication(getpid())
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success, let ws = list as? [AXUIElement] {
            for w in ws {
                var pos: CFTypeRef?, size: CFTypeRef?
                guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
                      AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { continue }
                var p = CGPoint.zero, sz = CGSize.zero
                AXValueGetValue(pos as! AXValue, .cgPoint, &p)
                AXValueGetValue(size as! AXValue, .cgSize, &sz)
                let top = (NSScreen.screens.first?.frame.maxY ?? 0) - window.frame.maxY
                if abs(p.x - window.frame.minX) < 2, abs(p.y - top) < 2, abs(sz.width - window.frame.width) < 2 {
                    raised = "AX raise \(AXUIElementPerformAction(w, kAXRaiseAction as CFString).rawValue)"
                    break
                }
            }
        }
        return ("front \(front), key records \(key1)/\(key2)\(key1 == 0 ? "" : " (refused: a test app has no event-posting grant)"), \(raised)",
                key1 == 0 && key2 == 0)
    }

    // MARK: Helpers

    /// Another app in front (the Finder, without Apple events): Airc inactive.
    private func lasAway(_ tag: String, _ done: @escaping (Bool) -> Void) {
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        NSApp.deactivate()
        finder?.activate()
        waitUntil({ !NSApp.isActive }, timeout: 3) {
            if NSApp.isActive {
                self.note("FAIL-ENV \(tag): another app didn't come to the front (front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))")
            }
            done(!NSApp.isActive)
        }
    }

    /// The browser window key in an active Airc.
    private func lasBrowserFront(_ tag: String, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
            let ok = NSApp.isActive && self.c.window.isKeyWindow
            if !ok { self.note("FAIL-ENV \(tag): the browser window isn't key (active \(NSApp.isActive))") }
            done(ok)
        }
    }

    /// Our front window as the window server orders them (NSApp.orderedWindows leaves panels out): a top-level, normal
    /// level window that can be key (the engine's child anchors and helpers don't count).
    private func lasFrontmostOurs() -> NSWindow? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for d in list where (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid()
            && (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
            guard let n = (d[kCGWindowNumber as String] as? NSNumber)?.intValue, let w = NSApp.window(withWindowNumber: n) else { continue }
            if w.isVisible, w.level == .normal, w.alphaValue > 0, w.frame.width > 2, w.parent == nil, w.canBecomeKey,
               !w.collectionBehavior.contains(.transient) { return w }
        }
        return nil
    }

    /// Airc active, `w` key and the first of our windows on screen.
    private func lasForward(_ w: NSWindow) -> (ok: Bool, desc: String) {
        let first = lasFrontmostOurs()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        let ok = NSApp.isActive && frontmost && w.isKeyWindow && first === w
        return (ok, "active \(NSApp.isActive), frontmost \(frontmost), key \(w.isKeyWindow), first ours \(first === w ? "it" : first.map { "\(type(of: $0)) “\($0.title)”" } ?? "none")"
                + ", key window \(NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "none")")
    }

    private func lasListed(_ w: NSWindow) -> Bool { NSApp.windowsMenu?.items.contains { ($0.target as AnyObject?) === w } == true }

    private func lasOnScreenQuiet(_ w: NSWindow) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return w.windowNumber > 0 && list.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == w.windowNumber }
    }

    private func lasOnScreen(_ w: NSWindow) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard w.windowNumber > 0, let d = list.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == w.windowNumber }) else {
            return false
        }
        let b = d[kCGWindowBounds as String] as? [String: Any] ?? [:]
        note("\(lasTag): window server: window \(w.windowNumber) (\(type(of: w)) “\(w.title)”, AppKit visible \(w.isVisible), alpha \(w.alphaValue)) "
             + "on screen: alpha \(d[kCGWindowAlpha as String] ?? "?"), layer \(d[kCGWindowLayer as String] ?? "?"), bounds \(b), "
             + "name “\(d[kCGWindowName as String] ?? "")”, owner pid \(d[kCGWindowOwnerPID as String] ?? "?")")
        return true
    }

    /// Every window the Window menu lists can come forward: visible or minimised, can be key, not see-through.
    private func lasInventory(_ tag: String, _ when: String) {
        let items = NSApp.windowsMenu?.items.compactMap { $0.target as? NSWindow } ?? []
        let bad = items.filter { w in !(w.isVisible || w.isMiniaturized) || !w.canBecomeKey || w.alphaValue < 0.5 }
        check(bad.isEmpty, "\(tag): \(when): every window the Window menu lists can come forward (\(items.count) listed"
              + (bad.isEmpty ? ")" : "; not: " + bad.map { "\(type(of: $0)) “\($0.title)” visible \($0.isVisible) key-able \($0.canBecomeKey) alpha \($0.alphaValue)" }
                .joined(separator: ", ") + ")"))
    }

    /// A real click at `p` (window coordinates of `w`), wherever the app's activation is.
    private func lasClick(_ p: NSPoint, in w: NSWindow, _ done: @escaping (Bool, String) -> Void) {
        let s = w.convertPoint(toScreen: p)
        let top = NSWindow.windowNumber(at: s, belowWindowWithWindowNumber: 0)
        guard top == w.windowNumber else { return done(false, "FAIL-ENV: another window is at the click point (\(Self.windowInfo(top).text))") }
        let y = (NSScreen.screens.first?.frame.maxY ?? 0) - s.y
        UIDriverClient.run(["--click", String(Double(s.x)), String(Double(y))]) { ok, out in done(ok, out) }
    }

    /// The centre of the menu bar title `title` and, once it's open, of its item `item` (own-process AX).
    private func lasMenuPoint(_ title: String, item: String? = nil) -> CGPoint? {
        let axApp = AXUIElementCreateApplication(getpid())
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else { return nil }
        func kids(_ e: AXUIElement) -> [AXUIElement] {
            var k: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &k) == .success ? (k as? [AXUIElement] ?? []) : []
        }
        func axTitle(_ e: AXUIElement) -> String? {
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &t)
            return t as? String
        }
        func centre(_ e: AXUIElement) -> CGPoint? {
            var pos: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &pos) == .success,
                  AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &size) == .success else { return nil }
            var p = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &p)
            AXValueGetValue(size as! AXValue, .cgSize, &sz)
            return sz.width > 0 && sz.height > 0 ? CGPoint(x: p.x + sz.width / 2, y: p.y + sz.height / 2) : nil
        }
        guard let menuTitle = kids(barEl as! AXUIElement).first(where: { axTitle($0) == title }) else { return nil }
        guard let item else { return centre(menuTitle) }
        for menu in kids(menuTitle) {
            // The window's item last: a window title can repeat a command's ("Little Airc" is also New Little Airc Window's
            // start), so the exact title, the last match.
            if let hit = kids(menu).last(where: { axTitle($0) == item }) { return centre(hit) }
        }
        return nil
    }

    // MARK: The cases

    /// The four ways back for `l`'s window (the case's name `name`).
    private func lasWaysBack(_ s: LittleArcStageState, _ name: String) {
        let tag = lasTag
        // Stage Manager / Mission Control / Dock: the window server's front request.
        step { [self] done in
            guard let w = s.little?.window else { return done() }
            lasAway(tag) { away in
                guard away else { return done() }
                let sent = self.lasFrontRequest(w)
                // Without the key records (a test app can't post them), what's asserted is the activation and the order.
                func forward() -> Bool {
                    let f = self.lasForward(w)
                    return sent.keyed ? f.ok : NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
                        && f.desc.contains("first ours it")
                }
                self.waitUntil(forward, timeout: 3) {
                    let f = self.lasForward(w)
                    self.check(forward(), "\(tag): \(name): chosen in a window list (the window server's front request, as Stage Manager, "
                               + "Mission Control and the Dock send it: \(sent.desc)) it comes forward"
                               + (sent.keyed ? " and takes the key" : ": Airc active and it in front") + " (\(f.desc))")
                    done()
                }
            }
        }
        // A real click on its row.
        step { [self] done in
            guard s.real, let l = s.little else { return done() }
            let w = l.window
            lasAway(tag) { away in
                guard away else { return done() }
                w.orderFront(nil)   // in front of our other windows, Airc still inactive (no activation)
                self.waitUntil({ false }, timeout: 0.4) {
                    let p = l.bar.convert(NSPoint(x: l.chip.frame.minX - 10, y: l.bar.bounds.midY), to: nil)
                    self.lasClick(p, in: w) { ok, out in
                        guard ok else {
                            self.note((out.hasPrefix("FAIL-ENV") ? "" : "FAIL-ENV \(tag): \(name): real click: ") + out)
                            return done()
                        }
                        self.waitUntil({ self.lasForward(w).ok }, timeout: 3) {
                            let f = self.lasForward(w)
                            self.check(f.ok, "\(tag): \(name): a real click on it with another app in front activates Airc and "
                                       + "makes it key (\(f.desc))")
                            done()
                        }
                    }
                }
            }
        }
        // Real ⌘` from the browser window: some press of the cycle makes it key.
        step { [self] done in
            guard s.real, let w = s.little?.window else { return done() }
            lasBrowserFront(tag) { ok in
                guard ok else { return done() }
                var seen: [String] = []
                // The system's Move-focus hotkey is handled by the window server: the app never gets the key itself.
                var raw = 0
                let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    if e.modifierFlags.contains(.command), [50, 10].contains(e.keyCode) { raw += 1 }
                    return e
                }
                func press(_ n: Int) {
                    let code = n % 2 == 1 ? "cmd+50" : "cmd+10"
                    UIDriverClient.run(["--keycode", code]) { sent, out in
                        self.waitUntil({ w.isKeyWindow }, timeout: 0.8) {
                            seen.append("\(code) → " + (NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"))
                            if !sent { self.note("\(tag): \(name): ⌘` press: \(out)") }
                            if w.isKeyWindow || n >= 4 || !sent {
                                if let monitor { NSEvent.removeMonitor(monitor) }
                                let f = self.lasForward(w)
                                let what = "\(tag): \(name): real ⌘` (HID keycode 50 or the ISO key 10, Airc frontmost) brings it forward with the key "
                                    + "(key windows after each press: \(seen.joined(separator: ", ")); \(f.desc))"
                                if !f.ok, raw > 0 {
                                    self.note("FAIL-ENV " + what + ": the system's Move-focus hotkey didn't fire for the driver's key (the app got the raw "
                                              + "⌘ key \(raw)×, which the hotkey never delivers; buildmac's Austrian layout types < on keycode 50)")
                                } else {
                                    self.check(f.ok, what)
                                }
                                return done()
                            }
                            press(n + 1)
                        }
                    }
                }
                press(1)
            }
        }
        // The Window menu, with real clicks.
        step { [self] done in
            guard s.real, let w = s.little?.window else { return done() }
            lasBrowserFront(tag) { ok in
                guard ok else { return done() }
                let listed = self.lasListed(w)
                self.check(listed, "\(tag): \(name): the Window menu lists it (“\(w.title)”)")
                guard listed, let menu = self.lasMenuPoint("Window") else {
                    if listed { self.note("FAIL-ENV \(tag): \(name): no Window menu title on the menu bar (AX)") }
                    return done()
                }
                var tries: [String] = []
                func attempt(_ n: Int) {
                    UIDriverClient.run(["--click", String(Double(menu.x)), String(Double(menu.y))]) { ok, out in
                        self.waitUntil({ self.lasMenuPoint("Window", item: w.title) != nil }, timeout: 2) {
                            guard ok, self.lasMenuPoint("Window", item: w.title) != nil else {
                                self.note("FAIL-ENV \(tag): \(name): the Window menu didn't open for a real click (\(out))")
                                NSApp.mainMenu?.cancelTracking()
                                return done()
                            }
                            // Once the menu has finished opening, where its item is now.
                            self.waitUntil({ false }, timeout: 0.35) {
                                guard let item = self.lasMenuPoint("Window", item: w.title) else { NSApp.mainMenu?.cancelTracking(); return done() }
                                UIDriverClient.run(["--click", String(Double(item.x)), String(Double(item.y))]) { clicked, _ in
                                    self.waitUntil({ self.lasForward(w).ok }, timeout: 3) {
                                        let f = self.lasForward(w)
                                        tries.append("try \(n): item at (\(Int(item.x)),\(Int(item.y))) clicked \(clicked) → key \(w.isKeyWindow)")
                                        if !f.ok, n < 2 {
                                            NSApp.mainMenu?.cancelTracking()
                                            return self.lasBrowserFront(tag) { _ in attempt(n + 1) }
                                        }
                                        self.check(f.ok, "\(tag): \(name): chosen in the Window menu (real clicks) it comes forward with the key "
                                                   + "(\(tries.joined(separator: "; ")); \(f.desc))")
                                        NSApp.mainMenu?.cancelTracking()
                                        done()
                                    }
                                }
                            }
                        }
                    }
                }
                attempt(1)
            }
        }
        run { [self] in lasInventory(tag, name) }
    }

    /// Real ⌘W on `l` (it's key first): closed for real, out of every list.
    private func lasCloses(_ s: LittleArcStageState, _ name: String) {
        let tag = lasTag
        step { [self] done in
            guard let l = s.little else { return done() }
            let w = l.window
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            waitUntil({ w.isKeyWindow && NSApp.isActive }, timeout: 3) {
                let closeNow: (@escaping () -> Void) -> Void = { next in
                    if s.real, w.isKeyWindow {
                        UIDriverClient.run(["--key", "cmd+w", "--pid", String(getpid())]) { ok, out in
                            if !ok { self.note("\(tag): \(name): real ⌘W: \(out); closing it directly"); l.closeWindow() }
                            next()
                        }
                    } else { l.closeWindow(); next() }
                }
                closeNow {
                    // Then the window server's close animation (about 0.2 s).
                    self.waitUntil({ self.app?.littleArcs.contains { $0 === l } == false && !self.lasOnScreenQuiet(w) }, timeout: 4) {
                        let kept = self.app?.littleArcs.contains { $0 === l } == true
                        let listed = self.lasListed(w), on = self.lasOnScreen(w)
                        self.check(!kept && !w.isVisible && !listed && !on,
                                   "\(tag): \(name): closed (\(s.real ? "real ⌘W" : "closeWindow")), it's in no window list: kept \(kept), "
                                   + "visible \(w.isVisible), in the Window menu \(listed), on screen \(on)")
                        self.lasInventory(tag, "\(name) closed")
                        done()
                    }
                }
            }
        }
    }

    func littleArcStageScenario() {
        let s = LittleArcStageState()
        let tag = lasTag
        s.real = UIDriverClient.requested && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
            && FileManager.default.isExecutableFile(atPath: UIDriverClient.path)
        let video = """
            <title>video</title><canvas id="c" width="160" height="90"></canvas><video id="v" playsinline></video>
            <script>var c=document.getElementById('c'),x=c.getContext('2d'),n=0;
            setInterval(function(){x.fillStyle='hsl('+(n++*7%360)+',60%,50%)';x.fillRect(0,0,160,90)},33);
            document.getElementById('v').srcObject=c.captureStream(30);</script>
            """
        step { [self] done in
            note("\(tag): real input \(s.real), fixes \(LittleArcController.stageFixOff ? "OFF (before arm)" : "on"), "
                 + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            s.server = LocalPageServer(responses: ["/a": .init(body: "<title>stage a</title><p>a</p>"),
                                                   "/b": .init(body: "<title>stage b</title><p>b</p>"),
                                                   "/video": .init(body: video)])
            s.server?.start { port in
                s.base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                if s.base.isEmpty { self.check(false, "\(tag): the loopback server starts") }
                done()
            }
        }
        func open(_ path: String, panel: Bool, _ name: String) {
            step { [self] done in
                guard let app, !s.base.isEmpty else { return done() }
                s.little = app.openLittleArc(url: URL(string: s.base + path), spaceID: c.currentSpaceID,
                                             overFullScreenOf: panel ? getpid() : nil)
                waitUntil({ s.little?.page?.isLoading == false && s.little?.window.isVisible == true }, timeout: 8) {
                    guard let l = s.little else { self.check(false, "\(tag): \(name): Little Airc opens"); return done() }
                    if panel {
                        let before = l.window.preventsActivationTag
                        // Its full-screen app left full screen: an ordinary window again.
                        l.settleOverFullScreen()
                        let w = l.window
                        self.check(w is NSPanel && w.level == .normal && !w.styleMask.contains(.nonactivatingPanel)
                                   && w.preventsActivationTag != true,
                                   "\(tag): \(name): settled, an ordinary window: panel \(w is NSPanel), level \(w.level.rawValue), "
                                   + "non-activating style \(w.styleMask.contains(.nonactivatingPanel)), window-server tag "
                                   + "\(before.map { "\($0)" } ?? "?") → \(w.preventsActivationTag.map { "\($0)" } ?? "?")")
                    }
                    self.waitUntil({ false }, timeout: 0.5, then: done)
                }
            }
        }

        // 1. An ordinary Little Airc.
        open("/a", panel: false, "Little Airc")
        lasWaysBack(s, "Little Airc")
        // Which Spaces behaviour keeps Little Airc out of ⌘`'s cycle: each variant, then real ⌘` from the browser window.
        if ProcessInfo.processInfo.environment["AIRC_LAS_CYCLE"] == "1" {
            func props(_ w: NSWindow) -> String {
                "\(type(of: w)) behaviour \(w.collectionBehavior.rawValue) style \(w.styleMask.rawValue) tabbing \(w.tabbingMode.rawValue) "
                    + "id “\(w.tabbingIdentifier)” restorable \(w.isRestorable) titleVis \(w.titleVisibility.rawValue) main-able \(w.canBecomeMain) "
                    + "key-able \(w.canBecomeKey) level \(w.level.rawValue) excluded \(w.isExcludedFromWindowsMenu) delegate \(w.delegate.map { "\(type(of: $0))" } ?? "none") "
                    + "windowController \(w.windowController != nil) parent \(w.parent != nil) children \(w.childWindows?.count ?? 0) "
                    + "sharing \(w.sharingType.rawValue) hidesOnDeactivate \(w.hidesOnDeactivate) ordered index \(NSApp.orderedWindows.firstIndex(of: w) ?? -1) "
                    + "documentEdited \(w.isDocumentEdited) represented \(w.representedURL != nil) minimizable \(w.styleMask.contains(.miniaturizable))"
            }
            run { [self] in
                if let w = s.little?.window { note("\(tag): cycle props: Little Airc: " + props(w)) }
                note("\(tag): cycle props: browser: " + props(c.window))
            }
            typealias Change = (NSWindow) -> () -> Void
            let variants: [(String, Change)] = [
                ("as shipped", { _ in {} }),
                ("tabbing automatic", { w in let o = w.tabbingMode; w.tabbingMode = .automatic; return { w.tabbingMode = o } }),
                ("tabbing as the browser's", { [weak self] w in let o = w.tabbingMode; w.tabbingMode = self?.c.window.tabbingMode ?? o
                    let oi = w.tabbingIdentifier; w.tabbingIdentifier = self?.c.window.tabbingIdentifier ?? oi
                    return { w.tabbingMode = o; w.tabbingIdentifier = oi } }),
                ("restorable", { w in let o = w.isRestorable; w.isRestorable = true; return { w.isRestorable = o } }),
                ("title visible", { w in let o = w.titleVisibility; w.titleVisibility = .visible; return { w.titleVisibility = o } }),
                ("behaviour as the browser's", { [weak self] w in let o = w.collectionBehavior; w.collectionBehavior = self?.c.window.collectionBehavior ?? o
                    return { w.collectionBehavior = o } }),
                ("style as the browser's", { [weak self] w in let o = w.styleMask; w.styleMask = self?.c.window.styleMask ?? o
                    return { w.styleMask = o } }),
                ("re-added to the Window menu", { w in NSApp.removeWindowsItem(w); NSApp.addWindowsItem(w, title: w.title, filename: false); return {} }),
            ]
            for (label, change) in variants {
                step { [self] done in
                    guard s.real, let w = s.little?.window else { return done() }
                    let undo = change(w)
                    let set = w.collectionBehavior.rawValue
                    lasBrowserFront(tag) { ok in
                        guard ok else { undo(); return done() }
                        UIDriverClient.run(["--keycode", "cmd+50"]) { _, _ in
                            self.waitUntil({ w.isKeyWindow }, timeout: 1.2) {
                                self.note("\(tag): cycle experiment: \(label) (behaviour \(set), tabbing \(w.tabbingMode.rawValue), "
                                          + "excluded \(w.isExcludedFromWindowsMenu)): ⌘` \(w.isKeyWindow ? "REACHES" : "skips") Little Airc "
                                          + "(key \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none"))")
                                undo()
                                done()
                            }
                        }
                    }
                }
            }
        }
        // Isolation: ⌘` from the browser window to (a) a fresh plain titled NSWindow, (b) a bare LittleArcWindow (no
        // controller, no engine), (c) the real Little Airc, with every became-key and resigned-key on the way.
        if ProcessInfo.processInfo.environment["AIRC_LAS_CYCLE"] == "1" {
            for kind in ["plain NSWindow", "bare LittleArcWindow", "Little Airc"] {
                step { [self] done in
                    guard s.real else { return done() }
                    let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
                    let frame = NSRect(x: 300, y: 300, width: 480, height: 320)
                    let target: NSWindow? = kind == "plain NSWindow" ? NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
                        : kind == "bare LittleArcWindow" ? LittleArcWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
                        : s.little?.window
                    guard let w = target else { return done() }
                    if kind != "Little Airc" { w.isReleasedWhenClosed = false; w.title = kind; w.orderFront(nil) }
                    var seen: [String] = []
                    let names: (Notification) -> String = { n in
                        let win = n.object as? NSWindow
                        return "\(n.name == NSWindow.didBecomeKeyNotification ? "key" : "resign") \(win.map { "\(type(of: $0)) “\($0.title)”" } ?? "?")"
                    }
                    let o1 = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { seen.append(names($0)) }
                    let o2 = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) { seen.append(names($0)) }
                    lasBrowserFront(tag) { ok in
                        seen.removeAll()
                        let order = NSApp.orderedWindows.prefix(6).map { "\(type(of: $0)) “\($0.title)” vis \($0.isVisible)" }.joined(separator: " | ")
                        UIDriverClient.run(["--keycode", "cmd+50"]) { _, _ in
                            self.waitUntil({ false }, timeout: 1.2) {
                                NotificationCenter.default.removeObserver(o1)
                                NotificationCenter.default.removeObserver(o2)
                                self.note("\(tag): cycle isolation: \(kind): ⌘` \(w.isKeyWindow ? "REACHES" : "skips") it; key events: "
                                          + "\(seen.isEmpty ? "none" : seen.joined(separator: ", ")); order before: \(order)")
                                if kind != "Little Airc" { w.close() }
                                done()
                            }
                        }
                    }
                }
            }
        }
        lasCloses(s, "Little Airc")

        // 2. A Little Airc that opened over a full-screen app, then became an ordinary window.
        open("/b", panel: true, "settled panel")
        lasWaysBack(s, "settled panel")
        lasCloses(s, "settled panel")

        #if canImport(AircCore)
        // 4. The mini player.
        if let engine = app?.engine as? ChromiumEngine {
            run { [self] in app?.settings.values.pipAutomatic = true }
            open("/video", panel: false, "mini player")
            step { [self] done in
                guard let p = s.little?.page else { return done() }
                engine.devToolsCall("Runtime.evaluate", params: [
                    "expression": "document.getElementById('v').play().then(function(){document.title='playing'})",
                    "userGesture": true, "awaitPromise": true, "returnByValue": true], in: p) { _, _ in
                    self.waitUntil({ s.little?.page?.title == "playing" }, timeout: 4) {
                        self.check(s.little?.page?.title == "playing", "\(tag): mini player: the video plays in Little Airc")
                        guard let l = s.little else { return done() }
                        l.closeWindow()
                        self.waitUntil({ l.isMiniPlayer && !self.lasOnScreenQuiet(l.window) }, timeout: 5) {
                            let w = l.window
                            let listed = self.lasListed(w), on = self.lasOnScreen(w)
                            self.check(l.isMiniPlayer && !w.isVisible && !listed && !on && w.isExcludedFromWindowsMenu,
                                       "\(tag): mini player: the hidden window is in no window list (mini player \(l.isMiniPlayer), visible "
                                       + "\(w.isVisible), in the Window menu \(listed), on screen \(on), excluded \(w.isExcludedFromWindowsMenu))")
                            // The picture in picture: as it ships, floating and out of the window cycle.
                            // A test engine instance records the shipping values (it runs at the normal level itself); otherwise
                            // the window's own.
                            func shipping(_ w: NSWindow) -> NSDictionary? {
                                w.responds(to: NSSelectorFromString("aircProductionPiPConfiguration"))
                                    ? w.value(forKey: "aircProductionPiPConfiguration") as? NSDictionary : nil
                            }
                            let pip = NSApp.windows.first { w in
                                w.isVisible && (shipping(w) != nil
                                    || (w.level == .floating && w.collectionBehavior.contains(.ignoresCycle) && String(describing: type(of: w)).contains("NativeWidget")))
                            }
                            let conf = pip.flatMap(shipping)
                            let level = (conf?["level"] as? NSNumber)?.intValue ?? pip?.level.rawValue ?? -1
                            let behaviour = NSWindow.CollectionBehavior(rawValue: (conf?["collectionBehavior"] as? NSNumber)?.uintValue
                                                                        ?? pip?.collectionBehavior.rawValue ?? 0)
                            self.check(pip != nil && level == NSWindow.Level.floating.rawValue && behaviour.contains(.ignoresCycle)
                                       && behaviour.contains(.canJoinAllSpaces),
                                       "\(tag): mini player: the picture in picture ships floating and out of the window cycle, so Stage "
                                       + "Manager's strip and ⌘` never show it (window \(pip != nil), level \(level), ignores cycle "
                                       + "\(behaviour.contains(.ignoresCycle)), all Spaces \(behaviour.contains(.canJoinAllSpaces)), "
                                       + "in the Window menu \(pip.map { self.lasListed($0) } ?? false))")
                            done()
                        }
                    }
                }
            }
            // ⌘` from the browser window never lands on the hidden window.
            step { [self] done in
                guard s.real, let l = s.little, l.isMiniPlayer else { return done() }
                lasBrowserFront(tag) { ok in
                    guard ok else { return done() }
                    var seen: [String] = []
                    func press(_ n: Int) {
                        UIDriverClient.run(["--keycode", n % 2 == 1 ? "cmd+50" : "cmd+10"]) { _, _ in
                            self.waitUntil({ false }, timeout: 0.5) {
                                seen.append(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none")
                                if n < 4 { return press(n + 1) }
                                self.check(l.isMiniPlayer && !l.window.isVisible,
                                           "\(tag): mini player: real ⌘` ×4 (keycodes 50 and 10) never brings the hidden window (key windows: \(seen.joined(separator: ", ")), "
                                           + "still the mini player \(l.isMiniPlayer), visible \(l.window.isVisible))")
                                done()
                            }
                        }
                    }
                    press(1)
                }
            }
            run { [self] in lasInventory(tag, "mini player") }
            // A stray order-front (any window list that still had it): the window again, the picture in picture closed.
            step { [self] done in
                guard let l = s.little, l.isMiniPlayer else { return done() }
                NSApp.activate(ignoringOtherApps: true)
                l.window.makeKeyAndOrderFront(nil)
                waitUntil({ !l.isMiniPlayer && l.window.isKeyWindow }, timeout: 3) {
                    self.waitUntil({ false }, timeout: 0.8) {
                        guard let p = l.page else { self.check(false, "\(tag): mini player: the page is kept"); return done() }
                        engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.pictureInPictureElement!==null",
                                                                         "returnByValue": true], in: p) { reply, _ in
                            let inPiP = ((reply?["result"] as? [String: Any])?["value"] as? Bool) == true
                            self.check(!l.isMiniPlayer && l.window.isKeyWindow && !inPiP && !l.window.isExcludedFromWindowsMenu && self.lasListed(l.window),
                                       "\(tag): mini player: brought forward another way, it's the window again (mini player \(l.isMiniPlayer), "
                                       + "key \(l.window.isKeyWindow), picture in picture \(inPiP), in the Window menu \(self.lasListed(l.window)))")
                            done()
                        }
                    }
                }
            }
            run { [self] in app?.settings.values.pipAutomatic = false }
            lasCloses(s, "mini player window")
            run { [self] in app?.settings.values.pipAutomatic = true }
        }
        #endif
        run { [self] in
            lasInventory(tag, "the end")
            s.server?.stop()
        }
    }
}
#endif
