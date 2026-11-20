// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AVFoundation
import AppKit
import AircKit
import CoreVideo

/// Part "aidemo" (`AIRC_MARKETING_PART=aidemo`, run on screen with real input by artifacts' record.sh): the homepage's and
/// X's Airc Agent video, recorded from the real window. The demo profile's Personal Space is on a fixture shop of our own
/// (Hearth & Steam, hearth.aircbrowser.com through the engine's host rules, served by MarketingServer on loopback). The
/// person clicks the agent button (⌥⌘A without one), uses Codex (signed in with ChatGPT) from the pane's Connect card, types a task, and the
/// agent works in its own window while the pane's live card shows it; Airc stops it at Pay with the approval card; the
/// person watches it from the Agents folder and allows once; the agent says what it did.
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
    let host = "http://hearth.aircbrowser.com"
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

    static let task = "Compare the two kettles under 70 euros and buy the cheaper one. Ask me before you pay."

    /// The fake Codex's steps for the task (one user turn). Coordinates are the fixture pages' fixed positions
    /// (CSS px = the agent window's screenshot pixels).
    var script: [[String: Any]] {
        let say: (String) -> [String: Any] = { ["say": $0, "every": 0.045] }
        let tool: (String, [String: Any]) -> [String: Any] = { ["tool": $0, "args": $1] }
        let hold: (Double) -> [String: Any] = { ["hold": $0] }
        return [
            say("I'll search Hearth & Steam for kettles first."), hold(0.6),
            tool("navigate", ["url": "\(host)/hearth/"]), hold(0.8),
            tool("left_click", ["coordinate": [330, 300]]), hold(0.4),
            tool("type", ["text": "electric kettle"]), hold(0.3),
            tool("key", ["text": "Return"]), hold(0.6),
            tool("wait_for_load", [:]), hold(0.4),
            tool("read_page", ["mode": "text"]), hold(0.9),
            say("Two are under €70: Fjord at €49 and Ember at €64. Let me check both."), hold(0.5),
            tool("left_click", ["coordinate": [210, 402]]), hold(0.6),
            tool("wait_for_load", [:]), hold(0.3),
            tool("scroll", ["coordinate": [480, 420], "scroll_direction": "down", "scroll_amount": 6]), hold(0.8),
            tool("read_page", ["mode": "text"]), hold(0.6),
            tool("go_back", [:]), hold(0.6),
            tool("left_click", ["coordinate": [500, 402]]), hold(0.6),
            tool("wait_for_load", [:]), hold(0.3),
            tool("scroll", ["coordinate": [480, 420], "scroll_direction": "down", "scroll_amount": 6]), hold(0.8),
            tool("read_page", ["mode": "text"]), hold(0.6),
            tool("go_back", [:]), hold(0.5),
            say("Both are 1.7 L with auto shut-off; Fjord is €15 cheaper. Adding it to the cart."), hold(0.4),
            tool("left_click", ["coordinate": [210, 476]]), hold(0.6),
            tool("wait_for_load", [:]), hold(0.4),
            tool("left_click", ["coordinate": [200, 404]]), hold(0.6),
            tool("wait_for_load", [:]), hold(0.4),
            tool("read_page", ["mode": "text"]), hold(0.6),
            tool("left_click", ["coordinate": [220, 546]]), hold(0.5),
            tool("wait_for_load", [:]), hold(0.4),
            say("Done. You bought the Fjord kettle for €49.00 (Ember was €64.00), paid with the saved card •••• 4242. Order HS-20714 arrives Tuesday."),
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
        for (path, page) in HearthShop.pages { MarketingServer.extraPages[path] = page }
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
        c.navigate(to: URL(string: "\(host)/hearth/")!, newTab: true)
        runner.waitUntil({ (AgentPaneProvider.all().prefix(2).allSatisfy(\.ready)) }, timeout: 15) { [self] in
            note("providers: \(AgentPaneProvider.all().map { "\($0.name) \($0.ready ? "ready" : "not ready")" }.joined(separator: ", "))")
            after(2.5) { self.front { ok in self.note("in front: \(ok)"); done() } }
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
        for path in HearthShop.pages.keys { MarketingServer.extraPages[path] = nil }
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

    /// The new agent button (agentux2), else ⌥⌘A.
    func openPane(_ done: @escaping () -> Void) {
        let names = (ProcessInfo.processInfo.environment["AIRC_AIDEMO_BUTTON"].map { [$0] } ?? []) +
            ["agent.button", "agentbutton", "toolbar.agent", "agent-button", "agents.button", "bottombar.agent"]
        let opened: () -> Void = { [self] in
            runner.waitUntil({ self.pane?.isShown == true }, timeout: 5) { [self] in
                mark("pane open, mode \(String(describing: pane?.model.mode))")
                after(1.4) { self.connect(done) }
            }
        }
        if real, let button = agentButton, let w = button.window, let main = NSScreen.screens.first {
            // agentux2's button: the sidebar footer's ✦ (accessibility label "Airc Agent").
            let r = w.convertToScreen(button.convert(button.bounds, to: nil))
            let p = CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
            move(to: p, ms: 900, dwell: 0.35) { [self] in
                UIDriverClient.run(["--click", "\(Int(p.x))", "\(Int(p.y))"]) { ok, out in
                    if !ok { self.note("agent button: driver refused (\(out))"); AgentUI.toggle(self.c) }
                    self.mark("click: agent button")
                    opened()
                }
            }
        } else if let name = names.first(where: { point($0) != nil }) {
            click(name, "agent button", fallback: { AgentUI.toggle(self.c) }) { opened() }
        } else {
            note("no agent button anchor (\(names.joined(separator: ", "))): ⌥⌘A")
            guard real else { AgentUI.toggle(c); return opened() }
            UIDriverClient.run(["--key", "cmd+opt+a", "--pid", "\(getpid())"]) { ok, _ in
                if !ok { AgentUI.toggle(self.c) }
                self.mark("key: ⌥⌘A")
                opened()
            }
        }
    }

    /// The window's Airc Agent button, found by its accessibility label (no API of its own needed here).
    var agentButton: NSView? {
        func find(_ v: NSView) -> NSView? {
            if v.accessibilityLabel() == "Airc Agent", v.accessibilityRole() == .button, !v.isHiddenOrHasHiddenAncestor, v.bounds.width > 4 { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return (c.window.contentView?.superview ?? c.window.contentView).flatMap(find)
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
        return s.contains("\"say\"") || s.contains("Order HS-20714") || s.split(separator: "\n").contains { $0.contains("\"event\": \"exit\"") }
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

/// Hearth & Steam, a made-up kitchenware shop: home with search, results, two product pages with specs below the fold,
/// cart, order review (a saved card shown as text, no card field) and the placed order. Fixed positions for every
/// control the script clicks. Drawings are CSS shapes of our own.
enum HearthShop {
    static let css = """
    <style>*{box-sizing:border-box}body{margin:0;font:16px/1.45 -apple-system,system-ui,sans-serif;background:#f7f3ee;color:#24201c}
    header{position:absolute;left:0;right:0;top:0;height:64px;background:#fff;border-bottom:1px solid #e8e0d6;display:flex;align-items:center;padding:0 40px}
    header b{font:700 20px ui-rounded,-apple-system,sans-serif;color:#b4532a;letter-spacing:-.2px}header nav{margin-left:auto;color:#6d645b;font-size:15px}
    header nav a{color:#6d645b;text-decoration:none;margin-left:22px}
    .abs{position:absolute}h1{font:700 34px ui-rounded,-apple-system,sans-serif;margin:0;letter-spacing:-.5px}.muted{color:#7a7067}
    .btn{display:flex;align-items:center;justify-content:center;border:0;border-radius:12px;background:#b4532a;color:#fff;font:600 16px -apple-system,sans-serif;text-decoration:none;cursor:pointer}
    .btn.alt{background:#efe6db;color:#5a3a24}
    .card{background:#fff;border:1px solid #e8e0d6;border-radius:16px}
    .kettle{position:absolute;width:120px;height:100px;border-radius:44px 44px 22px 22px}
    .kettle:before{content:"";position:absolute;left:34px;top:-14px;width:52px;height:16px;border-radius:8px 8px 0 0;background:inherit;filter:brightness(.85)}
    .kettle:after{content:"";position:absolute;right:-26px;top:22px;width:30px;height:46px;border:7px solid;border-color:inherit;border-left:0;border-radius:0 22px 22px 0}
    .stars{color:#d9902f;letter-spacing:1px}
    table{border-collapse:collapse;width:100%}td{padding:10px 0;border-top:1px solid #eee5da}td:last-child{text-align:right;color:#4a423b}
    </style>
    """
    static func header(_ cart: Int = 0) -> String {
        "<header><b>Hearth &amp; Steam</b><nav><a href=\"/hearth/\">Kitchen</a><a href=\"/hearth/\">Tea &amp; coffee</a><a href=\"/hearth/cart\">Cart (\(cart))</a></nav></header>"
    }
    static func kettle(_ x: Int, _ y: Int, _ body: String, _ rim: String) -> String {
        "<div class=\"kettle\" style=\"left:\(x)px;top:\(y)px;background:\(body);border-color:\(rim)\"></div>"
    }

    static let products: [(id: String, name: String, price: String, colour: String, rim: String, rating: String, reviews: Int)] = [
        ("fjord", "Fjord electric kettle", "€49.00", "#7fa3a8", "#5c7f84", "★★★★☆", 412),
        ("ember", "Ember electric kettle", "€64.00", "#c9694a", "#a24f34", "★★★★★", 268),
        ("brass", "Brass gooseneck kettle", "€89.00", "#c8a25a", "#a07e3c", "★★★★★", 97),
    ]

    static var home: String {
        """
        <!doctype html><title>Hearth & Steam · Kitchen and tea</title>\(css)\(header())
        <div class="abs" style="left:80px;top:130px;width:760px"><h1>Good things for slow mornings</h1>
        <p class="muted" style="margin:8px 0 0;font-size:18px">Kettles, teapots and pour-over gear, delivered in two days.</p></div>
        <form action="/hearth/search" method="get">
        <input class="abs" name="q" placeholder="Search kettles, teapots, grinders…" aria-label="Search" autocomplete="off"
          style="left:80px;top:274px;width:500px;height:52px;border:1px solid #d9cdbf;border-radius:14px;padding:0 18px;font:17px -apple-system,sans-serif;background:#fff">
        <button class="btn abs" style="left:596px;top:274px;width:120px;height:52px">Search</button></form>
        <div class="card abs" style="left:80px;top:370px;width:300px;height:150px;padding:20px"><b>Free delivery</b><p class="muted" style="margin:6px 0 0">On orders over €40.</p></div>
        <div class="card abs" style="left:400px;top:370px;width:300px;height:150px;padding:20px"><b>30-day returns</b><p class="muted" style="margin:6px 0 0">Not right? Send it back.</p></div>
        """
    }

    static var results: String {
        var cards = ""
        for (i, p) in products.enumerated() {
            let x = 80 + i * 290
            cards += """
            <div class="card abs" style="left:\(x)px;top:180px;width:260px;height:340px"></div>
            \(kettle(x + 62, 230, p.colour, p.rim))
            <a class="abs" href="/hearth/p/\(p.id)" style="left:\(x + 20)px;top:388px;width:220px;height:28px;font-weight:600;color:#24201c;text-decoration:none">\(p.name)</a>
            <div class="abs" style="left:\(x + 20)px;top:418px;font-size:14px"><span class="stars">\(p.rating)</span> <span class="muted">\(p.reviews)</span></div>
            <div class="abs" style="left:\(x + 20)px;top:440px;font-size:18px;font-weight:700">\(p.price)</div>
            <a class="btn abs" href="/hearth/cart" style="left:\(x + 20)px;top:458px;width:220px;height:40px;margin-top:0;\(i == 0 ? "" : "")">Add to cart</a>
            """
        }
        return """
        <!doctype html><title>“electric kettle” · Hearth & Steam</title>\(css)\(header())
        <div class="abs" style="left:80px;top:100px"><h1 style="font-size:26px">Results for “electric kettle”</h1><p class="muted" style="margin:4px 0 0">3 kettles</p></div>
        \(cards)
        """
    }

    static func product(_ i: Int) -> String {
        let p = products[i]
        let specs: [(String, String)] = i == 0
            ? [("Capacity", "1.7 L"), ("Power", "2200 W"), ("Auto shut-off", "Yes"), ("Keep warm", "No"), ("Body", "Matte steel"), ("Warranty", "2 years")]
            : [("Capacity", "1.7 L"), ("Power", "2400 W"), ("Auto shut-off", "Yes"), ("Keep warm", "30 min"), ("Body", "Enamelled steel"), ("Warranty", "2 years")]
        let rows = specs.map { "<tr><td>\($0.0)</td><td>\($0.1)</td></tr>" }.joined()
        return """
        <!doctype html><title>\(p.name) · Hearth & Steam</title>\(css)\(header())
        <div class="card abs" style="left:80px;top:100px;width:380px;height:380px"></div>
        <div style="position:absolute;left:150px;top:200px;transform:scale(1.9);transform-origin:0 0">\(kettle(0, 0, p.colour, p.rim))</div>
        <div class="abs" style="left:500px;top:110px;width:420px"><h1 style="font-size:30px">\(p.name)</h1>
        <div style="margin:8px 0"><span class="stars">\(p.rating)</span> <span class="muted">\(p.reviews) reviews</span></div>
        <div style="font-size:28px;font-weight:700;margin:12px 0 18px">\(p.price)</div>
        <p class="muted">\(i == 0 ? "A calm, quick kettle in brushed sea-green steel. Boils a full litre in under three minutes." : "Enamelled steel in warm terracotta, with a keep-warm setting for second cups.")</p></div>
        <a class="btn abs" href="/hearth/cart" style="left:500px;top:380px;width:220px;height:48px">Add to cart</a>
        <div class="abs" style="left:80px;top:560px;width:840px"><h2 style="font-size:22px;margin:0 0 6px">Specifications</h2><table>\(rows)</table>
        <h2 style="font-size:22px;margin:36px 0 6px">Reviews</h2><p class="muted">“Quiet and fast. Looks lovely on the counter.” · “Lid opens with one finger.”</p></div>
        <div style="height:1500px"></div>
        """
    }

    static var cart: String {
        """
        <!doctype html><title>Cart · Hearth & Steam</title>\(css)\(header(1))
        <div class="abs" style="left:80px;top:100px"><h1 style="font-size:28px">Your cart</h1></div>
        <div class="card abs" style="left:80px;top:160px;width:640px;height:150px"></div>
        <div style="position:absolute;left:104px;top:196px;transform:scale(.7);transform-origin:0 0">\(kettle(0, 0, products[0].colour, products[0].rim))</div>
        <div class="abs" style="left:230px;top:190px"><b>Fjord electric kettle</b><div class="muted">Sea green · 1.7 L · Qty 1</div></div>
        <div class="abs" style="left:620px;top:190px;font-weight:700">€49.00</div>
        <div class="abs muted" style="left:230px;top:262px;font-size:14px">Free delivery · arrives Tuesday</div>
        <a class="btn abs" href="/hearth/review" style="left:80px;top:380px;width:240px;height:48px">Review order</a>
        """
    }

    static var review: String {
        """
        <!doctype html><title>Review your order · Hearth & Steam</title>\(css)\(header(1))
        <div class="abs" style="left:80px;top:100px"><h1 style="font-size:28px">Review your order</h1></div>
        <div class="card abs" style="left:80px;top:160px;width:640px;height:340px;padding:24px 28px">
        <table><tr><td>Fjord electric kettle × 1</td><td>€49.00</td></tr><tr><td>Delivery (Tuesday)</td><td>Free</td></tr>
        <tr><td><b>Total</b></td><td><b>€49.00</b></td></tr>
        <tr><td>Deliver to</td><td>Ada Example, 12 Rua das Flores, Lisbon</td></tr>
        <tr><td>Pay with</td><td>Saved card •••• 4242</td></tr></table></div>
        <form action="/hearth/placed" method="post"><button class="btn abs" style="left:80px;top:522px;width:280px;height:52px">Pay €49.00</button></form>
        """
    }

    static var placed: String {
        """
        <!doctype html><title>Order placed · Hearth & Steam</title>\(css)\(header(0))
        <div class="abs" style="left:80px;top:120px;width:56px;height:56px;border-radius:28px;background:#3b8f5c;color:#fff;font-size:30px;display:flex;align-items:center;justify-content:center">✓</div>
        <div class="abs" style="left:80px;top:196px;width:700px"><h1 style="font-size:30px">Order HS-20714 is placed</h1>
        <p class="muted" style="font-size:18px">Fjord electric kettle · €49.00 · arrives Tuesday at 12 Rua das Flores.</p>
        <p class="muted" style="font-size:14px">A demo shop: nothing is charged or shipped.</p></div>
        """
    }

    static var pages: [String: String] {
        ["/hearth/": home, "/hearth": home, "/hearth/search": results, "/hearth/p/fjord": product(0), "/hearth/p/ember": product(1),
         "/hearth/cart": cart, "/hearth/review": review, "/hearth/placed": placed]
    }
}
#endif
