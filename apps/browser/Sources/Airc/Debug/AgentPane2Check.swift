// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
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
        step { done in k.caseCLI(.claudeCode, done) }
        step { done in k.caseCLI(.codex, done) }
        step { done in k.caseSignedOutTurn(done) }
        step { done in k.caseHandBack(done) }
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
        wait({ self.k.events.contains("tool wait") && self.k.point("agentpane.takeover") != nil }, 25) { [self] in
            guard let wid = run.runWindowID, let w = AgentCenter.shared.windows[wid], let page = w.activeTab, let agentTab = w.activeTabID else {
                check(false, "the agent works on the form page in its window"); return done()
            }
            check(page.url?.path == "/form.html", "the agent's page is the form (\(page.url?.path ?? "none"))")
            let before = c.shownTabID
            k.press("agentpane.takeover", "Take over", fallback: { self.model?.takeOver() }) { [self] how in
                wait({ self.model?.takenOver != nil && !self.run.state.isActive && self.c.shownTabID != before }, 8) { [self] in
                    guard let tabID = c.shownTabID, tabID != before else { check(false, "Take over makes the page this window's tab [\(how) click]"); return done() }
                    check(c.engineTab(for: tabID) === page, "Take over: the same page object is now this window's tab [\(how) click]")
                    check(model?.takenOver?.tabID == tabID && model?.takenOver?.agentTabID == agentTab, "… the pane remembers the tab and the agent's tab id (\(agentTab))")
                    // The person types in the form and scrolls (page script; the field keeps the value, the page its scroll).
                    evaluate(page, "var f=document.getElementById('f');f.focus();f.value='Typed by the person';f.dispatchEvent(new Event('input',{bubbles:true}));window.scrollTo(0,1200);window.__aircKept='kept';return {y:scrollY,h:history.length}") { [self] typed in
                        let history = typed["h"] as? Int ?? -1
                        note("agentpane2 \(engine): before Hand back: \(typed)")
                        k.fake.begin("handback2-after", Array(repeating: .text("Carrying on from your page."), count: 3), offset: 2)
                        k.press("agentpane.handback", "Hand back", fallback: { self.model?.handBack() }) { [self] how in
                            wait({ self.k.fake.requests(for: "handback2-after") > 0 && !self.run.state.isActive }, 25) { [self] in
                                let nw = run.runWindowID.flatMap { AgentCenter.shared.windows[$0] }
                                check(model?.takenOver == nil, "Hand back clears the banner [\(how) click]")
                                check(nw?.activeTab === page, "… the same page object (\(engine == "webkit" ? "WKWebView" : "WebContents")) is the agent window's tab again, not a reload of its address")
                                check(nw?.activeTabID == agentTab, "… with the same tab id (\(nw?.activeTabID.map(String.init) ?? "none") vs \(agentTab))")
                                check(nw?.tabs.count == 1, "… the window's blank first page closed (\(nw?.tabs.count ?? 0) tabs)")
                                check(c.store.tab(tabID) == nil && c.engineTab(for: tabID) == nil, "… and the tab left the person's sidebar")
                                check(c.shownTabID != tabID, "… the person's window shows another tab")
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

    // MARK: Finish

    func finish() {
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
