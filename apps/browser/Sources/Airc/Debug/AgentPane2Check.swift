// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AppKit
import AircKit

/// `--script agentpane2`: the pane's Install… and Sign in… for the person's own Claude Code and Codex, and the real Hand
/// back (docs/design/agent-ux.md §6, §8). Only agentcli's fake `claude` / `codex` (Python, no network, no credentials)
/// in a temporary folder the detector searches instead of the PATH, and the FakeModelServer; no Terminal launch (the
/// `.command` files are recorded, read, and the sign-in one is run with zsh as Terminal would run it).
/// Per CLI: not installed → the documented install command (Copy, Open Terminal with this command) → the fake appears
/// on the "PATH" → re-checked on focus → Use it → signed out → Sign in… (Claude Code: `claude auth login` in Terminal;
/// Codex: the app-server's sign-in page in a tab) → "Waiting for sign-in…" → the typed task runs by itself. Then a turn
/// that fails signed out → the banner's Sign in… → the task again; and Hand back moving the same page (typed text,
/// scroll position, document, tab id) back into the agent's window. Real driver clicks when the run has them.
extension SnapshotRunner {
    func agentPane2Scenario() {
        let k = AgentPane2Check(runner: self)
        step { done in k.setUp(done) }
        if AgentPane2Check.only == nil {
            step { done in k.caseButton(done) }
            step { done in k.caseCLI(.claudeCode, done) }
            step { done in k.caseCLI(.codex, done) }
            step { done in k.caseSignedOutTurn(done) }
            step { done in k.caseKey(done) }
            step { done in k.caseHandBack(done) }
            step { done in k.caseHint(done) }
        }
        // agentux3 (AgentPane3Check.swift): the live card frame by frame.
        if AgentPane2Check.runs("flicker") { step { done in k.caseFlicker(done) } }
        // watchfix (AgentWatch2Own.swift): Watch and the card through a long run with Continue; only when named.
        if AgentPane2Check.only?.contains("watchlong") == true { step { done in k.caseWatchLong(done) } }
        // agentux3 (AgentPane3NeedsYou.swift): "needs you" in one click from every entry point.
        if AgentPane2Check.runs("needsyou") {
            step { done in k.caseNeedsYouApprovals(done) }
            step { done in k.caseNeedsYouFullScreen(done) }
            step { done in k.caseNeedsYouPages(done) }
        }
        // agentfix (AgentFixCheck.swift): "needs you" in the task's own window and profile; Return in a page never approves.
        // cardflicker (AgentPaneTabMem.swift): tab-switch footprints with the card closed; only when named.
        if AgentPane2Check.only?.contains("tabmem") == true { step { done in k.caseTabMem(done) } }
        if AgentPane2Check.runs("agentfix") {
            step { done in k.caseRouteNeedsYou(done) }
            step { done in k.caseReturnInPage(done) }
        }
        run { k.finish() }
    }
}

final class AgentPane2Check {
    let k: AgentPaneCheck
    var runner: SnapshotRunner { k.runner }
    var c: WindowController { k.c }
    var run: AgentRunCenter { .shared }
    var model: AgentPaneModel? { k.model }
    var engine: String { k.engine }
    /// The one folder the detector searches (the "PATH"); empty = not installed.
    var root = URL(fileURLWithPath: "/nonexistent")
    var pathDir: URL { root.appendingPathComponent("path") }
    /// The `.command` files Airc asked Terminal to open.
    var terminalFiles: [URL] = []
    private var savedOpener: ((URL) -> Void)?
    static let signInPage = "<title>Sign in to Codex (fixture)</title><h1>Sign in</h1><p>The fake Codex finishes by itself.</p>"
    static let form = "<title>Order form</title><style>body{margin:0;font:16px sans-serif}.pad{height:3200px;background:linear-gradient(#fff,#dde)}</style>"
        + "<h1>Order form</h1><label>Name <input id=f name=f autocomplete=off></label><div class=pad></div><p id=end>End</p>"

    init(runner: SnapshotRunner) {
        k = AgentPaneCheck(runner: runner)
        k.label = "agentpane2"
        k.extraPages = ["/codex-signin.html": Self.signInPage, "/form.html": Self.form]
    }

    func check(_ ok: Bool, _ what: String) { k.check(ok, what) }
    func note(_ s: String) { k.note(s) }
    func after(_ s: Double, _ body: @escaping () -> Void) { k.after(s, body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ then: @escaping () -> Void) { runner.waitUntil(cond, timeout: timeout, then: then) }

    // MARK: Set up

    func setUp(_ done: @escaping () -> Void) {
        k.setUp { [self] in
            root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-panecli2-\(getpid())", isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
            AgentCLIDetector.shared.setDirForTesting(pathDir.path)
            savedOpener = AgentCLISetupFiles.openInTerminal
            AgentCLISetupFiles.openInTerminal = { [weak self] url in self?.terminalFiles.append(url) }
            check(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "python3 is there for the fake CLIs")
            done()
        }
    }

    /// The fakes appear in the searched folder ("installed"), with their script.
    func installFakes(case name: String, loggedIn: Bool, turns: [[[String: Any]]]) {
        for (n, source) in [("claude", AgentCLIFakes.claude), ("codex", AgentCLIFakes.codex)] {
            let u = pathDir.appendingPathComponent(n)
            try? source.write(to: u, atomically: true, encoding: .utf8)
            chmod(u.path, 0o755)
        }
        writeState(["case": name, "loggedIn": loggedIn, "turns": turns, "loginDelay": 1.5, "authUrl": "\(k.base)/codex-signin.html"])
    }

    func writeState(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: pathDir.appendingPathComponent("fake-state.json"), options: .atomic) }
    }

    func setLoggedIn(_ on: Bool) {
        let u = pathDir.appendingPathComponent("fake-state.json")
        guard let d = try? Data(contentsOf: u), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        o["loggedIn"] = on
        writeState(o)
    }

    func uninstallFakes() {
        for n in ["claude", "codex"] { try? FileManager.default.removeItem(at: pathDir.appendingPathComponent(n)) }
    }

    func fakeEvents(_ event: String) -> [[String: Any]] {
        guard let s = try? String(contentsOf: pathDir.appendingPathComponent("fake-log.jsonl"), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { $0["event"] as? String == event }
    }

    func row(_ kind: AgentCLIKind) -> AgentPaneProvider? { model?.providers.first { $0.cli == kind } }

    /// Terminal running a `.command` file: zsh with the file, no input (off the main thread). `done(exit, output)`.
    func runAsTerminal(_ file: URL, _ done: @escaping (Int32, String) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [file.path]
            p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "TERM": "dumb"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            var code: Int32 = -1
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                code = p.terminationStatus
                DispatchQueue.main.async { done(code, String(decoding: data, as: UTF8.self)) }
            } else {
                DispatchQueue.main.async { done(code, "") }
            }
        }
    }

    // MARK: Install and sign in, per CLI

    func caseCLI(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let n = kind.binary
        run.newConversation()
        k.setKeys(anthropic: false)
        uninstallFakes()
        AgentCLIDetector.shared.setDirForTesting(pathDir.path)
        AgentModelSettings.shared.setBackendForTesting(kind == .claudeCode ? .claudeCode : .codex)
        let p = AgentPaneController.show(c)
        p.model.cancelSetup()
        AgentPaneProvider.refresh()
        let task = kind == .claudeCode ? "Open the article and tell me what it says" : "Read the article for me"
        let answer = kind == .claudeCode ? "The article is about Fixturia." : "Fixturia's article, read."
        wait({ self.row(kind)?.fix == "Install…" }, 10) { [self] in
            check(row(kind)?.fix == "Install…" && model?.mode == .connect, "[\(kind.name)] not on this Mac: its row says Install…, the pane shows Connect your AI (\(row(kind)?.status ?? "?"))")
            k.type(task) { [self] typed in
                after(0.3) { [self] in
                    k.press("agentpane.send", "Send", fallback: { self.model?.send() }) { [self] how in
                        wait({ self.model?.setup?.kind == kind }, 4) { [self] in
                            check(model?.setup == AgentPaneModel.Setup(kind: kind, step: .install), "[\(kind.name)] Send: the pane shows how to install it, in the pane [\(how) click, \(typed) keys]")
                            check(model?.setupCommand == kind.install.command && k.point("agentpane.setup.command") != nil,
                                  "[\(kind.name)] … the command from its docs: \(model?.setupCommand ?? "none")")
                            check(model?.text == task && run.steps.isEmpty, "[\(kind.name)] … nothing is sent, the task stays in the field")
                            check(NSApp.windows.allSatisfy { !($0.isVisible && $0.title.contains("Settings")) }, "[\(kind.name)] … no Settings window instead")
                            k.shot("agentpane2-install-\(n)")
                            copyAndTerminal(kind) { [self] in installed(kind, task: task, answer: answer, done) }
                        }
                    }
                }
            }
        }
    }

    func copyAndTerminal(_ kind: AgentCLIKind, _ then: @escaping () -> Void) {
        NSPasteboard.general.clearContents()
        k.press("agentpane.setup.copy", "Copy", fallback: { self.model?.copySetupCommand() }) { [self] how in
            after(0.3) { [self] in
                check(NSPasteboard.general.string(forType: .string) == kind.install.command, "[\(kind.name)] Copy puts the command on the clipboard [\(how) click]")
                let before = terminalFiles.count
                k.press("agentpane.setup.terminal", "Open Terminal with this command", fallback: { self.model?.openSetupInTerminal() }) { [self] how in
                    wait({ self.terminalFiles.count > before }, 4) { [self] in
                        guard let f = terminalFiles.last, terminalFiles.count > before else {
                            check(false, "[\(kind.name)] Open Terminal with this command opens a .command file [\(how) click]")
                            return then()
                        }
                        let body = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                        let perms = ((try? FileManager.default.attributesOfItem(atPath: f.path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
                        check(f.pathExtension == "command" && perms == 0o700, "[\(kind.name)] Open Terminal with this command: a one-time .command file for Terminal, 0700 [\(how) click] (\(f.lastPathComponent))")
                        check(body.contains("\n" + kind.install.command + "\n"), "[\(kind.name)] … it runs the documented command")
                        if let r = body.range(of: "read -r"), let c = body.range(of: "\n" + kind.install.command + "\n") {
                            check(r.lowerBound < c.lowerBound && body.contains("|| exit 1"), "[\(kind.name)] … only after Return (closing the window cancels)")
                        } else {
                            check(false, "[\(kind.name)] … only after Return")
                        }
                        check(!body.contains("sudo") && body.contains("rm -f"), "[\(kind.name)] … never sudo, and it deletes itself")
                        check(!FileManager.default.fileExists(atPath: pathDir.appendingPathComponent(kind.binary).path),
                              "[\(kind.name)] … and nothing was installed by Airc itself (the file only runs in Terminal)")
                        try? FileManager.default.removeItem(at: f)
                        then()
                    }
                }
            }
        }
    }

    /// The fake appears on the "PATH"; Airc looks again when it becomes active; Use it; Sign in…; the task runs.
    func installed(_ kind: AgentCLIKind, task: String, answer: String, _ done: @escaping () -> Void) {
        installFakes(case: "setup-\(kind.binary)", loggedIn: false,
                     turns: [[["tool": "navigate", "args": ["url": "\(k.base)/article.html"]], ["say": answer]]])
        // Back from Terminal: Airc becomes active (posted: the app's own notification, as macOS sends it).
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        wait({ self.model?.setup?.step == .found }, 15) { [self] in
            check(model?.setup?.step == .found && k.point("agentpane.setup.use") != nil, "[\(kind.name)] installed: re-checked when Airc becomes active, “Use it” shows (\(AgentCLIDetector.shared.status(kind)?.summary(kind) ?? "?"))")
            k.shot("agentpane2-found-\(kind.binary)")
            k.press("agentpane.setup.use", "Use it", fallback: { self.model?.useSetup() }) { [self] how in
                wait({ self.model?.setup?.step == .signIn }, 10) { [self] in
                    check(AgentModelSettings.shared.values.backend == (kind == .claudeCode ? .claudeCode : .codex), "[\(kind.name)] Use it makes it the agent's backend [\(how) click]")
                    check(model?.setup?.step == .signIn && k.point("agentpane.setup.signin") != nil, "[\(kind.name)] … signed out (its own status): Sign in… (\(AgentCLIDetector.shared.status(kind)?.summary(kind) ?? "?"))")
                    k.shot("agentpane2-signin-\(kind.binary)")
                    let tabsBefore = Set(c.store.state.tabs.keys)
                    let filesBefore = terminalFiles.count
                    k.press("agentpane.setup.signin", "Sign in…", fallback: { self.model?.signIn() }) { [self] how in
                        if kind == .claudeCode {
                            wait({ self.terminalFiles.count > filesBefore }, 5) { [self] in signInTerminal(kind, how: how, filesBefore: filesBefore, task: task, answer: answer, done) }
                        } else {
                            wait({ self.signInTab(tabsBefore) != nil }, 10) { [self] in signInBrowser(kind, how: how, tabsBefore: tabsBefore, filesBefore: filesBefore, task: task, answer: answer, done) }
                        }
                    }
                }
            }
        }
    }

    func signInTab(_ before: Set<String>) -> LiveTab? {
        c.store.state.tabs.values.first { !before.contains($0.id) && $0.url.hasSuffix("/codex-signin.html") }
    }

    func signInTerminal(_ kind: AgentCLIKind, how: String, filesBefore: Int, task: String, answer: String, _ done: @escaping () -> Void) {
        guard terminalFiles.count > filesBefore, let f = terminalFiles.last else {
            check(false, "[\(kind.name)] Sign in… opens Claude Code's own sign-in in Terminal [\(how) click]")
            return done()
        }
        let body = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        let exe = pathDir.appendingPathComponent(kind.binary).path
        check(body.contains("\n" + ([exe] + kind.loginArguments).map(AgentCLIScript.quote).joined(separator: " ") + "\n"),
              "[\(kind.name)] Sign in… opens Terminal with the CLI's own sign-in (`claude auth login`) [\(how) click]")
        check(!body.contains("sudo"), "[\(kind.name)] … no sudo")
        check(k.point("agentpane.setup.waiting") != nil, "[\(kind.name)] … the pane says “Waiting for sign-in…”")
        k.shot("agentpane2-waiting-\(kind.binary)")
        // Terminal runs it (here: zsh, as Terminal would); the fake's login finishes after 1.5 s.
        runAsTerminal(f) { [self] code, out in
            check(code == 0 && out.contains("Signed in."), "[\(kind.name)] the .command file runs the sign-in to the end (exit \(code))")
            check(!FileManager.default.fileExists(atPath: f.path), "[\(kind.name)] … and deletes itself")
            check(fakeEvents("auth-login").count == 1, "[\(kind.name)] … the fake's `auth login` ran once")
            taskRuns(kind, task: task, answer: answer, done)
        }
    }

    func signInBrowser(_ kind: AgentCLIKind, how: String, tabsBefore: Set<String>, filesBefore: Int, task: String, answer: String, _ done: @escaping () -> Void) {
        let tab = signInTab(tabsBefore)
        check(tab != nil && c.shownTabID == tab?.id, "[\(kind.name)] Sign in… opens Codex's own sign-in page (account/login/start's authUrl) in a normal tab [\(how) click]")
        check(terminalFiles.count == filesBefore, "[\(kind.name)] … no Terminal (the app-server has a browser sign-in)")
        check(fakeEvents("login-start").first?["params"].flatMap { ($0 as? [String: Any])?["type"] as? String } == "chatgpt", "[\(kind.name)] … type chatgpt")
        if case .waiting(let url?)? = model?.setup?.step { check(url.path == "/codex-signin.html" && k.point("agentpane.setup.reopen") != nil, "[\(kind.name)] … “Waiting for sign-in…” with “Open the page again”") }
        else { check(false, "[\(kind.name)] … the pane waits for the sign-in (\(String(describing: model?.setup)))") }
        k.shot("agentpane2-waiting-\(kind.binary)")
        taskRuns(kind, task: task, answer: answer) { [self] in
            if let t = tab { _ = try? c.store.closeTab(t.id) }
            done()
        }
    }

    func taskRuns(_ kind: AgentCLIKind, task: String, answer: String, _ done: @escaping () -> Void) {
        wait({ self.run.state == .done && self.k.finalText == answer }, 40) { [self] in
            check(AgentCLIDetector.shared.status(kind)?.isReady == true, "[\(kind.name)] signed in: its own status says so (\(AgentCLIDetector.shared.status(kind)?.summary(kind) ?? "?"))")
            check(model?.setup == nil && model?.text.isEmpty == true, "[\(kind.name)] … the card goes")
            check(run.steps.first { $0.kind == .user }.map { AgentPaneItem.promptText($0.text) } == task, "[\(kind.name)] … the typed task goes by itself")
            check(run.state == .done && k.finalText == answer, "[\(kind.name)] … and runs to the end on \(kind.name) (“\(k.finalText)”, state \(run.state))")
            check(run.steps.contains { $0.kind == .action }, "[\(kind.name)] … through Airc's tools (a navigate step: \(run.steps.first { $0.kind == .action }?.text ?? "none"))")
            k.shot("agentpane2-done-\(kind.binary)")
            done()
        }
    }

    // MARK: Signed out mid-way: the error output

    func caseSignedOutTurn(_ done: @escaping () -> Void) {
        let kind = AgentCLIKind.claudeCode
        run.newConversation()
        installFakes(case: "expired", loggedIn: true, turns: [[["say": "Back after signing in."]]])
        AgentModelSettings.shared.setBackendForTesting(.claudeCode)
        AgentCLIDetector.shared.check(kind, maxAge: 0) { [self] s in
            check(s.isReady, "[expired] Claude Code reads signed in (\(s.summary(kind)))")
            // The sign-in expires after Airc looked: the turn fails on it (the CLI's error output).
            setLoggedIn(false)
            let p = AgentPaneController.show(c)
            p.model.text = "Summarize my open page"
            p.model.send()
            wait({ !self.run.state.isActive && self.k.point("agentpane.error.signin") != nil }, 20) { [self] in
                if case .failed(let m) = run.state { check(m.contains("Not logged in"), "[expired] a turn refused as signed out fails (“\(m.prefix(70))”)") }
                else { check(false, "[expired] a turn refused as signed out fails (state \(run.state))") }
                check(k.point("agentpane.error.signin") != nil, "[expired] … the banner offers Sign in…")
                k.shot("agentpane2-expired")
                k.press("agentpane.error.signin", "Sign in… (banner)", fallback: { self.model?.signInAfterFailure(kind) }) { [self] how in
                    wait({ self.model?.setup?.step == .signIn }, 10) { [self] in
                        check(model?.setup?.step == .signIn, "[expired] … which shows the sign-in card [\(how) click]")
                        let filesBefore = terminalFiles.count
                        k.press("agentpane.setup.signin", "Sign in…", fallback: { self.model?.signIn() }) { [self] how in
                            wait({ self.terminalFiles.count > filesBefore }, 5) { [self] in
                                guard let f = terminalFiles.last, terminalFiles.count > filesBefore else {
                                    check(false, "[expired] Sign in… opens Terminal [\(how) click]"); return done()
                                }
                                runAsTerminal(f) { [self] code, _ in
                                    check(code == 0, "[expired] the sign-in finishes in Terminal (exit \(code))")
                                    wait({ self.run.state == .done }, 30) { [self] in
                                        check(run.state == .done && k.finalText == "Back after signing in.", "[expired] … and the failed task goes again by itself, to the end (“\(k.finalText)”)")
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

    // MARK: Hand back

    func evaluate(_ tab: EngineTab, _ js: String, _ done: @escaping ([String: Any]) -> Void) {
        tab.evaluate("JSON.stringify((function(){" + js + "})())") { r in
            let o = (r as? String).flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
            DispatchQueue.main.async { done(o) }
        }
    }

    func caseHandBack(_ done: @escaping () -> Void) {
        AgentModelSettings.shared.setBackendForTesting(.apiKey)
        k.start("handback2", [.tool("navigate", ["url": "\(k.base)/form.html"]), .tool("wait", ["duration": 30]), .text("Never reached.")])
        // agentmainfix: in the main view Take over is on the page's bar (the pane's card shows only while away).
        let bar = { AgentMainView.shared.chromeView(self.c) }
        wait({ self.k.events.contains("tool wait") && (self.k.point("agentpane.takeover") != nil || bar().flatMap { self.k.point("agentmain.takeover", in: $0) } != nil) }, 25) { [self] in
            guard let wid = run.runWindowID, let w = AgentCenter.shared.windows[wid], let page = w.activeTab, let agentTab = w.activeTabID else {
                check(false, "the agent works on the form page in its window"); return done()
            }
            check(page.url?.path == "/form.html", "the agent's page is the form (\(page.url?.path ?? "none"))")
            // agentmainview: the agent's page is already this window's selected tab (the main view); Take over leaves it
            // there, the person's at once.
            let onBar = k.point("agentpane.takeover") == nil ? bar() : nil
            k.press(onBar == nil ? "agentpane.takeover" : "agentmain.takeover", onBar == nil ? "Take over" : "Take over (bar)", in: onBar,
                    fallback: { self.model?.takeOver() }) { [self] how in
                wait({ self.model?.takenOver != nil && !self.run.state.isActive }, 8) { [self] in
                    guard let tabID = model?.takenOver?.tabID, c.shownTabID == tabID else { check(false, "Take over makes the page this window's shown tab [\(how) click] (\(model?.takenOver?.tabID ?? "none"), shown \(c.shownTabID ?? "none"))"); return done() }
                    check(c.engineTab(for: tabID) === page, "Take over: the same page object is this window's tab [\(how) click]")
                    check(model?.takenOver?.tabID == tabID && model?.takenOver?.agentTabID == agentTab, "… the pane remembers the tab and the agent's tab id (\(agentTab))")
                    // The person types in the form and scrolls (page script; the field keeps the value, the page its scroll).
                    evaluate(page, "var f=document.getElementById('f');f.focus();f.value='Typed by the person';f.dispatchEvent(new Event('input',{bubbles:true}));window.scrollTo(0,1200);window.__aircKept='kept';return {y:scrollY,h:history.length}") { [self] typed in
                        let history = typed["h"] as? Int ?? -1
                        note("agentpane2 \(engine): before Hand back: \(typed)")
                        // However many model turns the stopped run made, any next one answers (the fake's index can't run past it).
                        k.fake.begin("handback2-after", Array(repeating: .text("Carrying on from your page."), count: 10), offset: 0)
                        k.press("agentpane.handback", "Hand back", fallback: { self.model?.handBack() }) { [self] how in
                            wait({ self.k.fake.requests(for: "handback2-after") > 0 && !self.run.state.isActive }, 25) { [self] in
                                let nw = run.runWindowID.flatMap { AgentCenter.shared.windows[$0] }
                                check(model?.takenOver == nil, "Hand back clears the banner [\(how) click]")
                                check(nw?.activeTab === page, "… the same page object (\(engine == "webkit" ? "WKWebView" : "WebContents")) is the agent window's tab again, not a reload of its address")
                                check(nw?.activeTabID == agentTab, "… with the same tab id (\(nw?.activeTabID.map(String.init) ?? "none") vs \(agentTab))")
                                check(nw?.tabs.count == 1, "… the window's blank first page closed (\(nw?.tabs.count ?? 0) tabs)")
                                // agentmainview: the page stays where the person left it, in the main view, the agent's again.
                                check(c.store.tab(tabID) != nil && c.engineTab(for: tabID) === page, "… the tab stays in the person's sidebar, the same page")
                                check(c.shownTabID == tabID, "… shown in the main view")
                                check(model?.handBackFailed == nil, "… no move error (\(model?.handBackFailed ?? "none"))")
                                let body = k.fake.bodies("handback2-after").last ?? ""
                                check(body.contains("handed it back") && body.contains("don't open its address again"), "… the agent is told the page is its tab again, to read it, not to reopen it")
                                check(k.finalText == "Carrying on from your page.", "… and goes on to the end (“\(k.finalText)”)")
                                evaluate(page, "var f=document.getElementById('f');return {v:f.value,y:scrollY,k:window.__aircKept||'',h:history.length}") { [self] o in
                                    check(o["v"] as? String == "Typed by the person", "… the typed form text is still there (“\(o["v"] as? String ?? "none")”)")
                                    let y = (o["y"] as? NSNumber)?.doubleValue ?? -1
                                    check(abs(y - 1200) < 60, "… the scroll position too (scrollY \(Int(y)))")
                                    check(o["k"] as? String == "kept", "… the same document (a script variable survived: no reload)")
                                    check(o["h"] as? Int == history && history > 0, "… and its history (\(o["h"] as? Int ?? -1) entries, before \(history))")
                                    run.newConversation()
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: The Airc Agent button (the sidebar's toolbar row, sidebarchrome 2026-11-20)

    var agentButton: NSView { c.sidebar.header.agent.button }

    /// A real click on a view's centre (the UI driver), else `fallback`. `done("real"|"posted")`.
    func pressView(_ v: NSView?, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        guard k.real, let v, let w = v.window, NSApp.isActive, let main = NSScreen.screens.first else { fallback(); return done("posted") }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        UIDriverClient.run(["--click", "\(Int(r.midX.rounded()))", "\(Int((main.frame.maxY - r.midY).rounded()))"]) { ok, out in
            DispatchQueue.main.async {
                if !ok { self.note("FAIL-ENV agentpane2 \(self.engine): the driver refused \(what) (\(out)); posted"); fallback(); return done("posted") }
                done("real")
            }
        }
    }

    func caseButton(_ done: @escaping () -> Void) {
        AgentUI.close(c)
        c.root.layoutSubtreeIfNeeded()
        let b = agentButton
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { c.window.standardWindowButton($0) }
            .map { $0.convert($0.bounds, to: nil) }.reduce(NSRect.null) { $0.union($1) }
        let bf = b.convert(b.bounds, to: nil)
        let h = c.sidebar.header
        let nav = h.back.convert(h.back.bounds, to: nil)
        check(!b.isHiddenOrHasHiddenAncestor && b.window === c.window && b.superview === h && bf.width >= 24,
              "the sidebar's toolbar row has the Airc Agent button (\(NSStringFromRect(bf)))")
        check(abs(bf.midY - nav.midY) < 0.5 && bf.size == nav.size && (b as? GlyphButton)?.symbolSize == h.back.symbolSize
              && (b as? GlyphButton)?.hoverFill == h.back.hoverFill,
              "… on the Back button's row, its size (\(Int(bf.width))×\(Int(bf.height)) vs \(Int(nav.width))×\(Int(nav.height))), glyph size and hover plate")
        let rowButtons = [h.back, h.forward, h.reload, b].filter { !$0.isHidden }.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        let pitches = zip(rowButtons, rowButtons.dropFirst()).map { $1.minX - $0.minX }
        check(rowButtons.last == bf && pitches.allSatisfy { abs($0 - AircMetrics.Sidebar.headerButtonPitch) < 0.5 }
              && abs(h.convert(h.bounds, to: nil).maxX - bf.maxX - DesignGaps.headerButtonEndInset) < 0.5,
              "… last in the row, on the row's 34 pt pitch (\(pitches.map { Int($0) })), 6 pt from the edge")
        check(!bf.intersects(lights) && bf.minX > h.toggle.convert(h.toggle.bounds, to: nil).maxX, "… nowhere near the traffic lights, right of the sidebar toggle")
        let footerHasIt = c.sidebar.footer.subviews.contains { $0.accessibilityLabel() == "Airc Agent" }
        check(!footerHasIt, "… and the bottom bar has no ✦ any more")
        // Narrow sidebars drop Reload, then Forward, then Back; the ✦ goes last (lead 2026-11-20, Arc ref §2.1).
        let tx = AircMetrics.Sidebar.toggleX + AircMetrics.Sidebar.headerButton
        let at: (CGFloat) -> [SidebarHeaderView.HeaderButton] = { w in SidebarHeaderView.shownButtons(width: w, toggleMaxX: tx) }
        check(at(AircMetrics.Sidebar.defaultWidth) == [.back, .forward, .agent] && at(251) == [.back, .forward, .reload, .agent]
              && at(AircMetrics.Sidebar.minWidth) == [.agent] && at(200) == [.back, .agent],
              "… collapse order: 228 pt \(at(AircMetrics.Sidebar.defaultWidth)), 251 pt \(at(251)), 200 pt \(at(200)), 164 pt \(at(AircMetrics.Sidebar.minWidth))")
        check(b.toolTip?.hasPrefix("Airc Agent (⌥⌘A)") == true && b.accessibilityLabel() == "Airc Agent", "… tooltip “\(b.toolTip ?? "")”, VoiceOver “\(b.accessibilityLabel() ?? "")”")
        let titles = (b as? GlyphButton)?.contextMenuProvider?()?.items.map(\.title) ?? []
        check(titles.contains("New Task") && titles.contains("Watch") && titles.contains("Settings › Agents…"), "… right-click: New Task, Watch, Settings › Agents (\(titles))")
        k.front { [self] _ in
            pressView(b, "the Airc Agent button", fallback: { AgentUI.toggle(self.c) }) { [self] how in
                wait({ AgentUI.isShown(self.c) }, 4) { [self] in
                    check(AgentUI.isShown(c), "a click on it opens the pane [\(how) click]")
                    check(b.accessibilityValue() as? String == "open", "… and it shows the pane is open")
                    after(0.5) { [self] in
                        pressView(b, "the Airc Agent button", fallback: { AgentUI.toggle(self.c) }) { [self] how in
                            wait({ !AgentUI.isShown(self.c) }, 4) { [self] in
                                check(!AgentUI.isShown(c), "another click closes it [\(how) click]")
                                // With the sidebar hidden the button goes with it (⌥⌘A stays).
                                c.toggleSidebar()
                                after(0.8) { [self] in
                                    let r = b.window == nil ? NSRect.zero : b.convert(b.bounds, to: nil)
                                    let gone = b.isHiddenOrHasHiddenAncestor || b.window == nil || r.maxX <= 1 || c.sidebar.alphaValue < 0.05
                                    check(c.sidebarHidden && gone, "the sidebar hidden: the button goes with it (sidebar hidden \(c.sidebarHidden), hidden \(b.isHiddenOrHasHiddenAncestor), frame \(NSStringFromRect(r)))")
                                    c.toggleSidebar()
                                    after(0.8) { [self] in
                                        check(!b.isHiddenOrHasHiddenAncestor, "… and back with it")
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

    // MARK: Connect with an API key, in the pane

    func caseKey(_ done: @escaping () -> Void) {
        run.newConversation()
        uninstallFakes()
        AgentCLIDetector.shared.setDirForTesting(pathDir.path)
        AgentModelSettings.shared.setTestKey(nil, provider: .anthropic, base: k.base)
        AgentModelSettings.shared.setTestKey(nil, provider: .openai, base: k.base)
        AgentModelSettings.shared.setBackendForTesting(.apiKey)
        AgentModelSettings.shared.update { $0.provider = .anthropic }
        k.fake.begin("pane-key", [.tool("navigate", ["url": "\(k.base)/article.html"]), .tool("wait", ["duration": 3]), .text("Fixturia's capital is Testville.")])
        AgentUI.close(c)
        let task = "What is the capital of Fixturia?"
        k.front { [self] _ in
            pressView(agentButton, "the Airc Agent button", fallback: { AgentUI.toggle(self.c) }) { [self] how in
                wait({ AgentUI.isShown(self.c) && self.model?.mode == .connect }, 6) { [self] in
                    check(model?.mode == .connect, "nothing connected: the button opens the pane on “Connect your AI”, in the pane, not Settings [\(how) click]")
                    model?.cancelSetup()
                    k.type(task) { [self] typed in
                        k.press("agentpane.send", "Send", fallback: { self.model?.send() }) { [self] _ in
                            after(0.6) { [self] in
                                check(model?.text == task && run.steps.isEmpty, "Send with nothing connected keeps the task [\(typed) keys]")
                                k.press("agentpane.provider.api-anthropic.fix", "Add key… (Anthropic)", fallback: { self.model?.enterKey(.anthropic) }) { [self] how in
                                    wait({ self.model?.keyEntry == .anthropic && self.k.point("agentpane.key.field") != nil }, 4) { [self] in
                                        check(model?.keyEntry == .anthropic, "Add key… shows the key field in the pane [\(how) click]")
                                        check(NSApp.windows.allSatisfy { !($0.isVisible && $0.title.contains("Settings")) }, "… and no Settings window")
                                        k.shot("agentpane2-key")
                                        typeKey { [self] how in
                                            wait({ self.model?.keyEntry == nil }, 4) { [self] in
                                                check(model?.keyEntry == nil && AgentModelSettings.shared.key(.anthropic) == k.key,
                                                      "Save keeps the key (Keychain; memory in this run) and closes the card [\(how)]")
                                                check(AgentModelSettings.shared.values.backend == .apiKey && AgentModelSettings.shared.values.provider == .anthropic, "… Anthropic is the agent's provider now")
                                                wait({ self.run.state.isActive }, 6) { [self] in
                                                    check(run.steps.first { $0.kind == .user }.map { AgentPaneItem.promptText($0.text) } == task, "… and the typed task goes by itself")
                                                    wait({ self.c.sidebar.header.agent.dotShown && self.c.sidebar.header.agent.liveAgentRow != nil }, 8) { [self] in
                                                        check(c.sidebar.header.agent.dotShown, "while it works, the button has its dot")
                                                        let watch = (agentButton as? GlyphButton)?.contextMenuProvider?()?.items.first { $0.title == "Watch" }
                                                        check(watch?.isEnabled == true, "… and right-click › Watch is on")
                                                        wait({ !self.run.state.isActive }, 30) { [self] in
                                                            check(run.state == .done && k.finalText == "Fixturia's capital is Testville.", "… to the end (“\(k.finalText)”)")
                                                            after(0.3) { [self] in
                                                                check(!c.sidebar.header.agent.dotShown, "the dot goes when it's done")
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
            }
        }
    }

    /// The fixture key into the key field: a real click and real keys, then Save (real); else posted.
    func typeKey(_ done: @escaping (String) -> Void) {
        guard k.real, let keys = UIDriverClient.keys(typing: k.key) else { model?.saveKey(k.key); return done("posted") }
        k.press("agentpane.key.field", "the key field", fallback: {}) { [self] _ in
            after(0.3) { [self] in
                UIDriverClient.press(keys, pid: getpid()) { [self] ok, _ in
                    DispatchQueue.main.async { [self] in
                        if !ok { model?.saveKey(k.key); return done("posted") }
                        after(0.3) { [self] in
                            k.press("agentpane.key.save", "Save", fallback: { self.model?.saveKey(self.k.key) }) { how in done("\(how) keys + \(how) click") }
                        }
                    }
                }
            }
        }
    }

    // MARK: The first-run hint

    func caseHint(_ done: @escaping () -> Void) {
        run.newConversation()
        AgentUI.close(c)
        AgentButtonHint.resetForTesting()
        k.front { [self] _ in
            let p = AgentButtonHint.show(in: c)
            wait({ AgentButtonHint.shownView != nil }, 3) { [self] in
                let v = AgentButtonHint.shownView
                check(p != nil && v != nil, "the first-run hint shows over the Airc Agent button")
                if let v, let w = v.window {
                    v.layoutSubtreeIfNeeded()
                    check(TestAnchors.view("agenthint.title", in: v) != nil, "… “Ask Airc to do things for you”")
                    let bf = agentButton.window.map { $0.convertToScreen(agentButton.convert(agentButton.bounds, to: nil)) } ?? .zero
                    check(abs(w.frame.midX - bf.midX) < w.frame.width / 2 + 4 && w.frame.maxY <= bf.minY + 4,
                          "… under the toolbar's button, pointing up at it (hint \(NSStringFromRect(w.frame)), button \(NSStringFromRect(bf)))")
                    if let img = runner.render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: runner.dir.appendingPathComponent("agentpane2-hint-\(engine).png"))
                    }
                }
                check(AgentButtonHint.wasShown, "… and it's remembered as shown on this Mac")
                after(0.8) { [self] in
                    let dismiss = AgentButtonHint.shownView.flatMap { TestAnchors.view("agenthint.dismiss", in: $0) }
                    pressView(dismiss, "Not now", fallback: { AgentButtonHint.close() }) { [self] how in
                        wait({ AgentButtonHint.shownView == nil }, 3) { [self] in
                            check(AgentButtonHint.shownView == nil, "“Not now” dismisses it [\(how) click]")
                            check(AgentButtonHint.show(in: c) == nil && AgentButtonHint.shownView == nil, "… and it doesn't show again")
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: Finish

    func finish() {
        AgentButtonHint.close()
        model?.cancelSetup()
        if let o = savedOpener { AgentCLISetupFiles.openInTerminal = o }
        for f in terminalFiles { try? FileManager.default.removeItem(at: f) }
        if root.path.contains("airc-panecli2-") {
            try? FileManager.default.copyItem(at: pathDir.appendingPathComponent("fake-log.jsonl"), to: runner.dir.appendingPathComponent("agentpane2-fake-log-\(engine).jsonl"))
            try? FileManager.default.removeItem(at: root)
        }
        AgentModelSettings.shared.setBackendForTesting(.apiKey)
        k.finish()
    }
}
#endif
