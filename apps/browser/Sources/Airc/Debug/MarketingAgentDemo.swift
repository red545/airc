// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AVFoundation
import AppKit
import AircKit
import CoreVideo

/// Part "aidemo" (`AIRC_MARKETING_PART=aidemo`, run on screen with real input by artifacts' record.sh): the homepage's and
/// X's Airc Agent video, recorded from the real window. The demo profile's Personal Space (made-up Favorites, pinned
/// tabs and Today tabs for this part) is on Steepwell, a made-up coffee and tea shop of our own (tools/agent-demo-shop:
/// static pages and product photos rendered from our own models, steepwell.aircbrowser.com through the engine's host
/// rules, served by MarketingServer on loopback). The person clicks ✦ in the toolbar row, uses Codex (signed in with
/// ChatGPT) from the pane's Connect card and types a task; the agent compares two kettles in its own window while the
/// pane's live card shows it, picks one with a reason, goes to payment, and Airc stops it at Pay with the approval card;
/// the person watches it from the Agents folder and allows once; the agent says what it did.
///
/// Scripted: "Codex" is the fake `codex` CLI (AgentCLIFakes.swift, app-server protocol) in a scratch folder, following the steps in
/// `script` (say / tool / hold). Every tool call is real: it goes through Airc's MCP server, which acts on the fixture
/// pages, and Airc's own risk gate asks before Pay. No real account, model or key.
///
/// The recording: the window server's picture of this window only (CGWindowListCreateImage with its window number, no
/// Screen Recording permission, nothing else on screen), 2×, ~30 fps, with the real pointer (its real position and the
/// system cursor's image) drawn in, to <snapshot dir>/aidemo/aidemo.mov (HEVC) plus timeline.json (event times for
/// the edit and captions). Pointer moves, clicks and keys are real (the UI driver).
extension SnapshotRunner {
    func mkAgentDemo(_ d: MarketingDemo) {
        let k = AgentDemo(runner: self, demo: d)
        step { done in k.setUp(done) }
        step { done in k.record(done) }
        run { k.tearDown() }
        wait(1.5)
    }
}

final class AgentDemo {
    unowned let runner: SnapshotRunner
    let demo: MarketingDemo
    var c: WindowController { runner.c }
    var app: AppDelegate { runner.app! }
    var dir: URL { runner.dir.appendingPathComponent("aidemo") }
    var cliBin = URL(fileURLWithPath: "/nonexistent")
    var recorder: WindowRecorder?
    var real = false
    let host = "http://steepwell.aircbrowser.com"
    var timeline: [[String: Any]] = []

    init(runner: SnapshotRunner, demo: MarketingDemo) { self.runner = runner; self.demo = demo }

    func note(_ s: String) { runner.note("aidemo: " + s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    func mark(_ what: String) {
        let t = recorder?.elapsed ?? 0
        timeline.append(["t": (t * 1000).rounded() / 1000, "event": what])
        note(String(format: "%6.2f s %@", t, what))
    }

    var pane: AgentPaneController? { AgentPaneController.pane(of: c) }
    var run: AgentRunCenter { .shared }

    // MARK: The task and the script

    static let task = "Compare the Pour and Rapid kettles and buy the better one for pour over coffee. Ask me before you pay."

    /// The fake Codex's steps for the task (one user turn). Coordinates are the fixture pages' fixed positions
    /// (CSS px = the agent window's screenshot pixels).
    var script: [[String: Any]] {
        let say: (String) -> [String: Any] = { ["say": $0, "every": 0.045] }
        let tool: (String, [String: Any]) -> [String: Any] = { ["tool": $0, "args": $1] }
        let hold: (Double) -> [String: Any] = { ["hold": $0] }
        // Centres from tools/agent-demo-shop/measure.py at the agent window's 1280 × 800 viewport.
        return [
            say("I'll find both kettles on Steepwell."), hold(0.5),
            tool("navigate", ["url": "\(host)/"]), hold(0.7),
            tool("left_click", ["coordinate": [932, 72]]), hold(0.4),
            tool("type", ["text": "kettle"]), hold(0.3),
            tool("key", ["text": "Return"]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.4),
            tool("read_page", ["mode": "text"]), hold(0.7),
            say("Both are here: Pour at €79 and Rapid at €64. I'll put them side by side."), hold(0.5),
            tool("left_click", ["coordinate": [136, 684]]), hold(0.7),
            tool("left_click", ["coordinate": [422, 684]]), hold(0.9),
            tool("left_click", ["coordinate": [793, 749]]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.4),
            tool("read_page", ["mode": "text"]), hold(0.8),
            tool("scroll", ["coordinate": [640, 520], "scroll_direction": "down", "scroll_amount": 5]), hold(1.4),
            tool("scroll", ["coordinate": [640, 420], "scroll_direction": "up", "scroll_amount": 10]), hold(0.5),
            say("For pour over, the Pour is the better pick: its gooseneck gives a slow, steady stream, and it holds 40–100 °C "
                + "to the degree. The Rapid boils faster and holds more, but its wide spout pours too fast for a dripper. "
                + "Adding the Pour to the bag."), hold(0.5),
            tool("left_click", ["coordinate": [590, 315]]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.5),
            tool("left_click", ["coordinate": [1010, 430]]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.4),
            tool("read_page", ["mode": "text"]), hold(0.6),
            tool("left_click", ["coordinate": [1010, 510]]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.4),
            say("Done. I bought the Pour gooseneck kettle in Slate for €79.00 with your saved card ending 4242. For pour over "
                + "it beats the Rapid (€64): a controlled stream and the exact temperature. Order SW-48213 arrives Thursday."),
        ]
    }

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("input \(real ? "real (UI driver)" : "posted: not a take")")
        guard demo.serverUp else { note("MISSING: no demo server (AIRC_MARKETING_PORT)"); return done() }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard SteepwellShop.load() else { note("MISSING: no shop (AIRC_AIDEMO_SHOP, tools/agent-demo-shop/site)"); return done() }
        AgentCenter.shared.app = app
        AgentUI.forcedForTesting = true
        AgentWatchView.ignoresOcclusion = false
        // Only the fake CLIs, in a scratch folder; logged in (the fake's own state), never a real install.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-aidemo-\(getpid())", isDirectory: true)
        cliBin = root.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: cliBin, withIntermediateDirectories: true)
        // The fake Codex is "signed in with ChatGPT" (a made-up account in its own state, never a real one).
        for (name, source) in [("claude", AgentCLIFakes.claude), ("codex", AgentCLIFakes.codex)] {
            let u = cliBin.appendingPathComponent(name)
            try? source.write(to: u, atomically: true, encoding: .utf8)
            chmod(u.path, 0o755)
        }
        writeState()
        AgentCLIDetector.shared.setDirForTesting(cliBin.path)
        AgentModelSettings.shared.update { $0.backend = .apiKey; $0.blockedSites = [] }
        AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: nil)
        AgentModelSettings.shared.setTestKey(nil, provider: .openai, base: nil)
        AgentPaneProvider.refresh()
        run.newConversation()
        UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
        c.sidebar.agents.model.expanded = true
        UserDefaults.standard.removeObject(forKey: AgentPaneController.widthKey)
        if let personal = demo.space["personal"], c.currentSpaceID != personal { c.switchToSpace(personal, animated: false) }
        stageSidebar()
        c.navigate(to: URL(string: "\(host)/")!, newTab: true)
        runner.waitUntil({ (AgentPaneProvider.all().prefix(2).allSatisfy(\.ready)) }, timeout: 15) { [self] in
            note("providers: \(AgentPaneProvider.all().map { "\($0.name) \($0.ready ? "ready" : "not ready")" }.joined(separator: ", "))")
            after(2.5) { self.front { ok in self.note("in front: \(ok)"); done() } }
        }
    }

    /// Personal, made up for this video: no real brands in the sidebar. Favorites, pinned tabs and Today tabs of sites
    /// that don't exist, with our own letter icons (served on loopback: the app fetches icons outside the host rules).
    func stageSidebar() {
        let s = c.store
        guard let space = demo.space["personal"] else { return }
        let profile = s.profile(ofSpace: space).id
        let port = ProcessInfo.processInfo.environment["AIRC_MARKETING_PORT"] ?? "0"
        let icon = { (name: String) in "http://127.0.0.1:\(port)/assets/fav/\(name).png" }
        let site = { (name: String, path: String) in "http://\(name).aircbrowser.com\(path)" }
        do {
            for i in s.favorites(ofProfile: profile) { try s.deleteItem(i.id) }
            for i in s.pinnedRoots(ofSpace: space) { try s.deleteItem(i.id) }
            for t in s.todayTabs(ofSpace: space) { _ = try s.closeTab(t.id) }
            for (url, title, ic) in [(site("kite", "/inbox"), "Inbox (2) – Kite Mail", "kite"),
                                     (site("daybook", "/week"), "This week – Daybook", "daybook"),
                                     (site("loop", "/mix"), "Sunday morning – Loop", "loop"),
                                     (site("shelf", "/files"), "Home – Shelf", "shelf")] {
                try runner.favorite(url, title: title, icon: icon(ic), profile: profile, space: space)
            }
            try runner.pin(site("tally", "/budget-2027"), title: "Home budget 2027 – Tally", icon: icon("tally"), space: space)
            let recipes = try s.createFolder(named: "Recipes", inSpace: space)
            try runner.pin(site("crumb", "/pasteis-de-nata"), title: "Pastéis de nata – Crumb", icon: icon("crumb"), space: space, parent: recipes.id)
            try runner.pin(site("crumb", "/shakshuka"), title: "Shakshuka for two – Crumb", icon: icon("crumb"), space: space, parent: recipes.id)
            let reading = try s.createFolder(named: "Reading list", inSpace: space)
            try runner.pin(site("fieldnotes", "/a-quieter-web"), title: "A quieter web – Field Notes", icon: icon("fieldnotes"), space: space, parent: reading.id)
            try s.toggleFolder(reading.id)
            for (url, title, ic) in [(site("stride", "/plan/week-6"), "Week 6 – Stride run plan", "stride"),
                                     (site("atlas", "/porto"), "Weekend in Porto – Atlas", "atlas"),
                                     (site("crumb", "/sourdough"), "Sourdough schedule – Crumb", "crumb")] {
                let t = try s.openTab(url: url, inSpace: space, activate: false, title: title)
                s.updateTab(t.id, faviconURL: icon(ic))
            }
            c.reloadAll(animated: false)
        } catch {
            note("sidebar: \(error)")
        }
    }

    func writeState() {
        let o: [String: Any] = ["case": "aidemo", "loggedIn": true, "turns": [script]]   // read by both fakes
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: cliBin.appendingPathComponent("fake-state.json")) }
    }

    func front(_ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 6) { done(NSApp.isActive && self.c.window.isKeyWindow) }
    }

    func tearDown() {
        recorder?.stop {}
        if run.state.isActive { run.stop() }
        // Ends the CLI session too: its socket and MCP config in $TMPDIR go with it (a left one breaks agentpanel).
        run.newConversation()
        c.sidebar.agents.closeWatch()
        pane?.close()
        AgentUI.forcedForTesting = nil
        AgentCLIDetector.shared.setDirForTesting(nil)
        SteepwellShop.unload()
        try? FileManager.default.removeItem(at: cliBin.deletingLastPathComponent())
    }

    // MARK: Pointer and keys (real)

    /// An anchor's centre in Quartz global points.
    func point(_ name: String, in host: NSView? = nil) -> CGPoint? {
        let h = host ?? c.window.contentView?.superview ?? c.window.contentView
        guard let h else { return nil }
        h.layoutSubtreeIfNeeded()
        guard let v = TestAnchors.view(name, in: h), let w = v.window, let main = NSScreen.screens.first else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
    }

    /// Moves the real pointer there along a path (eased by the driver's steps), then waits `dwell`.
    func move(to p: CGPoint, ms: Int = 700, dwell: Double = 0.25, _ done: @escaping () -> Void) {
        guard real else { return after(Double(ms) / 1000 + dwell, done) }
        UIDriverClient.run(["--move", "\(Int(p.x))", "\(Int(p.y))", "--steps", "\(max(12, ms / 12))", "--duration", "\(ms)"]) { ok, out in
            if !ok { self.note("move refused: \(out)") }
            self.after(dwell, done)
        }
    }

    /// Moves to an anchor and clicks it for real; `fallback` (posted/direct) when that can't be done.
    func click(_ anchor: String, _ what: String, in host: NSView? = nil, ms: Int = 700, fallback: @escaping () -> Void, _ done: @escaping () -> Void) {
        guard real, let p = point(anchor, in: host) else {
            note("\(what): \(real ? "anchor \(anchor) missing" : "posted"), direct action")
            fallback()
            return after(0.4, done)
        }
        move(to: p, ms: ms) { [self] in
            guard let q = point(anchor, in: host) else { fallback(); return done() }
            UIDriverClient.run(["--click", "\(Int(q.x))", "\(Int(q.y))"]) { ok, out in
                if !ok { self.note("\(what): driver refused (\(out)), direct action"); fallback() }
                self.mark("click: \(what)")
                done()
            }
        }
    }

    func typeTask(_ done: @escaping () -> Void) {
        click("agentpane.field", "the composer", in: pane?.card?.hostingView, ms: 650, fallback: { self.pane?.focus() }) { [self] in
        pane?.focus()
        after(0.3) { [self] in
            guard real, let keys = UIDriverClient.keys(typing: Self.task) else { pane?.model.text = Self.task; return done() }
            mark("typing start")
            UIDriverClient.press(keys, pid: getpid()) { ok, out in
                if !ok { self.note("typing failed (\(out)); set directly"); self.pane?.model.text = Self.task }
                self.mark("typing end")
                done()
            }
        }
        }
    }

    // MARK: The take

    func record(_ done: @escaping () -> Void) {
        guard demo.serverUp else { return done() }
        guard let rec = WindowRecorder(window: c.window, url: dir.appendingPathComponent("aidemo.mov")) else {
            note("MISSING: the recorder didn't start (window not capturable?)"); return done()
        }
        recorder = rec
        // Park the pointer on the page, away from the controls.
        let f = c.window.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
        let park = CGPoint(x: (f.minX + f.width * 0.55).rounded(), y: (top - f.maxY + f.height * 0.62).rounded())
        move(to: park, ms: 200, dwell: 0.2) { [self] in
            rec.start()
            mark("start")
            after(2.2) { self.openPane(done) }
        }
    }

    /// ✦ in the sidebar's toolbar row (since 0.1.47), clicked for real; ⌥⌘A if it isn't there.
    func openPane(_ done: @escaping () -> Void) {
        let opened: () -> Void = { [self] in
            runner.waitUntil({ self.pane?.isShown == true }, timeout: 5) { [self] in
                mark("pane open, mode \(String(describing: pane?.model.mode))")
                after(1.4) { self.connect(done) }
            }
        }
        let button = c.sidebar.header.agent.button
        if real, !button.isHiddenOrHasHiddenAncestor, button.bounds.width > 4, let w = button.window, let main = NSScreen.screens.first {
            let r = w.convertToScreen(button.convert(button.bounds, to: nil))
            let p = CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
            move(to: p, ms: 900, dwell: 0.35) { [self] in
                UIDriverClient.run(["--click", "\(Int(p.x))", "\(Int(p.y))"]) { ok, out in
                    if !ok { self.note("agent button: driver refused (\(out))"); AgentUI.toggle(self.c) }
                    self.mark("click: ✦ in the toolbar")
                    opened()
                }
            }
        } else {
            note("✦ not clickable (real \(real), hidden \(button.isHiddenOrHasHiddenAncestor)): ⌥⌘A")
            guard real else { AgentUI.toggle(c); return opened() }
            UIDriverClient.run(["--key", "cmd+opt+a", "--pid", "\(getpid())"]) { ok, _ in
                if !ok { AgentUI.toggle(self.c) }
                self.mark("key: ⌥⌘A")
                opened()
            }
        }
    }

    func connect(_ done: @escaping () -> Void) {
        let host = pane?.card?.hostingView
        // Codex, signed in with ChatGPT (owner 2026-11-19 20:45: lead with the ChatGPT subscription).
        let use = "agentpane.provider.cli-codex.use"
        let rows = pane?.model.providers ?? []
        click(use, "Use on Codex", in: host, fallback: { if let r = rows.first(where: { $0.name == "Codex" }) { self.pane?.model.switchProvider(r, retrying: false) } }) { [self] in
            runner.waitUntil({ self.pane?.model.mode == .newTask }, timeout: 5) { [self] in
                mark("connected: \(pane?.model.providerLabel ?? "?")")
                after(1.0) { self.task(done) }
            }
        }
    }

    func task(_ done: @escaping () -> Void) {
        writeState()
        typeTask { [self] in
            after(0.5) { [self] in
                let send: (@escaping () -> Void) -> Void = { [self] k in
                    guard real else { pane?.model.send(); return k() }
                    UIDriverClient.run(["--key", "return", "--pid", "\(getpid())"]) { ok, _ in
                        if !ok { self.pane?.model.send() }
                        k()
                    }
                }
                send { [self] in
                    mark("sent")
                    // The agent works; the pane's live card shows it. Wait for Airc's question at Pay.
                    runner.waitUntil({ self.approvalShown }, timeout: 90) { [self] in
                        mark(approvalShown ? "approval shown" : "no approval (timeout)")
                        after(2.6) { self.watch(done) }
                    }
                }
            }
        }
    }

    var approvalShown: Bool {
        run.approval != nil
    }

    /// The person opens the run from the Agents folder (Watch), sees the same question there and allows once.
    func watch(_ done: @escaping () -> Void) {
        let folder: NSView = c.sidebar.agents
        guard let row = AgentActivity.shared.model.rows.last(where: { $0.isLive })?.id else {
            note("no live Agents folder row"); return finish(done)
        }
        guard let p = point("agents-row-\(row)", in: folder) else {
            c.sidebar.agents.openWatch(row); return afterWatch(done)
        }
        move(to: p, ms: 800, dwell: 0.5) { [self] in
            click("agents-watch-\(row)", "Watch", in: folder, ms: 250, fallback: { self.c.sidebar.agents.openWatch(row) }) { [self] in
                afterWatch(done)
            }
        }
    }

    func afterWatch(_ done: @escaping () -> Void) {
        runner.waitUntil({ self.c.sidebar.agents.watch != nil }, timeout: 4) { [self] in
            mark("watch open: \(c.sidebar.agents.watch?.mode ?? "none")")
            after(3.0) { [self] in
                let watchView: NSView? = c.sidebar.agents.watch
                click("agentwatch-allow", "Allow Once (Watch)", in: watchView, fallback: { self.allowDirect() }) { [self] in
                    runner.waitUntil({ !self.run.state.isActive }, timeout: 40) { [self] in
                        mark("run ended: \(run.state)")
                        after(2.2) { [self] in
                            // Back to the person's page: the pane shows the answer.
                            if let w = c.sidebar.agents.watch, point("agentwatch-close", in: w) != nil {
                                click("agentwatch-close", "close Watch", in: w, ms: 600, fallback: { self.c.sidebar.agents.closeWatch() }) { self.finish(done) }
                            } else {
                                c.sidebar.agents.closeWatch()
                                finish(done)
                            }
                        }
                    }
                }
            }
        }
    }

    func allowDirect() {
        if run.approval != nil { run.answerApproval(allow: true) }
    }

    /// The fake CLI logged its last step.
    var cliDone: Bool {
        guard let s = try? String(contentsOf: cliBin.appendingPathComponent("fake-log.jsonl"), encoding: .utf8) else { return false }
        return s.contains("\"say\"") || s.contains("Order SW-48213") || s.split(separator: "\n").contains { $0.contains("\"event\": \"exit\"") }
    }

    func finish(_ done: @escaping () -> Void) {
        // Park the pointer off the controls and hold on the answer.
        let f = c.window.frame, top = NSScreen.screens.first?.frame.maxY ?? 0
        move(to: CGPoint(x: (f.minX + f.width * 0.45).rounded(), y: (top - f.maxY + f.height * 0.7).rounded()), ms: 700) { [self] in
            mark("answer")
            after(4.5) { [self] in
                mark("end")
                let log = (try? String(contentsOf: cliBin.appendingPathComponent("fake-log.jsonl"), encoding: .utf8)) ?? ""
                try? log.write(to: dir.appendingPathComponent("fake-log.jsonl"), atomically: true, encoding: .utf8)
                recorder?.stop { [self] in
                    let o: [String: Any] = ["task": Self.task, "input": real ? "real" : "posted", "events": timeline,
                                            "frames": recorder?.frames ?? 0, "dropped": recorder?.dropped ?? 0,
                                            "size": [recorder?.size.width ?? 0, recorder?.size.height ?? 0]]
                    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
                        try? d.write(to: dir.appendingPathComponent("timeline.json"))
                    }
                    note("recorded \(recorder?.frames ?? 0) frames (\(recorder?.dropped ?? 0) late) at \(Int(recorder?.size.width ?? 0))×\(Int(recorder?.size.height ?? 0))")
                    done()
                }
            }
        }
    }
}

// MARK: - The recorder

/// Records one of our own windows as the window server shows it (CGWindowListCreateImage with that window's number
/// only: no other window, no desktop, no menu bar), with the real pointer drawn at its real position. HEVC, ~30 fps,
/// frames timestamped when they were taken.
final class WindowRecorder {
    let windowID: UInt32
    let size: CGSize
    let scale: CGFloat
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "airc.aidemo.recorder", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var cursorTimer: Timer?
    private var t0: CFTimeInterval = 0
    private let lock = NSLock()
    private var cursor: (image: CGImage, hot: CGPoint, size: CGSize, at: CGPoint)?
    private var windowFrame: CGRect
    private(set) var frames = 0
    private(set) var dropped = 0
    private var busy = false
    private var stopped = false
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private let create: CreateImage

    var elapsed: Double { t0 == 0 ? 0 : CACurrentMediaTime() - t0 }

    init?(window: NSWindow, url: URL) {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1",
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        create = unsafeBitCast(sym, to: CreateImage.self)
        windowID = UInt32(window.windowNumber)
        scale = window.backingScaleFactor
        windowFrame = window.frame
        // Even dimensions for the encoder.
        let w = Int(window.frame.width * scale) & ~1, h = Int(window.frame.height * scale) & ~1
        size = CGSize(width: w, height: h)
        try? FileManager.default.removeItem(at: url)
        guard let wr = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer = wr
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        // One test picture: nil while the window can't be captured.
        guard let probe = create(.null, 1 << 3, windowID, (1 << 3) | (1 << 0))?.takeRetainedValue(), probe.width > 8 else { return nil }
    }

    func start() {
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        t0 = CACurrentMediaTime()
        // The pointer, read on main 60 times a second (NSCursor and the window frame belong to AppKit).
        let ct = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.sampleCursor() }
        RunLoop.main.add(ct, forMode: .common)
        cursorTimer = ct
        sampleCursor()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private var lastCursor: NSCursor?
    private var lastCursorImage: (CGImage, CGPoint, CGSize)?
    private func sampleCursor() {
        let loc = NSEvent.mouseLocation
        let cur = NSCursor.currentSystem ?? NSCursor.arrow
        var img = lastCursorImage
        if img == nil || lastCursor?.image !== cur.image || lastCursor?.hotSpot != cur.hotSpot {
            var r = NSRect(origin: .zero, size: cur.image.size)
            if let cg = cur.image.cgImage(forProposedRect: &r, context: nil, hints: [.ctm: AffineTransform(scale: scale)]) {
                img = (cg, cur.hotSpot, cur.image.size)
            }
            lastCursor = cur
            lastCursorImage = img
        }
        let frame = NSApp.windows.first { $0.windowNumber == Int(windowID) }?.frame ?? windowFrame
        lock.lock()
        windowFrame = frame
        if let img { cursor = (img.0, img.1, img.2, loc) }
        lock.unlock()
    }

    private func tick() {
        guard !stopped, !busy else { dropped += 1; return }
        busy = true
        defer { busy = false }
        let now = CACurrentMediaTime() - t0
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool,
              let shot = create(.null, 1 << 3, windowID, (1 << 3) | (1 << 0))?.takeRetainedValue() else { dropped += 1; return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { dropped += 1; return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { dropped += 1; return }
        // The window's rounded corners are transparent: the X cut's backdrop colour under them (the site clips them).
        ctx.setFillColor(CGColor(srgbRed: 0xEF / 255.0, green: 0xE7 / 255.0, blue: 0xDD / 255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(shot, in: CGRect(x: 0, y: h - shot.height, width: shot.width, height: shot.height))
        lock.lock()
        let cur = cursor, frame = windowFrame
        lock.unlock()
        if let cur, frame.contains(cur.at) || frame.insetBy(dx: -40, dy: -40).contains(cur.at) {
            // Window points → image pixels (CG's origin is bottom-left, as AppKit's).
            let x = (cur.at.x - frame.minX - cur.hot.x) * scale
            let y = (cur.at.y - frame.minY) * scale - (cur.size.height - cur.hot.y) * scale
            ctx.draw(cur.image, in: CGRect(x: x, y: y, width: cur.size.width * scale, height: cur.size.height * scale))
        }
        if adaptor.append(buffer, withPresentationTime: CMTime(seconds: now, preferredTimescale: 600)) { frames += 1 } else { dropped += 1 }
    }

    func stop(_ done: @escaping () -> Void) {
        guard !stopped else { return done() }
        stopped = true
        cursorTimer?.invalidate()
        queue.async { [self] in
            timer?.cancel()
            input.markAsFinished()
            writer.finishWriting { DispatchQueue.main.async(execute: done) }
        }
    }
}

// MARK: - The fixture shop

/// Steepwell, the made-up shop (tools/agent-demo-shop/site, written by its build.py): `x.html` is served as `/x`,
/// `index.html` as `/`, everything else under its own path. Found through AIRC_AIDEMO_SHOP (record.sh passes the work
/// folder's copy).
enum SteepwellShop {
    static var paths: [String] = []

    static func load() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["AIRC_AIDEMO_SHOP"] else { return false }
        let root = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        let types = ["css": "text/css", "webp": "image/webp", "png": "image/png", "ttf": "font/ttf", "woff2": "font/woff2", "txt": "text/plain"]
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: u) else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(root.path.count))
            if u.pathExtension == "html" {
                let path = rel == "/index.html" ? "/" : String(rel.dropLast(5))
                MarketingServer.extraPages[path] = String(decoding: data, as: UTF8.self)
                paths.append(path)
            } else if let type = types[u.pathExtension] {
                MarketingServer.extraFiles[rel] = (type, data)
                paths.append(rel)
            }
        }
        return MarketingServer.extraPages["/"] != nil
    }

    static func unload() {
        for p in paths { MarketingServer.extraPages[p] = nil; MarketingServer.extraFiles[p] = nil }
        paths = []
    }
}
#endif
