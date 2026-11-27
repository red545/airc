// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import WebKit
import ImageIO

/// agentparkcpu: what parked Airc Agent tasks cost while they wait, and what the agent's next step costs after one.
/// Opt-in cases of `--script agentparallel` (never in its default run): `AIRC_AGENTPARALLEL_ONLY=parkcpu` or `parkstep`.
/// - parkcpu: `AIRC_PARKCPU_TASKS` (default 3) tasks wait at a long model hold with their animating pages parked. CPU of
///   the app and of its engine processes (WebKit: our pages' WebContent processes and every WebKit service; Chromium:
///   the app's child processes), with nothing parked first, then in alternating rounds with the idle rest off (A, the
///   old behaviour) and on (B); then B with the pane open on one task (its card copies: that page must keep drawing).
///   Asserts (WebKit): with B the parked pages rest (no frames) and the pane's page doesn't; a tool call wakes a page.
/// - cardframe: a finished task's Recent-tasks card keeps a picture of its page (header, boxes, text), not the page
///   caught mid-paint: the task ends shown in the main view, parked, and parked after an idle rest; and a later copy of
///   the same page with far less in it never replaces a good one (aidemo4's empty card).
/// - parkstep: one task that idles 7 s before each look (screenshot, click, screenshot): the time from each tool call
///   to the next model request, rounds alternating A and B, and whether the page drew in between.
extension AgentParallelCheck {
    static var parkPages: [String: String] {
        var p: [String: String] = [:]
        for (i, css) in ["#1e8c7a", "#2f6fdf", "#c0392b"].enumerated() {
            // A CSS animation and a rAF counter (frames drawn), as the tally pages, plus a Count button.
            p["/pk-\(i + 1).html"] = """
            <title>Park \(i + 1)</title><style>html,body{margin:0;background:\(css);font:16px sans-serif;color:#fff}
            #bar{position:fixed;top:120px;left:0;width:120px;height:40px;background:#fff8;animation:m 1s linear infinite alternate}
            @keyframes m{to{left:600px}} #count{position:absolute;left:220px;top:220px;width:200px;height:80px;font-size:20px}</style>
            <div id=bar></div><button id=count onclick="window.counts=(window.counts||0)+1;document.title='Park \(i + 1) '+window.counts">Count</button>
            <script>window.frames_=0;(function t(){window.frames_++;requestAnimationFrame(t)})()</script>
            """
        }
        // A page like aidemo4's audio page: a dark header, three boxes with gradients and text, on a light background.
        p["/pk-card.html"] = """
        <title>Sound Test</title><body style="margin:0;font:15px sans-serif;background:#f4f1ec;color:#222">
        <div style="padding:18px 26px;background:#1f1f24;color:#fff;font-weight:600">Sound Test</div>
        <div style="display:flex;gap:16px;padding:22px 26px">
        <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#c9b8a6,#7d6a58)"></div><b>Model A</b><p>30 h</p></div>
        <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#9fb3c8,#43566b)"></div><b>Model B</b><p>24 h</p></div>
        <div style="flex:1;background:#fff;border-radius:14px;padding:16px"><div style="height:110px;border-radius:10px;background:linear-gradient(135deg,#e5c7c7,#a05b5b)"></div><b>Model C</b><p>40 h</p></div>
        </div></body>
        """
        p["/parks.html"] = SnapshotRunner.parksPage
        p["/audio.html"] = SnapshotRunner.audioPage
        return p
    }

    /// The page's driver's idle rest.
    func idle(_ page: EngineTab?) -> AgentIdleRest? { page.flatMap { main.entry($0)?.window?.driver.idleRest } }
    func resting(_ page: EngineTab) -> Bool { idle(page)?.isResting(page) == true }

    /// CPU seconds so far: the app, its engine processes (see above), and our pages' own content processes.
    func parkCPU() -> (app: Double, engine: Double, content: Double) { let c = parkCPUDetail(); return (c.app, c.engine, c.content) }

    /// Engine CPU seconds by process (name and pid), for the breakdown note.
    func parkCPUDetail() -> (app: Double, engine: Double, content: Double, each: [String: Double]) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,time=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        struct P { let pid: Int32; let ppid: Int32; let cpu: Double; let name: String }
        let all: [P] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { return nil }
            return P(pid: pid, ppid: ppid, cpu: AgentSpike.seconds(String(f[2])), name: String(f[3]))
        }
        let me = getpid()
        var content = Set<Int32>()
        for w in AgentCenter.shared.windows.values {
            for t in w.tabs { if let v = (t.tab as? WebKitTab)?.webView, let n = v.value(forKey: "_webProcessIdentifier") as? NSNumber { content.insert(n.int32Value) } }
        }
        var mine = Set([me])
        var grew = true
        while grew {   // the app's descendants (Chromium's helpers)
            grew = false
            for p in all where !mine.contains(p.pid) && mine.contains(p.ppid) { mine.insert(p.pid); grew = true }
        }
        let eng = all.filter { $0.pid != me && (mine.contains($0.pid) || $0.name.contains("com.apple.WebKit.")) }
        var each: [String: Double] = [:]
        for p in eng { each["\((p.name as NSString).lastPathComponent)[\(p.pid)]"] = p.cpu }
        return (Self.cpuTime(), eng.reduce(0) { $0 + $1.cpu }, all.filter { content.contains($0.pid) }.reduce(0) { $0 + $1.cpu }, each)
    }

    /// Percent of one core over `seconds`, for the app, the engine processes and our content processes.
    func parkSample(_ seconds: Double, _ done: @escaping (Double, Double, Double) -> Void) {
        let t0 = ProcessInfo.processInfo.systemUptime, c0 = parkCPUDetail()
        after(seconds) { [self] in
            let c1 = parkCPUDetail(), wall = ProcessInfo.processInfo.systemUptime - t0
            let top = c1.each.compactMap { k, v in c0.each[k].map { (k, 100 * (v - $0) / wall) } }.sorted { $0.1 > $1.1 }.prefix(5)
            note("agentparkcpu \(engine):   by process: " + top.map { "\($0.0) \(pct($0.1)) %" }.joined(separator: ", "))
            done(100 * (c1.app - c0.app) / wall, 100 * (c1.engine - c0.engine) / wall, 100 * (c1.content - c0.content) / wall)
        }
    }

    func pct(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Frames a page drew over `seconds` (its rAF counter, read without waking it: the tab's own evaluate).
    func frames(_ page: EngineTab?, over seconds: Double, _ done: @escaping (Int) -> Void) {
        read("window.frames_", on: page) { [self] a in
            after(seconds) { [self] in read("window.frames_", on: page) { b in done(a < 0 || b < 0 ? -1 : b - a) } }
        }
    }

    /// The idle rest on or off; off wakes every resting page (as before agentparkcpu).
    func setRest(_ on: Bool, _ pages: [EngineTab]) {
        AgentIdleRest.enabled = on
        if !on { for p in pages { main.entry(p)?.window?.driver.wake(p, for: 0) } }
    }

    // MARK: parkcpu

    func caseParkCPU(_ done: @escaping () -> Void) {
        events = []
        let n = max(1, min(3, Int(ProcessInfo.processInfo.environment["AIRC_PARKCPU_TASKS"] ?? "") ?? 3))
        let rest0 = AgentIdleRest.enabled
        if let p = AgentPaneController.pane(of: home), p.isShown { p.close() }
        after(2) { [self] in
            parkSample(12) { [self] app0, eng0, _ in
                note("agentparkcpu \(engine): 0 parked: app \(pct(app0)) %, engine \(pct(eng0)) % (load \(String(format: "%.1f", Self.load())))")
                var runs: [AgentRunCenter] = []
                for i in 0..<n {
                    if let r = start("k\(i + 1)", [.tool("navigate", ["url": "\(base)/pk-\(i + 1).html"]), .toolThenHold("wait", ["duration": 1], hold: 200),
                                                   .text("Done.")], task: "Park on page \(i + 1)") { runs.append(r) }
                }
                wait({ runs.count == n && runs.allSatisfy { r in self.events.contains { $0.task == self.name(r) && $0.event == "tool wait" } } }, 30) { [self] in
                    if let h = k.app.controllers.first, let tab = h.store.state.tabs.values.first(where: { $0.spaceID == h.currentSpaceID && $0.url.hasSuffix("/home.html") }) {
                        h.show(tab.id, focus: false)
                    }
                    AgentPaneController.pane(of: home)?.close()
                    after(1) { [self] in
                        let pages = runs.compactMap { page($0) }
                        let parked = runs.filter { r in main.entry(for: r).map { e in e.page.map { e.window?.isParked($0) ?? false } ?? false } ?? false }.count
                        check(parked == n && pages.count == n, "parkcpu: the \(n) pages are parked (\(parked))")
                        rounds(n, pages, runs, rest0, done)
                    }
                }
            }
        }
    }

    private func rounds(_ n: Int, _ pages: [EngineTab], _ runs: [AgentRunCenter], _ rest0: Bool, _ done: @escaping () -> Void) {
        var a: [(Double, Double, Double)] = [], b: [(Double, Double, Double)] = []
        let order = [false, true, false, true]
        func round(_ i: Int) {
            guard i < order.count else { return finish() }
            let on = order[i]
            setRest(on, pages)
            // B: idleAfter (5 s) and the 1 s rest timer pass before the sample.
            after(on ? AgentIdleRest.idleAfter + 2.5 : 2) { [self] in
                if on {
                    let resting = pages.filter { self.resting($0) }.count
                    check(resting == n, "parkcpu: with the rest on, the \(n) idle parked pages rest (\(resting))")
                    let w = pages.first?.view.window
                    note("agentparkcpu \(engine): agent window \(w.map { NSStringFromClass(type(of: $0)) } ?? "none"): occlusion visible \(w?.occlusionState.contains(.visible) ?? false), isVisible \(w?.isVisible ?? false)")
                }
                parkSample(12) { [self] app, eng, content in
                    note("agentparkcpu \(engine): \(n) parked, rest \(on ? "on (B)" : "off (A)"): app \(pct(app)) %, engine \(pct(eng)) %, our content \(pct(content)) %")
                    if on { b.append((app, eng, content)) } else { a.append((app, eng, content)) }
                    round(i + 1)
                }
            }
        }
        func avg(_ s: [(Double, Double, Double)]) -> (Double, Double, Double) {
            let c = Double(max(1, s.count))
            return (s.reduce(0) { $0 + $1.0 } / c, s.reduce(0) { $0 + $1.1 } / c, s.reduce(0) { $0 + $1.2 } / c)
        }
        func finish() {
            let ma = avg(a), mb = avg(b)
            note("agentparkcpu \(engine): SUMMARY \(n) parked: A app \(pct(ma.0)) % engine \(pct(ma.1)) % content \(pct(ma.2)) % | B app \(pct(mb.0)) % engine \(pct(mb.1)) % content \(pct(mb.2)) % (load \(String(format: "%.1f", Self.load())))")
            do {
                frames(pages.first, over: 2) { [self] f in
                    check(f == 0, "parkcpu: a resting page draws no frames (\(f) in 2 s)")
                    // A tool call on it: the page draws again at once.
                    if let p = pages.first { main.entry(p)?.window?.driver.wake(p, for: 0) }
                    frames(pages.first, over: 1) { [self] f2 in
                        check(f2 >= 20, "parkcpu: woken by a tool call, the page draws again (\(f2) frames in 1 s)")
                        paneOpen()
                    }
                }
            }
        }
        func paneOpen() {
            // The pane open on the first task: its live card copies that page, which keeps drawing; the others rest.
            guard let r = runs.first else { return end() }
            AgentPaneController.show(home, task: r)
            after(AgentIdleRest.idleAfter + 2.5) { [self] in
                let resting = pages.filter { self.resting($0) }.count
                check(!self.resting(pages[0]), "parkcpu: the page the pane's card shows keeps drawing")
                check(resting == n - 1, "parkcpu: the other parked pages rest (\(resting) of \(n - 1))")
                parkSample(12) { [self] app, eng, content in
                    note("agentparkcpu \(engine): \(n) parked, rest on, pane card on task 1: app \(pct(app)) %, engine \(pct(eng)) %, our content \(pct(content)) %")
                    AgentPaneController.pane(of: home)?.close()
                    end()
                }
            }
        }
        func end() {
            AgentIdleRest.enabled = rest0
            runs.forEach { $0.stop() }
            wait({ runs.allSatisfy { !$0.isBusy } }, 10) { [self] in after(0.5, done) }
        }
        round(0)
    }

    // MARK: cardframe

    func caseCardFrame(_ done: @escaping () -> Void) {
        events = []
        let thumbs = AgentTaskThumbs.shared
        // The rule itself: a flat copy of the same page keeps the good one; another page replaces it.
        if let good = AgentParkCPUPictures.page(), let flat = AgentParkCPUPictures.flat() {
            let u = URL(string: "\(base)/pk-card.html")
            let g = AgentTaskThumbs.Shot(image: good, title: "", host: nil, url: u, detail: AgentTaskThumbs.detail(good))
            let f = AgentTaskThumbs.Shot(image: flat, title: "", host: nil, url: u, detail: AgentTaskThumbs.detail(flat))
            let other = AgentTaskThumbs.Shot(image: flat, title: "", host: nil, url: URL(string: "\(base)/other.html"), detail: f.detail)
            check(!AgentTaskThumbs.replaces(f, g) && AgentTaskThumbs.replaces(other, g) && AgentTaskThumbs.replaces(g, f),
                  "cardframe: a copy of the same page with far less in it keeps the good picture (detail \(String(format: "%.2f", f.detail)) vs \(String(format: "%.2f", g.detail))); another page replaces it")
        }
        let variants: [(name: String, park: Bool, idle: Double)] = [("shown", false, 0.2), ("parked", true, 0.2), ("rested", true, AgentIdleRest.idleAfter + 3)]
        func one(_ i: Int) {
            guard i < variants.count else { return after(0.5, done) }
            let v = variants[i]
            let name = "cf\(i + 1)"
            guard let r = start(name, [.tool("navigate", ["url": "\(base)/pk-card.html"]), .tool("read_page", ["mode": "text"]),
                                       .tool("find_element", ["text": "Model"]), .toolThenHold("wait", ["duration": 1], hold: v.idle),
                                       .text("Model C lasts longest.")], task: "Compare the models \(v.name)") else {
                check(false, "cardframe [\(v.name)]: the task starts"); return one(i + 1)
            }
            if v.park {
                wait({ self.events.contains { $0.task == name && $0.event == "tool read_page" } }, 20) { [self] in
                    if let h = k.app.controllers.first, let tab = h.store.state.tabs.values.first(where: { $0.spaceID == h.currentSpaceID && $0.url.hasSuffix("/home.html") }) {
                        h.show(tab.id, focus: false)
                    }
                }
            }
            wait({ !r.isBusy && r.steps.contains { $0.kind == .final } }, 40) { [self] in
                after(2.5) { [self] in
                    guard let id = AgentTaskRecorder.shared.recordID(r), let shot = thumbs.task(id) else {
                        check(false, "cardframe [\(v.name)]: the finished task's card has a picture"); return one(i + 1)
                    }
                    let img = shot.image
                    let head = AgentImages.pixel(img, x: img.width / 2, y: max(1, img.height / 40))
                    let dark = head.map { Int($0.r) + Int($0.g) + Int($0.b) < 240 } ?? false
                    let d = AgentTaskThumbs.detail(img)
                    check(!AgentTaskThumbs.isBlank(img) && dark && d >= 1.5,
                          "cardframe [\(v.name)]: the card shows the page, header and all (header \(head.map { "\($0)" } ?? "none"), detail \(String(format: "%.2f", d)), \(img.width)×\(img.height))")
                    note("agentparkcpu \(engine): cardframe [\(v.name)]: copies kept out \(thumbs.keptOver.count) so far")
                    one(i + 1)
                }
            }
        }
        one(0)
    }

    // MARK: cardrepro

    /// aidemo4's flow (MarketingAgentTasks): two tasks from the Command Bar, one after the other, on the parks and the
    /// audio page; every copy made for their cards, and the cards' pictures saved.
    func caseCardRepro(_ done: @escaping () -> Void) {
        let thumbs = AgentTaskThumbs.shared
        let tasks: [(String, String, String)] = [("r1", "Find the largest park in Brightport", "/parks.html"), ("r2", "Compare noise-cancelling headphones under €300", "/audio.html")]
        var ids: [String] = []
        func one(_ i: Int) {
            guard i < tasks.count else { return report() }
            let (name, prompt, path) = tasks[i]
            AgentRunCenter.shared.newConversation()
            k.fake.begin(name, [.tool("navigate", ["url": "\(base)\(path)"]), .tool("read_page", ["mode": "text"])] + (i == 1 ? [.tool("find_element", ["text": "battery"])] : [])
                                + [.toolThenHold("wait", ["duration": 1], hold: 0.2), .text("Done \(name).")])
            CommandBarView.startAgentTask(prompt, attached: [], in: home)
            wait({ !AgentRunCenter.shared.state.isActive && AgentRunCenter.shared.steps.contains { $0.kind == .final } }, 30) { [self] in
                if let id = AgentTaskRecorder.shared.currentID { ids.append(id) }
                after(0.6) { one(i + 1) }
            }
        }
        func report() {
            after(2) { [self] in
                for l in thumbs.captureLog { note("agentparkcpu \(engine): cardrepro copy: \(l)") }
                for (i, id) in ids.enumerated() {
                    guard let shot = thumbs.task(id) else { check(false, "cardrepro: task \(i + 1)'s card has a picture"); continue }
                    let url = runner.dir.appendingPathComponent("cardrepro-\(i + 1)-\(engine).png")
                    if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, shot.image, nil); CGImageDestinationFinalize(d) }
                    let d = AgentTaskThumbs.detail(shot.image)
                    check(d >= 1.5, "cardrepro: task \(i + 1)'s card picture is its page (detail \(String(format: "%.2f", d)), \(shot.url?.path ?? "-"))")
                }
                onScreen()
            }
        }
        // ⌘T Ask, as aidemo4's shot: each finished card shows the top of its page (both fixtures' tops are dark or
        // saturated: the parks page's green hero, the audio page's dark header), not the page's bare background.
        func onScreen() {
            home.closeCommandBar()
            home.openCommandBar(mode: .newTab)
            after(0.4) { [self] in
                home.commandBar?.setAskMode(true)
                after(1.2) { [self] in
                    guard let ask = home.commandBar?.askPanel, let win = ask.window,
                          let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
                        check(false, "cardrepro: ⌘T Ask's panel"); home.closeCommandBar(); return after(0.5, done)
                    }
                    ask.layoutSubtreeIfNeeded()
                    typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                    guard let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(win.windowNumber), 1 << 0)?.takeRetainedValue() else {
                        note("FAIL-ENV agentparallel \(engine): cardrepro: no window-server picture of our own window"); home.closeCommandBar(); return after(0.5, done)
                    }
                    let shotURL = runner.dir.appendingPathComponent("cardrepro-ask-\(engine).png")
                    if let d = CGImageDestinationCreateWithURL(shotURL as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                    let scale = CGFloat(img.width) / max(1, win.frame.width)
                    for (i, id) in ids.enumerated() {
                        guard let v = TestAnchors.view("agentask.card.thumb.\(id)", in: ask) else {
                            check(false, "cardrepro: task \(i + 1)'s card shows a picture in ⌘T Ask"); continue
                        }
                        let r = v.convert(v.bounds, to: nil)   // window points, origin bottom left
                        let x = Int((r.midX) * scale), top = Int((win.frame.height - r.maxY + r.height * 0.06) * scale)
                        let mid = Int((win.frame.height - r.midY) * scale)
                        let a = AgentImages.pixel(img, x: x, y: top), b = AgentImages.pixel(img, x: x, y: mid)
                        // Light page background is ~(240, 238, 232); the tops are dark (header) or green (hero).
                        let notBackground = a.map { $0.r + $0.g + $0.b < 600 } ?? false
                        check(notBackground, "cardrepro: task \(i + 1)'s card in ⌘T Ask shows the top of its page (top \(a.map { "\($0)" } ?? "none"), middle \(b.map { "\($0)" } ?? "none"), \(Int(r.width))×\(Int(r.height)) pt)")
                    }
                    home.closeCommandBar()
                    after(0.5, done)
                }
            }
        }
        one(0)
    }

    // MARK: parkstep

    /// The agent's looks after an idle wait: tool call → next model request, A and B alternating.
    func caseParkStep(_ done: @escaping () -> Void) {
        events = []
        let rest0 = AgentIdleRest.enabled
        let rounds = 6
        var turns: [FakeModelServer.Turn] = [.tool("navigate", ["url": "\(base)/pk-1.html"])]
        for _ in 0..<rounds {
            turns += [.toolThenHold("wait", ["duration": 0.5], hold: 9), .tool("screenshot", [:]),
                      .tool("left_click", ["coordinate": [320, 260]]), .tool("screenshot", [:])]
        }
        turns.append(.text("Done."))
        // Round r's rest setting is set when its wait starts (A first).
        var waits = 0
        var parkedLooks = 0, looks = 0
        guard let r = start("ks", turns, task: "Look at page 1") else { check(false, "parkstep: the task starts"); return done() }
        let tag = self.name(r)
        r.onEvent = { [weak self] e in
            guard let self else { return }
            self.events.append((tag, e, Date()))
            if e == "tool wait" {
                let on = waits % 2 == 1
                waits += 1
                // The person looks at their own tab once the task's page is there: it parks.
                if waits == 1 {
                    if let h = self.k.app.controllers.first, let tab = h.store.state.tabs.values.first(where: { $0.spaceID == h.currentSpaceID && $0.url.hasSuffix("/home.html") }) {
                        h.show(tab.id, focus: false)
                    }
                    AgentPaneController.pane(of: self.home)?.close()
                }
                self.setRest(on, self.page(r).map { [$0] } ?? [])
            }
            if e == "tool screenshot", let p = self.page(r) {
                looks += 1
                if self.main.entry(p)?.window?.isParked(p) == true { parkedLooks += 1 }
            }
        }
        wait({ !r.isBusy }, 120) { [self] in
            AgentIdleRest.enabled = rest0
            // Per round: tool → next "turn" for screenshot, left_click, screenshot.
            var round = -1
            var lat: [Bool: [String: [Double]]] = [false: [:], true: [:]]
            let ev = events.filter { $0.task == tag }
            for (i, e) in ev.enumerated() {
                if e.event == "tool wait" { round += 1; continue }
                guard round >= 0, e.event.hasPrefix("tool "), let next = ev[(i + 1)...].first(where: { $0.event == "turn" }) else { continue }
                let tool = String(e.event.dropFirst(5))
                lat[round % 2 == 1, default: [:]][tool, default: []].append(1000 * next.at.timeIntervalSince(e.at))
            }
            func med(_ v: [Double]) -> Double { v.isEmpty ? -1 : v.sorted()[v.count / 2] }
            for on in [false, true] {
                let l = lat[on] ?? [:]
                note("agentparkcpu \(engine): parkstep rest \(on ? "on (B)" : "off (A)"): " + l.keys.sorted().map { "\($0) median \(Int(med(l[$0]!))) ms max \(Int(l[$0]!.max() ?? -1)) ms (n \(l[$0]!.count))" }.joined(separator: ", "))
            }
            let a = med((lat[false] ?? [:]).values.flatMap { $0 }), b = med((lat[true] ?? [:]).values.flatMap { $0 })
            check(round + 1 == rounds, "parkstep: \(rounds) rounds ran (\(round + 1))")
            check(parkedLooks == looks && looks > 0, "parkstep: the page was parked at every look (\(parkedLooks) of \(looks))")
            check(b >= 0 && b <= a + 60, "parkstep: a step after an idle rest takes about as long as without (median B \(Int(b)) ms, A \(Int(a)) ms)")
            let wakes = idle(page(r))?.wakes ?? 0
            check(wakes >= rounds / 2, "parkstep: the rested page was woken for its looks (\(wakes) wakes)")
            after(0.5, done)
        }
    }
}

/// cardframe's made-up pictures: the fixture's look drawn directly (a dark band, boxes with text-like bars) and the same
/// page caught mid-paint (its background and white boxes only).
enum AgentParkCPUPictures {
    static func draw(_ full: Bool) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 360, height: 225, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.957, green: 0.945, blue: 0.925, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 225))
        if full { ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)); ctx.fill(CGRect(x: 0, y: 200, width: 360, height: 25)) }
        for i in 0..<3 {
            let x = CGFloat(13 + i * 115)
            ctx.setFillColor(.white); ctx.fill(CGRect(x: x, y: 60, width: 105, height: 125))
            guard full else { continue }
            ctx.setFillColor(CGColor(red: 0.5, green: 0.45, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: x + 8, y: 110, width: 89, height: 65))
            ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1))
            for l in 0..<3 { ctx.fill(CGRect(x: x + 8, y: CGFloat(70 + l * 12), width: CGFloat(40 + l * 15), height: 5)) }
        }
        return ctx.makeImage()
    }
    static func page() -> CGImage? { draw(true) }
    static func flat() -> CGImage? { draw(false) }
}
#endif
