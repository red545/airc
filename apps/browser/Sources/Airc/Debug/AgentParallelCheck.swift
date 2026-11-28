// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentparallel` (agentparallel; docs/design/agent-ux.md §1, §5, §6): Airc Agent tasks run side by side.
/// FakeModelServer scripts per task (a marker in each prompt), local fixture pages (one per task, each with its own
/// counter), real driver clicks in a dedicated session (else posted, and said so). `AIRC_AGENTPARALLEL_ONLY=three,stop,
/// approvals,windows,idle,queue,ratelimit`. Cases:
/// - three: three tasks started back to back in one window: each its own run, agent window, Today tab, task row and
///   record; their tool calls overlap in time; each page counts only its own task's clicks; each ends with its own
///   answer; the window never changes Space and stays key;
/// - stop: Stop on one task's bar (real click) ends that task only; the other two finish;
/// - approvals: two tasks wait for an OK at once: two "needs you" items, each landing on its own task; Allow once on
///   one lets only that one go on; Deny on the other stops only it;
/// - windows: a task in window A and one in window B (another profile) at once: each page in its own window and
///   profile, neither window changes Space, the key window stays the same;
/// - idle: three tasks parked at a model wait: CPU and memory of the app (samples, for the report and the budget);
/// - queue: with a limit of 2 (AIRC_AGENT_MAX_PARALLEL), a third task is Queued and starts when one ends;
/// - ratelimit: the model answers 429 once: the task waits (Retry-After) and goes on.
extension SnapshotRunner {
    func agentParallelScenario() {
        let m = AgentParallelCheck(runner: self)
        step { done in m.setUp(done) }
        if AgentParallelCheck.runs("three") { step { done in m.caseThree(done) } }
        if AgentParallelCheck.runs("stop") { step { done in m.caseStop(done) } }
        if AgentParallelCheck.runs("approvals") { step { done in m.caseApprovals(done) } }
        if AgentParallelCheck.runs("windows") { step { done in m.caseWindows(done) } }
        if AgentParallelCheck.runs("idle") { step { done in m.caseIdle(done) } }
        if AgentParallelCheck.runs("queue") { step { done in m.caseQueue(done) } }
        if AgentParallelCheck.runs("ratelimit") { step { done in m.caseRateLimit(done) } }
        // agentparkcpu (AgentParkCPUCheck.swift): measurements, only when asked for by name.
        if AgentParallelCheck.only?.contains("parkcpu") == true { step { done in m.caseParkCPU(done) } }
        if AgentParallelCheck.only?.contains("parkstep") == true { step { done in m.caseParkStep(done) } }
        if AgentParallelCheck.only?.contains("cardframe") == true { step { done in m.caseCardFrame(done) } }
        if AgentParallelCheck.only?.contains("cardrepro") == true { step { done in m.caseCardRepro(done) } }
        // agentpanescope (AgentPaneSpaces.swift): the pane per window and Space, the field keeping the keys.
        if AgentParallelCheck.only?.contains("spaces") == true { step { done in m.caseSpaces(done) } }
        if AgentParallelCheck.only?.contains("panefocus") == true { step { done in m.caseFocus(done) } }
        // agentparkclick (AgentParkClick.swift): asked, then a Space switch before the page exists.
        if AgentParallelCheck.only?.contains("askswitch") == true { step { done in m.caseAskSwitch(done) } }
        run { m.finish() }
    }
}

final class AgentParallelCheck {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var tasks: AgentTaskCenter { .shared }
    var main: AgentMainView { .shared }
    var engine: String { k.engine }
    var base: String { k.base }
    /// The main window, fixed at set up (k.c follows the frontmost controller).
    var home: WindowController!
    /// Events of every task, with the task and the time.
    var events: [(task: String, event: String, at: Date)] = []
    /// agentpanescope: the spaces case's Space switches and main-view events, with times.
    var spaceLog: [(Date, String)] = []

    static var only: Set<String>? {
        ProcessInfo.processInfo.environment["AIRC_AGENTPARALLEL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    }
    static func runs(_ name: String) -> Bool { only?.contains(name) ?? true }

    /// A tally page per task: its own colour, a moving bar, a Count button (neutral word: no approval) and a counter.
    static func tally(_ name: String, _ css: String) -> String {
        """
        <title>\(name)</title><style>html,body{margin:0;background:\(css);font:16px sans-serif;color:#fff}
        #bar{position:fixed;top:120px;left:0;width:120px;height:40px;background:#fff8;animation:m 1s linear infinite alternate}
        @keyframes m{to{left:600px}} #count{position:absolute;left:220px;top:220px;width:200px;height:80px;font-size:20px}</style>
        <div id=bar></div><button id=count onclick="window.counts=(window.counts||0)+1;document.title='\(name) '+window.counts">Count</button>
        """
    }

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agentparallel"
        k.extraPages = ["/pa-1.html": Self.tally("One", "#1e8c7a"), "/pa-2.html": Self.tally("Two", "#2f6fdf"),
                        "/pa-3.html": Self.tally("Three", "#c0392b"), "/pa-4.html": Self.tally("Four", "#7a3fd0")]
        k.extraPages.merge(Self.parkPages) { a, _ in a }
    }

    func check(_ ok: Bool, _ what: String) { k.check(ok, what) }
    func note(_ s: String) { k.note(s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { k.after(s, body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        k.setUp { [self] in
            home = c
            AgentModelSettings.shared.setTestKey(k.key, provider: .anthropic, base: base)
            note("agentparallel \(engine): limit \(tasks.limit), input \(k.real ? "real" : "posted")")
            done()
        }
    }

    /// Follows a run's events (with its marker as the task's name).
    func follow(_ r: AgentRunCenter, _ name: String) {
        r.onEvent = { [weak self] e in self?.events.append((name, e, Date())) }
    }

    /// A new task from the window's pane (✎ New, then the field's Send), with its own script.
    @discardableResult
    func start(_ name: String, _ turns: [FakeModelServer.Turn], task: String, in w: WindowController? = nil) -> AgentRunCenter? {
        let w = w ?? home!
        k.fake.begin(tagged: "[[\(name)]]", name, turns)
        let p = AgentPaneController.show(w)
        p.model.newTask()
        let r = p.model.run
        follow(r, name)
        p.model.text = task + " [[\(name)]]"
        p.model.send()
        return r.steps.isEmpty && r.queuedPrompt == nil ? nil : r
    }

    func tally(_ n: Int, _ end: String, holds: Double = 2.5) -> [FakeModelServer.Turn] {
        [.tool("navigate", ["url": "\(base)/pa-\(n).html"]), .tool("screenshot", [:]),
         .tool("left_click", ["coordinate": [320, 260]]), .toolThenHold("wait", ["duration": 2], hold: holds),
         .tool("left_click", ["coordinate": [320, 260]]), .text(end)]
    }

    func page(_ r: AgentRunCenter) -> EngineTab? { main.entry(for: r)?.page }

    func read(_ js: String, on page: EngineTab?, _ done: @escaping (Int) -> Void) {
        guard let page else { return done(-1) }
        page.evaluate("JSON.stringify(\(js))") { v in done(Int("\(v ?? "")") ?? (v as? NSNumber)?.intValue ?? -1) }
    }

    /// The window's Space and key state, sampled while a case runs (no Space switch, no focus steal).
    final class Steady {
        var spaceChanges = 0, keyLost = 0, samples = 0
        var spaces: [ObjectIdentifier: String] = [:]
        var onSpace: [ObjectIdentifier: Bool] = [:]
        var offSpace = 0
    }

    func watchSteady(_ windows: [WindowController], key: WindowController?, while active: @escaping () -> Bool) -> Steady {
        let s = Steady()
        for w in windows {
            s.spaces[ObjectIdentifier(w)] = w.currentSpaceID
            s.onSpace[ObjectIdentifier(w)] = w.window.isOnActiveSpace
        }
        func tick() {
            guard active() else { return }
            s.samples += 1
            for w in windows {
                if s.spaces[ObjectIdentifier(w)] != w.currentSpaceID { s.spaceChanges += 1; s.spaces[ObjectIdentifier(w)] = w.currentSpaceID }
                if s.onSpace[ObjectIdentifier(w)] == true, !w.window.isOnActiveSpace { s.offSpace += 1 }
            }
            if let key, NSApp.isActive, !key.window.isKeyWindow { s.keyLost += 1 }
            after(0.1, tick)
        }
        tick()
        return s
    }

    // MARK: Three at once

    func caseThree(_ done: @escaping () -> Void) {
        events = []
        let wasKey = home.window.isKeyWindow
        let space = home.currentSpaceID
        var runs: [AgentRunCenter] = []
        var most = 0
        var allRunning = false
        let steady = watchSteady([home], key: wasKey ? home : nil, while: { runs.count < 3 || runs.contains { $0.isBusy } })
        func sample() {
            let n = runs.filter { $0.state.isActive }.count
            most = max(most, n)
            if n == 3 { allRunning = true }
            if runs.count < 3 || runs.contains(where: { $0.isBusy }) { after(0.05, sample) }
        }
        sample()
        for (i, name) in ["p1", "p2", "p3"].enumerated() {
            after(Double(i) * 0.4) { [self] in
                if let r = start(name, tally(i + 1, "Task \(name) counted twice."), task: "Count twice on tally page \(i + 1)") { runs.append(r) }
                else { check(false, "three: task \(name) starts while \(runs.count) run") }
            }
        }
        // While they run: three rows, three pages.
        wait({ runs.count == 3 && runs.allSatisfy { r in self.events.contains { $0.task == self.name(r) && $0.event == "tool wait" } } }, 40) { [self] in
            let ids = Set(runs.map(\.taskID))
            check(ids.count == 3 && Set(runs.map { ObjectIdentifier($0) }).count == 3, "three: three tasks, each its own run (\(ids.count) ids)")
            let windows = Set(runs.compactMap(\.runWindowID))
            check(windows.count == 3, "three: … each its own agent window (\(windows.sorted()))")
            let tabs = runs.compactMap { main.entry(for: $0)?.tabID }
            check(Set(tabs).count == 3 && tabs.allSatisfy { home.store.tab($0)?.isToday == true && home.store.tab($0)?.spaceID == space },
                  "three: … each its own Today tab of this Space (\(tabs.count))")
            check(home.shownTabID == tabs.last, "three: the last one started is the one in the main view (shown \(home.shownTabID ?? "none"))")
            let rows = SidebarTaskList.tasks(spaceID: space, profileID: home.store.profile(ofSpace: space).id).map(\.id)
            check(ids.isSubset(of: Set(rows)), "three: … each its own task row in the Agents section (\(ids.intersection(rows).count) of 3)")
            let lines = SidebarTaskList.lines(SidebarTaskList.tasks(spaceID: space, profileID: home.store.profile(ofSpace: space).id))
            check(lines.filter { ids.contains($0.id) && $0.liveRowID != nil }.count == 3, "three: … each row with its own live page")
            home.sidebar.agents.refresh()
        }
        wait({ runs.count == 3 && runs.allSatisfy { !$0.isBusy } }, 60) { [self] in
            check(allRunning && most == 3, "three: all three ran at the same time (at most \(most) at once)")
            let overlaps = overlap(["p1", "p2", "p3"])
            check(overlaps, "three: their tool calls overlap in time")
            for (i, r) in runs.enumerated() {
                let name = self.name(r)
                check(r.state == .done, "three: \(name) finishes (\(r.state))")
                let answer = r.steps.last { $0.kind == .final }?.text ?? ""
                check(answer == "Task \(name) counted twice.", "three: … with its own answer (“\(answer)”)")
                check(!r.steps.contains { $0.kind == .user && !$0.text.contains("tally page \(i + 1)") }, "three: … its conversation is only its own")
            }
            check(steady.spaceChanges == 0 && steady.offSpace == 0, "three: the window never changed Space (\(steady.spaceChanges) changes, \(steady.offSpace) off-Space in \(steady.samples) samples)")
            if wasKey { check(steady.keyLost == 0, "three: … and stayed key (\(steady.keyLost) samples not key)") }
            else { note("agentparallel \(engine): three: window not key at start (posted run): focus not asserted") }
            var counts: [Int] = []
            // The recorder writes each task's record at most every 0.5 s.
            wait({ runs.allSatisfy { r in AgentTaskRecorder.shared.tasks.first { $0.id == r.taskID }?.status == .done } }, 4) { [self] in
            let records = runs.compactMap { r in AgentTaskRecorder.shared.tasks.first { $0.id == r.taskID } }
            check(records.count == 3 && records.allSatisfy { $0.status == .done }, "three: three task records, each Done (\(records.map(\.status.rawValue)))")
            func next(_ i: Int) {
                guard i < runs.count else {
                    check(counts == [2, 2, 2], "three: each page counted only its own task's clicks (\(counts))")
                    return after(0.3, done)
                }
                read("window.counts||0", on: page(runs[i]) ?? tabPage(runs[i])) { n in counts.append(n); next(i + 1) }
            }
            next(0)
            }
        }
    }

    /// The person's tab the task's page became (after the run ended its agent window keeps it, or the tab took it).
    func tabPage(_ r: AgentRunCenter) -> EngineTab? {
        main.hosted.first { $0.window?.taskID == r.taskID }?.page
    }

    func name(_ r: AgentRunCenter) -> String {
        let t = r.steps.first { $0.kind == .user }?.text ?? ""
        guard let a = t.range(of: "[["), let b = t.range(of: "]]", range: a.upperBound..<t.endIndex) else { return "?" }
        return String(t[a.upperBound..<b.lowerBound])
    }

    /// Whether every pair of the named tasks had tool calls in flight at overlapping times.
    func overlap(_ names: [String]) -> Bool {
        func span(_ n: String) -> (Date, Date)? {
            let t = events.filter { $0.task == n && $0.event.hasPrefix("tool ") }.map(\.at)
            guard let a = t.min(), let b = t.max() else { return nil }
            return (a, b)
        }
        let spans = names.compactMap(span)
        guard spans.count == names.count else { return false }
        for i in spans.indices { for j in spans.indices where j > i { if spans[i].1 < spans[j].0 || spans[j].1 < spans[i].0 { return false } } }
        return true
    }

    // MARK: Stop one

    func caseStop(_ done: @escaping () -> Void) {
        events = []
        var runs: [AgentRunCenter] = []
        for (i, name) in ["s1", "s2", "s3"].enumerated() {
            if let r = start(name, [.tool("navigate", ["url": "\(base)/pa-\(i + 1).html"]), .toolThenHold("wait", ["duration": 5], hold: 0.3),
                                    .tool("left_click", ["coordinate": [320, 260]]), .text("Task \(name) done.")],
                             task: "Wait then count on page \(i + 1)") { runs.append(r) }
        }
        guard runs.count == 3 else { check(false, "stop: three tasks start (\(runs.count))"); return done() }
        wait({ runs.allSatisfy { r in self.events.contains { $0.task == self.name(r) && $0.event == "tool wait" } } }, 30) { [self] in
            let target = runs[2]
            let shown = main.shownRun(in: home)
            check(shown === target, "stop: the window shows the last task's page, with its bar")
            guard let chrome = main.chromeView(home) else { check(false, "stop: the bar is there"); return done() }
            k.press("agentmain.stop", "Stop (bar of s3)", in: chrome, fallback: { chrome.bar.onStop() }) { [self] how in
                wait({ !target.isBusy }, 8) { [self] in
                    if case .stopped = target.state { check(true, "stop: Stop on s3's bar ends s3 [\(how) click]") } else { check(false, "stop: Stop on s3's bar ends s3 [\(how) click] (\(target.state))") }
                    check(runs[0].state.isActive && runs[1].state.isActive, "stop: … s1 and s2 keep running (\(runs[0].state), \(runs[1].state))")
                    wait({ !runs[0].isBusy && !runs[1].isBusy }, 30) { [self] in
                        check(runs[0].state == .done && runs[1].state == .done, "stop: s1 and s2 finish (\(runs[0].state), \(runs[1].state))")
                        check(!target.steps.contains { $0.kind == .final }, "stop: s3 didn't go on after Stop")
                        after(0.3, done)
                    }
                }
            }
        }
    }

    // MARK: Two approvals at once

    func caseApprovals(_ done: @escaping () -> Void) {
        events = []
        AgentAttention.resetForTesting()
        let sentBefore = k.fake.targets.filter { $0.hasPrefix("/sent") }.count
        func mail(_ end: String) -> [FakeModelServer.Turn] {
            [.tool("navigate", ["url": "\(base)/mail.html"]), .tool("left_click", ["coordinate": [80, 320]]), .tool("wait_for_load", [:]), .text(end)]
        }
        guard let a = start("a1", mail("Sent by a1."), task: "Send the fixture mail"),
              let b = start("a2", mail("Sent by a2."), task: "Send the fixture mail too") else { check(false, "approvals: two tasks start"); return done() }
        wait({ a.approval != nil && b.approval != nil }, 30) { [self] in
            check(a.approval != nil && b.approval != nil, "approvals: both tasks wait for an OK at once")
            let items = AgentAttention.items().filter { $0.kind == .approval }
            check(items.count == 2 && Set(items.compactMap(\.taskID)) == [a.taskID, b.taskID], "approvals: two “needs you” items, one per task (\(items.count))")
            check(a.approval?.id != b.approval?.id, "approvals: … two separate requests")
            // The pane shows b (started last): its Allow once lets only b go on.
            let p = AgentPaneController.pane(of: home)
            check(p?.model.run === b, "approvals: the pane shows the task started last")
            after(0.4) { [self] in
                k.press("agentpane.allow", "Allow once (b)", fallback: { b.answerApproval(allow: true) }) { [self] how in
                    wait({ !b.isBusy }, 20) { [self] in
                        check(b.state == .done, "approvals: Allow once on a2 lets a2 finish [\(how) click] (\(b.state))")
                        check(a.approval != nil && a.state == .waiting, "approvals: … a1 still waits for its own OK (\(a.state))")
                        check(!a.steps.contains { $0.kind == .decision }, "approvals: … nothing was decided for a1")
                        let sent = k.fake.targets.filter { $0.hasPrefix("/sent") }.count - sentBefore
                        check(sent == 1, "approvals: exactly one message sent so far (\(sent))")
                        // a1's item lands on a1 (the pane switches to it), Deny there.
                        guard let it = AgentAttention.items().first(where: { $0.taskID == a.taskID }) else { check(false, "approvals: a1's item"); return done() }
                        AgentAttention.go(it, from: "check")
                        after(0.6) { [self] in
                            check(AgentPaneController.pane(of: home)?.model.run === a, "approvals: a1's “needs you” opens the pane on a1")
                            k.press("agentpane.deny", "Deny (a1)", fallback: { a.answerApproval(allow: false) }) { [self] how in
                                wait({ !a.isBusy }, 10) { [self] in
                                    if case .stopped = a.state { check(true, "approvals: Deny on a1 stops a1 [\(how) click]") } else { check(false, "approvals: Deny on a1 stops a1 (\(a.state))") }
                                    check(b.steps.contains { $0.kind == .decision && $0.text.hasPrefix("Allowed") } && !b.steps.contains { $0.text.hasPrefix("Declined") },
                                          "approvals: a2's transcript has only its own Allowed")
                                    check(a.steps.contains { $0.kind == .decision && $0.text.hasPrefix("Declined") } && !a.steps.contains { $0.text.hasPrefix("Allowed") },
                                          "approvals: a1's transcript has only its own Declined")
                                    let sent = k.fake.targets.filter { $0.hasPrefix("/sent") }.count - sentBefore
                                    check(sent == 1, "approvals: still one message sent (\(sent))")
                                    after(0.3, done)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Two windows, two profiles

    func caseWindows(_ done: @escaping () -> Void) {
        events = []
        let a = home!
        let aSpace = a.currentSpaceID
        let p = try? a.profiles.createProfile(name: "Parallel Other", emoji: "", color: nil)
        guard let p, let s = try? a.store.createSpace(name: "Parallel other", icon: nil, theme: a.store.selectedSpace.theme, profileID: p.id, after: aSpace) else {
            check(false, "windows: another profile and its Space"); return done()
        }
        k.app.profiles.whenLoaded(p.id, { [self] _ in
            let b = k.app.openNewWindow(from: a, spaceID: s.id, commandBar: false)
            after(1.0) { [self] in
                guard let b else { check(false, "windows: a second window"); return done() }
                a.window.makeKeyAndOrderFront(nil)
                after(0.5) { [self] in
                    let key = a.window.isKeyWindow ? a : nil
                    var both: [AgentRunCenter] = []
                    let steady = watchSteady([a, b], key: key, while: { both.count < 2 || both.contains { $0.isBusy } })
                    let bSpace = b.currentSpaceID
                    // B's task starts from B's pane without making B key (a task asked there by a click would; here the
                    // point is that A's task and B's task run at once and neither moves the other window).
                    guard let ra = start("w1", tally(1, "w1 done.", holds: 3), task: "Count on page 1", in: a),
                          let rb = start("w2", tally(2, "w2 done.", holds: 3), task: "Count on page 2", in: b) else {
                        check(false, "windows: both tasks start"); b.window.close(); return done()
                    }
                    both = [ra, rb]
                    wait({ !ra.isBusy && !rb.isBusy }, 50) { [self] in
                        check(ra.state == .done && rb.state == .done, "windows: both finish (\(ra.state), \(rb.state))")
                        check(overlap(["w1", "w2"]), "windows: … at the same time")
                        let ea = main.hosted.first { $0.window?.taskID == ra.taskID }, eb = main.hosted.first { $0.window?.taskID == rb.taskID }
                        check(ea?.controller === a && eb?.controller === b, "windows: each task's page is a tab of its own window")
                        check(ra.profileID == a.store.profile(ofSpace: aSpace).id && rb.profileID == p.id, "windows: … each in its own window's profile")
                        check(a.currentSpaceID == aSpace && b.currentSpaceID == bSpace && steady.spaceChanges == 0,
                              "windows: neither window changed Space (\(steady.spaceChanges) in \(steady.samples) samples)")
                        if let key { check(steady.keyLost == 0 && key.window.isKeyWindow, "windows: window A stayed key (\(steady.keyLost) samples not)") }
                        else { note("agentparallel \(engine): windows: A not key at start (posted run): focus not asserted") }
                        b.window.close()
                        a.window.makeKeyAndOrderFront(nil)
                        after(0.6, done)
                    }
                }
            }
        }, failed: { [self] in check(false, "windows: the other profile loads"); done() })
    }

    // MARK: Parked, idle

    /// Three tasks wait at a long model hold with their pages parked: the app's CPU and memory, against before.
    func caseIdle(_ done: @escaping () -> Void) {
        events = []
        func cpuAndMemory(_ seconds: Double, _ done: @escaping (Double, Double) -> Void) {
            let t0 = ProcessInfo.processInfo.systemUptime, c0 = Self.cpuTime()
            after(seconds) {
                let used = Self.cpuTime() - c0, wall = ProcessInfo.processInfo.systemUptime - t0
                done(100 * used / wall, Double(Self.footprint()) / 1_048_576)
            }
        }
        cpuAndMemory(10) { [self] cpu0, mem0 in
            note("agentparallel \(engine): idle before: app CPU \(String(format: "%.2f", cpu0)) %, footprint \(Int(mem0)) MB")
            var runs: [AgentRunCenter] = []
            for (i, name) in ["i1", "i2", "i3"].enumerated() {
                if let r = start(name, [.tool("navigate", ["url": "\(base)/pa-\(i + 1).html"]), .toolThenHold("wait", ["duration": 1], hold: 40),
                                        .text("Done.")], task: "Hold on page \(i + 1)") { runs.append(r) }
            }
            wait({ runs.count == 3 && runs.allSatisfy { r in self.events.contains { $0.task == self.name(r) && $0.event == "tool wait" } } }, 30) { [self] in
                // The person goes back to their own tab: all three pages park (live).
                if let h = k.app.controllers.first, let tab = h.store.state.tabs.values.first(where: { $0.spaceID == h.currentSpaceID && $0.url.hasSuffix("/home.html") }) {
                    h.show(tab.id, focus: false)
                }
                after(3) { [self] in
                    let parked = runs.filter { r in main.entry(for: r).map { e in e.page.map { e.window?.isParked($0) ?? false } ?? false } ?? false }.count
                    check(parked == 3, "idle: the three pages are parked (\(parked))")
                    cpuAndMemory(20) { [self] cpu, mem in
                        note("agentparallel \(engine): idle with 3 parked: app CPU \(String(format: "%.2f", cpu)) %, footprint \(Int(mem)) MB (+\(Int(mem - mem0)) MB)")
                        let load = Self.load()
                        note("agentparallel \(engine): idle: load \(String(format: "%.1f", load)) (budget proposal: ≤ +1 % app CPU per parked task, ≤ +150 MB each)")
                        check(cpu - cpu0 < 30, "idle: three parked tasks don't busy-loop the app (CPU \(String(format: "%.1f", cpu)) %, before \(String(format: "%.1f", cpu0)) %)")
                        runs.forEach { $0.stop() }
                        wait({ runs.allSatisfy { !$0.isBusy } }, 10) { [self] in after(0.5, done) }
                    }
                }
            }
        }
    }

    static func cpuTime() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func load() -> Double {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) > 0 ? l[0] : -1
    }

    // MARK: Queue

    func caseQueue(_ done: @escaping () -> Void) {
        events = []
        let limit = tasks.limit
        guard limit > 0, limit <= 3 else { note("agentparallel \(engine): queue: limit \(limit): run with AIRC_AGENT_MAX_PARALLEL=2"); return done() }
        var runs: [AgentRunCenter] = []
        for i in 0..<(limit + 1) {
            let name = "q\(i + 1)"
            if let r = start(name, [.tool("navigate", ["url": "\(base)/pa-\(i % 4 + 1).html"]), .toolThenHold("wait", ["duration": 1], hold: 3),
                                    .text("\(name) done.")], task: "Queue task \(i + 1)") { runs.append(r) }
        }
        guard runs.count == limit + 1, let last = runs.last else { check(false, "queue: \(limit + 1) tasks asked (\(runs.count))"); return done() }
        after(0.5) { [self] in
            check(last.queuedPrompt != nil && !last.state.isActive, "queue: past the limit of \(limit), the next task is Queued")
            let rec = AgentTaskRecorder.shared.tasks.first { $0.id == last.taskID }
            check(rec?.status == .queued, "queue: … its record and row say Queued (\(rec?.status.rawValue ?? "none"))")
            check(tasks.active.count == limit, "queue: … \(limit) run (\(tasks.active.count))")
            wait({ runs.allSatisfy { !$0.isBusy } }, 60) { [self] in
                check(last.state == .done, "queue: the queued task started when one ended, and finished (\(last.state))")
                let started = events.first { $0.task == name(last) && $0.event == "state running" }?.at
                let firstEnd = events.filter { $0.task != name(last) && $0.event.hasPrefix("state done") }.map(\.at).min()
                if let started, let firstEnd { check(started >= firstEnd, "queue: … not before a slot was free") }
                after(0.3, done)
            }
        }
    }

    // MARK: Rate limit

    func caseRateLimit(_ done: @escaping () -> Void) {
        events = []
        k.fake.rateLimitNext("r1")
        guard let r = start("r1", [.tool("navigate", ["url": "\(base)/pa-1.html"]), .text("r1 done.")], task: "Open page 1") else {
            check(false, "ratelimit: the task starts"); return done()
        }
        wait({ !r.isBusy }, 30) { [self] in
            check(events.contains { $0.task == "r1" && $0.event.hasPrefix("rate limited") }, "ratelimit: a 429 makes the task wait, not fail")
            check(r.state == .done, "ratelimit: … then it goes on and finishes (\(r.state))")
            check(r.steps.contains { $0.kind == .info && $0.text.contains("rate limit") }, "ratelimit: … and says so in its steps")
            after(0.3, done)
        }
    }

    func finish() {
        tasks.stopAll()
        k.finish()
    }
}
#endif
