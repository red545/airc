// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script agentpane`: the Airc Agent pane (docs/design/agent-ux.md §3, §14) end to end against the FakeModelServer
/// (Debug/AgentPanelCheck.swift) on 127.0.0.1. No real model or key: a fixture key, in memory only.
/// Cases: the pane's place and size (beside the page, away from the sidebar, resize and reset, per Space), first run
/// ("Connect your AI"), a new task with the page chip and suggestions, a task started from the pane (steps, live page
/// card, "Done in …" fold, site chips), the Command Bar's "Ask Airc to…", the approval pinned above the composer (Deny,
/// Allow once, mirrored in Watch), Stop (button, Esc Esc), Take over and Hand back, an error with Try again and "Use …
/// instead", the All tasks tab, and the task file (no key, no page text). Real driver clicks and keys when the run has
/// the UI driver and a dedicated session; else posted, and said so.
extension SnapshotRunner {
    func agentPaneScenario() {
        let k = AgentPaneCheck(runner: self)
        step { done in k.setUp(done) }
        step { done in k.caseConnect(done) }
        step { done in k.caseLayout(done) }
        step { done in k.caseNewTask(done) }
        step { done in k.caseRun(done) }
        step { done in k.caseLiveMotion(done) }
        step { done in k.caseCommandBar(done) }
        step { done in k.caseApproval(done) }
        step { done in k.caseRowPopover(done) }
        step { done in k.caseStop(done) }
        step { done in k.caseTakeOver(done) }
        step { done in k.caseError(done) }
        step { done in k.caseTasksPage(done) }
        step { done in k.caseOldPanelSwitch(done) }
        run { k.finish() }
    }
}

final class AgentPaneCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var real = false
    var server: LocalPageServer?
    var port: UInt16 = 0
    let key = "airc-fixture-model-key-5521"
    let openaiKey = "airc-fixture-openai-key-5522"
    let fake = FakeModelServer()
    var run: AgentRunCenter { .shared }
    var events: [String] = []
    var cliNone = URL(fileURLWithPath: "/nonexistent")
    var cliBin = URL(fileURLWithPath: "/nonexistent")

    init(runner: SnapshotRunner) { self.runner = runner }

    var base: String { "http://127.0.0.1:\(port)" }
    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "agentpane \(engine): " + what) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }

    var pane: AgentPaneController? { AgentPaneController.pane(of: c) }
    var model: AgentPaneModel? { pane?.model }
    var host: NSView? { pane?.card?.hostingView }
    var finalText: String { run.steps.last { $0.kind == .final }?.text ?? "" }

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        AgentUI.forcedForTesting = true
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("agentpane \(engine): input \(real ? "real (UI driver)" : "posted")")
        let pages: [String: String] = ["/article.html": AgentPanelCheck.article, "/shop.html": AgentPanelCheck.shop,
                                       "/mail.html": AgentPanelCheck.mail, "/saved.html": "<title>Saved</title>Saved.",
                                       "/home.html": "<title>Corner Shop</title><h1>Corner Shop</h1><p>Groceries, delivered.</p>",
                                       // A page that keeps moving: a big block sliding across, for the live card's motion proof.
                                       "/moving.html": "<title>Moving</title><style>body{margin:0;background:#fff}#b{position:absolute;top:40px;left:0;width:420px;height:300px;background:#e0306a;animation:m .8s linear infinite alternate}@keyframes m{to{left:760px}}</style><div id=b></div>"]
        let s = LocalPageServer(responses: [:])
        s?.requestHandler = { [fake] r in
            fake.record(r)
            if r.method == "POST", r.path == "/v1/messages" || r.path == "/v1/responses" { return fake.answer(r) }
            if r.method == "POST" { return LocalPageServer.Page(body: "<title>Done</title>Posted \(r.path)") }
            return pages[r.path].map { LocalPageServer.Page(body: $0) }
        }
        server = s
        s?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fake model and fixture server on loopback")
            AgentCenter.shared.app = app
            // Never a real Claude Code or Codex: an empty folder first ("not installed"), the fakes later.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-panecli-\(getpid())", isDirectory: true)
            cliNone = root.appendingPathComponent("none")
            cliBin = root.appendingPathComponent("bin")
            try? FileManager.default.createDirectory(at: cliNone, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: cliBin, withIntermediateDirectories: true)
            for (name, source) in [("claude", AgentCLIFakes.claude), ("codex", AgentCLIFakes.codex)] {
                let u = cliBin.appendingPathComponent(name)
                try? source.write(to: u, atomically: true, encoding: .utf8)
                chmod(u.path, 0o755)
            }
            AgentCLIDetector.shared.setDirForTesting(cliNone.path)
            AgentModelSettings.shared.update { $0.backend = .apiKey }
            AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: base)
            AgentModelSettings.shared.setTestKey(nil, provider: .openai, base: base)
            AgentModelSettings.shared.update { $0.provider = .anthropic; $0.anthropicModel = "claude-opus-5-5"; $0.blockedSites = [] }
            run.onEvent = { [weak self] e in self?.events.append(e) }
            UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
            c.sidebar.agents.model.expanded = true
            UserDefaults.standard.removeObject(forKey: AgentPaneController.widthKey)
            let profile = c.store.profile(ofSpace: c.currentSpaceID)
            app.profiles.whenLoaded(profile.id, { _ in
                // A normal page in the window, for the page chip and the layout.
                self.c.navigate(to: URL(string: "\(self.base)/home.html")!, newTab: true)
                self.after(1.0) { self.front { _ in done() } }
            }, failed: { self.check(false, "the profile loads"); done() })
        }
    }

    func front(_ done: @escaping (Bool) -> Void) {
        guard real else { return done(false) }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 6) { done(NSApp.isActive && self.c.window.isKeyWindow) }
    }

    /// The anchor's centre in Quartz global points.
    func point(_ name: String, in other: NSView? = nil) -> CGPoint? {
        guard let host = other ?? host else { return nil }
        host.layoutSubtreeIfNeeded()
        guard let v = TestAnchors.view(name, in: host), let w = v.window, let main = NSScreen.screens.first else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
    }

    func frame(_ name: String) -> NSRect? {
        guard let host, let v = TestAnchors.view(name, in: host) else { return nil }
        host.layoutSubtreeIfNeeded()
        return v.convert(v.bounds, to: nil)
    }

    /// A real click on a pane anchor, else `fallback` (posted). `done("real"|"posted")`.
    func press(_ anchor: String, _ what: String, in other: NSView? = nil, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        if real, let h = other ?? host, let v = TestAnchors.view(anchor, in: h), let w = v.window {
            let mid = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            let hit = w.contentView?.superview?.hitTest(mid) ?? w.contentView?.hitTest(mid)
            let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: mid), belowWindowWithWindowNumber: 0)
            note("agentpane \(engine): \(what) at \(Int(mid.x)),\(Int(mid.y)) in \(Swift.type(of: w)) #\(w.windowNumber) (key \(w.isKeyWindow), top window #\(top)); hit \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing")")
        }
        guard real, let p = point(anchor, in: other), NSApp.isActive else {
            if real { note("FAIL-ENV agentpane \(engine): no real click for \(what) (anchor \(point(anchor, in: other) == nil ? "missing" : "found"), active \(NSApp.isActive)); posted") }
            fallback()
            return done("posted")
        }
        UIDriverClient.run(["--click", "\(p.x)", "\(p.y)"]) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.note("FAIL-ENV agentpane \(self.engine): the driver refused \(what) (\(out)); posted"); fallback(); return done("posted") }
                done("real")
            }
        }
    }

    func key(_ combo: String, _ done: @escaping (Bool) -> Void) {
        UIDriverClient.run(["--key", combo, "--pid", "\(getpid())"]) { ok, _ in DispatchQueue.main.async { done(ok) } }
    }

    /// Types `text` into the pane's field: real keys (layout-aware), else set on the model.
    func type(_ text: String, _ done: @escaping (String) -> Void) {
        guard real else { model?.text = text; return done("posted") }
        pane?.focus()
        after(0.2) { [self] in
            guard let keys = UIDriverClient.keys(typing: text) else { self.model?.text = text; return done("posted") }
            UIDriverClient.press(keys, pid: getpid()) { ok, out in
                DispatchQueue.main.async {
                    if !ok { self.note("FAIL-ENV agentpane \(self.engine): the driver couldn't type (\(out)); posted"); self.model?.text = text; return done("posted") }
                    done("real")
                }
            }
        }
    }

    func untilIdle(_ timeout: Double = 30, _ then: @escaping () -> Void) { runner.waitUntil({ !self.run.state.isActive }, timeout: timeout, then: then) }
    func untilApproval(_ then: @escaping () -> Void) { runner.waitUntil({ self.run.approval != nil }, timeout: 30, then: then) }

    func setKeys(anthropic: Bool, openai: Bool = false) {
        AgentModelSettings.shared.setTestKey(anthropic ? key : nil, provider: .anthropic, base: base)
        AgentModelSettings.shared.setTestKey(openai ? openaiKey : nil, provider: .openai, base: base)
        AgentModelSettings.shared.update { $0.provider = .anthropic }
    }

    /// A fresh task in the pane: the fake's script, the prompt sent from the pane's model (posted).
    func start(_ name: String, _ turns: [FakeModelServer.Turn], task: String = "Do the fixture task") {
        run.newConversation()
        events = []
        fake.begin(name, turns)
        setKeys(anthropic: true)
        let p = AgentPaneController.show(c)
        p.model.text = task
        p.model.send()
    }

    func shot(_ name: String) {
        guard let v = pane?.card else { return }
        v.layoutSubtreeIfNeeded()
        if let image = runner.render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png"))
        }
    }

    // MARK: First run

    func caseConnect(_ done: @escaping () -> Void) {
        run.newConversation()
        setKeys(anthropic: false)
        let open: (@escaping (String) -> Void) -> Void = { [self] k in
            guard real else { AgentUI.toggle(c); return k("posted") }
            key("cmd+opt+a") { ok in k(ok ? "real key" : "posted") }
        }
        open { [self] how in
            runner.waitUntil({ self.pane?.isShown == true }, timeout: 4) { [self] in
                check(pane?.isShown == true, "⌥⌘A opens the pane in the window [\(how)]")
                check(c.window.childWindows?.contains { $0 is AgentPanelWindow } != true, "… as a card in the window, not a child panel")
                check(model?.mode == .connect, "no provider connected: the pane shows “Connect your AI” (mode \(String(describing: model?.mode)))")
                check(point("agentpane.connect") != nil, "… on screen")
                let rows = model?.providers ?? []
                check(rows.map(\.name) == ["Claude Code", "Codex", "Anthropic API key", "OpenAI API key"], "the providers in the design's order (\(rows.map(\.name).joined(separator: ", ")))")
                check(rows.count == 4 && rows.allSatisfy { !$0.ready && $0.fix != nil }, "… each provider row has its fix (\(rows.map { "\($0.name): \($0.fix ?? "ready")" }.joined(separator: ", ")))")
                check(point("agentpane.provider.api-anthropic.fix") != nil, "… “Add key…” on the Anthropic row")
                // Detection is asynchronous: the CLI rows read "Check" until it has looked.
                runner.waitUntil({ (self.model?.providers.prefix(2).allSatisfy { $0.fix != "Check" }) == true }, timeout: 10) { [self] in
                let rows = model?.providers ?? []
                check(rows.prefix(2).allSatisfy { $0.fix == "Install…" }, "… no CLI in the folder: Claude Code and Codex say Install… (\(rows.prefix(2).map { $0.fix ?? "ready" }.joined(separator: ", ")))")
                runner.waitUntil({ (self.c.window.firstResponder as? NSTextView).map { $0.isDescendant(of: self.host ?? NSView()) } == true }, timeout: 2) { [self] in
                    check((c.window.firstResponder as? NSView)?.isDescendant(of: host ?? NSView()) == true, "opening focuses the composer")
                    // Typing still works; the text stays (nothing is sent without a provider).
                    model?.text = "keep this task"
                    model?.send()
                    after(0.4) { [self] in
                        check(model?.text == "keep this task" && run.steps.isEmpty, "Send with nothing connected keeps the text and sends nothing")
                        closeSettingsWindows()
                        shot("agentpane-connect")
                        model?.text = ""
                        connectCLI(done)
                    }
                }
                }
            }
        }
    }

    /// The fake Claude Code and Codex installed: the rows turn ready, and choosing one makes it the agent's backend.
    func connectCLI(_ done: @escaping () -> Void) {
        AgentCLIDetector.shared.setDirForTesting(cliBin.path)
        AgentPaneProvider.refresh()
        runner.waitUntil({ (self.model?.providers.prefix(2).allSatisfy(\.ready)) == true }, timeout: 15) { [self] in
            let rows = model?.providers ?? []
            check(rows.prefix(2).allSatisfy(\.ready), "fake Claude Code and Codex found: both rows ready (\(rows.prefix(2).map { "\($0.name): \($0.status)" }.joined(separator: ", ")))")
            after(0.3) { [self] in
                press("agentpane.provider.cli-claude-code.use", "Use on Claude Code", fallback: { if let r = rows.first { self.model?.switchProvider(r, retrying: false) } }) { [self] how in
                    after(0.4) { [self] in
                        check(AgentModelSettings.shared.values.backend == .claudeCode, "Use on the Claude Code row makes it the agent's backend [\(how) click]")
                        check(model?.mode == .newTask && model?.providerLabel == "Claude Code", "… the pane is ready for a task, the pill says Claude Code (\(model?.providerLabel ?? ""))")
                        // Back to the API key for the fake model server's cases.
                        AgentModelSettings.shared.update { $0.backend = .apiKey }
                        AgentCLIDetector.shared.setDirForTesting(cliNone.path)
                        done()
                    }
                }
            }
        }
    }

    func closeSettingsWindows() {
        for w in NSApp.windows where w.isVisible && w !== c.window && (w.title.contains("Settings") || String(describing: Swift.type(of: w)).contains("Settings")) { w.close() }
    }

    // MARK: Layout

    func caseLayout(_ done: @escaping () -> Void) {
        guard let p = pane, let card = p.card else { check(false, "the pane is open for the layout case"); return done() }
        c.layoutRoot()
        let page = c.card.frame
        let gap = AircMetrics.Window.cardInset
        check(abs(card.frame.width - min(400, max(340, (page.width + card.frame.width + gap) * 0.45))) < 1.5,
              "the pane is 400 pt wide by default (or 45 % of the content) (\(Int(card.frame.width)) pt)")
        if c.sidebarOnRight {
            check(card.frame.maxX + gap <= page.minX + 0.5, "sidebar on the right: the pane is left of the page (\(card.frame) vs \(page))")
        } else {
            check(abs(card.frame.minX - (page.maxX + gap)) < 1, "sidebar on the left: the pane sits right of the page with the window's 8 pt gap (pane x \(Int(card.frame.minX)), page maxX \(Int(page.maxX)))")
        }
        check(abs(card.frame.minY - page.minY) < 1 && abs(card.frame.height - page.height) < 1, "… the same height as the page card")
        let before = page.width
        let available = page.width + card.frame.width + gap
        p.resize(to: 480)
        let want = p.clampedWidth(for: available)
        check(abs((pane?.card?.frame.width ?? 0) - want) < 1.5 && (want <= 400.5 || c.card.frame.width < before),
              "dragging wider: 480 pt (at most 45 % of \(Int(available)) pt: \(Int(want))), and the page gives way (\(Int(pane?.card?.frame.width ?? 0)) pt)")
        p.resize(to: 200)
        check(abs((pane?.card?.frame.width ?? 0) - 340) < 1, "… never narrower than 340 pt (\(Int(pane?.card?.frame.width ?? 0)))")
        p.resize(to: 900)
        check((pane?.card?.frame.width ?? 0) <= 560.5, "… never wider than 560 pt (\(Int(pane?.card?.frame.width ?? 0)))")
        p.resetWidth()
        check(UserDefaults.standard.double(forKey: AgentPaneController.widthKey) == 400, "double-click on the edge resets to 400 pt, and the width is remembered")
        // A real drag on the inner edge, when we have the driver.
        let realDrag: (@escaping () -> Void) -> Void = { [self] k in
            guard real, let card = pane?.card, let main = NSScreen.screens.first else { return k() }
            let edge = c.window.convertToScreen(card.convert(NSRect(x: c.sidebarOnRight ? card.bounds.maxX - 1 : 1, y: card.bounds.midY, width: 1, height: 1), to: nil))
            let from = CGPoint(x: edge.midX, y: main.frame.maxY - edge.midY)
            let to = CGPoint(x: from.x + (c.sidebarOnRight ? 60 : -60), y: from.y)
            UIDriverClient.run(["--drag", "\(Int(from.x))", "\(Int(from.y))", "\(Int(to.x))", "\(Int(to.y))"]) { ok, out in
                DispatchQueue.main.async { [self] in
                    let w = pane?.card?.frame.width ?? 0
                    check(ok && w > 440, "a real drag on the pane's inner edge widens it (\(Int(w)) pt\(ok ? "" : ", driver: \(out)"))")
                    pane?.resetWidth()
                    k()
                }
            }
        }
        realDrag { [self] in
            // Per Space: closed in another Space, open again back here.
            let spaces = c.store.orderedSpaces
            guard spaces.count > 1, let other = spaces.first(where: { $0.id != c.currentSpaceID }) else {
                note("agentpane \(engine): one Space only; the per-Space case is skipped")
                return done()
            }
            let here = c.currentSpaceID
            c.switchToSpace(other.id, animated: false)
            after(0.4) { [self] in
                check(pane?.isShown != true && pane?.card == nil, "another Space: the pane isn't there (it's per Space)")
                c.switchToSpace(here, animated: false)
                after(0.4) { [self] in
                    check(pane?.isShown == true && pane?.card?.superview != nil, "back in the first Space: the pane is open again")
                    done()
                }
            }
        }
    }

    // MARK: New task

    func caseNewTask(_ done: @escaping () -> Void) {
        setKeys(anthropic: true)
        run.newConversation()
        pane?.close()
        AgentPaneController.show(c)
        after(0.4) { [self] in
            check(model?.mode == .newTask, "connected: the pane shows a new task (mode \(String(describing: model?.mode)))")
            check(point("agentpane.newtask") != nil, "… “What should Airc do?” on screen")
            check(model?.page?.url.path == "/home.html" && point("agentpane.chip") != nil, "the page chip holds the window's page (\(model?.page?.title ?? "none"))")
            check(model?.suggestions.first == "Summarize this page" && point("agentpane.suggestion.0") != nil, "three suggestions from the page (\(model?.suggestions.joined(separator: " | ") ?? ""))")
            check(model?.providerLabel.hasPrefix("Anthropic · ") == true, "the provider pill names the provider and model (\(model?.providerLabel ?? ""))")
            shot("agentpane-newtask")
            press("agentpane.suggestion.0", "a suggestion", fallback: { self.model?.text = self.model?.suggestions.first ?? "" }) { [self] how in
                after(0.2) { [self] in
                    check(model?.text == "Summarize this page", "a suggestion fills the field [\(how) click]")
                    press("agentpane.chip.remove", "✕ on the chip", fallback: { self.model?.removeChip() }) { [self] how in
                        after(0.2) { [self] in
                            check(model?.page == nil, "✕ removes the page chip [\(how) click]")
                            model?.text = ""
                            pane?.close()
                            AgentPaneController.show(c)
                            check(model?.page == nil, "… and it stays removed for this tab")
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: A task from the pane

    func caseRun(_ done: @escaping () -> Void) {
        run.newConversation()
        setKeys(anthropic: true)
        model?.newTask()   // the chip comes back for a new task
        fake.begin("pane", [.tool("navigate", ["url": "\(base)/article.html"]), .toolThenHold("read_page", ["mode": "text"], hold: 1.5),
                            .tool("find_element", ["query": "capital"]),
                            .slowText("The capital of Fixturia is **Brightport**.", every: 0.05)])
        pane?.close()
        AgentPaneController.show(c)
        after(0.3) { [self] in
            type("What is the capital of Fixturia?") { [self] how in
                let send: (@escaping (String) -> Void) -> Void = { [self] k in
                    guard real else { model?.send(); return k("posted") }
                    key("return") { ok in k(ok ? "real key" : "posted") }
                }
                send { [self] sendHow in
                    var sawSteps = false, sawLive = false, liveMode = "none", sawProgress = false
                    runner.waitUntil({
                        if self.point("agentpane.steps") != nil { sawSteps = true }
                        if self.point("agentpane.live") != nil { sawLive = true }
                        if let m = AgentPaneLiveView.current?.mode, m != "none" { liveMode = m }
                        if self.point("agentpane.progress") != nil { sawProgress = true }
                        return !self.run.state.isActive && self.fake.requests(for: "pane") > 0
                    }, timeout: 40) { [self] in
                        check(run.state == .done, "a task typed in the pane runs to the end [\(how) typing, \(sendHow) Return] (state \(run.state))")
                        check(firstUserText(fake.bodies("pane").first).contains("What is the capital of Fixturia?"), "the prompt reached the model")
                        check(firstUserText(fake.bodies("pane").first).contains("/home.html"), "the attached page's address went with it")
                        check(sawSteps, "while running, the steps show as one-line rows")
                        check(sawLive, "while running, the live page card is on top")
                        check(liveMode == "live" || liveMode == "copies", "… with the agent's page in it (\(liveMode))")
                        check(sawProgress, "the composer shows the elapsed time and steps while running")
                        let items = model?.items ?? []
                        let summary = items.compactMap { if case .summary(_, let s, let rows) = $0 { return (s, rows.count) } else { return nil } }.first
                        check(summary?.0.hasPrefix("Done in ") == true && summary?.0.contains("3 steps") == true, "when done, the steps fold into “\(summary?.0 ?? "no summary")”")
                        check(point("agentpane.summary") != nil && point("agentpane.steps") == nil, "… one summary line, no step rows")
                        check(point("agentpane.answer") != nil && finalText.contains("Brightport"), "the answer shows (\(finalText.prefix(60)))")
                        check(items.contains { if case .sites(_, let s) = $0 { return s.contains { $0.host.hasPrefix("127.0.0.1") } } else { return false } },
                              "a site chip for the site it used")
                        check(model?.title == "What is the capital of Fixturia?", "the header shows the task title (\(model?.title ?? ""))")
                        check(point("agentpane.live") == nil, "the live card goes when the task ends")
                        after(0.6) { [self] in press("agentpane.summary", "the summary", fallback: { if case .summary(let id, _, _)? = items.first(where: { if case .summary = $0 { return true }; return false }) { self.model?.expanded.insert(id) } }) { [self] how in
                            after(0.3) { [self] in
                                check(point("agentpane.steps.expanded") != nil, "clicking the summary unfolds the steps [\(how) click]")
                                shot("agentpane-done")
                                done()
                            }
                        } }
                    }
                }
            }
        }
    }

    // MARK: The agent's page moves in the pane while it works (owner feedback: no live render)

    func caseLiveMotion(_ done: @escaping () -> Void) {
        start("motion", [.tool("navigate", ["url": "\(base)/moving.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")])
        runner.waitUntil({ self.events.contains("tool wait") && AgentPaneLiveView.current?.window != nil && AgentPaneLiveView.current?.mode != "none" }, timeout: 20) { [self] in
            after(1.2) { [self] in
                let v = AgentPaneLiveView.current
                let mode = v?.mode ?? "none"
                let frames0 = v?.framesShown ?? 0
                let a = livePixels()
                after(0.45) { [self] in
                    let b = livePixels()
                    after(1.6) { [self] in
                        let frames1 = v?.framesShown ?? 0
                        check(point("agentpane.live.picture") != nil, "while the agent works, its page shows in the pane (live card, \(mode))")
                        if a.isEmpty || b.isEmpty {
                            note("FAIL-ENV agentpane \(engine): no window-server picture of our own window (AIRC_DISABLE_LEGACY_WINDOW_CAPTURE or none)")
                        } else {
                            let moved = zip(a, b).filter { abs($0.r - $1.r) + abs($0.g - $1.g) + abs($0.b - $1.b) > 60 }.count
                            let pink = b.filter { $0.r > 150 && $0.g < 120 }.count
                            check(pink > 0, "… the window server shows the page in the card (\(pink)/\(b.count) samples are the page's block)")
                            check(moved > 0, "… and it moves as the page does: \(moved)/\(a.count) samples changed in 0.45 s")
                        }
                        if mode == "copies" { check(frames1 - frames0 >= 5, "… copies keep coming while visible (\(frames1 - frames0) in 1.6 s)") }
                        if engine == "chromium" { check(mode == "live", "Chromium: the engine's own output, no copies (\(mode))") }
                        watchFromRow(done)
                    }
                }
            }
        }
    }

    /// A background task (pane closed): its Agents folder row offers Watch on hover, which opens the live page.
    func watchFromRow(_ done: @escaping () -> Void) {
        pane?.close()
        let folder: NSView = c.sidebar.agents
        guard let row = AgentActivity.shared.model.rows.last(where: { $0.isLive && $0.window == run.runWindowID })?.id else {
            check(false, "the working task has a live Agents folder row"); run.stop(); return untilIdle(5) { done() }
        }
        let hover: (@escaping () -> Void) -> Void = { [self] k in
            guard real, let p = point("agents-row-\(row)", in: folder) else { return k() }
            UIDriverClient.run(["--move", "\(p.x)", "\(p.y)"]) { _, _ in DispatchQueue.main.async { self.after(0.4, k) } }
        }
        hover { [self] in
            if real { check(point("agents-watch-\(row)", in: folder) != nil, "hovering the background task's row shows Watch") }
            press("agents-watch-\(row)", "Watch on the row", in: folder, fallback: { self.c.sidebar.agents.openWatch(row) }) { [self] how in
                runner.waitUntil({ self.c.sidebar.agents.watch?.rowID == row }, timeout: 4) { [self] in
                    let w = c.sidebar.agents.watch
                    check(w != nil, "Watch on the row opens the agent's page over this window's page [\(how) click]")
                    after(1.0) { [self] in
                        check(w.map { $0.mode == "live" || $0.framesShown > 0 } == true, "… live (\(w?.mode ?? "none"), \(w?.framesShown ?? 0) copies)")
                        c.sidebar.agents.closeWatch()
                        AgentPaneController.show(c)
                        run.stop()
                        untilIdle(5) { done() }
                    }
                }
            }
        }
    }

    /// A grid of samples over the live card's picture, from the window server's image of our own window (no Screen
    /// Recording). Empty when unavailable or switched off.
    func livePixels() -> [(r: Int, g: Int, b: Int)] {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1", let v = AgentPaneLiveView.current, let w = v.window,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue(),
              img.width > 8 else { return [] }
        let s = CGFloat(img.width) / w.frame.width
        let r = v.convert(v.bounds, to: nil)
        var out: [(r: Int, g: Int, b: Int)] = []
        for i in 1...16 { for j in 1...8 {
            let x = r.minX + r.width * CGFloat(i) / 17, y = r.minY + r.height * CGFloat(j) / 9
            if let p = AgentImages.pixel(img, x: Int(x * s), y: Int((w.frame.height - y) * s)) { out.append(p) }
        } }
        return out
    }

    func firstUserText(_ body: String?) -> String {
        guard let b = body, let o = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any],
              let m = (o["messages"] as? [[String: Any]])?.first, let content = m["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    // MARK: Command Bar

    func caseCommandBar(_ done: @escaping () -> Void) {
        run.newConversation()
        pane?.close()
        setKeys(anthropic: true)
        fake.begin("bar", [.text("The 07:12 is the cheapest.")])
        let prompt = "find the cheapest train to Brightport tomorrow"
        c.closeCommandBar()
        c.window.makeKeyAndOrderFront(nil)
        c.openCommandBar(mode: .newTab)
        after(0.3) { [self] in
            c.commandBar?.type(prompt)
            after(0.6) { [self] in
                let results = c.commandBar?.results ?? []
                guard let i = results.firstIndex(where: { $0.title == CommandBarView.agentRowTitle }) else {
                    check(false, "⌘T: a prompt gets the “Ask Airc to…” row (\(results.map(\.title).joined(separator: " | ")))")
                    c.closeCommandBar()
                    return done()
                }
                check(true, "⌘T: a prompt gets the “Ask Airc to…” row (row \(i))")
                var downs = i
                func next() {
                    guard downs > 0 else { return barKey("return") { [self] in untilIdle { [self] in barDone(prompt, done) } } }
                    downs -= 1
                    barKey("down", next)
                }
                next()
            }
        }
    }

    /// ↓ or Return in the bar: a real driver key (PID-targeted), or posted through the app's event path.
    func barKey(_ name: String, _ done: @escaping () -> Void) {
        if real {
            return UIDriverClient.press([name], pid: getpid()) { ok, out in
                if !ok { self.note("FAIL-ENV agentpane \(self.engine): the driver refused \(name) (\(out))") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            }
        }
        let (code, chars): (UInt16, String) = name == "down" ? (125, "\u{F701}") : (36, "\r")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: code == 125 ? [.numericPad, .function] : [],
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
    }

    private func barDone(_ prompt: String, _ done: @escaping () -> Void) {
        check(pane?.isShown == true, "↩ on it opens the pane (not the old panel) [\(real ? "real keys" : "posted keys")]")
        check(AgentPanelController.panel(of: c) == nil, "… and no child panel")
        check(run.steps.first { $0.kind == .user }?.text.hasPrefix(prompt) == true && finalText == "The 07:12 is the cheapest.",
              "… and runs the task (“\(finalText)”)")
        done()
    }

    // MARK: Approval

    func caseApproval(_ done: @escaping () -> Void) {
        start("pay", [.tool("navigate", ["url": "\(base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")])
        untilApproval { [self] in
            after(0.4) { [self] in
                check(run.approval?.risk.category == .payment, "Pay now asks first: \(run.approval?.title ?? "no card")")
                let card = frame("agentpane.approval"), field = frame("agentpane.field")
                check(card != nil && field != nil && card!.minY >= field!.maxY - 0.5, "the approval is pinned above the composer (card \(card.map { "\(Int($0.minY))" } ?? "-"), field top \(field.map { "\(Int($0.maxY))" } ?? "-"))")
                check(model?.placeholder == "Or tell it what to change…", "the field says “Or tell it what to change…” while it waits")
                shot("agentpane-approval")
                // Watch shows the same request; one answer clears both.
                var watchShown = false
                if let row = model?.liveRowID { c.sidebar.agents.openWatch(row, takeKeys: false) }
                runner.waitUntil({ self.c.sidebar.agents.watch?.approvalShown == true }, timeout: 4) { [self] in
                    watchShown = c.sidebar.agents.watch?.approvalShown == true
                    check(watchShown, "Watch mirrors the approval")
                    c.sidebar.agents.closeWatch()
                    press("agentpane.deny", "Deny", fallback: { self.run.answerApproval(allow: false) }) { [self] how in
                        untilIdle { [self] in after(0.5) { [self] in
                            if case .stopped = run.state { check(true, "Deny stops the task [\(how) click]") } else { check(false, "Deny stops the task [\(how) click] (state \(run.state))") }
                            check(!fake.targets.contains("/paid"), "nothing was paid")
                            check(point("agentpane.approval") == nil, "the pinned card goes once answered")
                            check(run.steps.contains { $0.kind == .decision && $0.text.hasPrefix("Declined: Pay") } && point("agentpane.decision") != nil,
                                  "the transcript says “Declined: Pay …”")
                            allow(done)
                        } }
                    }
                }
            }
        }
    }

    private func allow(_ done: @escaping () -> Void) {
        start("send", [.tool("navigate", ["url": "\(base)/mail.html"]), .tool("left_click", ["coordinate": [80, 320]]),
                       .tool("wait_for_load", [:]), .text("Sent.")])
        untilApproval { [self] in
            after(0.3) { [self] in
                press("agentpane.allow", "Allow once", fallback: { self.run.answerApproval(allow: true) }) { [self] how in
                    untilIdle { [self] in
                        check(run.state == .done, "Allow once continues to the end [\(how) click] (state \(run.state))")
                        check(fake.targets.contains("/sent"), "the message was sent once allowed")
                        escDenies(done)
                    }
                }
            }
        }
    }

    /// Esc in the pane while it waits = Deny.
    private func escDenies(_ done: @escaping () -> Void) {
        start("escdeny", [.tool("navigate", ["url": "\(base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")])
        untilApproval { [self] in
            pane?.focus()
            after(0.3) { [self] in
                let esc: (@escaping (String) -> Void) -> Void = { [self] k in
                    guard real else { pane?.escape(); return k("posted") }
                    key("escape") { ok in k(ok ? "real key" : "posted") }
                }
                esc { [self] how in
                    untilIdle(10) { [self] in
                        if case .stopped = run.state { check(true, "Esc in the pane denies [\(how)]") } else { check(false, "Esc in the pane denies [\(how)] (state \(run.state))") }
                        check(pane?.isShown == true, "… and doesn't close the pane")
                        done()
                    }
                }
            }
        }
    }

    // MARK: The task's row in the Agents folder

    func caseRowPopover(_ done: @escaping () -> Void) {
        start("rowpay", [.tool("navigate", ["url": "\(base)/shop.html"]), .tool("left_click", ["coordinate": [100, 180]]), .text("Paid.")])
        pane?.close()
        untilApproval { [self] in
            c.sidebar.agents.refresh()
            let folder: NSView = c.sidebar.agents
            let popoverHost = { self.c.sidebar.agents.approvalPopoverView }
            runner.waitUntil({ popoverHost() != nil }, timeout: 4) { [self] in after(0.8) { [self] in
                let row = model?.liveRowID
                check(row.map { TestAnchors.view("agents-waiting-\($0)", in: folder) != nil } == true, "pane closed: the task's row shows ✋ while it waits")
                let host = popoverHost()
                check(host != nil, "… and the row's popover asks (Open task / Deny / Allow once)")
                press("agents-popover-deny", "Deny in the row's popover", in: host, fallback: { self.run.answerApproval(allow: false) }) { [self] how in
                    untilIdle { [self] in after(0.6) { [self] in
                        if case .stopped = run.state { check(true, "Deny in the popover stops the task [\(how) click]") } else { check(false, "Deny in the popover stops the task [\(how) click] (state \(run.state))") }
                        check(popoverHost() == nil, "one answer clears the popover")
                        AgentPaneController.show(c)
                        done()
                    } }
                }
                }
            }
        }
    }

    // MARK: Stop

    func caseStop(_ done: @escaping () -> Void) {
        start("stop", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")])
        runner.waitUntil({ self.events.contains("tool wait") }, timeout: 20) { [self] in
            after(0.3) { [self] in
                shot("agentpane-running")
                let t0 = Date()
                press("agentpane.stop", "Stop", fallback: { self.run.stop() }) { [self] how in
                    untilIdle(5) { [self] in
                        let ms = Int(Date().timeIntervalSince(t0) * 1000)
                        if case .stopped = run.state { check(ms < 3000, "Stop ■ ends the task at once [\(how) click] (\(ms) ms)") } else { check(false, "Stop ■ ends the task [\(how) click] (state \(run.state))") }
                        check(!finalText.contains("Never reached"), "it doesn't go on after Stop")
                        check(model?.placeholder == "Reply…", "the task stays open for a follow-up (“Reply…”)")
                        escEsc(done)
                    }
                }
            }
        }
    }

    private func escEsc(_ done: @escaping () -> Void) {
        start("escstop", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")])
        runner.waitUntil({ self.events.contains("tool wait") }, timeout: 20) { [self] in
            pane?.focus()
            after(0.3) { [self] in
                let esc: (@escaping (String) -> Void) -> Void = { [self] k in
                    guard real else { pane?.escape(); return k("posted") }
                    key("escape") { ok in k(ok ? "real key" : "posted") }
                }
                esc { [self] how in
                    after(0.3) { [self] in
                        check(run.state.isActive, "one Esc while running doesn't stop [\(how)]")
                        esc { [self] how in
                            untilIdle(5) { [self] in
                                if case .stopped = run.state { check(true, "Esc twice stops [\(how)]") } else { check(false, "Esc twice stops [\(how)] (state \(run.state))") }
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Take over, hand back

    func caseTakeOver(_ done: @escaping () -> Void) {
        start("takeover", [.tool("navigate", ["url": "\(base)/article.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")])
        runner.waitUntil({ self.events.contains("tool wait") && self.point("agentpane.takeover") != nil }, timeout: 20) { [self] in
            note("agentpane \(engine): take over: live row \(model?.liveRowID ?? "none"), run window \(run.runWindowID.map(String.init) ?? "none")")
            let tabsBefore = Set(c.store.state.tabs.keys)
            press("agentpane.takeover", "Take over", fallback: { self.model?.takeOver() }) { [self] how in
                runner.waitUntil({ self.model?.takenOver != nil && !self.run.state.isActive }, timeout: 8) { [self] in
                    let newTab = c.store.state.tabs.values.first { !tabsBefore.contains($0.id) && $0.url.hasSuffix("/article.html") }
                    check(model?.takenOver != nil && point("agentpane.takenover") != nil, "Take over: the pane says “You have the page” [\(how) click]")
                    check(newTab != nil && c.shownTabID == newTab?.id, "… the agent's page is this window's tab now, shown")
                    check(!run.state.isActive, "… and the agent is paused")
                    shot("agentpane-takenover")
                    // The stopped run made two or three model turns, depending on when Stop landed: any of them answers.
                    fake.begin("handback", Array(repeating: .text("Carrying on from your page."), count: 3), offset: 2)
                    press("agentpane.handback", "Hand back", fallback: { self.model?.handBack() }) { [self] how in
                        runner.waitUntil({ self.fake.requests(for: "handback") > 0 && !self.run.state.isActive }, timeout: 20) { [self] in
                            check(model?.takenOver == nil, "Hand back clears the banner [\(how) click]")
                            check(fake.bodies("handback").last?.contains("handed it back") == true, "… and the agent goes on, told to read the page again")
                            check(finalText == "Carrying on from your page.", "… to the end (“\(finalText)”)")
                            if let t = newTab { _ = try? c.store.closeTab(t.id) }
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: Errors

    func caseError(_ done: @escaping () -> Void) {
        run.newConversation()
        // A provider that can't be reached: the task fails with a way out.
        // setTestKey's base is one for both providers and picks the provider: OpenAI first, then Anthropic unreachable.
        AgentModelSettings.shared.setTestKey(openaiKey, provider: .openai, base: base)
        AgentModelSettings.shared.setTestKey(key, provider: .anthropic, base: "http://127.0.0.1:9")
        fake.begin("retry", [.text("Second time lucky.")])
        AgentPaneController.show(c)
        model?.text = "Try the unreachable provider"
        model?.send()
        untilIdle(40) { [self] in
            after(0.3) { [self] in
                if case .failed = run.state { check(true, "an unreachable provider fails the task (\(run.state))") } else { check(false, "an unreachable provider fails the task (state \(run.state))") }
                check(point("agentpane.error") != nil, "… with the error banner on top")
                check(point("agentpane.error.retry") != nil, "… and Try again")
                check(point("agentpane.error.switch") != nil, "… and “Use OpenAI instead” (another ready provider)")
                shot("agentpane-error")
                AgentModelSettings.shared.setTestKey(key, provider: .anthropic, base: base)
                press("agentpane.error.retry", "Try again", fallback: { self.model?.retry() }) { [self] how in
                    untilIdle(30) { [self] in
                        check(run.state == .done && finalText == "Second time lucky.", "Try again sends the task again and it finishes [\(how) click] (state \(run.state))")
                        check(point("agentpane.error") == nil, "the banner goes")
                        done()
                    }
                }
            }
        }
    }

    // MARK: All tasks, the task file

    func caseTasksPage(_ done: @escaping () -> Void) {
        press("agentpane.history", "◷ All tasks", fallback: { self.model?.openAllTasks() }) { [self] how in
            after(0.8) { [self] in
                let tab = c.store.tab(c.shownTabID)
                check(AgentTasksURL.isPage(tab?.url), "◷ opens the All tasks tab [\(how) click] (\(tab?.url ?? "none"))")
                let page = AgentTasksPage.existing(c.shownTabID)
                check(page?.host.superview === c.card, "… a native page in the card")
                let tasks = AgentTaskRecorder.shared.tasks
                check(tasks.count >= 5, "the tasks of this run are listed (\(tasks.count))")
                check(tasks.contains { $0.title == "What is the capital of Fixturia?" && $0.status == .done && $0.steps == 3 },
                      "a finished task has its title, Done and its step count")
                if let v = page?.host {
                    check(TestAnchors.view("agenttasks.row", in: v) != nil, "… shown as rows")
                }
                // The task files: metadata only.
                let folder = AppPaths.dataDirectory.appendingPathComponent("Agent/Tasks")
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
                check(!files.isEmpty, "task files in <data>/Agent/Tasks (\(files.count))")
                check(!text.contains(key) && !text.contains(openaiKey), "no key in any task file")
                check(!text.contains("three bridges"), "no page text in any task file")
                let modes = files.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions] as? NSNumber)?.intValue }
                check(!modes.isEmpty && modes.allSatisfy { $0 == 0o600 }, "task files are 0600")
                if let id = c.shownTabID { _ = try? c.store.closeTab(id) }
                done()
            }
        }
    }

    // MARK: The test-only switch

    func caseOldPanelSwitch(_ done: @escaping () -> Void) {
        pane?.close()
        AgentUI.forcedForTesting = false
        AgentUI.toggle(c)
        after(0.4) { [self] in
            check(AgentPanelController.panel(of: c) != nil && pane?.isShown != true, "the test-only switch still gives the old panel")
            AgentPanelController.panel(of: c)?.close()
            AgentUI.forcedForTesting = true
            done()
        }
    }

    func finish() {
        run.newConversation()
        pane?.close()
        AgentUI.forcedForTesting = nil
        AgentCLIDetector.shared.setDirForTesting(nil)
        if let root = Optional(cliBin.deletingLastPathComponent()), root.path.contains("airc-panecli-") { try? FileManager.default.removeItem(at: root) }
        run.onEvent = nil
        server?.stop()
        runner.finish()
    }
}
#endif
