// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agenttasks` (asidepass): the agent's tasks as the person meets them, against the FakeModelServer
/// (no real model, no key but a fixture one in memory).
/// - The Command Bar's Ask mode: the Search | Ask switch, Tab keeping its Arc jobs (actions on an empty field) and
///   switching only where it would do nothing else, back from Ask always; the chips (attach, where, asks first,
///   provider, effort), "@" attaching the page; Return starting the task in its task view.
/// - The task view: steps on the timeline as they happen (the running one shimmers), the page an "Opened …" step
///   found, the streaming answer, the floating live card, Stop, the composer with its chips and a reply in the same
///   task; approvals in the view (Deny, Allow once).
/// - The sidebar's task rows: New Task, a spinner while it works, ✋ while it waits, a blue dot when it finished
///   unseen, a click opening the task view, Show all.
/// - agentrows: one sidebar row per task, running, waiting or done, before and after Show all (AgentRowsCensus): the
///   run's page is never a second row; the row's single status (spinner, ✋ with "Waiting for your OK", blue dot); a
///   click opens the right view (the task view, the approval); All tasks lists it once and opens it.
/// - Recent tasks cards in Ask mode (working time, title, last steps or the answer), a card opening its task.
/// Real driver clicks and keys in a dedicated session; else posted, and said so.
extension SnapshotRunner {
    func agentTasksScenario() {
        let t = AgentTasksCheck(runner: self)
        step { done in t.setUp(done) }
        step { done in t.caseAskMode(done) }
        step { done in t.caseTaskView(done) }
        step { done in t.caseReply(done) }
        step { done in t.caseSidebar(done) }
        step { done in t.caseShowAll(done) }
        step { done in t.caseRecent(done) }
        step { done in t.caseApproval(done) }
        run { t.finish() }
    }
}

final class AgentTasksCheck {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var run: AgentRunCenter { .shared }
    var engine: String { k.engine }
    var real: Bool { k.real }
    var bar: CommandBarView? { c.commandBar }
    var recorder: AgentTaskRecorder { .shared }
    let prompt = "Find the largest park in Brightport"
    var taskID: String?

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agenttasks"
        k.extraPages = ["/park.html": SnapshotRunner.parksPage]
    }

    func check(_ ok: Bool, _ what: String) { k.check(ok, what) }
    func note(_ s: String) { k.note(s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { k.after(s, body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    var taskPage: AgentTasksPage? { AgentTasksPage.existing(c.shownTabID) }
    var taskHost: NSView? { taskPage?.host }
    func inTask(_ anchor: String) -> Bool { taskHost.map { TestAnchors.view(anchor, in: $0) != nil } ?? false }
    func inSidebar(_ anchor: String) -> Bool { TestAnchors.view(anchor, in: c.sidebar.agents) != nil }
    func inAsk(_ anchor: String) -> Bool { bar?.askPanel.map { TestAnchors.view(anchor, in: $0) != nil } ?? false }

    func setUp(_ done: @escaping () -> Void) {
        k.setUp { [self] in
            k.setKeys(anthropic: true)
            // Wide enough for the floating live card beside the column.
            var f = c.window.frame
            if f.width < 1320 { f.size.width = min(1320, (c.window.screen?.visibleFrame.width ?? 1320) - 40); c.window.setFrame(f, display: true) }
            done()
        }
    }

    // MARK: Keys

    /// Tab, Return, "@": a real driver key at our PID, else posted through the app's queue.
    func barKey(_ name: String, _ done: @escaping (String) -> Void) {
        // "@" is typed through the bar's editor even with the driver: its key differs per layout (⌥L on buildmac's
        // Austrian one, where the driver's guess typed a quote).
        if real, name != "@" {
            return UIDriverClient.press([name], pid: getpid()) { ok, out in
                if !ok { self.note("FAIL-ENV agenttasks \(self.engine): the driver refused \(name) (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(ok ? "real key" : "posted") }
            }
        }
        if name == "@" {
            bar?.type((bar?.typed ?? "") + "@")
            return after(0.2) { done("posted") }
        }
        // Posted: the key's command through the bar's own field editor, as the keyboard's would go (ParityC08b): a posted
        // key event never reaches the field of a window that isn't key (a -g launch).
        if let b = bar {
            let ed = (b.window?.firstResponder as? NSTextView) ?? b.fieldEditor
            ed.doCommand(by: name == "tab" ? #selector(NSResponder.insertTab(_:)) : #selector(NSResponder.insertNewline(_:)))
        }
        after(0.3) { done("posted") }
    }

    func typeInBar(_ text: String, _ done: @escaping (String) -> Void) {
        guard real, let keys = UIDriverClient.keys(typing: text) else { bar?.type(text); return after(0.3) { done("posted") } }
        UIDriverClient.press(keys, pid: getpid()) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.note("FAIL-ENV agenttasks \(self.engine): the driver couldn't type (\(out)); posted"); self.bar?.type(text) }
                self.after(0.4) { done(ok ? "real" : "posted") }
            }
        }
    }

    /// A real click at a view's centre (AppKit views without anchors), else `fallback`.
    func click(_ v: NSView?, x fraction: CGFloat = 0.5, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        guard real, NSApp.isActive, let v, let w = v.window, let main = NSScreen.screens.first else { fallback(); return after(0.3) { done("posted") } }
        v.superview?.layoutSubtreeIfNeeded()
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        let p = CGPoint(x: (r.minX + r.width * fraction).rounded(), y: (main.frame.maxY - r.midY).rounded())
        UIDriverClient.run(["--click", "\(Int(p.x))", "\(Int(p.y))"]) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.note("FAIL-ENV agenttasks \(self.engine): the driver refused \(what) (\(out)); posted"); fallback() }
                self.after(0.4) { done(ok ? "real" : "posted") }
            }
        }
    }

    // MARK: Ask mode

    func caseAskMode(_ done: @escaping () -> Void) {
        run.newConversation()
        AgentPaneController.pane(of: c)?.close()
        k.fake.begin("ask", [.tool("navigate", ["url": "\(k.base)/park.html"]), .toolThenHold("read_page", ["mode": "text"], hold: 2.5),
                             .tool("find_element", ["query": "largest"]),
                             .slowText("The largest park in Brightport is **Brightport Commons**, at 412 hectares.\n\nIt has a lake and two playgrounds.", every: 0.06)])
        c.closeCommandBar()
        k.front { _ in }
        c.openCommandBar(mode: .newTab)
        after(0.4) { [self] in
            guard let bar else { check(false, "⌘T opens the Command Bar"); return done() }
            let toggle = bar.modeToggleForTesting
            check(!toggle.isHidden, "⌘T: the bar has the Search | Ask switch")
            check(!bar.askMode && !toggle.ask, "… on Search")
            check(toggle.showsTabHint, "… with “Tab to switch” on an empty field too (owner, 2026-11-24: Tab always switches)")
            barKey("tab") { [self] how in
                check(bar.askMode && bar.typed.isEmpty, "Tab on the empty field switches to Ask [\(how)] (field “\(bar.typed)”)")
                bar.setAskMode(false)
                bar.type("")
                typeInBar(prompt) { [self] typing in
                    check(toggle.showsTabHint, "a task typed: “Tab to switch” shows [\(typing) typing]")
                    barKey("tab") { [self] how in
                        check(bar.askMode && toggle.ask, "Tab switches to Ask [\(how)]")
                        check(bar.typed == prompt || bar.typed.hasPrefix(prompt), "… keeping what's typed (“\(bar.typed)”)")
                        check(bar.results.isEmpty, "… and Ask lists no search rows (\(bar.results.count))")
                        for (a, what) in [("agentask.chips", "the chips"), ("agentask.attach", "+ attach"), ("agentask.where", "where it runs (this Mac)"),
                                          ("agentask.safety", "asks first"), ("agentask.provider", "the provider"), ("agentask.level", "the effort")] {
                            check(inAsk(a), "Ask shows \(what)")
                        }
                        barKey("tab") { [self] how in
                            check(!bar.askMode && bar.typed.hasPrefix(prompt), "Tab in Ask goes back to Search, the text kept [\(how)]")
                            barKey("tab") { [self] _ in
                                check(bar.askMode, "… and Tab again is Ask again")
                                barKey("@") { [self] how in
                                    // Search's history and suggestions for the same words answer late: none may show in Ask.
                                    check(bar.results.isEmpty, "Ask stays free of search rows that arrive late (\(bar.results.count))")
                                    let attached = bar.askPanel?.model.attached ?? []
                                    check(attached.count == 1 && attached.first?.url.path == "/home.html", "“@” attaches the window's page as a chip [\(how)] (\(attached.map(\.title)))")
                                    check(inAsk("agentask.attached"), "… shown in the chips")
                                    check(!bar.typed.hasSuffix("@"), "… and the @ leaves the field")
                                    shot(bar, "agenttasks-ask")
                                    barKey("return") { [self] how in
                                        wait({ AgentTasksURL.taskID(self.c.store.tab(self.c.shownTabID)?.url) != nil }, 6) { [self] in
                                            let id = AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url)
                                            taskID = id
                                            check(id != nil && id == recorder.currentID, "Return in Ask starts the task and opens its task view [\(how)] (\(c.store.tab(c.shownTabID)?.url ?? "none"))")
                                            check(c.commandBar?.isParked != false, "… the bar closes")
                                            check(k.firstUserText(k.fake.bodies("ask").first).contains("/home.html"), "… with the attached page's address for the model")
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

    // MARK: Task view

    func caseTaskView(_ done: @escaping () -> Void) {
        var sawRunning = false, sawLive = false, sawPartial = false, sawSpinner = false, sawWorking = false, sawStop = false
        var liveFrame: NSRect?, columnMax: CGFloat = 0
        var census: (ok: Bool, detail: String)?, pageCensus: (ok: Bool, detail: String)?, statusWhileRunning = ""
        wait({
            if self.inTask("agenttask.step.running") { sawRunning = true }
            if self.inTask("agenttask.live") {
                sawLive = true
                if let h = self.taskHost, let v = TestAnchors.view("agenttask.live", in: h) { liveFrame = v.convert(v.bounds, to: h) }
                if let h = self.taskHost, let v = TestAnchors.view("agenttask.steps", in: h) { columnMax = max(columnMax, v.convert(v.bounds, to: h).maxX) }
            }
            if self.inTask("agenttask.partial") { sawPartial = true }
            if self.inTask("agenttask.working") { sawWorking = true }
            if self.inTask("agenttask.stop") { sawStop = true }
            if self.inSidebar("agents-task-spinner") { sawSpinner = true }
            // agentrows: once its page is live, the running task is one row (its page no second one).
            if census == nil, sawLive, self.run.state == .running, let id = self.recorder.currentID, AgentAttention.paneRowID != nil {
                census = AgentRowsCensus.folderTask(self.c, task: id)
                pageCensus = AgentRowsCensus.pageTask(self.c, task: id)
                statusWhileRunning = ["agents-task-spinner", "agents-task-waiting", "agents-task-unread", "agents-task-favicon", "agents-task-sparkle"]
                    .filter { self.inSidebar($0) }.joined(separator: " ")
                if census?.ok == true { self.shot(self.c.sidebar, "agentrows-running") }
            }
            if sawLive && sawRunning && !sawPartial, self.run.state == .running { self.shotTask("agenttasks-running") }
            return !self.run.state.isActive && self.k.fake.requests(for: "ask") > 0
        }, 45) { [self] in
            check(run.state == .done, "the task runs to the end (\(run.state))")
            check(sawRunning, "while it works, its step shows on the timeline and shimmers")
            check(sawWorking && sawStop, "… “Working for …” at the top and Stop in the composer")
            check(sawLive, "… the agent's page floats beside the timeline (live card)")
            if let f = liveFrame { check(f.minX >= columnMax - 0.5, "… right of the column, not over it (card x \(Int(f.minX)), column ends \(Int(columnMax)))") }
            check(sawPartial, "the answer streams into the view")
            check(sawSpinner, "the sidebar's task row spins while it works")
            check(census?.ok == true, "agentrows: running: the task is one row in the folder, its page no second one (\(census?.detail ?? "never sampled"))")
            check(pageCensus?.ok == true, "agentrows: running: All tasks lists it once (\(pageCensus?.detail ?? "never sampled"))")
            check(statusWhileRunning.contains("agents-task-spinner") && !statusWhileRunning.contains("waiting") && !statusWhileRunning.contains("unread")
                  && (statusWhileRunning.contains("favicon") || statusWhileRunning.contains("sparkle")),
                  "agentrows: running: one status, the spinner, and an icon (the page's or ✦) (\(statusWhileRunning))")
            after(1.0) { [self] in
                check(inTask("agenttask.answer"), "the answer stays in the view")
                check(!inTask("agenttask.live") && !inTask("agenttask.stop"), "the live card and Stop go when it's done")
                check(inTask("agenttask.summary"), "the run's steps have their header (“Worked for …”)")
                check(inTask("agenttask.result.page"), "the “Opened …” step shows the page it found")
                let r = recorder.tasks.first { $0.id == taskID }
                check(r?.status == .done && r?.unread == false, "the record: done, seen (it was on screen) (\(r.map { "\($0.status) unread \($0.unread)" } ?? "none"))")
                let kinds = r?.entries?.map(\.kind) ?? []
                check(kinds.first == .prompt && kinds.contains(.step) && kinds.last == .answer, "… keeps the timeline: prompt, steps, answer (\(kinds.count) lines)")
                check(r?.answerHead?.hasPrefix("The largest park in Brightport is Brightport Commons") == true, "… and the answer's start for the cards")
                check(r?.entries?.first?.text == prompt, "… the prompt without the attached page's line")
                // Never the key or page text in the file.
                let file = AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks/\(taskID ?? "x").json")
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                check(!text.isEmpty && !text.contains(k.key) && !text.contains("hectares.</p>") && !text.contains("<h1>"), "the task file has no key and no page text")
                check(!inSidebar("agents-task-spinner") && !inSidebar("agents-task-unread"), "the sidebar row: no spinner, no dot (seen)")
                shotTask("agenttasks-done")
                done()
            }
        }
    }

    func caseReply(_ done: @escaping () -> Void) {
        guard let page = taskPage else { check(false, "the task view is shown for a reply"); return done() }
        k.fake.begin("reply", Array(repeating: .text("It opens at 7:00 every day."), count: 10), offset: 0)
        check(inTask("agenttask.composer") && inTask("agentask.chips"), "the composer has the Ask chips")
        check(page.task.placeholder == "Reply, @ for context", "… and says “Reply, @ for context”")
        let send: (@escaping (String) -> Void) -> Void = { [self] k2 in
            guard real, let h = taskHost else { page.task.text = "When does it open?"; page.task.send(); return k2("posted") }
            k.press("agenttask.field", "the reply field", in: h, fallback: {}) { [self] _ in
                typeInBar("When does it open?") { [self] how in
                    barKey("return") { _ in k2(how) }
                }
            }
        }
        send { [self] how in
            wait({ !self.run.state.isActive && self.run.steps.filter { $0.kind == .final }.count >= 2 }, 20) { [self] in
                check(run.steps.filter { $0.kind == .user }.count == 2, "a reply goes on in the same task [\(how)]")
                check(recorder.currentID == taskID, "… the same record")
                check(page.task.lines.filter { $0.kind == .answer }.count == 2, "… and the view shows both answers")
                done()
            }
        }
    }

    // MARK: Sidebar

    func caseSidebar(_ done: @escaping () -> Void) {
        c.sidebar.agents.refresh()
        check(inSidebar("agents-newtask") && inSidebar("agents-showall"), "the Agents folder lists New Task and Show all")
        check(inSidebar("agents-task"), "… and the task as a row")
        // A task that finishes while you look elsewhere: a blue dot.
        if let id = c.shownTabID { _ = try? c.store.closeTab(id) }
        c.navigate(to: URL(string: "\(k.base)/home.html")!, newTab: true)
        run.newConversation()
        k.fake.begin("bg", [.tool("navigate", ["url": "\(k.base)/park.html"]), .text("Background answer.")])
        after(0.6) { [self] in
            AgentPaneController.show(c).model.text = "Check the park opening hours"
            AgentPaneController.pane(of: c)?.model.send()
            after(0.2) { [self] in AgentPaneController.pane(of: c)?.close() }
            wait({ !self.run.state.isActive && self.k.fake.requests(for: "bg") > 0 }, 20) { [self] in
                after(0.8) { [self] in
                    let id = recorder.currentID
                    check(recorder.tasks.first { $0.id == id }?.unread == true, "a task that ends unseen is unread")
                    check(inSidebar("agents-task-unread"), "… its row has the blue dot")
                    shot(c.sidebar, "agenttasks-sidebar")
                    guard let id else { return done() }
                    let census = AgentRowsCensus.folderTask(c, task: id)
                    check(census.ok, "agentrows: done: one row for the finished task (\(census.detail))")
                    check(!inSidebar("agents-task-spinner") && !inSidebar("agents-task-waiting") && !inSidebar("agents-task-subtitle"),
                          "agentrows: done: the dot alone, no spinner, ✋ or line under it")
                    let all = c.sidebar.agents.model.tasks.map(\.id)
                    check(Set(all).count == all.count, "agentrows: every task in the folder once (\(all.count) rows)")
                    let row = TestAnchors.view("agents-task-\(id)", in: c.sidebar.agents)
                    click(row, "the unread task row", fallback: { self.c.sidebar.agents.openTask(id) }) { [self] how in
                        wait({ AgentTasksURL.taskID(self.c.store.tab(self.c.shownTabID)?.url) == id }, 4) { [self] in
                            check(AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url) == id, "a click on the row opens its task view [\(how) click]")
                            after(0.6) { [self] in
                                check(recorder.tasks.first { $0.id == id }?.unread == false && !inSidebar("agents-task-unread"), "… and the dot goes")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Recent tasks

    func caseRecent(_ done: @escaping () -> Void) {
        c.navigate(to: URL(string: "\(k.base)/home.html")!, newTab: true)
        after(0.6) { [self] in
            c.closeCommandBar()
            c.openCommandBar(mode: .newTab)
            after(0.4) { [self] in
                guard let bar else { check(false, "the bar opens"); return done() }
                // The switch takes a click, too.
                click(bar.modeToggleForTesting, x: 0.85, "Ask on the switch", fallback: { bar.setAskMode(true) }) { [self] how in
                    check(bar.askMode, "a click on “Ask” switches [\(how) click]")
                    after(0.5) { [self] in
                        guard let ask = bar.askPanel else { check(false, "Ask's panel"); return done() }
                        ask.layoutSubtreeIfNeeded()
                        let mine = recorder.tasks.filter { $0.spaceID == c.currentSpaceID }.prefix(3)
                        let cards = mine.compactMap { TestAnchors.view("agentask.card.\($0.id)", in: ask) }
                        check(inAsk("agentask.recent") && cards.count >= 2, "Recent tasks shows this Space's newest tasks as cards (\(cards.count) of \(mine.count))")
                        check(TestAnchors.view("agentask.card.thumb", in: ask) != nil || TestAnchors.view("agentask.card.live", in: ask) != nil,
                              "… with the agent's page on a card")
                        shot(bar, "agenttasks-recent")
                        guard let first = cards.first else { return done() }
                        let target = recorder.tasks.first { $0.spaceID == c.currentSpaceID }?.id
                        click(first, "the first card", fallback: { if let t = target, let r = self.recorder.tasks.first(where: { $0.id == t }) { bar.askPanel?.model.openTask?(r) } }) { [self] how in
                            wait({ AgentTasksURL.taskID(self.c.store.tab(self.c.shownTabID)?.url) != nil }, 4) { [self] in
                                check(AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url) == target, "a card opens its task view [\(how) click]")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Approval

    func caseApproval(_ done: @escaping () -> Void) {
        run.newConversation()
        k.setKeys(anthropic: true)
        k.fake.begin("pay", [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")])
        CommandBarView.startAgentTask("Pay for the order", attached: [], in: c)
        k.untilApproval { [self] in
            after(0.8) { [self] in
                check(AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url) == recorder.currentID, "the task's view is shown")
                check(inTask("agenttask.approval"), "the approval card is in the task view: \(run.approval?.title ?? "none")")
                check(inSidebar("agents-task-waiting"), "the sidebar row shows ✋ while it waits")
                check(taskPage?.task.placeholder == "Or tell it what to change…", "the composer says “Or tell it what to change…”")
                shotTask("agenttasks-approval")
                waitingRows { [self] in
                guard let h = taskHost else { return done() }
                k.press("agenttask.deny", "Deny", in: h, fallback: { self.run.answerApproval(allow: false) }) { [self] how in
                    k.untilIdle { [self] in after(0.6) { [self] in
                        if case .stopped = run.state { check(true, "Deny stops the task [\(how) click]") } else { check(false, "Deny stops the task [\(how) click] (\(run.state))") }
                        check(!k.fake.targets.contains("/paid"), "nothing was paid")
                        check(!inTask("agenttask.approval") && inTask("agenttask.decision"), "the card goes; the timeline says it was declined")
                        allow(done)
                    } }
                }
                }
            }
        }
    }

    // MARK: One row per task (agentrows)

    /// The waiting task: one row with ✋ and "Waiting for your OK"; a click on it lands on the approval (the pane's
    /// card); then back to its task view for Deny.
    func waitingRows(_ done: @escaping () -> Void) {
        guard let id = recorder.currentID else { check(false, "agentrows: waiting: a current task"); return done() }
        let census = AgentRowsCensus.folderTask(c, task: id)
        check(census.ok, "agentrows: waiting: one row for the task that waits (\(census.detail))")
        let line = c.sidebar.agents.model.tasks.first { $0.id == id }
        check(line?.status == .needsYou && line?.subtitle == "Waiting for your OK" && inSidebar("agents-task-subtitle"),
              "agentrows: waiting: ✋ and “Waiting for your OK” under the title (\(line?.subtitle ?? "no line"))")
        check(!inSidebar("agents-task-spinner"), "agentrows: waiting: no spinner with the ✋")
        check(line?.liveRowID.map { inSidebar("agents-waiting-\($0)") } == true, "agentrows: waiting: the ✋ is the task row's (its page's id on it)")
        let page = AgentRowsCensus.pageTask(c, task: id)
        check(page.ok && AgentRowsCensus.pageRows(c).first { $0.id == id }?.chip == "Waiting", "agentrows: waiting: All tasks lists it once, as Waiting (\(page.detail))")
        shot(c.sidebar, "agentrows-waiting")
        k.press("agents-task-\(id)", "the waiting task's row", in: c.sidebar.agents, fallback: { self.c.sidebar.agents.openTask(id) }) { [self] how in
            wait({ AgentPaneController.pane(of: self.c)?.isShown == true }, 4) { [self] in
                check(AgentPaneController.pane(of: c)?.isShown == true && run.approval != nil,
                      "agentrows: waiting: a click on its row lands on the approval [\(how) click]")
                let after = AgentRowsCensus.folderTask(c, task: id)
                check(after.ok, "agentrows: waiting: still one row with the approval in front (\(after.detail))")
                AgentPaneController.pane(of: c)?.close()
                c.sidebar.agents.closeApproval()
                AgentTasksPage.openTask(id, in: c)
                self.after(0.8) { [self] in
                    check(inTask("agenttask.approval"), "agentrows: back in the task view, the approval card still asks")
                    done()
                }
            }
        }
    }

    /// Show all: the folder keeps one row per task, All tasks lists each once, and a click there opens the task.
    func caseShowAll(_ done: @escaping () -> Void) {
        guard let id = recorder.currentID ?? recorder.tasks.first?.id else { check(false, "agentrows: a task for Show all"); return done() }
        let before = c.sidebar.agents.model.tasks.map(\.id)
        k.press("agents-showall", "Show all", in: c.sidebar.agents, fallback: { self.c.sidebar.agents.showAllTasks() }) { [self] how in
            wait({ self.taskPage != nil && self.taskPage?.model.taskID == nil }, 4) { [self] in
                check(taskPage != nil && taskPage?.model.taskID == nil, "agentrows: Show all opens All tasks [\(how) click]")
                after(0.6) { [self] in
                    let census = AgentRowsCensus.folderTask(c, task: id)
                    check(census.ok && c.sidebar.agents.model.tasks.map(\.id) == before,
                          "agentrows: after Show all the folder still has one row per task, no new ones (\(census.detail); \(before.count) → \(c.sidebar.agents.model.tasks.count))")
                    let rows = AgentRowsCensus.pageRows(c)
                    let ids = rows.map(\.id)
                    check(Set(ids).count == ids.count && !rows.contains { $0.external && AgentActivity.shared.model.row(String($0.id.dropFirst("session-".count)))?.clientKey == AgentBridge.clientKey },
                          "agentrows: All tasks lists each task once and none of their pages (\(rows.count) rows)")
                    check(AgentRowsCensus.pageTask(c, task: id).ok, "agentrows: … the finished task once (\(AgentRowsCensus.pageTask(c, task: id).detail))")
                    shot(c.root, "agentrows-showall")
                    guard let h = taskHost else { return done() }
                    k.press("agenttasks.row.\(id)", "the task on All tasks", in: h, fallback: { if let r = rows.first(where: { $0.id == id }) { self.taskPage?.model.open(r) } }) { [self] how in
                        wait({ AgentTasksURL.taskID(self.c.store.tab(self.c.shownTabID)?.url) == id }, 4) { [self] in
                            check(AgentTasksURL.taskID(c.store.tab(c.shownTabID)?.url) == id, "agentrows: a click on All tasks' row opens that task's view [\(how) click]")
                            let census = AgentRowsCensus.folderTask(c, task: id)
                            check(census.ok, "agentrows: and the folder still has it once (\(census.detail))")
                            done()
                        }
                    }
                }
            }
        }
    }

    func allow(_ done: @escaping () -> Void) {
        run.newConversation()
        k.fake.begin("pay2", [.tool("navigate", ["url": "\(k.base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")])
        CommandBarView.startAgentTask("Pay for the order again", attached: [], in: c)
        k.untilApproval { [self] in
            after(0.8) { [self] in
                guard let h = taskHost else { check(false, "the task view for Allow once"); return done() }
                k.press("agenttask.allow", "Allow once", in: h, fallback: { self.run.answerApproval(allow: true) }) { [self] how in
                    k.untilIdle { [self] in after(0.6) { [self] in
                        check(run.state == .done && k.finalText.contains("Paid"), "Allow once lets it go on to the end [\(how) click] (\(run.state))")
                        done()
                    } }
                }
            }
        }
    }

    // MARK: Pictures

    func shot(_ v: NSView, _ name: String) {
        v.layoutSubtreeIfNeeded()
        if let image = runner.render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png"))
        }
    }

    private var shotsTaken = Set<String>()
    func shotTask(_ name: String) {
        guard !shotsTaken.contains(name) else { return }
        shotsTaken.insert(name)
        shot(c.root, name)
    }

    func finish() {
        c.closeCommandBar()
        k.finish()
    }
}
#endif
