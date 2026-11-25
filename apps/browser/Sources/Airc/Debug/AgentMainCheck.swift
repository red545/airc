// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script agentmain` (agentmainview, owner decision 2026-11-23): the Airc Agent works in the main view.
/// Against the FakeModelServer on 127.0.0.1 (AgentPaneCheck's fixtures and helpers), with real driver clicks and keys in
/// a dedicated session (else posted, and said so). Cases:
/// - start: the task's page is the selected tab of the window (a Today tab of this Space, titled with the page), full
///   size; the agent's viewport is that real size; glow and bar on; the window-server picture of the page is the page
///   (not white); the agent's click lands on the page, with a pulse where it clicked;
/// - shield: the person's click and typing don't reach the page (hint shows); a scroll does, and the agent's next click is
///   refused until it looks again;
/// - Take over (bar) hands the page over at once (the person's click reaches it), Hand back (bar) goes on in the same tab;
/// - switching to another tab: the page parks, the agent goes on (it navigates there), the pane's card shows it live,
///   the Today row follows its title; the card brings it back (same page, nothing loaded again);
/// - two agent tabs at once (the task opens a second): each a Today tab, only the selected one in the main view;
/// - 32 navigations with a Stop and Continue in between: the main view's pixels are the page's after every one, and
///   Continue goes on in the same tab;
/// - Stop (bar): the task ends, the tabs stay the person's ordinary tabs.
/// Light and dark pictures of the window and a frame sequence of one case (artifacts) for the report.
extension SnapshotRunner {
    func agentMainScenario() {
        let m = AgentMainCheck(runner: self)
        step { done in m.setUp(done) }
        if AgentMainCheck.runs("start") { step { done in m.caseStart(done) } }
        if AgentMainCheck.runs("switch") { step { done in m.caseSwitch(done) } }
        if AgentMainCheck.runs("two") { step { done in m.caseTwo(done) } }
        if AgentMainCheck.runs("long") { step { done in m.caseLong(done) } }
        if AgentMainCheck.runs("dark") { step { done in m.caseDark(done) } }
        // agentmainfix (AgentMainParked.swift): a parked page keeps its full frame rate.
        if AgentMainCheck.runs("parked") { step { done in m.caseParked(done) } }
        // agentmainfix (AgentMainRows.swift): finished tasks leave their page's row and card picture, no about:blank rows.
        if AgentMainCheck.runs("rows") { step { done in m.caseRows(done) } }
        run { m.finish() }
    }
}

final class AgentMainCheck {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var run: AgentRunCenter { .shared }
    var main: AgentMainView { .shared }
    var engine: String { k.engine }
    var base: String { k.base }
    var mainEvents: [String] = []
    /// The person's own tab the window showed before the first task.
    var homeTabID: String?
    /// Frames of one case for the report's recording (window-server pictures of our own window).
    var frames: [CGImage] = []
    var recording = false

    static var only: Set<String>? {
        ProcessInfo.processInfo.environment["AIRC_AGENTMAIN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    }
    static func runs(_ name: String) -> Bool { only?.contains(name) ?? true }

    /// A tally page (no shop words: a "Buy" button asks for the person's OK first): a teal band, a moving bar (live pixels), a button that counts clicks (the agent's and the person's),
    /// every mouse-down counted, a field, and room to scroll.
    static let shop = """
        <title>Tally (fixture)</title><style>html,body{margin:0;background:#1e8c7a;font:16px sans-serif;color:#fff}
        #bar{position:fixed;top:120px;left:0;width:120px;height:40px;background:#ffd23f;animation:m 1s linear infinite alternate}
        @keyframes m{to{left:600px}} #buy{position:absolute;left:220px;top:220px;width:200px;height:80px;font-size:20px}
        #q{position:absolute;left:220px;top:340px;width:200px} .pad{height:3200px}</style>
        <div id=bar></div><button id=buy onclick="window.buys=(window.buys||0)+1;document.title='Counted '+window.buys">Count</button>
        <input id=q autocomplete=off><div class=pad></div>
        <script>window.downs=0;addEventListener('mousedown',function(){window.downs++},true);</script>
        """
    static func colour(_ name: String, _ css: String) -> String {
        "<title>\(name)</title><style>html,body{margin:0;background:\(css);height:100%}#bar{position:absolute;top:30px;left:0;width:160px;height:40px;background:#fff8;animation:m .9s linear infinite alternate}@keyframes m{to{left:500px}}</style><div id=bar></div>"
    }

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agentmain"
        k.extraPages = ["/am-shop.html": Self.shop, "/am-a.html": Self.colour("Page A", "#e0306a"),
                        "/am-b.html": Self.colour("Page B", "#2f6fdf"), "/am-moving.html": Self.colour("Moving", "#7a3fd0")]
    }

    func check(_ ok: Bool, _ what: String) { k.check(ok, what) }
    func note(_ s: String) { k.note(s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { k.after(s, body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    var chrome: AgentMainChromeView? { main.chromeView(c) }
    var entry: AgentMainView.Hosted? { main.runEntry }
    var runWindow: AgentWindow? { run.runWindowID.flatMap { AgentCenter.shared.windows[$0] } }
    var pageView: NSView? { c.shownTabID.flatMap { c.engineTab(for: $0) }?.view }

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        k.setUp { [self] in
            main.onEvent = { [weak self] e in self?.mainEvents.append(e) }
            homeTabID = c.shownTabID
            note("agentmain \(engine): home tab \(homeTabID ?? "none"), card \(Int(c.card.frame.width))x\(Int(c.card.frame.height))")
            done()
        }
    }

    /// Reads a value from the shown agent page (its own world: the fixture's counters).
    func read(_ js: String, from page: EngineTab? = nil, _ done: @escaping (Any?) -> Void) {
        guard let p = page ?? entry?.page else { return done(nil) }
        p.evaluate("JSON.stringify(\(js))") { v in
            if let s = v as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { return done(o) }
            done(v)
        }
    }

    func number(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int("\(v ?? "")") ?? -1 }

    /// The page's centre (or a point of it, top-left page coordinates) in Quartz global points, for a real click.
    func globalPoint(_ p: CGPoint, in v: NSView) -> CGPoint? {
        guard let w = v.window, let screen = NSScreen.screens.first else { return nil }
        let local = v.isFlipped ? p : CGPoint(x: p.x, y: v.bounds.height - p.y)
        let r = w.convertToScreen(NSRect(origin: v.convert(local, to: nil), size: .zero))
        return CGPoint(x: r.minX.rounded(), y: (screen.frame.maxY - r.minY).rounded())
    }

    /// A real driver click at a page point (posted mouse down/up to the window when there's no driver).
    func personClick(_ p: CGPoint, _ done: @escaping (String) -> Void) {
        guard let v = c.card.hostView else { return done("none") }
        if k.real, let g = globalPoint(p, in: v), NSApp.isActive {
            UIDriverClient.run(["--click", "\(g.x)", "\(g.y)"]) { ok, _ in DispatchQueue.main.async { done(ok ? "real" : "posted-failed") } }
            return
        }
        let local = v.isFlipped ? p : CGPoint(x: p.x, y: v.bounds.height - p.y)
        let wp = v.convert(local, to: nil)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(e, atStart: false)
            }
        }
        done("posted")
    }

    func personType(_ text: String, _ done: @escaping (String) -> Void) {
        if k.real, let keys = UIDriverClient.keys(typing: text) {
            UIDriverClient.press(keys, pid: getpid()) { ok, _ in DispatchQueue.main.async { done(ok ? "real" : "posted-failed") } }
            return
        }
        for ch in text {
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: c.window.windowNumber, context: nil, characters: String(ch),
                                            charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 7) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        done("posted")
    }

    /// A scroll over the page (the driver has no wheel: posted through the window, as macOS delivers one).
    func personScroll(_ dy: Int32, _ done: @escaping () -> Void) {
        guard let v = c.card.hostView, let g = globalPoint(CGPoint(x: v.bounds.midX, y: v.bounds.midY), in: v),
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return done() }
        cg.location = g
        if let e = NSEvent(cgEvent: cg) { c.window.sendEvent(e) }
        after(0.5, done)
    }

    // MARK: Pixels

    /// The window server's picture of the main view's page (our own window: no Screen Recording).
    func pagePicture() -> AgentPaneFlickerProbe.Pixels? {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1", let v = c.card.hostView,
              let rect = AgentPaneFlickerProbe.rect(of: v, margin: -4),
              let img = AgentPaneFlickerProbe.capture(UInt32(c.window.windowNumber), rect) else { return nil }
        if recording, frames.count < 400, let whole = AgentPaneFlickerProbe.rect(of: c.window.contentView!, margin: 0),
           let f = AgentPaneFlickerProbe.capture(UInt32(c.window.windowNumber), whole) { frames.append(f) }
        return AgentPaneFlickerProbe.Pixels(img)
    }

    struct Look { var white: Double; var match: Double; var dominant: (Int, Int, Int) }

    /// How much of the picture is near-white, and how much is close to `want` (sampled on a grid, below the bar).
    func look(_ p: AgentPaneFlickerProbe.Pixels, want: (Int, Int, Int)?) -> Look {
        var white = 0, match = 0, n = 0
        var counts: [Int: Int] = [:]
        let step = max(8, min(p.w, p.h) / 40)
        var y = p.h / 6
        while y < p.h - 4 {
            var x = 4
            while x < p.w - 4 {
                let q = p.at(x, y)
                n += 1
                if q.0 > 235, q.1 > 235, q.2 > 235 { white += 1 }
                if let w = want, abs(q.0 - w.0) < 40, abs(q.1 - w.1) < 40, abs(q.2 - w.2) < 40 { match += 1 }
                counts[(q.0 / 16) << 8 | (q.1 / 16) << 4 | (q.2 / 16), default: 0] += 1
                x += step
            }
            y += step
        }
        let top = counts.max { $0.value < $1.value }?.key ?? 0
        return Look(white: Double(white) / Double(max(1, n)), match: Double(match) / Double(max(1, n)),
                    dominant: ((top >> 8 & 15) * 16 + 8, (top >> 4 & 15) * 16 + 8, (top & 15) * 16 + 8))
    }

    func shot(_ name: String) {
        guard let whole = AgentPaneFlickerProbe.rect(of: c.window.contentView!, margin: 0),
              let img = AgentPaneFlickerProbe.capture(UInt32(c.window.windowNumber), whole) else { return note("agentmain \(engine): no window picture for \(name)") }
        let rep = NSBitmapImageRep(cgImage: img)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png")) }
    }

    func writeFrames(_ name: String) {
        let dir = runner.dir.appendingPathComponent("\(name)-\(engine)-frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, f) in frames.enumerated() {
            if let png = NSBitmapImageRep(cgImage: f).representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(String(format: "f%04d.png", i)))
            }
        }
        note("agentmain \(engine): \(frames.count) frames written to \(dir.lastPathComponent)")
        frames = []
    }

    /// Samples the main view every `every` s while `active` holds.
    func sampleWhile(every: Double = 0.125, _ active: @escaping () -> Bool, into store: @escaping (AgentPaneFlickerProbe.Pixels) -> Void, _ done: @escaping () -> Void) {
        func tick() {
            guard active() else { return done() }
            if let p = pagePicture() { store(p) }
            after(every, tick)
        }
        tick()
    }

    // MARK: Start, shield, Take over, Hand back

    func caseStart(_ done: @escaping () -> Void) {
        recording = true
        // The report's recording: our own window at 10 frames a second while this case runs.
        sampleWhile(every: 0.1, { [weak self] in self?.recording == true }, into: { _ in }) {}
        let before = Set(c.store.state.tabs.keys)
        k.start("main", [.tool("navigate", ["url": "\(base)/am-shop.html"]), .tool("screenshot", [:]),
                         .tool("left_click", ["coordinate": [320, 260]]),
                         .toolThenHold("wait", ["duration": 9], hold: 0.5),
                         // After the person's scroll: refused until it looks again, then fine.
                         .tool("left_click", ["coordinate": [320, 260]]), .tool("screenshot", [:]),
                         .tool("left_click", ["coordinate": [320, 120]]),
                         .toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")],
                task: "Count once on the tally page")
        wait({ self.k.events.filter { $0 == "tool wait" }.count >= 1 }, 30) { [self] in
            guard let e = entry, let page = e.page, let w = runWindow else { check(false, "the task's page is hosted in the main view (events \(mainEvents))"); return done() }
            let tab = c.store.tab(e.tabID)
            check(!before.contains(e.tabID) && c.shownTabID == e.tabID, "the task's page is a new tab, selected in the window (\(e.tabID), shown \(c.shownTabID ?? "none"))")
            check(tab?.isToday == true && tab?.spaceID == c.currentSpaceID, "… a Today tab of the current Space")
             check(tab?.title == "Counted 1" || tab?.title == "Tally (fixture)", "… titled with the page (“\(tab?.title ?? "")”)")
            check(!w.isParked(page) && page.view.window === c.window, "… its page is in the person's window, not a hidden one")
            let host = c.card.hostView?.bounds.size ?? .zero
            check(abs(page.view.bounds.width - host.width) < 1 && abs(page.view.bounds.height - host.height) < 1,
                  "… full size: the page fills the card (\(Int(page.view.bounds.width))x\(Int(page.view.bounds.height)) in \(Int(host.width))x\(Int(host.height)))")
            check(w.size == page.view.bounds.size, "the agent's viewport is that real size (\(Int(w.size.width))x\(Int(w.size.height)))")
            let display = "(display \(Int(w.size.width))x\(Int(w.size.height)))"
            check(k.fake.bodies("main").contains { $0.contains(display) }, "… its screenshot was taken at it: \(display)")
            check(main.modeShown(c) == .working(waiting: false) && chrome?.isHidden == false, "glow and bar are on (\(main.modeShown(c)))")
            check(chrome.map { TestAnchors.view("agentmain.bar.title", in: $0) != nil && $0.barFrame.height > 20 } == true, "… the bar is on the page (\(chrome?.barFrame ?? .zero))")
            check((chrome?.glowState.opacity ?? 0) > 0.4, "… the glow is on (opacity \(chrome?.glowState.opacity ?? 0))")
            check(chrome?.frame == c.card.hostView?.frame, "… lying over the page: no layout shift (page \(c.card.hostView?.frame ?? .zero))")
            if let p = pagePicture() {
                let l = look(p, want: (0x1e, 0x8c, 0x7a))
                check(l.white < 0.2 && l.match > 0.5, "the main view shows the page's pixels, live (teal \(Int(l.match * 100)) %, white \(Int(l.white * 100)) %, dominant \(l.dominant))")
            } else { note("FAIL-ENV agentmain \(engine): no window-server picture (legacy capture off)") }
            check((chrome?.pulses ?? 0) >= 1 && chrome?.lastPulse == CGPoint(x: 320, y: 260), "the agent's click shows a pulse where it clicked (\(chrome?.pulses ?? 0), \(String(describing: chrome?.lastPulse)))")
            read("window.buys||0") { [self] v in
                check(number(v) == 1, "the agent's click landed on the page's button (buys \(number(v)))")
                shot("agentmain-working-light")
                shield(done)
            }
        }
    }

    func shield(_ done: @escaping () -> Void) {
        let clicks0 = chrome?.blockedClicks ?? 0
        read("window.downs") { [self] d0 in
            personClick(CGPoint(x: 320, y: 260)) { [self] how in
                after(0.6) { [self] in
                    read("[window.downs, window.buys||0]") { [self] v in
                        let a = v as? [Any] ?? []
                        check((chrome?.blockedClicks ?? 0) > clicks0, "the person's click on the page stops at the shield [\(how)] (\(chrome?.blockedClicks ?? 0))")
                        check(a.count == 2 && number(a[0]) == number(d0) && number(a[1]) == 1, "… and doesn't reach the page (downs \(number(d0)) → \(a.first.map(number) ?? -1), buys \(a.count > 1 ? number(a[1]) : -1))")
                        check(chrome.map { TestAnchors.view("agentmain.hint", in: $0) != nil } == true && chrome?.bar.hint == "Take over to use this page",
                              "… with the hint “Take over to use this page”")
                        shot("agentmain-hint-light")
                        let keys0 = chrome?.blockedKeys ?? 0
                        personType("xy") { [self] how in
                            after(0.6) { [self] in
                                read("document.getElementById('q').value") { [self] q in
                                    check((chrome?.blockedKeys ?? 0) > keys0, "the person's typing stops at the shield too [\(how)] (\(chrome?.blockedKeys ?? 0))")
                                    check((q as? String) == "", "… nothing typed reaches the page (“\(q ?? "")”)")
                                    scrollAndLook(done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func scrollAndLook(_ done: @escaping () -> Void) {
        personScroll(-240) { [self] in
            read("window.scrollY") { [self] y in
                check(number(y) > 0, "a scroll to look reaches the page (scrollY \(number(y))) [posted]")
                check(mainEvents.contains { $0.hasPrefix("person-scroll") }, "… and is noted for the agent")
                // The script's next click after the wait comes without a look: refused; after its screenshot, it acts.
                wait({ self.k.events.filter { $0 == "tool wait" }.count >= 2 }, 30) { [self] in
                    let bodies = k.fake.bodies("main").joined()
                    check(bodies.contains("moved since your last look"), "the agent's click after the scroll is refused until it looks again")
                    read("window.buys||0") { [self] v in
                        check(number(v) == 1, "… so it never clicked a stale place (buys \(number(v)))")
                        takeOver(done)
                    }
                }
            }
        }
    }

    func takeOver(_ done: @escaping () -> Void) {
        guard let chrome, let e = entry, let page = e.page else { check(false, "the bar is there for Take over"); return done() }
        let tabID = e.tabID
        k.press("agentmain.takeover", "Take over (bar)", in: chrome, fallback: { self.chrome?.bar.onTakeOver() }) { [self] how in
            wait({ !self.run.state.isActive && self.main.modeShown(self.c) == .takenOver }, 8) { [self] in
                check(!run.state.isActive && k.model?.takenOver != nil, "Take over pauses the agent at once [\(how) click]")
                check(c.shownTabID == tabID && main.modeShown(c) == .takenOver, "… the page stays where it is, the person's now (bar: Hand back)")
                check(chrome.shields == false, "… no shield any more")
                shot("agentmain-takenover-light")
                // The run stopped (Take over), so the page is read directly, not through the run's window.
                read("window.downs", from: page) { [self] d0 in
                    personClick(CGPoint(x: 320, y: 140)) { [self] how in
                        after(0.6) { [self] in
                            read("window.downs", from: page) { [self] d1 in
                                check(number(d1) == number(d0) + 1, "… the person's click reaches the page now [\(how)] (downs \(number(d0)) → \(number(d1)))")
                                handBack(tabID, done)
                            }
                        }
                    }
                }
            }
        }
    }

    func handBack(_ tabID: String, _ done: @escaping () -> Void) {
        let kept = AgentPaneCheck.modelTurns(items: run.conversationItemsForTesting)
        k.fake.begin("back", [.tool("screenshot", [:]), .tool("left_click", ["coordinate": [320, 120]]),
                              .toolThenHold("wait", ["duration": 3], hold: 0.3),
                              .tool("navigate", ["url": "\(base)/am-moving.html"]),
                              .toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")], offset: kept)
        k.events = []
        guard let chrome else { return done() }
        k.press("agentmain.handback", "Hand back (bar)", in: chrome, fallback: { self.chrome?.bar.onHandBack() }) { [self] how in
            wait({ self.run.state.isActive && self.k.events.contains("tool wait") }, 20) { [self] in
                check(run.state.isActive && k.fake.bodies("back").last?.contains("handed it back") == true, "Hand back: the agent goes on, told to look again [\(how) click]")
                check(entry?.tabID == tabID && c.shownTabID == tabID && main.modeShown(c) == .working(waiting: false), "… in the same tab, glow and bar on again")
                recording = false
                writeFrames("agentmain-start")
                done()
            }
        }
    }

    // MARK: Switching away and back

    func caseSwitch(_ done: @escaping () -> Void) {
        // Continues the "back" script: the agent waits 3 s, then navigates while the person looks at another tab.
        if !run.state.isActive {
            k.start("back", [.tool("navigate", ["url": "\(base)/am-shop.html"]), .toolThenHold("wait", ["duration": 3], hold: 0.3),
                             .tool("navigate", ["url": "\(base)/am-moving.html"]), .toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")],
                    task: "Look at the moving page")
        }
        wait({ self.k.events.contains("tool wait") && self.entry != nil }, 20) { [self] in
            guard let e = entry, let page = e.page, let w = runWindow, let home = homeTabID else { check(false, "a running task for the switch case"); return done() }
            let size = page.view.bounds.size
            c.show(home)
            wait({ w.isParked(page) }, 3) { [self] in
                check(c.shownTabID == home && w.isParked(page), "switching tabs: the agent's page leaves the main view and parks, live [posted pick]")
                check(w.size == size, "… at the same viewport size (\(Int(w.size.width))x\(Int(w.size.height)) vs \(Int(size.width))x\(Int(size.height)))")
                check(main.modeShown(c) == .off && chrome?.isHidden != false, "… no glow or bar over the person's tab")
                wait({ self.k.point("agentpane.live.picture") != nil && AgentPaneLiveView.current?.mode ?? "none" != "none" }, 6) { [self] in
                    check(k.point("agentpane.live.picture") != nil, "the pane shows the small live card while the person is away (\(AgentPaneLiveView.current?.mode ?? "none"))")
                    wait({ self.c.store.tab(e.tabID)?.title == "Moving" }, 15) { [self] in
                        check(run.state.isActive && page.url?.path == "/am-moving.html", "the agent keeps going in its tab (it navigated: \(page.url?.path ?? ""))")
                        check(c.store.tab(e.tabID)?.title == "Moving", "… and its Today row follows (“\(c.store.tab(e.tabID)?.title ?? "")”)")
                        cardMoves { [self] moving in
                            check(moving, "… with live pixels in the card (two window-server pictures 0.4 s apart differ)")
                            shot("agentmain-away-light")
                            page.evaluate("window.__am = 42; 1") { [self] _ in
                                // The way back, pictured at 60 per second from the click on: never a blank frame.
                                var back: [Look] = []
                                var sampling = true
                                sampleWhile(every: 1.0 / 60, { sampling }, into: { [weak self] p in
                                    guard let self, self.c.shownTabID == e.tabID else { return }
                                    back.append(self.look(p, want: (0x7a, 0x3f, 0xd0)))
                                }) {}
                                after(1.6) { sampling = false }
                                k.press("agentpane.live.picture", "the live card", fallback: { self.k.model?.openWatch() }) { [self] how in
                                    wait({ self.c.shownTabID == e.tabID && !w.isParked(page) }, 4) { [self] in
                                      after(1.7) { [self] in
                                        let blank = back.filter { $0.white > 0.6 || ($0.match < 0.2 && $0.white > 0.3) }
                                        note("agentmain \(engine): way back: \(back.count) pictures, white/blank \(blank.count); first \(back.prefix(3).map { "white \(Int($0.white * 100)) % match \(Int($0.match * 100)) %" })")
                                        check(back.count >= 20 && blank.isEmpty, "… with no blank frame on the way back (\(blank.count) of \(back.count) pictures at 60/s)")
                                        check(c.shownTabID == e.tabID && !w.isParked(page), "a click on the card brings the page back into the main view [\(how) click]")
                                        check(page.view.bounds.size == size, "… at its size (\(Int(page.view.bounds.width))x\(Int(page.view.bounds.height)))")
                                        check(main.modeShown(c) == .working(waiting: false), "… glow and bar back on")
                                        after(0.4) { [self] in
                                            check(k.point("agentpane.live.picture") == nil, "… and the pane's card goes (the main view shows it)")
                                            read("window.__am") { [self] v in
                                                check(number(v) == 42, "… the same page, nothing loaded again (marker \(number(v)))")
                                                if let p = pagePicture() {
                                                    let l = look(p, want: (0x7a, 0x3f, 0xd0))
                                                    check(l.white < 0.2 && l.match > 0.4, "… its live pixels in the main view (purple \(Int(l.match * 100)) %, white \(Int(l.white * 100)) %)")
                                                }
                                                done()
                                            }
                                        }
                                      }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Two window-server pictures of the pane's card differ (the page's bar moves).
    func cardMoves(_ done: @escaping (Bool) -> Void) {
        guard let v = AgentPaneLiveView.current, let rect = AgentPaneFlickerProbe.rect(of: v, margin: -2), let w = v.window,
              let a = AgentPaneFlickerProbe.capture(UInt32(w.windowNumber), rect) else { return done(false) }
        after(0.4) {
            guard let b = AgentPaneFlickerProbe.capture(UInt32(w.windowNumber), rect), let pa = AgentPaneFlickerProbe.Pixels(a),
                  let pb = AgentPaneFlickerProbe.Pixels(b), pa.w == pb.w, pa.h == pb.h else { return done(false) }
            var diff = 0
            for i in stride(from: 0, to: pa.data.count, by: 4 * 7) where abs(Int(pa.data[i]) - Int(pb.data[i])) > 30 { diff += 1 }
            done(diff > 20)
        }
    }

    // MARK: Two agent tabs

    func caseTwo(_ done: @escaping () -> Void) {
        k.start("two", [.tool("navigate", ["url": "\(base)/am-a.html"]), .tool("open_tab", ["url": "\(base)/am-b.html"]),
                        .toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")], task: "Compare page A and page B")
        wait({ self.k.events.contains("tool wait") }, 25) { [self] in
            let mine = main.hosted.filter { $0.window === self.runWindow }
            let ids = mine.map(\.tabID)
            check(mine.count == 2 && ids.allSatisfy { c.store.tab($0)?.isToday == true }, "two agent tabs at once, both Today tabs (\(ids))")
            let b = mine.first { $0.page?.url?.path == "/am-b.html" }, a = mine.first { $0.page?.url?.path == "/am-a.html" }
            check(b != nil && c.shownTabID == b?.tabID, "… the agent's selected one is in the main view")
            check(a.flatMap { x in x.page.map { x.window?.isParked($0) == true } } == true, "… the other one is parked, live")
            guard let a, let b else { return done() }
            outsideAgent { [self] in
            c.show(a.tabID)
            wait({ b.page.map { b.window?.isParked($0) == true } == true }, 3) { [self] in
                check(c.shownTabID == a.tabID && a.page?.view.window === c.window, "picking the other agent tab: it comes into the main view [posted pick]")
                check(b.page.map { b.window?.isParked($0) == true } == true, "… and the first one parks; only one is ever in the main view")
                if let p = pagePicture() {
                    let l = look(p, want: (0xe0, 0x30, 0x6a))
                    check(l.white < 0.2 && l.match > 0.4, "… with its own live pixels (pink \(Int(l.match * 100)) %, white \(Int(l.white * 100)) %)")
                }
                stop(keeping: [a.tabID, b.tabID]) { [self] in
                    if let o = outside { AgentCenter.shared.endPanel(o, .done) }
                    outside = nil
                    done()
                }
            }
            }
        }
    }

    /// An outside app's agent (an MCP session, in process) at the same time: its own off-screen window, never hosted,
    /// its page live (the engine's own capture of it isn't blank) while the Airc task's two tabs are in the window.
    var outside: AgentSession?
    func outsideAgent(_ done: @escaping () -> Void) {
        let s = AgentSession(id: 990_001, persistent: true)
        s.client = "Fixture MCP app"
        s.clientName = "Fixture MCP app"
        s.clientKey = "fixture-mcp-app"
        s.via = "check"
        s.profileID = c.store.profile(ofSpace: c.currentSpaceID).id
        AgentCenter.shared.admitPanel(s)
        outside = s
        guard let open = AgentCenter.shared.tools.first(where: { $0.name == "open_window" }) else { check(false, "open_window"); return done() }
        open.run(["url": "\(base)/am-moving.html"], s) { [self] r in
            let wid = (r.structured?["window"] as? Int) ?? s.currentWindow
            guard let ow = wid.flatMap({ AgentCenter.shared.windows[$0] }), let page = ow.activeTab else { check(false, "the outside app's window opens (\(AgentBridge.text(r)))"); return done() }
            check(!ow.hostsInMainView && main.entry(page) == nil && page.view.window === ow.window, "an outside app's agent at the same time keeps its own off-screen window (not in the main view)")
            let mine = main.hosted.filter { $0.window === self.runWindow }.count
            check(mine == 2 && run.state.isActive, "… while the Airc task's two tabs stay live in the person's window (\(mine) hosted)")
            after(1.0) { [self] in
                ow.driver.capture(page) { [self] result in
                    DispatchQueue.main.async { [self] in
                        if case .success(let img) = result, let p = AgentPaneFlickerProbe.Pixels(img) {
                            let l = look(p, want: (0x7a, 0x3f, 0xd0))
                            check(l.match > 0.4, "… and its page draws (purple \(Int(l.match * 100)) %)")
                        } else { check(false, "… and its page draws (no capture)") }
                        done()
                    }
                }
            }
        }
    }

    func stop(keeping ids: [String], _ done: @escaping () -> Void) {
        guard let chrome else { check(false, "the bar is there for Stop"); return done() }
        let windowID = run.runWindowID
        k.press("agentmain.stop", "Stop (bar)", in: chrome, fallback: { self.chrome?.bar.onStop() }) { [self] how in
            wait({ !self.run.state.isActive }, 8) { [self] in
                if case .stopped = run.state { check(true, "Stop in the bar ends the task [\(how) click]") } else { check(false, "Stop in the bar ends the task (\(run.state))") }
                after(0.8) { [self] in
                    check(windowID.map { AgentCenter.shared.windows[$0] == nil } == true, "… its agent window is gone")
                    check(ids.allSatisfy { c.store.tab($0) != nil } && main.hosted.isEmpty, "… its tabs stay, the person's ordinary tabs (\(ids.filter { c.store.tab($0) != nil }.count) of \(ids.count))")
                    check(main.modeShown(c) == .off && self.chrome?.isHidden == true, "… no glow or bar")
                    for id in ids { c.closeTab(id) }
                    done()
                }
            }
        }
    }

    // MARK: 32 navigations, Stop and Continue

    func caseLong(_ done: @escaping () -> Void) {
        func navs(_ range: Range<Int>) -> [FakeModelServer.Turn] {
            range.map { i in .tool("navigate", ["url": "\(base)/am-\(i % 2 == 0 ? "a" : "b").html?\(i)"]) }
        }
        let first = navs(0..<16) + [.toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")]
        var samples: [(nav: Int, path: String, look: Look, settled: Bool)] = []
        var navDone = 0
        let pink = (0xe0, 0x30, 0x6a), blue = (0x2f, 0x6f, 0xdf)
        var tabAtStart: String?
        k.start("long", first, task: "Visit page A and page B over and over")
        let observer = run.onEvent
        run.onEvent = { [weak self] e in
            observer?(e)
            guard let self, e == "turn" else { return }
            // A turn starts after each navigate's result: the page has loaded. A settled sample now.
            let path = self.entry?.page?.url?.path ?? ""
            // The first turn comes before any navigation (about:blank): not a page of the run.
            guard path.hasPrefix("/am-") else { return }
            navDone += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, let p = self.pagePicture() else { return }
                samples.append((navDone, path, self.look(p, want: path.contains("am-a") ? pink : blue), true))
            }
        }
        var active = true
        sampleWhile({ active }, into: { [weak self] p in
            guard let self, let path = self.entry?.page?.url?.path, path.hasPrefix("/am-") else { return }
            samples.append((navDone, path, self.look(p, want: path.contains("am-a") ? pink : blue), false))
        }) {}
        wait({ self.k.events.contains("tool wait") }, 60) { [self] in
            tabAtStart = entry?.tabID
            guard let chrome else { active = false; check(false, "the bar for the long case"); return done() }
            k.press("agentmain.stop", "Stop (bar) mid-run", in: chrome, fallback: { self.chrome?.bar.onStop() }) { [self] how in
                wait({ !self.run.state.isActive }, 8) { [self] in
                    let kept = AgentPaneCheck.modelTurns(items: run.conversationItemsForTesting)
                    k.fake.begin("long2", navs(16..<32) + [.text("Visited both pages 32 times.")], offset: kept)
                    k.events = []
                    check(tabAtStart != nil && c.store.tab(tabAtStart!) != nil, "Stop mid-run [\(how) click]: the tab stays")
                    run.continueRun()
                    wait({ !self.run.state.isActive && self.k.events.contains("state done") }, 90) { [self] in
                        active = false
                        let settled = samples.filter { $0.settled }
                        let navCount = 32
                        // Never white or empty (the card's own dark fill); the page just loaded shows in most pictures
                        // (otherwise the one before it, until the new one paints).
                        func empty(_ l: Look) -> Bool { l.white > 0.2 || (l.dominant.0 < 60 && l.dominant.1 < 60 && l.dominant.2 < 60) }
                        let bad = settled.filter { empty($0.look) }
                        let own = settled.filter { $0.look.match >= 0.4 }.count
                        note("agentmain \(engine): long: \(samples.count) samples (\(settled.count) settled), white samples \(samples.filter { $0.look.white > 0.5 }.count); bad settled: \(bad.prefix(6).map { "#\($0.nav) \($0.path) white \(Int($0.look.white * 100)) % match \(Int($0.look.match * 100)) % dominant \($0.look.dominant)" })")
                        check(run.state == .done && finalText == "Visited both pages 32 times.", "Continue goes on to the end (\(run.state))")
                        check(tabAtStart != nil && entry?.tabID == tabAtStart && c.shownTabID == tabAtStart,
                              "… in the same tab, in the main view (\(tabAtStart ?? "none") → \(entry?.tabID ?? "none"))")
                        check(settled.count >= navCount - 2, "\(navCount) navigations, a main-view picture after each (\(settled.count))")
                        check(!settled.isEmpty && bad.isEmpty, "… every one shows live page pixels, never white or empty (\(bad.count) bad)")
                        check(Double(own) >= 0.8 * Double(settled.count), "… the page just loaded in \(own) of \(settled.count) (else the one before it, still painting)")
                        let blank = samples.filter { empty($0.look) }.count
                        check(blank == 0, "… and at 8 per second, never a white or empty main view (\(blank) of \(samples.count))")
                        run.onEvent = observer
                        if let id = tabAtStart { c.closeTab(id) }
                        done()
                    }
                }
            }
        }
    }

    var finalText: String { run.steps.last { $0.kind == .final }?.text ?? "" }

    // MARK: Dark

    func caseDark(_ done: @escaping () -> Void) {
        let old = NSApp.appearance
        let oldTheme = c.store.space(c.currentSpaceID)?.theme.appearance
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = .dark }
        c.reloadAll(animated: false)
        k.start("dark", [.tool("navigate", ["url": "\(base)/am-shop.html"]), .tool("screenshot", [:]), .tool("left_click", ["coordinate": [320, 260]]),
                         .toolThenHold("wait", ["duration": 40], hold: 1.5), .text("Never reached.")], task: "Count once (dark)")
        wait({ self.k.events.contains("tool wait") }, 25) { [self] in
            after(0.3) { [self] in
                check(main.modeShown(c) == .working(waiting: false), "dark: glow and bar on")
                shot("agentmain-working-dark")
                personClick(CGPoint(x: 320, y: 260)) { [self] _ in
                    after(0.4) { [self] in
                        shot("agentmain-hint-dark")
                        let id = entry?.tabID
                        run.stop()
                        after(0.6) { [self] in
                            NSApp.appearance = old
                            if let oldTheme { try? c.store.updateSpace(c.currentSpaceID) { $0.theme.appearance = oldTheme } }
                            c.reloadAll(animated: false)
                            if let id { c.closeTab(id) }
                            done()
                        }
                    }
                }
            }
        }
    }

    func finish() {
        note("agentmain \(engine): main-view events \(mainEvents.suffix(40).joined(separator: " | "))")
        main.onEvent = nil
        k.finish()
    }
}
#endif
