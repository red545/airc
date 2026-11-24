// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentlights`: while an outside MCP app works in Airc (the real `airc-mcp` helper, like agentspike), nothing
/// of ours, and nothing above normal window level from anyone, covers a browser window's close / minimize / zoom
/// buttons, in the main window and in a second one made from a moved-out tab. Per window, at three moments (working,
/// "is using Airc" banner, Watch open): each button is shown, AppKit's hit test lands on it, the window server's
/// front-most window at its centre is ours, and our window's own picture there has the button's colour; every window
/// (any process) over the top-left corner is listed. Then the "✦ <app>" pill: in the sidebar header next to the
/// traffic lights, never over them; a click opens what it means with Watch and Stop; Stop ends the app's work. And
/// real clicks: minimize and close on the second window while the agent works. Real driver clicks with the UI driver
/// in a dedicated session; else posted, said so.
extension SnapshotRunner {
    func agentLightsScenario() {
        let k = AgentLightsCheck(runner: self)
        step { done in k.setUp(done) }
        step { done in k.startAgent(done) }
        step { done in k.measureAll("working", done) }
        step { done in k.caseBanner(done) }
        step { done in k.caseWatch(done) }
        step { done in k.casePill(done) }
        step { done in k.caseMinimizeClose(done) }
        step { done in k.caseStop(done) }
        run { k.finish() }
    }
}

final class AgentLightsCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var c2: WindowController?
    var engine = "?"
    var real = false
    var server: LocalPageServer?
    var port: UInt16 = 0
    var client: SpikeMCPClient?
    var working = false
    var windowID: Int?
    var calls = 0

    init(runner: SnapshotRunner) { self.runner = runner }

    var base: String { "http://127.0.0.1:\(port)" }
    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "agentlights \(engine): " + what) }
    func env(_ what: String) { note("FAIL-ENV agentlights \(engine): " + what) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    func wait(_ cond: @escaping () -> Bool, _ t: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: t, then: then) }

    static let page = "<title>Fixture work</title><style>body{margin:0;font:16px sans-serif}#b{width:300px;height:200px;background:#2a7}</style><h1>Work page</h1><div id=b></div><p>Some text to read.</p>"

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        let e = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && e["AIRC_UI_DEDICATED_SESSION"] == "1" && e["AIRC_LA_AS_OWNER"] == "1"
        note("agentlights \(engine): input \(real ? "real (UI driver)" : "posted")")
        let s = LocalPageServer(responses: ["/work.html": LocalPageServer.Page(body: Self.page), "/mine.html": LocalPageServer.Page(body: "<title>My page</title><h1>Mine</h1>"),
                                            "/other.html": LocalPageServer.Page(body: "<title>Other page</title><h1>Other</h1>")])
        server = s
        s?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fixture server on loopback")
            AgentCenter.shared.app = app
            AgentCenter.shared.enableForCheck(grants: [], http: false)
            AgentCenter.shared.approvals.automatic = true
            let profile = c.store.profile(ofSpace: c.currentSpaceID)
            app.profiles.whenLoaded(profile.id, { [self] _ in
                c.navigate(to: URL(string: "\(base)/mine.html")!, newTab: true)
                c.navigate(to: URL(string: "\(base)/other.html")!, newTab: true)
                after(1.0) { [self] in
                    // A second window, from a tab moved out of the first (what the person had).
                    guard let tab = c.shownTabID, let w2 = c.openInNewWindow(tab) else { check(false, "a tab moves out into a second window"); return done() }
                    c2 = w2
                    after(1.5) { [self] in
                        check(app.controllers.count >= 2, "two browser windows (\(app.controllers.count))")
                        if w2.sidebarHidden {
                            // winclose's fix: a moved-out window shouldn't inherit a hidden sidebar (its lights hide with it).
                            note("agentlights \(engine): the moved-out window opened with its sidebar hidden (winclose's case); showing it")
                            w2.toggleSidebar()
                        }
                        // Apart, so neither covers the other's corner.
                        if let screen = c.window.screen ?? NSScreen.main {
                            let v = screen.visibleFrame
                            c.window.setFrame(NSRect(x: v.minX + 20, y: v.maxY - 760, width: 1000, height: 740), display: true)
                            w2.window.setFrame(NSRect(x: v.minX + 520, y: v.maxY - 860, width: 1000, height: 740), display: true)
                        }
                        after(0.8) { done() }
                    }
                }
            }, failed: { [self] in check(false, "the profile loads"); done() })
        }
    }

    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/airc-mcp").path }

    /// The outside app: the bundled helper as an MCP client, opening a page and working on it until Stop.
    func startAgent(_ done: @escaping () -> Void) {
        let profile = c.store.profile(ofSpace: c.currentSpaceID)
        let cl = SpikeMCPClient(helper: helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", "agentlights-check", "--profile", profile.name])
        client = cl
        guard cl.start() else { check(false, "the airc-mcp helper starts"); return done() }
        cl.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "agentlights-check", "version": "1"]]) { [self] m in
            cl.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            check(m["result"] != nil, "an outside MCP app connects through the helper")
            cl.call("open_window", ["url": "\(base)/work.html"]) { [self] r, _ in
                windowID = SpikeMCPClient.json(r)["window"] as? Int
                check(windowID != nil && !SpikeMCPClient.isError(r), "it opens an agent window on the work page (\(windowID.map(String.init) ?? SpikeMCPClient.text(r)))")
                working = true
                keepWorking()
                after(1.5, done)
            }
        }
    }

    /// Screenshots and scrolls, one after another, while `working`.
    func keepWorking() {
        guard working, let cl = client else { return }
        let tool = calls % 2 == 0 ? "screenshot" : "scroll"
        let args: [String: Any] = tool == "scroll" ? ["coordinate": [200, 200], "scroll_direction": calls % 4 == 1 ? "down" : "up", "scroll_amount": 2] : [:]
        calls += 1
        cl.call(tool, args, timeout: 20) { [weak self] _, _ in self?.after(0.3) { self?.keepWorking() } }
    }

    // MARK: The traffic lights of one window

    static let buttons: [(NSWindow.ButtonType, String)] = [(.closeButton, "close"), (.miniaturizeButton, "minimize"), (.zoomButton, "zoom")]

    /// Quartz global point (top-left origin) for a point in `w`'s base coordinates.
    func quartz(_ p: NSPoint, in w: NSWindow) -> CGPoint {
        let s = w.convertPoint(toScreen: p)
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: s.x.rounded(), y: (h - s.y).rounded())
    }

    func center(_ b: NSButton) -> NSPoint { b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil) }

    /// Our window's own picture (the window server's, no Screen Recording needed).
    func windowImage(_ w: NSWindow) -> CGImage? {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1",
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        return unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue()
    }

    /// Everything over `w`'s top-left corner, front to back (any process): who, level, frame.
    func windowsOverCorner(_ w: NSWindow) -> (above: [[String: Any]], all: [String]) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
        let h = NSScreen.screens.first?.frame.maxY ?? 0
        let f = w.frame
        let corner = CGRect(x: f.minX, y: h - f.maxY, width: 170, height: 56)
        var above: [[String: Any]] = []
        var all: [String] = []
        var seenOurs = false
        for info in list {
            let num = info[kCGWindowNumber as String] as? Int ?? -1
            if num == w.windowNumber { seenOurs = true; continue }
            guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            guard r.intersects(corner), r.width > 1, r.height > 1 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let name = info[kCGWindowName as String] as? String ?? ""
            let pid = info[kCGWindowOwnerPID as String] as? Int ?? -1
            // macOS 26 keeps a full-screen Notification Centre window at layer 21 on screen at all times (it comes straight
            // back after a NotificationCenter restart). It isn't an overlay of ours and takes no clicks: log it, don't count it.
            let systemNotificationLayer = pid != Int(getpid()) && layer == 21
                && (owner == "Notification Centre" || owner == "Notification Center")
            all.append("\(seenOurs ? "below" : "ABOVE") \(owner)\(pid == Int(getpid()) ? " (ours)" : "") layer \(layer) \(name.isEmpty ? "" : "“\(name)” ")\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))\(systemNotificationLayer ? " (ignored: system Notification Centre layer)" : "")")
            if !seenOurs, !systemNotificationLayer { above.append(["owner": owner, "layer": layer, "pid": pid, "rect": r]) }
        }
        return (above, all)
    }

    /// The three buttons of `w` at `moment`: shown, hit, front-most, coloured; nothing of ours over them.
    func measure(_ wc: WindowController, _ label: String, _ moment: String) {
        let w = wc.window
        let tag = "[\(label), \(moment)]"
        let frameView = w.contentView?.superview
        let img = windowImage(w)
        let scale = img.map { CGFloat($0.width) / w.frame.width } ?? 1
        let corner = windowsOverCorner(w)
        note("agentlights \(engine): \(tag) windows over the top-left corner: \(corner.all.isEmpty ? "none" : corner.all.joined(separator: "; ")) (key \(w.isKeyWindow), active \(NSApp.isActive))")
        var lights: [NSRect] = []
        for (type, name) in Self.buttons {
            guard let b = w.standardWindowButton(type) else { check(false, "\(tag) \(name) button exists"); continue }
            let shown = !b.isHiddenOrHasHiddenAncestor && b.alphaValue > 0.5 && b.window === w
            check(shown, "\(tag) the \(name) button is shown (hidden \(b.isHiddenOrHasHiddenAncestor), alpha \(b.alphaValue))")
            let mid = center(b)
            lights.append(b.convert(b.bounds, to: nil))
            let hit = frameView.flatMap { $0.hitTest($0.convert(mid, from: nil)) }
            check(hit === b || hit?.isDescendant(of: b) == true, "\(tag) … a click at its centre reaches it (hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"))")
            let screenPoint = w.convertPoint(toScreen: mid)
            let top = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            let q = quartz(mid, in: w)
            let over = corner.above.filter { ($0["rect"] as? CGRect)?.contains(q) == true }
            let oursOver = over.filter { ($0["pid"] as? Int) == Int(getpid()) || (($0["layer"] as? Int) ?? 0) != 0 }
            if top == w.windowNumber {
                check(true, "\(tag) … ours is the front-most window at its centre")
            } else if !over.isEmpty, oursOver.isEmpty {
                env("\(tag) … another app's normal window is in front at the \(name) button: \(over.map { "\($0["owner"] ?? "?")" }.joined(separator: ", "))")
            } else {
                check(false, "\(tag) … the front-most window at its centre is #\(top), not ours (#\(w.windowNumber)): \(oursOver.map { "\($0["owner"] ?? "?") layer \($0["layer"] ?? 0)" }.joined(separator: ", "))")
            }
            check(oursOver.isEmpty, "\(tag) … nothing of Airc's and no indicator/overlay window is over it (\(oursOver.count))")
            if let img, let px = AgentImages.pixel(img, x: Int(mid.x * scale), y: Int((w.frame.height - mid.y) * scale)) {
                // Key window: red / yellow / green; otherwise AppKit's grey. Either way the button's own colour, not a page.
                let coloured: Bool
                switch type {
                case .closeButton: coloured = px.r > 180 && px.g < 140
                case .miniaturizeButton: coloured = px.r > 180 && px.g > 120 && px.b < 120
                default: coloured = px.g > 150 && px.r < 150
                }
                let grey = abs(px.r - px.g) < 18 && abs(px.g - px.b) < 18
                check(w.isKeyWindow ? coloured : (coloured || grey), "\(tag) … the window's picture shows the \(name) button (rgb \(px.r),\(px.g),\(px.b), key \(w.isKeyWindow))")
            }
        }
        // Our own views over the lights: the toast, Watch, the pill.
        let union = lights.reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -2, dy: -2)
        if let t = wc.toast.shownText {
            let r = wc.toast.convert(wc.toast.bounds, to: nil)
            check(!r.intersects(union), "\(tag) the “\(t)” toast isn't over the traffic lights (\(NSStringFromRect(r)))")
        }
        if let v = wc.sidebar.agents.watch {
            let r = v.convert(v.bounds, to: nil)
            check(!r.intersects(union), "\(tag) Watch isn't over the traffic lights (\(NSStringFromRect(r)))")
        }
        let pill = wc.sidebar.header.agentPill
        if !pill.isHidden, pill.window === w {
            let r = pill.convert(pill.bounds, to: nil)
            check(!r.intersects(union) && r.maxY <= union.minY && r.width >= 120, "\(tag) the ✦ bar is its own row under the traffic lights, not over them (\(NSStringFromRect(r)) vs \(NSStringFromRect(union)))")
            if let field = wc.sidebar.pager.frame as NSRect? {
                let f = wc.sidebar.convert(field, to: nil)
                check(f.maxY <= r.minY + 0.5, "\(tag) … and the address field moved down under it (pager top \(Int(f.maxY)), bar bottom \(Int(r.minY)))")
            }
        }
    }

    func windows() -> [(WindowController, String)] {
        [(c, "main window")] + (c2.map { [($0, "moved-out window")] } ?? [])
    }

    /// Front each window in turn (dedicated session: key; else just ordered front) and measure it.
    func measureAll(_ moment: String, _ done: @escaping () -> Void) {
        var list = windows()
        func next() {
            guard !list.isEmpty else { return done() }
            let (wc, label) = list.removeFirst()
            front(wc) { [self] in measure(wc, label, moment); next() }
        }
        next()
    }

    func front(_ wc: WindowController, _ then: @escaping () -> Void) {
        if real { NSApp.activate(ignoringOtherApps: true); wc.window.makeKeyAndOrderFront(nil) } else { wc.window.orderFront(nil) }
        wait({ !self.real || wc.window.isKeyWindow }, 3) { self.after(0.4, then) }
    }

    // MARK: The banner, Watch

    func caseBanner(_ done: @escaping () -> Void) {
        // "<app> is using Airc · <site>" goes to every window of the profile once the page is named; force one in a
        // window whose card isn't laid out (zero), as a just-made window has it.
        let shown = AgentActivity.shared.banners.last
        note("agentlights \(engine): banner \(shown ?? "none yet")")
        // watchfix: the real "is using Airc" banner can still be up (agent windows now install a page part first, so it
        // comes a little later): the zero-rect case starts once no toast shows, waiting at most 12 s (logged).
        let t0 = Date()
        wait({ self.c.toast.shownText == nil }, 12) { [self] in
            note("agentlights \(engine): banner cleared after \(Int(Date().timeIntervalSince(t0) * 1000)) ms (still shown: \(c.toast.shownText ?? "none"))")
            c.toast.show("agentlights is using Airc · fixture", palette: c.currentPalette, in: .zero)
            check(c.toast.shownText == nil, "a toast for a window whose card isn't laid out yet isn't shown (centred on nothing it would sit on the traffic lights)")
            // The real banner in both windows (shown again on purpose, in case it went before the windows were measured).
            for (wc, _) in windows() { wc.toast.show("agentlights-check is using Airc · Fixture work", palette: wc.currentPalette, in: wc.card.frame, duration: 8) }
            measureAll("banner", done)
        }
    }

    func caseWatch(_ done: @escaping () -> Void) {
        guard let w2 = c2, let row = AgentActivity.shared.model.rows.first(where: { $0.isLive && $0.window == windowID }) else {
            check(false, "the agent's page has a live row for Watch"); return done()
        }
        w2.sidebar.agents.openWatch(row.id, takeKeys: false)
        wait({ w2.sidebar.agents.watch != nil }, 4) { [self] in
            check(w2.sidebar.agents.watch != nil, "Watch opens in the moved-out window")
            after(1.0) { [self] in
                front(w2) { [self] in
                    measure(w2, "moved-out window", "Watch open")
                    w2.sidebar.agents.closeWatch()
                    done()
                }
            }
        }
    }

    // MARK: The pill

    /// A real click on a view's centre, else `fallback`.
    func press(_ v: NSView?, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        guard real, let v, let w = v.window, NSApp.isActive else { fallback(); return done("posted") }
        let mid = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
        let hit = w.contentView?.superview?.hitTest(w.contentView?.superview?.convert(mid, from: nil) ?? mid)
        let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: mid), belowWindowWithWindowNumber: 0)
        note("agentlights \(engine): \(what) at \(Int(mid.x)),\(Int(mid.y)) in \(Swift.type(of: w)) #\(w.windowNumber) (key \(w.isKeyWindow), alpha \(w.alphaValue), top #\(top)); hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing")")
        let p = quartz(mid, in: w)
        UIDriverClient.run(["--click", "\(Int(p.x))", "\(Int(p.y))"]) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.env("the driver refused \(what) (\(out)); posted"); fallback(); return done("posted") }
                done("real")
            }
        }
    }

    func casePill(_ done: @escaping () -> Void) {
        let pill = c.sidebar.header.agentPill
        pill.refresh()
        check(!pill.isHidden && pill.apps.count == 1 && pill.window === c.window && pill.frame.width >= 120, "while the outside app works, the main window's sidebar shows “✦ \(pill.sentence)” (\(Int(pill.frame.width)) pt)")
        if let p2 = c2?.sidebar.header.agentPill { check(!p2.isHidden, "… and so does the moved-out window's") }
        check(pill.accessibilityLabel() == pill.sentence && pill.sentence.hasSuffix("is using Airc"), "… VoiceOver reads “\(pill.sentence)”")
        front(c) { [self] in
            press(pill, "the ✦ pill", fallback: { pill.open() }) { [self] how in
                wait({ pill.popoverView != nil }, 3) { [self] in
                    let v = pill.popoverView
                    check(v != nil, "a click on the pill opens what it means [\(how) click]")
                    if let v {
                        v.layoutSubtreeIfNeeded()
                        check(TestAnchors.view("agentpill.stop", in: v) != nil && TestAnchors.view("agentpill.watch", in: v) != nil,
                              "… with Watch and Stop")
                        if let img = runner.render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: runner.dir.appendingPathComponent("agentlights-popover-\(engine).png"))
                        }
                    }
                    shotHeader(c, "agentlights-pill")
                    // Watch from the popover, once it has finished appearing.
                    after(0.8) { [self] in press(v.flatMap { TestAnchors.view("agentpill.watch", in: $0) }, "Watch", fallback: { pill.watch() }) { [self] how in
                        wait({ self.c.sidebar.agents.watch != nil }, 4) { [self] in
                            check(c.sidebar.agents.watch != nil, "… Watch shows the agent's page [\(how) click]")
                            c.sidebar.agents.closeWatch()
                            done()
                        }
                    } }
                }
            }
        }
    }

    func shotHeader(_ wc: WindowController, _ name: String) {
        let v = wc.sidebar.header
        if let img = runner.render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png"))
        }
    }

    // MARK: Real clicks on the second window's buttons

    func caseMinimizeClose(_ done: @escaping () -> Void) {
        guard let w2 = c2 else { return done() }
        check(working && !(AgentCenter.shared.windows.isEmpty), "the outside app is still working")
        front(w2) { [self] in
            press(w2.window.standardWindowButton(.miniaturizeButton), "minimize", fallback: { w2.window.standardWindowButton(.miniaturizeButton)?.performClick(nil) }) { [self] how in
                wait({ w2.window.isMiniaturized }, 4) { [self] in
                    check(w2.window.isMiniaturized, "minimize on the moved-out window works while the agent works [\(how) click]")
                    w2.window.deminiaturize(nil)
                    wait({ !w2.window.isMiniaturized && w2.window.isVisible }, 4) { [self] in
                        front(w2) { [self] in
                            let before = app.controllers.count
                            press(w2.window.standardWindowButton(.closeButton), "close", fallback: { w2.window.standardWindowButton(.closeButton)?.performClick(nil) }) { [self] how in
                                wait({ !w2.window.isVisible }, 4) { [self] in
                                    check(!w2.window.isVisible, "close on the moved-out window closes it [\(how) click] (windows \(before) → \(app.controllers.count))")
                                    c2 = nil
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Stop

    func caseStop(_ done: @escaping () -> Void) {
        let pill = c.sidebar.header.agentPill
        front(c) { [self] in
            press(pill, "the ✦ pill", fallback: { pill.open() }) { [self] _ in
                wait({ pill.popoverView != nil }, 3) { [self] in
                    let key = pill.apps.first?.clientKey
                    after(0.8) { [self] in
                    let stop = pill.popoverView.flatMap { TestAnchors.view("agentpill.stop", in: $0) }
                    press(stop, "Stop", fallback: { pill.stop() }) { [self] how in
                        wait({ pill.isHidden && AgentPillWindows.outside() == 0 }, 6) { [self] in
                            working = false
                            check(AgentPillWindows.outside() == 0, "Stop in the pill ends the outside app's work: its agent windows close [\(how) click]")
                            check(pill.isHidden, "… and the pill goes")
                            if let key { AgentCenter.shared.allowAgain(key) }
                            done()
                        }
                    }
                    }
                }
            }
        }
    }

    func finish() {
        working = false
        client?.stop()
        if let w2 = c2 { w2.window.close() }
        server?.stop()
        runner.finish()
    }
}

enum AgentPillWindows {
    /// Agent windows of outside apps (not the Airc Agent's own run).
    static func outside() -> Int { AgentCenter.shared.windows.values.filter { $0.clientKey != AgentBridge.clientKey }.count }
}
#endif
