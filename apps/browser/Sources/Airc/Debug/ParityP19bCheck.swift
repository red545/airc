// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import WebKit
#if canImport(AircCore)
import AircCore
#endif

/// P19b, live Captures on Easels (parity N03) and P19a's leftovers (N07), both engines, loopback pages only. Mouse and
/// keys are NSEvents through the app's own queue (the check helpers' drag and click), except the ⌥-click on a sidebar
/// row, which is the UI driver's real click when the run has it (AIRC_REAL_KEYS=1); input into a page is the
/// engine's (Chromium's DevTools Input events, WebKit events handed to its web view, as the agent drivers do); no page here
/// ever calls getUserMedia, getDisplayMedia, geolocation or Notification (the guards are checked by what they replaced).
///   - `parityp19b` (live Captures) and `parityp19b-ui` (Interact, the drags, private windows, splits, Duplicate; on an
///     Easel of its own), together: a real drag over Capture picks a region, Add to Easel keeps it live (its CSS rect, zoom, profile);
///     ⌘R refreshes it from the changed page (the picture's colour changes; no undo step, and ⌘Z of an earlier move
///     keeps the new picture); captured at 125 % the region is the same rect and refreshes; signed out (401), gone
///     (404) and an unreachable server keep the last picture and say so; Detach and deleting cancel a refresh under way
///     and nothing lands; the offscreen page is muted with media paused and its permission APIs replaced, opens no
///     window and leaves no window behind; Live refreshes a stale block when the Easel opens; double-click makes it the
///     real page (a click in it counts), Esc pictures it again; a link dragged out of that page (the engine's own drag)
///     drops as a link card; a sidebar row dragged onto the Easel (the sidebar's drag loop) becomes a link card; a
///     private window's page can't become a live Capture; ⌥-click and menus never put an Easel in a split; Duplicate
///     gives the copied row an Easel of its own.
///   - `parityp19b-relaunch` (same data folder): the live sources are there as they were left (mode, state, rect).
extension SnapshotRunner {
    private static let p19bState = "p19b-state.json"

    func parityP19bScenario() {
        // A check app never outlives its check: the runner's own time-out runs on the main queue, so a step stuck in a
        // nested event loop (a drag loop) would hold it off. This one doesn't need the main thread: past 280 s it writes
        // the FAIL line itself and exits (the runner's 240 s one normally ends the run first).
        let file = dir.appendingPathComponent("log.txt"), name = script
        DispatchQueue.global().asyncAfter(deadline: .now() + 280) {
            let previous = (try? String(contentsOf: file, encoding: .utf8)).map { $0 + "\n" } ?? ""
            try? (previous + "[\(name)]\nFAIL \(name): the main thread was stuck past 280 s (off-main watchdog quit the app)").write(to: file, atomically: true, encoding: .utf8)
            exit(70)
        }
        switch script {
        case "parityp19b-relaunch": parityP19bRelaunch()
        default: parityP19bMain(ui: script == "parityp19b-ui")
        }
    }

    // MARK: Helpers

    private final class P19b {
        var easelID = ""
        var easelTab = ""
        var ids: [String: String] = [:]
        var visits: [String: Int] = [:]
        var reports: [String] = []
        var ended: [(block: String, label: String)] = []
        var status401 = false
        var status404 = false
    }

    private func p19bSetup() {
        run { [self] in
            c.window.makeFirstResponder(nil)
            note("p19b: window key \(c.window.isKeyWindow), on the active Space \(c.window.isOnActiveSpace)")
            Self.emulateKeyWindow(c) { [weak self] in self?.note($0) }
            let keyWindowOrder = KeyMonitor.testKeyWindowDispatch
            KeyMonitor.testKeyWindowDispatch = { [weak self] e in
                if keyWindowOrder?(e) == true { return true }
                guard let self, e.type == .keyDown, e.window === self.c.window, let r = self.c.window.firstResponder else { return false }
                r.keyDown(with: e)
                return true
            }
        }
    }

    private func p19bKey(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        step { [self] done in
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: c.window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code) else { continue }
                NSApp.sendEvent(e)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: done)
        }
    }

    private func p19bEditor(_ id: String) -> EaselEditor? { EaselCenter.shared.existingEditor(id) }

    /// A click on a sidebar row: the UI driver's real click (with `mods`) when the run has the driver, at a point where
    /// the window is ours and the row is hit; otherwise a posted press and release (never sent: the row's drag loop runs
    /// inside the mouse-down and reads the release from the queue). `done` gets how it was made.
    private func p19bRowClick(_ row: NSView, at p: NSPoint, mods: String, _ done: @escaping (String) -> Void) {
        let w = c.window
        if UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1" {
            if !w.isKeyWindow { w.makeKey() }
            let screen = w.convertPoint(toScreen: p)
            let ours = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == w.windowNumber
            let hit = w.contentView?.superview.flatMap { $0.hitTest($0.convert(p, from: nil)) }
            guard ours, let hit, hit === row || hit.isDescendant(of: row) else {
                return done("real click refused: window ours \(ours), the point hits \(Self.describe(hit))")
            }
            UIDriverClient.click(p, in: w, mods: mods) { ok, out in
                done(ok ? "real driver click, --mods \(mods)" : "real driver click failed: \(out.prefix(120))")
            }
            return
        }
        let flags: NSEvent.ModifierFlags = mods.contains("opt") ? .option : []
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        done("posted press and release")
    }

    /// A page's CSS point in window coordinates (zoom `z`).
    private func p19bPagePoint(_ tab: EngineTab, _ x: Double, _ y: Double, zoom z: Double = 1) -> NSPoint {
        let v = tab.view
        let py = CGFloat(y * z)
        return v.convert(NSPoint(x: CGFloat(x * z), y: v.isFlipped ? py : v.bounds.height - py), to: nil)
    }

    /// The hue (0–360) at the middle of an Easel asset.
    private func p19bHue(_ easelID: String, _ asset: String) -> Double? {
        guard let url = EaselCenter.shared.files.assetURL(easelID, asset), let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()),
              let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh * 3 / 4)?.usingColorSpace(.sRGB) else { return nil }
        return Double(c.hueComponent) * 360
    }

    private static func p19bHueOf(visit n: Int) -> Int { (n * 97) % 360 }

    /// Run in the offscreen page just before its picture: whether the guards replaced the browser's own APIs ("false":
    /// not the browser's; "absent": not in this engine), and whether its media plays.
    private static let p19bProbe = """
    (function(){ function native(f){ if (typeof f !== 'function') return 'absent'; try { return String(/\\[native code\\]/.test(Function.prototype.toString.call(f))); } catch(e){ return 'x'; } }
      var md = navigator.mediaDevices || {}, a = document.getElementById('a'), v = document.getElementById('v');
      return JSON.stringify({guard: String(!!window.__aircLiveGuard), gum: native(md.getUserMedia), gdm: native(md.getDisplayMedia),
        geo: native(navigator.geolocation && navigator.geolocation.getCurrentPosition), notif: native(window.Notification && Notification.requestPermission),
        play: native(HTMLMediaElement.prototype.play), alert: native(window.alert), open: native(window.open),
        audioPaused: String(!a || a.paused), videoPaused: String(!v || v.paused)}); })()
    """

    private func p19bHueNear(_ a: Double?, _ b: Int) -> Bool {
        guard let a else { return false }
        let d = abs(a - Double(b)).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d) < 14
    }

    private func p19bCapture(_ b: EaselBlock?) -> EaselCapture? {
        if case .capture(let c)? = b?.content { return c }
        return nil
    }

    private func p19bDescribe(_ r: EaselRect?) -> String {
        r.map { String(format: "%.1f, %.1f, %.1f × %.1f", $0.x, $0.y, $0.width, $0.height) } ?? "none"
    }

    // MARK: The main run

    /// `ui`: the second half (Interact, the link and row drags, private windows, splits, Duplicate) on an Easel of its
    /// own, so each half stays well inside the runner's four minutes.
    private func parityP19bMain(ui: Bool) {
        let s = P19b()
        var server: LocalPageServer?
        var base = ""
        var doc: EaselDocument { p19bEditor(s.easelID)?.document ?? EaselDocument() }
        func block(_ key: String) -> EaselBlock? { s.ids[key].flatMap { doc.block($0) } }
        func cap(_ key: String) -> EaselCapture? { p19bCapture(block(key)) }
        let lock = NSLock()

        // Pages: /live/<name> shows its visit count as a colour (each request a new one); /auth turns 401, /gone 404,
        // /slow answers after 6 s; /media plays and reports what its APIs are.
        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.handler = { path in
                let clean = path.components(separatedBy: "?").first ?? path
                if clean.hasPrefix("/report") {
                    lock.lock(); s.reports.append(path); lock.unlock()
                    return LocalPageServer.Page(body: "ok")
                }
                guard clean.hasPrefix("/live/") || ["/auth", "/gone", "/slow", "/media"].contains(clean) else { return nil }
                lock.lock()
                let n = (s.visits[clean] ?? 0) + 1
                s.visits[clean] = n
                let a401 = s.status401, a404 = s.status404
                lock.unlock()
                if clean == "/auth", a401 { return LocalPageServer.Page(status: "401 Unauthorized", body: "<title>Sign in</title>Sign in") }
                if clean == "/gone", a404 { return LocalPageServer.Page(status: "404 Not Found", body: "<title>Gone</title>Gone") }
                let hue = Self.p19bHueOf(visit: n)
                var extra = ""
                if clean == "/media" {
                    // Only what's safe to call in a test: nothing that could reach a device or a system prompt.
                    extra = """
                    <video id=v autoplay muted loop playsinline width=40 height=30></video><audio id=a autoplay loop src="data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="></audio>
                    """
                }
                let body = """
                <title>Live \(clean) \(n)</title><style>body{margin:0;font:28px -apple-system;background:#fff}#card{position:absolute;left:60px;top:140px;width:320px;height:180px;background:hsl(\(hue),75%,50%);color:#fff;padding:12px;box-sizing:border-box}#tall{height:2400px}a{position:absolute;left:60px;top:360px;font-size:22px;padding:8px;background:#eee}</style>
                <div id=tall></div><div id=card onclick="var c=document.getElementById('clicks');c.textContent=String(Number(c.textContent)+1)">Visit \(n) <span id=clicks>0</span></div><button id=b style="position:absolute;left:400px;top:140px;width:120px;height:60px" onclick="var c=document.getElementById('clicks');c.textContent=String(Number(c.textContent)+1)">Count</button>
                <a id=link href="https://example.com/dragged-from-page">Dragged link</a>\(extra)
                """
                return LocalPageServer.Page(body: body, delay: clean == "/slow" && n > 1 ? 6 : 0)
            }
            server?.start { port in
                base = port.map { "http://127.0.0.1:\($0)" } ?? ""
                done()
            }
        }
        p19bSetup()
        run { [self] in
            CaptureSession.addsLive = true
            EaselLiveCenter.shared.onEnded = { _, b, label in s.ended.append((b, label)) }
            check(!base.isEmpty, "p19b: the loopback page server runs")
        }

        // A new Easel (⌃⇧E), named.
        p19bKey("\u{05}", 14, [.control, .shift], ignoring: "E")
        wait(0.5)
        run { [self] in
            let t = c.store.tab(c.shownTabID)
            s.easelTab = t?.id ?? ""
            s.easelID = EaselURL.easelID(t?.url) ?? ""
            check(!s.easelID.isEmpty, "p19b: ⌃⇧E makes an Easel")
        }
        for ch in "Live board" { p19bKey(String(ch), 0) }
        p19bKey("\r", 36)

        /// Opens `path` in a Today tab, captures the region of its #card with a real drag over Capture, and adds it to
        /// the Easel as block `key`. `zoomSteps`: the page zoomed in first (⌘+ steps).
        func captureCard(_ path: String, key: String, zoomSteps: Int = 0) {
            run { [self] in
                guard let t = try? c.store.openTab(url: base + path, inSpace: c.currentSpaceID, title: path) else { return }
                s.ids["tab-" + key] = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in waitUntil({ self.c.engineTab(for: s.ids["tab-" + key] ?? "")?.isLoading == false }, timeout: 10) { done() } }
            if zoomSteps > 0 {
                run { [self] in for _ in 0..<zoomSteps { c.engineTab(for: s.ids["tab-" + key] ?? "")?.zoom(step: 1) } }
                wait(0.8)
            }
            wait(0.6)
            run { [self] in c.startCapture() }
            step { [self] done in waitUntil({ CaptureSession.active(in: self.c.window)?.picturesReady == true }, timeout: 8) { done() } }
            step { [self] done in
                guard let tab = c.engineTab(for: s.ids["tab-" + key] ?? ""), CaptureSession.active(in: c.window) != nil else {
                    check(false, "p19b: Capture started on \(path)"); return done()
                }
                let z = tab.zoomFactor
                s.ids["zoom-" + key] = String(z)
                drag(from: p19bPagePoint(tab, 60, 140, zoom: z), to: p19bPagePoint(tab, 380, 320, zoom: z), done)
            }
            wait(0.3)
            run { [self] in
                guard let session = CaptureSession.active(in: c.window) else { return check(false, "p19b: Capture still up after the drag") }
                let before = Set(doc.blocks.map(\.id))
                let id = session.addToEasel(s.easelID)
                s.ids[key] = doc.blocks.map(\.id).first { !before.contains($0) }
                check(id == s.easelID && s.ids[key] != nil, "p19b: Add to Easel puts \(path)'s region on the Easel")
            }
            step { [self] done in waitUntil({ cap(key)?.live != nil }, timeout: 4) { done() } }
        }

        // MARK: Capture → a live block
        captureCard("/live/a", key: "a")
        run { [self] in
            let live = cap("a")?.live
            let expected = EaselRect(x: 60, y: 140, width: 320, height: 180)
            let near = live.map { abs($0.rect.x - expected.x) < 2.5 && abs($0.rect.y - expected.y) < 2.5 && abs($0.rect.width - expected.width) < 2.5 && abs($0.rect.height - expected.height) < 2.5 } ?? false
            check(near, "p19b: the live Capture keeps the region in the page's CSS pixels (\(p19bDescribe(live?.rect)))")
            check(live?.url == base + "/live/a" && live?.profileID == c.store.profile(ofSpace: c.currentSpaceID).id && live?.mode == .live
                  && abs((live?.zoom ?? 0) - 1) < 0.01 && (live?.viewportWidth ?? 0) > 300,
                  "p19b: …its address, profile, zoom and viewport, Live by default (zoom \(live?.zoom ?? 0), viewport \(Int(live?.viewportWidth ?? 0))×\(Int(live?.viewportHeight ?? 0)))")
            check(p19bHueNear(cap("a").flatMap { p19bHue(s.easelID, $0.asset) }, Self.p19bHueOf(visit: 1)),
                  "p19b: its picture is the page's first visit (hue \(Int(cap("a").flatMap { p19bHue(s.easelID, $0.asset) } ?? -1)))")
            if let u = p19bEditor(s.easelID)?.history.undoName { check(u == "Add Capture", "p19b: the source is part of the Add step (Undo \(u))") }
            if let t = s.ids["tab-a"] { c.closeTab(t) }
            c.show(s.easelTab, focus: true)
        }
        wait(0.5)

        if !ui {
        // MARK: Refresh (⌘R): the page changed; no undo step; an earlier move's undo keeps the new picture
        run { [self] in
            c.window.makeFirstResponder(p19bEditor(s.easelID)?.view.canvas)
            if let id = s.ids["a"] { p19bEditor(s.easelID)?.selection = [id] }
        }
        p19bKey("\u{F703}", 124, [.shift])   // ⇧→: a 10 pt nudge, one undo step
        var undoCount = 0
        var assetBefore = ""
        run { [self] in
            undoCount = p19bEditor(s.easelID)?.history.undoStack.count ?? 0
            assetBefore = cap("a")?.asset ?? ""
            s.ended = []
        }
        p19bKey("r", 15, .command)
        run { [self] in check(p19bEditor(s.easelID)?.refreshing.contains(s.ids["a"] ?? "") == true, "p19b: ⌘R starts refreshing the live Capture (its chip says Refreshing…)") }
        step { [self] done in waitUntil({ s.ended.contains { $0.block == s.ids["a"] } }, timeout: 25) { done() } }
        run { [self] in
            let label = s.ended.first { $0.block == s.ids["a"] }?.label ?? "none"
            let visits = s.visits["/live/a"] ?? 0
            check(label == "picture" && cap("a")?.asset != assetBefore, "p19b: the refresh brings a new picture (\(label), page visited \(visits)×)")
            check(p19bHueNear(cap("a").flatMap { p19bHue(s.easelID, $0.asset) }, Self.p19bHueOf(visit: visits)),
                  "p19b: …of the page as it is now (hue \(Int(cap("a").flatMap { p19bHue(s.easelID, $0.asset) } ?? -1)), visit \(visits) is \(Self.p19bHueOf(visit: visits)))")
            if let px = cap("a")?.pixelWidth { check(abs(px - 640) <= 4, "p19b: …the same region, at 2 px per CSS pixel (\(Int(px)) px wide)") }
            check(p19bEditor(s.easelID)?.history.undoStack.count == undoCount, "p19b: a refresh is no undo step")
            check(cap("a")?.live?.status == .ok && cap("a")?.live?.refreshedAt.map { Date().timeIntervalSince($0) < 30 } == true, "p19b: its state is up to date")
            check(EaselLiveCenter.shared.activeCount == 0 && NSApp.windows.filter { $0 is LiveCaptureWindow && $0.isVisible }.isEmpty,
                  "p19b: the offscreen page and its window are gone after the refresh")
        }
        p19bKey("z", 6, .command)
        run { [self] in
            let x = block("a")?.frame.x ?? 0
            check(cap("a")?.asset != assetBefore && p19bEditor(s.easelID)?.history.undoName == "Add Capture",
                  "p19b: ⌘Z undoes the move (x \(Int(x))) and keeps the refreshed picture")
        }

        // MARK: Zoom: captured at 125 %, the same CSS rect; it refreshes
        captureCard("/live/z", key: "z", zoomSteps: 1)
        run { [self] in
            let live = cap("z")?.live, a = cap("a")?.live
            let z = Double(s.ids["zoom-z"] ?? "1") ?? 1
            let same = live.flatMap { l in a.map { abs(l.rect.x - $0.rect.x) < 3 && abs(l.rect.y - $0.rect.y) < 3 && abs(l.rect.width - $0.rect.width) < 3 && abs(l.rect.height - $0.rect.height) < 3 } } ?? false
            check(z > 1.05 && abs((live?.zoom ?? 0) - z) < 0.02, "p19b: a Capture of a zoomed page keeps its zoom (\(z))")
            check(same, "p19b: …and the region in CSS pixels is the same as at 100 % (\(p19bDescribe(live?.rect)))")
            if let t = s.ids["tab-z"] {
                c.engineTab(for: t)?.zoom(step: -1)
                c.closeTab(t)
            }
            c.show(s.easelTab, focus: true)
            s.ended = []
            if let id = s.ids["z"] { p19bEditor(s.easelID)?.refreshLive([id]) }
        }
        step { [self] done in waitUntil({ s.ended.contains { $0.block == s.ids["z"] } }, timeout: 25) { done() } }
        run { [self] in
            let label = s.ended.first { $0.block == s.ids["z"] }?.label ?? "none"
            check(label == "picture" && p19bHueNear(cap("z").flatMap { p19bHue(s.easelID, $0.asset) }, Self.p19bHueOf(visit: s.visits["/live/z"] ?? 0)),
                  "p19b: the zoomed Capture refreshes the same region after a reload (\(label))")
        }

        // MARK: Signed out (401), gone (404), unreachable: the last picture stays and the block says why
        captureCard("/auth", key: "auth")
        captureCard("/gone", key: "gone")
        run { [self] in
            for k in ["tab-auth", "tab-gone"] { if let t = s.ids[k] { c.closeTab(t) } }
            c.show(s.easelTab, focus: true)
            s.status401 = true
            s.status404 = true
            s.ended = []
            s.ids["auth-asset"] = cap("auth")?.asset
            s.ids["gone-asset"] = cap("gone")?.asset
            p19bEditor(s.easelID)?.refreshLive([s.ids["auth"], s.ids["gone"]].compactMap { $0 })
        }
        step { [self] done in waitUntil({ s.ended.count >= 2 }, timeout: 30) { done() } }
        run { [self] in
            check(cap("auth")?.live?.status == .signedOut && cap("auth")?.asset == s.ids["auth-asset"] && cap("auth")?.live?.problem == "Sign in to refresh",
                  "p19b: a page that asks to sign in (401) keeps the last picture and says “Sign in to refresh” (\(cap("auth")?.live?.status.rawValue ?? "-"))")
            check(cap("gone")?.live?.status == .failed && cap("gone")?.asset == s.ids["gone-asset"] && cap("gone")?.live?.problem == "Page not found (404)",
                  "p19b: a page that's gone (404) keeps the last picture and says so (\(cap("gone")?.live?.problem ?? "-"))")
            check((cap("auth")?.live?.failures ?? 0) >= 1 && cap("auth")?.live?.attemptedAt != nil, "p19b: failures count for the back-off")
        }

        // MARK: Cancelling: Detach and Delete while a refresh is under way (a slow page)
        captureCard("/slow", key: "slow")
        run { [self] in
            if let t = s.ids["tab-slow"] { c.closeTab(t) }
            c.show(s.easelTab, focus: true)
            s.ended = []
            s.ids["slow-asset"] = cap("slow")?.asset
            if let id = s.ids["slow"] { p19bEditor(s.easelID)?.refreshLive([id]) }
        }
        wait(1.5)
        run { [self] in
            guard let e = p19bEditor(s.easelID), let id = s.ids["slow"] else { return }
            check(e.refreshing.contains(id), "p19b: the slow page's refresh is under way")
            e.selection = [id]
            e.detachLive()
            check(cap("slow")?.live == nil && e.history.undoName == "Detach", "p19b: Detach makes it a static picture (one undo step)")
        }
        wait(7)
        run { [self] in
            let label = s.ended.first { $0.block == s.ids["slow"] }?.label
            check(label == "cancelled" && cap("slow")?.asset == s.ids["slow-asset"] && cap("slow")?.live == nil,
                  "p19b: the refresh under way stops and nothing lands on the detached block (\(label ?? "-"))")
            check(EaselLiveCenter.shared.activeCount == 0 && NSApp.windows.filter { $0 is LiveCaptureWindow && $0.isVisible }.isEmpty,
                  "p19b: its offscreen page is gone")
        }
        p19bKey("z", 6, .command)
        run { [self] in
            check(cap("slow")?.live != nil, "p19b: ⌘Z after Detach makes it live again")
            s.ended = []
            if let id = s.ids["slow"] {
                p19bEditor(s.easelID)?.refreshLive([id])
                p19bEditor(s.easelID)?.selection = [id]
            }
        }
        wait(1.2)
        p19bKey("\u{7f}", 51)
        wait(0.4)
        run { [self] in
            check(block("slow") == nil && s.ended.first { $0.block == s.ids["slow"] }?.label == "cancelled",
                  "p19b: deleting a block cancels its refresh (\(s.ended.first { $0.block == s.ids["slow"] }?.label ?? "-"))")
        }

        // MARK: Nothing heard, asked or opened: the media page refreshed offscreen
        captureCard("/media", key: "media")
        run { [self] in
            if let t = s.ids["tab-media"] { c.closeTab(t) }
            c.show(s.easelTab, focus: true)
            lock.lock(); s.reports = []; lock.unlock()
            s.ended = []
            s.ids["windows"] = String(NSApp.windows.filter { $0.isVisible }.count)
            // What the offscreen page is like just before its picture (more than a second after it loaded).
            LivePageGuards.testProbe = (Self.p19bProbe, { r in s.ids["probe"] = r as? String ?? "" })
            if let id = s.ids["media"] { p19bEditor(s.easelID)?.refreshLive([id]) }
        }
        step { [self] done in waitUntil({ s.ended.contains { $0.block == s.ids["media"] } }, timeout: 25) { done() } }
        wait(1.5)
        run { [self] in
            LivePageGuards.testProbe = nil
            let label = s.ended.first { $0.block == s.ids["media"] }?.label
            check(cap("media")?.live != nil && label == "picture", "p19b: the media page's live Capture refreshed (\(label ?? "no refresh ended"))")
            let probe = (s.ids["probe"]?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            func v(_ k: String) -> String { probe[k] ?? "-" }
            note("p19b: the offscreen media page, just before its picture: \(s.ids["probe"] ?? "no answer")")
            check(v("guard") == "true", "p19b: the offscreen page's guards ran before its own scripts")
            let refused = ["false", "absent"]   // replaced by the guards, or not there at all in this engine
            check(refused.contains(v("gum")) && refused.contains(v("gdm")) && refused.contains(v("geo")) && refused.contains(v("notif")),
                  "p19b: the offscreen page's camera, screen, location and notification APIs are Airc's refusals, not the browser's")
            check(v("play") == "false" && v("audioPaused") == "true" && v("videoPaused") == "true", "p19b: …its media doesn't play (audio \(v("audioPaused")), video \(v("videoPaused")) paused)")
            check(v("open") == "false" && v("alert") == "false", "p19b: …it opens no window and shows no dialog (window.open and alert are Airc's)")
            check(String(NSApp.windows.filter { $0.isVisible }.count) == s.ids["windows"] && NSApp.windows.filter { $0 is LiveCaptureWindow && $0.isVisible }.isEmpty,
                  "p19b: no window appeared or stayed behind")
        }

        // MARK: Live: a stale Live block refreshes when its Easel opens
        run { [self] in
            guard let e = p19bEditor(s.easelID), let id = s.ids["a"], var live = e.document.liveSource(id) else { return }
            live.refreshedAt = Date().addingTimeInterval(-EaselLivePolicy.staleAfter - 60)
            // As if the last refresh was long ago (the state a relaunch reads).
            var d = e.document
            d.setLive(live, for: id)
            e.setLive(d)
            s.ended = []
            if let t = try? c.store.openTab(url: "about:blank", inSpace: c.currentSpaceID, title: "elsewhere") {
                s.ids["blank"] = t.id
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
        }
        wait(0.5)
        run { [self] in c.show(s.easelTab, focus: true) }
        step { [self] done in waitUntil({ s.ended.contains { $0.block == s.ids["a"] } }, timeout: 25) { done() } }
        run { [self] in
            check(s.ended.first { $0.block == s.ids["a"] }?.label == "picture" && s.ended.allSatisfy { $0.block == s.ids["a"] || $0.block == s.ids["z"] },
                  "p19b: opening the Easel refreshes its stale Live Capture (and only what's due: \(s.ended.map(\.label)))")
            if let t = s.ids["blank"] { c.closeTab(t) }
        }

        }
        if ui {
        // MARK: Interact: double-click makes it the real page; a click in it counts; Esc pictures it again
        run { [self] in
            guard let e = p19bEditor(s.easelID), let id = s.ids["a"], let b = e.document.block(id) else { return }
            e.selection = []
            e.view.canvas.restoreViewport(EaselViewport(centerX: b.frame.midX, centerY: b.frame.midY, zoom: 1))
            s.ids["a-asset"] = cap("a")?.asset
        }
        wait(0.3)
        step { [self] done in
            guard let e = p19bEditor(s.easelID), let b = block("a") else { return done() }
            let p = e.view.canvas.windowPoint(plane: b.frame.center)
            // Posted, never sent: a view's own tracking loop must find its mouse-up in the queue.
            for (type, n) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
                if let ev = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                               context: nil, eventNumber: 0, clickCount: n, pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(ev, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
        }
        step { [self] done in waitUntil({ EaselInteraction.current?.page?.isLoading == false }, timeout: 10) { done() } }
        wait(1.0)
        run { [self] in
            let i = EaselInteraction.current
            check(i != nil && i?.pageView?.window === c.window && i?.pageView?.isHiddenOrHasHiddenAncestor == false,
                  "p19b: double-clicking a live Capture puts the real page over it")
        }
        // A click in it reaches the page (the region is its #card, which counts clicks): engine input, as the agent
        // drivers deliver it (Chromium's DevTools Input events; WebKit events handed to its web view).
        step { [self] done in
            guard let i = EaselInteraction.current, let page = i.page else { return done() }
            let x = i.source.rect.midX - i.source.scrollX, y = i.source.rect.midY - i.source.scrollY
            p19bPageMouse(page, [(x, y), (x, y)], zoom: i.source.zoom) {
                page.evaluate("document.getElementById('clicks').textContent") { r in
                    self.check("\(r ?? "-")" == "1", "p19b: a click in the interacting page reaches it (its counter reads \(r ?? "-"))")
                    done()
                }
            }
        }
        // Esc through the app's key path: the key monitor ends it before the page sees it.
        p19bKey("\u{1b}", 53)
        step { [self] done in waitUntil({ EaselInteraction.current == nil && cap("a")?.asset != s.ids["a-asset"] }, timeout: 6) { done() } }
        run { [self] in
            check(EaselInteraction.current == nil && cap("a")?.asset != s.ids["a-asset"], "p19b: Esc ends it and pictures the region as the page is now")
            check(p19bEditor(s.easelID)?.view.subviews.contains { $0.accessibilityIdentifier() == "easel.live.interaction" } != true,
                  "p19b: the page is gone from the board")
        }

        // MARK: A link dragged out of the page (the engine's own drag) drops on the canvas as a link card
        run { [self] in
            guard let e = p19bEditor(s.easelID), let id = s.ids["a"] else { return }
            EaselInteraction.begin(e, blockID: id)
        }
        step { [self] done in waitUntil({ EaselInteraction.current?.page?.isLoading == false }, timeout: 10) { done() } }
        wait(1.0)
        step { [self] done in
            guard let i = EaselInteraction.current, let page = i.page, let e = p19bEditor(s.easelID) else { check(false, "p19b link drag: the page is up"); return done() }
            // Bring the link into the region: it sits just under the card.
            page.evaluate("var a=document.getElementById('link'); a.style.top='\(Int(i.source.rect.y + 60))px'; a.style.left='\(Int(i.source.rect.x + 20))px'; true") { _ in
                let dragPB = NSPasteboard(name: .drag)
                let before = dragPB.changeCount
                let x = i.source.rect.x + 50 - i.source.scrollX, y = i.source.rect.y + 80 - i.source.scrollY
                let path = (0...8).map { k in (x + Double(k) * 6, y - Double(k) * 4) }
                let target = e.view.canvas.windowPoint(plane: EaselPoint((self.block_frame(e, s.ids["a"])?.maxX ?? 0) + 200, self.block_frame(e, s.ids["a"])?.midY ?? 0))
                self.p19bPageMouse(page, path, zoom: i.source.zoom) {
                    self.waitUntil({ dragPB.changeCount != before }, timeout: 2) {
                        let url = (dragPB.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString ?? dragPB.string(forType: .URL) ?? dragPB.string(forType: .string)
                        let ours = dragPB.changeCount != before && url == "https://example.com/dragged-from-page"
                        // Never the pasteboard's contents in the log: another app's drag can be anything.
                        self.check(ours, "p19b link drag: the engine drags the page's link out (its drag pasteboard \(ours ? "holds the link" : dragPB.changeCount == before ? "didn't change" : "holds something else"))")
                        guard ours else { return done() }
                        // No event-posting access on the build Mac (as W10): the drop goes to the canvas's own drop handler with
                        // that real drag pasteboard, at a point beside the block.
                        let before = e.document.blocks.count
                        let info = P04DragInfo(dragPB, at: target, in: self.c.window)   // ParityP04DropCheck.swift's
                        _ = e.view.canvas.draggingEntered(info)
                        let ok = e.view.canvas.performDragOperation(info)
                        let card = e.document.stacked.last
                        if case .link(let l)? = card?.content {
                            self.check(ok && e.document.blocks.count == before + 1 && l.url == "https://example.com/dragged-from-page",
                                       "p19b link drag: dropped on the canvas it becomes a link card (\(l.title ?? "-"))")
                        } else { self.check(false, "p19b link drag: the drop made a link card") }
                        done()
                    }
                }
            }
        }
        run { [self] in EaselInteraction.current?.end(capture: false) }
        wait(0.5)

        // MARK: A sidebar row dragged onto the Easel (the sidebar's own drag loop) becomes a link card
        run { [self] in
            guard let t = try? c.store.openTab(url: base + "/live/row", inSpace: c.currentSpaceID, background: true, activate: false, title: "Row page") else { return }
            s.ids["row"] = t.id
            c.reloadAll(animated: false)
            c.show(s.easelTab, focus: true)
        }
        wait(0.6)
        step { [self] done in
            guard let page = c.pageView(for: c.currentSpaceID), let rowID = s.ids["row"], let row = todayRow(rowID, in: page), let e = p19bEditor(s.easelID) else {
                check(false, "p19b row drag: the page's row shows"); return done()
            }
            let before = e.document.blocks.count
            let start = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
            let canvas = e.view.canvas
            let end = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY - 60), to: nil)
            drag(from: start, to: end, hold: 0.25) {
                self.waitUntil({ e.document.blocks.count > before }, timeout: 2) {
                    let card = e.document.stacked.last
                    if case .link(let l)? = card?.content {
                        self.check(l.url == self.c.store.tab(rowID)?.url && self.c.store.tab(rowID) != nil,
                                   "p19b row drag: a Today row dragged onto the Easel becomes a link card of its page (\(l.title ?? "-")), the tab stays")
                    } else {
                        self.check(false, "p19b row drag: the drop made a link card (\(e.document.blocks.count - before) new blocks)")
                    }
                    done()
                }
            }
        }

        // MARK: Private windows: their pages never become live Captures
        var privateWindow: PrivateWindowController?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { x in
                privateWindow = x
                _ = x?.openPage(URL(string: base + "/live/private"))
                done()
            }
        }
        step { [self] done in waitUntil({ privateWindow?.capturePages.first?.isLoading == false }, timeout: 10) { done() } }
        run { [self] in
            guard let x = privateWindow, let page = x.capturePages.first else { return check(false, "p19b private: a private window's page loads") }
            check(c.profiles.profileID(for: page.profile) == nil, "p19b private: a private page has no Airc profile, so no live source can name one")
            CaptureSession.toggle(x)
        }
        step { [self] done in waitUntil({ privateWindow.flatMap { CaptureSession.active(in: $0.window) }?.picturesReady == true }, timeout: 8) { done() } }
        run { [self] in
            guard let x = privateWindow, let session = CaptureSession.active(in: x.window) else { return check(false, "p19b private: Capture starts there") }
            session.toggleFullPage()
            let blocks = doc.blocks.count
            check(session.addToEasel(s.easelID) == nil && doc.blocks.count == blocks, "p19b private: its Capture can't go onto an Easel at all")
            session.cancel()
            x.closeWindow()
        }
        wait(0.5)

        // MARK: Splits: never an Easel (⌥-click, menus, New Split View)
        run { [self] in
            guard let t = try? c.store.openTab(url: base + "/live/split", inSpace: c.currentSpaceID, title: "Split page") else { return }
            s.ids["split-page"] = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        wait(0.6)
        step { [self] done in
            guard let page = c.pageView(for: c.currentSpaceID), let item = c.store.tab(s.easelTab)?.itemID,
                  let row = page.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == s.easelTab })
                    ?? page.subviews.flatMap({ $0.subviews }).compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == s.easelTab }) else {
                // The pinned row may be drawn elsewhere: ⌥-click through the action itself.
                let entry = c.store.item(c.store.tab(s.easelTab)?.itemID ?? "").map { SidebarEntry.pinned($0, depth: 0, c.store.tab(s.easelTab)) }
                let splits = c.store.state.splits.count
                if let entry { c.optionClickSplit(entry) }
                check(c.store.state.splits.count == splits && c.store.split(containing: s.easelTab) == nil, "p19b splits: ⌥-click on an Easel's row makes no split")
                return done()
            }
            _ = item
            let splits = c.store.state.splits.count
            page.layoutSubtreeIfNeeded()
            let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
            // A real ⌥-click from the UI driver when the run has it (checkreal2: a posted pair can lose its mouse-up, and
            // the row's drag loop then waits inside the mouse-down while later steps run in it, until quit). Otherwise
            // the posted pair; never sent, since the loop runs inside the mouse-down and reads the release from the queue.
            p19bRowClick(row, at: p, mods: "opt") { how in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.check(self.c.store.state.splits.count == splits && self.c.store.split(containing: s.easelTab) == nil,
                               "p19b splits: ⌥-click on an Easel's row makes no split (no blank pane; \(how))")
                    let open = self.c.dragsInProgress
                    guard open > 0, how.hasPrefix("posted") else {
                        self.check(open == 0 && !how.contains("refused") && !how.contains("failed"), "p19b splits: the ⌥-click's press ended with its release (\(how); presses open \(open))")
                        return done()
                    }
                    // A posted pair can lose its release before the row's loop reads it (checkreal2; p19d's quit hang):
                    // the loop's guard ends a press that never had the button down after SpacePageView.quietLimit.
                    let t0 = CACurrentMediaTime()
                    self.waitUntil({ self.c.dragsInProgress == 0 }, timeout: SpacePageView.quietLimit + 2) {
                        self.check(self.c.dragsInProgress == 0, String(format: "p19b splits: the posted ⌥-click lost its release; the press loop's guard ended it %.1f s later (open %d)", CACurrentMediaTime() - t0 + 0.5, self.c.dragsInProgress))
                        done()
                    }
                }
            }
        }
        // checkreal2: the sidebar's press loop ends by itself when its release never arrives. HID button state is
        // stood in for (a posted press can't set it); the press is posted with no mouse-up after it.
        func easelRow() -> (SpacePageView, TabRowView)? {
            guard let page = c.pageView(for: c.currentSpaceID),
                  let row = page.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == s.easelTab })
                    ?? page.subviews.flatMap({ $0.subviews }).compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == s.easelTab }) else { return nil }
            return (page, row)
        }
        func postPress(_ row: TabRowView, buttons: (() -> Bool)?) -> Int {
            SpacePageView.testLeftButtonDown = buttons
            let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
            if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(e, atStart: false)
            }
            return SpacePageView.releasesLost
        }
        func order() -> [String] { c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id) + c.store.state.splits.keys.sorted() }
        step { [self] done in
            guard let row = easelRow()?.1 else { check(false, "p19b press guard: the Easel's row shows"); return done() }
            var down = true
            let before = order(), lost = postPress(row, buttons: { down })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let held = self.c.dragsInProgress
                down = false
                let up = CACurrentMediaTime()
                self.waitUntil({ self.c.dragsInProgress == 0 }, timeout: 3) {
                    let after = CACurrentMediaTime() - up
                    self.check(held == 1 && self.c.dragsInProgress == 0 && SpacePageView.releasesLost == lost + 1 && after < 1,
                               String(format: "p19b press guard: a held press whose release never comes ends %.2f s after the button is up (held %d, open %d)", after, held, self.c.dragsInProgress))
                    self.check(order() == before, "p19b press guard: …as Esc does: nothing moves")
                    SpacePageView.testLeftButtonDown = nil
                    done()
                }
            }
        }
        wait(0.3)
        step { [self] done in
            guard let row = easelRow()?.1 else { return done() }
            let lost = postPress(row, buttons: { false }), t0 = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let open = self.c.dragsInProgress
                self.waitUntil({ self.c.dragsInProgress == 0 }, timeout: SpacePageView.quietLimit + 2) {
                    let after = CACurrentMediaTime() - t0
                    self.check(open == 1 && self.c.dragsInProgress == 0 && SpacePageView.releasesLost == lost + 1
                               && after >= SpacePageView.quietLimit - 0.5,
                               String(format: "p19b press guard: a posted press with no release (no button ever down) ends after %.1f s without events (open at 2 s: %d)", after, open))
                    SpacePageView.testLeftButtonDown = nil
                    done()
                }
            }
        }
        // Diagnostic (AIRC_P19B_PRESS_PROBE=<n>): n posted ⌥-click pairs on the row, each with the main window key, with
        // another of the app's windows key, and right after that window closed; how many lost their release.
        if let n = ProcessInfo.processInfo.environment["AIRC_P19B_PRESS_PROBE"].flatMap(Int.init), n > 0 {
            for mode in ["key", "other-key", "after-close"] {
                var stuck = 0, rows = 0
                for _ in 0..<n {
                    var other: NSWindow?
                    if mode != "key" {
                        run {
                            let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
                            w.isReleasedWhenClosed = false
                            w.makeKeyAndOrderFront(nil)
                            other = w
                        }
                        wait(0.3)
                        if mode == "after-close" { run { other?.close() } }
                    }
                    step { [self] done in
                        guard let row = easelRow()?.1 else { return done() }
                        rows += 1
                        let lost = SpacePageView.releasesLost
                        let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
                        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                                NSApp.postEvent(e, atStart: false)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            guard self.c.dragsInProgress > 0 else { return done() }
                            stuck += 1
                            self.waitUntil({ self.c.dragsInProgress == 0 }, timeout: SpacePageView.quietLimit + 2) {
                                self.note("p19b probe \(mode): a posted ⌥-click pair lost its release; the guard ended it (\(SpacePageView.releasesLost - lost))")
                                done()
                            }
                        }
                    }
                    run { other?.close(); other = nil }
                    wait(0.2)
                }
                run { [self] in note("p19b probe \(mode): \(stuck) of \(rows) posted ⌥-click pairs lost their release (key \(c.window.isKeyWindow), active \(NSApp.isActive))") }
            }
        }
        run { [self] in
            if let item = c.store.tab(s.easelTab)?.itemID.flatMap({ c.store.item($0) }) {
                check(!c.optionClickSplits(.pinned(item, depth: 0, c.store.tab(s.easelTab))), "p19b splits: an Easel's row menu has no Open in Split View")
            }
            check((try? c.store.createSplit([s.ids["split-page"] ?? "", s.easelTab], inSpace: c.currentSpaceID)) == nil, "p19b splits: the store refuses an Easel pane")
            c.show(s.easelTab, focus: true)
            let splits = c.store.state.splits.count
            c.newSplitView()
            check(c.store.state.splits.count == splits && c.shownTabID == s.easelTab, "p19b splits: New Split View on an Easel does nothing")
            c.closeCommandBar()
            check(c.splitCommandActions().isEmpty, "p19b splits: the Command Bar offers no split for an Easel")
            if let t = s.ids["split-page"] { c.closeTab(t) }
        }

        // MARK: Duplicate: the copy is an Easel of its own
        run { [self] in
            EaselCenter.shared.saveAll(wait: true)
            guard let dup = try? c.store.duplicateTab(s.easelTab), let copy = EaselURL.easelID(dup.url) else { return check(false, "p19b duplicate: the row duplicates") }
            let r = EaselCenter.shared.files.load(copy)
            check(copy != s.easelID && r.source == .document && r.document.blocks.count == doc.blocks.count && r.document.title == doc.title,
                  "p19b duplicate: a duplicated Easel row is a new Easel with the same \(r.document.blocks.count) blocks")
            let assets = doc.assets
            check(assets.allSatisfy { a in EaselCenter.shared.files.assetURL(copy, a).map { FileManager.default.fileExists(atPath: $0.path) } == true },
                  "p19b duplicate: …and its pictures")
            s.ids["copy"] = copy
            c.reloadAll(animated: false)
        }

        }
        // On disk; the state the relaunch reads; the board's picture.
        run { [self] in
            EaselCenter.shared.saveAll(wait: true)
            check(NSApp.windows.filter { $0 is LiveCaptureWindow }.allSatisfy { !$0.isVisible } && EaselLiveCenter.shared.activeCount == 0,
                  "p19b: no offscreen page or window is left (\(EaselLiveCenter.shared.loadersMade) pages made in all)")
            let state: [String: Any] = ["easel": s.easelID, "a": s.ids["a"] ?? "", "auth": s.ids["auth"] ?? "", "rect": [cap("a")?.live?.rect.x ?? 0, cap("a")?.live?.rect.y ?? 0]]
            if !ui { try? JSONSerialization.data(withJSONObject: state).write(to: AppPaths.dataDirectory.appendingPathComponent(Self.p19bState)) }
            server?.stop()
            EaselLiveCenter.shared.onEnded = nil
            c.window.makeFirstResponder(nil)
            c.show(s.easelTab, focus: false)
            p19bEditor(s.easelID)?.selection = []
            p19bEditor(s.easelID)?.view.canvas.zoomToFit(animated: false)
        }
        wait(0.8)
        capture(ui ? "p19b-ui" : "p19b-live")
    }

    /// Mouse input into a page as its engine takes it (the agent drivers' way): a press at the first point, moves (button
    /// held) through the rest, a release at the last. Points in the page viewport's CSS pixels.
    private func p19bPageMouse(_ page: EngineTab, _ points: [(Double, Double)], zoom: Double, _ done: @escaping () -> Void) {
        guard let first = points.first, let last = points.last else { return done() }
        #if canImport(AircCore)
        if let t = page as? ChromiumTab {
            var events: [[String: Any]] = [["type": "mousePressed", "x": first.0, "y": first.1, "button": "left", "buttons": 1, "clickCount": 1]]
            for p in points.dropFirst().dropLast() { events.append(["type": "mouseMoved", "x": p.0, "y": p.1, "button": "left", "buttons": 1]) }
            events.append(["type": "mouseReleased", "x": last.0, "y": last.1, "button": "left", "buttons": 0, "clickCount": 1])
            func send(_ k: Int) {
                guard k < events.count, !t.isClosed else { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
                t.core.devToolsCall("Input.dispatchMouseEvent", params: events[k], timeout: 5) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { send(k + 1) }
                }
            }
            return send(0)
        }
        #endif
        guard let v = (page as? WebKitTab)?.webView, let w = v.window else { return done() }
        func event(_ type: NSEvent.EventType, _ p: (Double, Double)) -> NSEvent? {
            let py = CGFloat(p.1 * zoom)
            let local = NSPoint(x: CGFloat(p.0 * zoom), y: v.isFlipped ? py : v.bounds.height - py)
            return NSEvent.mouseEvent(with: type, location: v.convert(local, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        var steps: [() -> Void] = [{ if let e = event(.leftMouseDown, first) { v.mouseDown(with: e) } }]
        for p in points.dropFirst().dropLast() { steps.append { if let e = event(.leftMouseDragged, p) { v.mouseDragged(with: e) } } }
        steps.append { if let e = event(.leftMouseUp, last) { v.mouseUp(with: e) } }
        func run(_ k: Int) {
            guard k < steps.count else { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done) }
            steps[k]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { run(k + 1) }
        }
        run(0)
    }

    private func block_frame(_ e: EaselEditor, _ id: String?) -> EaselRect? { id.flatMap { e.document.block($0)?.frame } }

    // MARK: Relaunch

    private func parityP19bRelaunch() {
        var state: [String: Any] = [:]
        p19bSetup()
        run { [self] in
            state = (try? Data(contentsOf: AppPaths.dataDirectory.appendingPathComponent(Self.p19bState)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let id = state["easel"] as? String ?? ""
            // No server now: nothing may refresh on its own while this runs (the stale check would fail anyway).
            guard let t = c.store.tabs(showingEasel: id).first else { return check(false, "p19b relaunch: the Easel's row is there") }
            c.show(t.id, focus: true)
        }
        wait(0.6)
        run { [self] in
            let id = state["easel"] as? String ?? ""
            let d = EaselCenter.shared.existingEditor(id)?.document
            let a = d.flatMap { $0.liveSource(state["a"] as? String ?? "") }
            let auth = d.flatMap { $0.liveSource(state["auth"] as? String ?? "") }
            let rect = state["rect"] as? [Double] ?? []
            check(a != nil && a?.mode == .live && rect.count == 2 && abs((a?.rect.x ?? 0) - rect[0]) < 0.01 && abs((a?.rect.y ?? 0) - rect[1]) < 0.01,
                  "p19b relaunch: the live Capture is still live, its region as it was")
            check(auth?.status == .signedOut, "p19b relaunch: the signed-out block still says so")
        }
        capture("p19b-relaunch")
    }
}

#endif
