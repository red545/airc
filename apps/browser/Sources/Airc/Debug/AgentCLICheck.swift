// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentcli` (and the end of `--script agentpanel`): the Airc Agent on the person's own Claude Code and Codex
/// (docs/design/agent-cli.md, "Tests"), against fake `claude` and `codex` executables (AgentCLIFakes.swift, Python 3)
/// that speak the same protocols (stream-json; app-server JSON-RPC) and drive Airc's real MCP tools through the bundled
/// airc-mcp helper on the run's own socket, on the fixture pages of the agentpanel check. Airc looks only in the fakes'
/// folder (`setDirForTesting`), never at a real install; no account, no model, no credentials.
/// Per CLI: not installed, not logged in (status and a turn that fails on login), streaming + tool calls, a follow-up in
/// the same process, Pay → Deny, Send → Allow, Stop mid-turn (interrupt honoured; and ignored → process group killed,
/// next task resumes the session), a crash mid-turn, a foreign tool (shell) stopped; Codex: approvals declined and
/// elicitations answered. Real clicks on Stop / Deny / Allow and a typed task with the UI driver in a dedicated session.
extension SnapshotRunner {
    func agentCLIScenario() {
        let k = AgentPanelCheck(runner: self)
        step { done in k.setUp(done) }
        k.addCLISteps(self)
        run { k.finish() }
    }
}

extension AgentPanelCheck {
    private static var cliRoot: URL?
    private static var savedKeyEnv: String?
    private static let fixtureEnvKey = "airc-fixture-env-key-5520"

    var cliBin: URL { Self.cliRoot!.appendingPathComponent("bin", isDirectory: true) }
    var cliNone: URL { Self.cliRoot!.appendingPathComponent("none", isDirectory: true) }

    func addCLISteps(_ r: SnapshotRunner) {
        r.step { done in self.cliSetUp(done) }
        for kind in AgentCLIKind.allCases {
            r.step { done in self.cliNotInstalled(kind, done) }
            r.step { done in self.cliNotLoggedIn(kind, done) }
            r.step { done in self.cliRead(kind, done) }
            r.step { done in self.cliPayDeny(kind, done) }
            r.step { done in self.cliSendAllow(kind, done) }
            r.step { done in self.cliStop(kind, done) }
            r.step { done in self.cliStopKill(kind, done) }
            r.step { done in self.cliCrash(kind, done) }
            r.step { done in self.cliForeign(kind, done) }
        }
        r.step { done in self.cliTearDown(done) }
    }

    func cliCheck(_ kind: AgentCLIKind, _ ok: Bool, _ what: String) { check(ok, "[\(kind.name)] " + what) }

    // MARK: Fixtures

    func cliSetUp(_ done: @escaping () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-fakecli-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        Self.cliRoot = root
        try? FileManager.default.createDirectory(at: cliBin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cliNone, withIntermediateDirectories: true)
        for (name, source) in [("claude", AgentCLIFakes.claude), ("codex", AgentCLIFakes.codex)] {
            let u = cliBin.appendingPathComponent(name)
            try? source.write(to: u, atomically: true, encoding: .utf8)
            chmod(u.path, 0o755)
        }
        check(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "(cli) python3 is there for the fake CLIs")
        check(FileManager.default.isExecutableFile(atPath: AgentSetup.helperPath), "(cli) the bundled airc-mcp helper is there (\(AgentSetup.helperPath.hasSuffix("airc-mcp")))")
        // A key in Airc's own environment must never reach the CLI (it uses the login the person made in it).
        Self.savedKeyEnv = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        setenv("ANTHROPIC_API_KEY", Self.fixtureEnvKey, 1)
        setenv("OPENAI_API_KEY", Self.fixtureEnvKey, 1)
        AgentCLIDetector.shared.setDirForTesting(cliBin.path)
        done()
    }

    func cliTearDown(_ done: @escaping () -> Void) {
        let pids = cliLog(nil).flatMap { e -> [Int32] in
            [(e["pid"] as? NSNumber)?.int32Value, (e["helperPid"] as? NSNumber)?.int32Value].compactMap { $0 }
        }
        run.newConversation()
        AgentModelSettings.shared.setBackendForTesting(.apiKey)
        AgentCLIDetector.shared.setDirForTesting(nil)
        unsetenv("OPENAI_API_KEY")
        if let k = Self.savedKeyEnv { setenv("ANTHROPIC_API_KEY", k, 1) } else { unsetenv("ANTHROPIC_API_KEY") }
        runner.waitUntil({ pids.allSatisfy { kill($0, 0) != 0 } }, timeout: 5) { [self] in
            let alive = pids.filter { kill($0, 0) == 0 }
            check(alive.isEmpty, "(cli) no fake CLI or helper process is left after the conversation ends (\(pids.count) started, alive: \(alive))")
            let sockets = (try? FileManager.default.contentsOfDirectory(atPath: (AgentCLIRun.temporaryPath("x") as NSString).deletingLastPathComponent))?
                .filter { $0.hasPrefix("airc-run-") } ?? []
            check(sockets.isEmpty, "(cli) the runs' sockets and config files are gone (\(sockets))")
            if let root = Self.cliRoot {
                try? FileManager.default.copyItem(at: root.appendingPathComponent("bin/fake-log.jsonl"), to: runner.dir.appendingPathComponent("agentcli-fake-log-\(engine).jsonl"))
                try? FileManager.default.removeItem(at: root)
            }
            done()
        }
    }

    /// The fake's script for the next case.
    func cliState(_ name: String, turns: [[[String: Any]]], loggedIn: Bool = true, ignoreInterrupt: Bool = false) {
        let o: [String: Any] = ["case": name, "loggedIn": loggedIn, "ignoreInterrupt": ignoreInterrupt, "turns": turns]
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: cliBin.appendingPathComponent("fake-state.json")) }
    }

    /// What the fakes logged (for one case, or all).
    func cliLog(_ name: String?) -> [[String: Any]] {
        guard let root = Self.cliRoot, let s = try? String(contentsOf: root.appendingPathComponent("bin/fake-log.jsonl"), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { name == nil || $0["case"] as? String == name }
    }

    func cliEvents(_ name: String, _ event: String) -> [[String: Any]] { cliLog(name).filter { $0["event"] as? String == event } }

    /// The CLI's runs (not Airc's status probes: `codex app-server` with no flags, which also logs a start).
    func cliRuns(_ name: String) -> [[String: Any]] { cliEvents(name, "start").filter { ($0["argv"] as? [String] ?? []).count > 1 } }

    func untilFake(_ name: String, _ event: String, timeout: Double = 20, _ then: @escaping () -> Void) {
        runner.waitUntil({ !self.cliEvents(name, event).isEmpty }, timeout: timeout, then: then)
    }

    func backend(_ kind: AgentCLIKind) -> AgentBackend { kind == .claudeCode ? .claudeCode : .codex }

    /// A fresh conversation on `kind` with the fake's script, the task asked (posted).
    func cliStart(_ kind: AgentCLIKind, _ name: String, _ turns: [[[String: Any]]], loggedIn: Bool = true, ignoreInterrupt: Bool = false,
                  task: String = "Do the fixture task") {
        run.newConversation()
        events = []
        cliState(name, turns: turns, loggedIn: loggedIn, ignoreInterrupt: ignoreInterrupt)
        AgentModelSettings.shared.setBackendForTesting(backend(kind))
        if panel == nil { AgentPanelController.show(c) }
        cliAsk(task)
    }

    func cliAsk(_ task: String) {
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        run.ask(task, profileID: p.id, profileName: p.name)
    }

    func status(_ kind: AgentCLIKind, fresh: Bool = true, _ then: @escaping (AgentCLIStatus) -> Void) {
        AgentCLIDetector.shared.check(kind, maxAge: fresh ? 0 : 30) { s in then(s) }
    }

    var lastError: String { run.steps.last { $0.kind == .error }?.text ?? "" }

    // MARK: Not installed, not logged in

    func cliNotInstalled(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        AgentCLIDetector.shared.setDirForTesting(cliNone.path)
        AgentModelSettings.shared.setBackendForTesting(backend(kind))
        status(kind) { [self] s in
            cliCheck(kind, s == .notInstalled, "not installed is detected (\(s.summary(kind)))")
            cliCheck(kind, s.fix(kind)?.contains(kind == .claudeCode ? "@anthropic-ai/claude-code" : "@openai/codex") == true, "… with how to install it")
            cliCheck(kind, !run.hasKey, "the panel shows its connect card instead of a task field")
            run.newConversation()
            cliAsk("Anything")
            untilIdle(10) { [self] in
                cliCheck(kind, run.state != .done && lastError.contains("not installed"), "a task says it isn't installed and how to fix it (“\(lastError.prefix(90))”)")
                shot("agentcli-notinstalled-\(kind.binary)")
                AgentCLIDetector.shared.setDirForTesting(cliBin.path)
                done()
            }
        }
    }

    func cliNotLoggedIn(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        cliState("login-\(kind.binary)", turns: [[["say": "Should never be said."]]], loggedIn: false)
        status(kind) { [self] s in
            if case .notLoggedIn(_, let v) = s { cliCheck(kind, v != nil, "not logged in is detected (\(s.summary(kind)))") }
            else { cliCheck(kind, false, "not logged in is detected (\(s.summary(kind)))") }
            cliCheck(kind, s.fix(kind)?.contains("run `\(kind.binary)` in Terminal") == true, "… with “run \(kind.binary) in Terminal and log in”")
            run.newConversation()
            cliAsk("Anything")
            untilIdle(10) { [self] in
                cliCheck(kind, lastError.contains("Not logged in"), "a task says to log in first (“\(lastError.prefix(80))”)")
                cliCheck(kind, cliEvents("login-\(kind.binary)", "turn").isEmpty, "… without starting a turn")
                // Logged in when Airc checked, then the login expired: the turn fails with the same advice.
                cliState("login2-\(kind.binary)", turns: [[["say": "Should never be said."]]])
                status(kind) { [self] s2 in
                    cliCheck(kind, s2.isReady, "logged in is detected (\(s2.summary(kind)))")
                    cliCheck(kind, s2.summary(kind) == (kind == .claudeCode ? "Claude Code 2.9.0, logged in (Max)" : "Codex 0.200.0, logged in (ChatGPT Plus)"),
                             "Settings reads “\(s2.summary(kind))”, never the account's email")
                    cliStart(kind, "login2-\(kind.binary)", [[["say": "Should never be said."]]], loggedIn: false)
                    untilIdle(20) { [self] in
                        if case .failed = run.state { cliCheck(kind, lastError.contains("Not logged in"), "a turn refused for login ends with “log in” (“\(lastError.prefix(80))”)") }
                        else { cliCheck(kind, false, "a turn refused for login fails (state \(run.state))") }
                        // The failed turn started a status check that may have read "logged out": check again after it.
                        cliState("login3-\(kind.binary)", turns: [[["say": "x"]]])
                        status(kind) { [self] _ in
                            status(kind) { [self] s3 in
                                cliCheck(kind, s3.isReady, "logged in again once the CLI is (\(s3.summary(kind)))")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Streaming, tools, follow-up

    func cliRead(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "read-\(kind.binary)"
        let turns: [[[String: Any]]] = [
            [["say": "Let me read the page.", "every": 0.08], ["tool": "navigate", "args": ["url": "\(base)/article.html"]],
             ["tool": "read_page", "args": ["mode": "text"]], ["say": "The capital of Fixturia is Brightport.", "every": 0.05]],
            [["say": "Still Brightport."]]]
        var sawPartial = false
        var sawRow = false
        let started = Date()
        let then = { [self] in
            runner.waitUntil({
                if !self.run.partial.isEmpty { sawPartial = true }
                if AgentActivity.shared.model.rows.contains(where: { $0.client == kind.clientName && $0.isLive }) { sawRow = true }
                return !self.run.state.isActive && Date().timeIntervalSince(started) > 0.3
            }, timeout: 40) { [self] in
                cliCheck(kind, run.state == .done, "the task finishes (state \(run.state); \(lastError.prefix(120)))")
                cliCheck(kind, finalText.contains("Brightport"), "the answer shows in the panel (“\(finalText.prefix(60))”)")
                cliCheck(kind, run.steps.contains { $0.kind == .say && $0.text == "Let me read the page." }, "text before a tool call is a step of its own")
                cliCheck(kind, sawPartial, "the answer streams in (live line)")
                cliCheck(kind, run.steps.filter { $0.kind == .action }.count >= 2, "the panel lists the tool steps (\(run.steps.filter { $0.kind == .action }.count))")
                let tools = cliEvents(name, "tool")
                let read = tools.first { $0["name"] as? String == "read_page" }
                cliCheck(kind, (read?["result"] as? String)?.contains("Brightport") == true && (read?["result"] as? String)?.contains("untrusted-page-content") == true,
                         "\(kind.binary) called Airc's read_page through airc-mcp and got the page, fenced as untrusted")
                cliCheck(kind, fake.pages.contains("/article.html"), "the run's agent window loaded the fixture page")
                let listed = cliEvents(name, "mcp").first?["tools"] as? [String] ?? []
                cliCheck(kind, listed.contains("navigate") && !listed.contains("open_window") && !listed.contains("use_profile") && !listed.contains("list_profiles"),
                         "the CLI sees the panel's tools only (\(listed.count), no window/profile tools)")
                let start = cliRuns(name).first ?? [:]
                cliCheck(kind, start["apiKeyEnv"] as? Bool == false, "no API key from Airc's environment reaches \(kind.binary)")
                cliCheck(kind, (start["cwd"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path.hasSuffix("AgentCLI/work") } == true,
                         "\(kind.binary) runs in Airc's empty work folder (\(start["cwd"] as? String ?? "-"))")
                cliCheck(kind, (start["pgid"] as? NSNumber)?.int32Value == (start["pid"] as? NSNumber)?.int32Value, "\(kind.binary) has a process group of its own")
                let argv = start["argv"] as? [String] ?? []
                if kind == .claudeCode {
                    func value(_ f: String) -> String? { argv.firstIndex(of: f).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil } }
                    cliCheck(kind, value("--tools") == "" && value("--allowedTools") == "mcp__airc" && value("--permission-mode") == "dontAsk" && argv.contains("--strict-mcp-config"),
                             "claude runs with no built-in tools, only Airc's MCP server allowed, dontAsk")
                    cliCheck(kind, cliEvents(name, "config").first?["servers"] as? [String] == ["airc"], "the MCP config has only Airc's server")
                    cliCheck(kind, start["mcpTimeout"] as? String == "330000", "MCP calls may wait for an approval (MCP_TOOL_TIMEOUT 330 s)")
                    cliCheck(kind, run.usageLine.contains("$0.01"), "the usage line shows what Claude Code reported (\(run.usageLine))")
                } else {
                    cliCheck(kind, argv.contains("shell_tool") && argv.contains("unified_exec"), "codex app-server runs with its shell tools off")
                    let p = cliEvents(name, "thread/start").first?["params"] as? [String: Any] ?? [:]
                    let servers = (p["config"] as? [String: Any])?["mcp_servers"] as? [String: Any] ?? [:]
                    cliCheck(kind, p["approvalPolicy"] as? String == "never" && p["sandbox"] as? String == "read-only", "the thread is read-only and never asks")
                    cliCheck(kind, (servers["personal-fs"] as? [String: Any])?["enabled"] as? Bool == false, "the person's own MCP servers are off for the thread")
                    cliCheck(kind, (p["developerInstructions"] as? String)?.contains("Airc Agent") == true, "Airc's rules go in as developer instructions")
                }
                cliCheck(kind, run.usage.total > 0, "usage is counted (\(run.usage.total) tokens)")
                cliCheck(kind, sawRow, "the run shows in the Agents folder as “\(kind.clientName)”")
                shot("agentcli-read-\(kind.binary)")
                // A follow-up in the same conversation: the same process, the next turn.
                let pid = run.cliPIDForTesting
                cliAsk("And again?")
                untilIdle(20) { [self] in
                    cliCheck(kind, run.state == .done && finalText == "Still Brightport.", "a follow-up works in the same conversation (“\(finalText)”)")
                    cliCheck(kind, pid != nil && run.cliPIDForTesting == pid && cliRuns(name).count == 1, "… in the same \(kind.binary) process")
                    done()
                }
            }
        }
        guard real else {
            cliStart(kind, name, turns, task: "What is the capital of Fixturia?")
            return then()
        }
        // Real keys: ⌥⌘A if the panel is closed, the task typed, Return.
        run.newConversation()
        cliState(name, turns: turns)
        AgentModelSettings.shared.setBackendForTesting(backend(kind))
        panel?.close()
        key("cmd+opt+a") { [self] ok in
            runner.waitUntil({ self.panel != nil && self.panel!.panel.isKeyWindow }, timeout: 4) { [self] in
                cliCheck(kind, ok && panel?.panel.isKeyWindow == true, "⌥⌘A opens the panel [real key]")
                var keys = ["c", "a", "p", "i", "t", "a", "l", "return"][...]
                func next() {
                    guard let k = keys.popFirst() else { return then() }
                    key(k) { _ in next() }
                }
                next()
            }
        }
    }

    // MARK: Approvals

    func cliPayDeny(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "pay-\(kind.binary)"
        cliStart(kind, name, [[["tool": "navigate", "args": ["url": "\(base)/shop.html"]], ["tool": "left_click", "args": ["coordinate": [100, 180]]],
                               ["say": "Paid."]]])
        untilApproval { [self] in
            cliCheck(kind, run.approval?.risk.category == .payment, "Pay now asks first: \(run.approval?.title ?? "no card")")
            shot("agentcli-approval-\(kind.binary)")
            press("agent.deny", "Deny", fallback: { self.run.answerApproval(allow: false) }) { [self] how in
                untilIdle(15) { [self] in
                    if case .stopped = run.state { cliCheck(kind, true, "Deny stops the run [\(how) click]") }
                    else { cliCheck(kind, false, "Deny stops the run [\(how) click] (state \(run.state))") }
                    cliCheck(kind, !fake.targets.contains("/paid"), "nothing was paid (no POST /paid)")
                    let click = cliEvents(name, "tool").first { $0["name"] as? String == "left_click" }
                    cliCheck(kind, click?["isError"] as? Bool == true && (click?["result"] as? String)?.contains("declined") == true,
                             "\(kind.binary) got the decline as the tool's error")
                    cliCheck(kind, !run.steps.contains { $0.kind == .final && $0.text == "Paid." }, "the run doesn't go on after Deny")
                    cliCheck(kind, run.steps.contains { $0.kind == .decision && $0.text.hasPrefix("Declined: Pay") }, "the panel logs “Declined: Pay …”")
                    done()
                }
            }
        }
    }

    func cliSendAllow(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "send-\(kind.binary)"
        cliStart(kind, name, [[["tool": "navigate", "args": ["url": "\(base)/mail.html"]], ["tool": "left_click", "args": ["coordinate": [80, 320]]],
                               ["tool": "wait_for_load", "args": [:]], ["say": "Sent."]]])
        untilApproval { [self] in
            cliCheck(kind, run.approval?.risk.category == .send, "Send asks first: \(run.approval?.title ?? "no card")")
            press("agent.allow", "Allow Once", fallback: { self.run.answerApproval(allow: true) }) { [self] how in
                untilIdle(20) { [self] in
                    cliCheck(kind, run.state == .done && finalText == "Sent.", "Allow continues to the end [\(how) click] (state \(run.state))")
                    cliCheck(kind, fake.targets.contains("/sent"), "the message was sent once allowed (POST /sent)")
                    cliCheck(kind, run.steps.contains { $0.kind == .decision && $0.text.hasPrefix("Allowed: Send") }, "the panel logs “Allowed: Send …”")
                    done()
                }
            }
        }
    }

    // MARK: Stop

    func cliStop(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "stop-\(kind.binary)"
        cliStart(kind, name, [[["say": "Working on it."], ["tool": "navigate", "args": ["url": "\(base)/article.html"]], ["hold": 30], ["say": "Never reached."]],
                              [["say": "Still here."]]])
        untilFake(name, "hold") { [self] in
            let pid = run.cliPIDForTesting
            let t0 = Date()
            press("agent.stop", "Stop", fallback: { self.run.stop() }) { [self] how in
                untilIdle(6) { [self] in
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if case .stopped = run.state { cliCheck(kind, ms < 3000, "Stop mid-turn ends the run [\(how) click] (\(ms) ms)") }
                    else { cliCheck(kind, false, "Stop mid-turn ends the run [\(how) click] (state \(run.state))") }
                    cliCheck(kind, !cliEvents(name, "interrupt").isEmpty, "\(kind.binary) was asked to interrupt its turn")
                    cliCheck(kind, pid.map { kill($0, 0) == 0 } == true, "… and kept its process (no kill needed)")
                    cliCheck(kind, !finalText.contains("Never reached"), "the run doesn't go on after Stop")
                    cliCheck(kind, AgentActivity.shared.model.rows.contains { $0.client == kind.clientName && $0.end == .stopped }, "the Agents folder row reads Stopped")
                    cliAsk("Are you there?")
                    untilIdle(20) { [self] in
                        cliCheck(kind, run.state == .done && finalText == "Still here.", "a follow-up after Stop works (“\(finalText)”)")
                        cliCheck(kind, run.cliPIDForTesting == pid, "… in the same process")
                        done()
                    }
                }
            }
        }
    }

    func cliStopKill(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "kill-\(kind.binary)"
        cliStart(kind, name, [[["tool": "navigate", "args": ["url": "\(base)/article.html"]], ["hold": 60]], [["say": "Back again."]]], ignoreInterrupt: true)
        untilFake(name, "hold") { [self] in
            let pid = run.cliPIDForTesting
            let session = run.cliSessionForTesting
            let helper = (cliEvents(name, "mcp").first?["helperPid"] as? NSNumber)?.int32Value
            let t0 = Date()
            run.stop()
            untilIdle(8) { [self] in
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if case .stopped = run.state { cliCheck(kind, ms < 5000, "Stop ends the run when \(kind.binary) ignores the interrupt (\(ms) ms)") }
                else { cliCheck(kind, false, "Stop ends the run when \(kind.binary) ignores the interrupt (state \(run.state))") }
                runner.waitUntil({ [pid, helper].compactMap { $0 }.allSatisfy { kill($0, 0) != 0 } }, timeout: 3) { [self] in
                    cliCheck(kind, pid.map { kill($0, 0) != 0 } == true, "… its process is gone (killed with its group)")
                    cliCheck(kind, helper.map { kill($0, 0) != 0 } == true, "… and so is the airc-mcp helper it started")
                    cliState(name, turns: [[], [["say": "Back again."]]])
                    cliAsk("Go on")
                    untilIdle(20) { [self] in
                        cliCheck(kind, run.state == .done && finalText == "Back again.", "the next task starts a new \(kind.binary) (“\(finalText)”)")
                        cliCheck(kind, run.cliPIDForTesting != pid, "… in a new process")
                        if kind == .claudeCode {
                            let argv = cliRuns(name).last?["argv"] as? [String] ?? []
                            cliCheck(kind, session != nil && argv.firstIndex(of: "--resume").map { argv[$0 + 1] } == session, "… resuming the same session (--resume)")
                        } else {
                            cliCheck(kind, (cliEvents(name, "thread/resume").last?["params"] as? [String: Any])?["threadId"] as? String == session && session != nil,
                                     "… resuming the same thread (thread/resume)")
                        }
                        done()
                    }
                }
            }
        }
    }

    // MARK: Crash, foreign tools

    func cliCrash(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "crash-\(kind.binary)"
        cliStart(kind, name, [[["say": "Starting."], ["tool": "navigate", "args": ["url": "\(base)/article.html"]], ["crash": 3]], [["say": "Recovered."]]])
        untilIdle(20) { [self] in
            if case .failed(let m) = run.state {
                cliCheck(kind, m.contains("quit unexpectedly (exit 3)") && m.contains("crashing on purpose"), "a crash mid-turn ends the task with what happened (“\(m.prefix(100))”)")
            } else { cliCheck(kind, false, "a crash mid-turn fails the task (state \(run.state))") }
            cliCheck(kind, run.approval == nil && run.partial.isEmpty, "nothing is left waiting in the panel")
            cliAsk("Try again")
            untilIdle(20) { [self] in
                cliCheck(kind, run.state == .done && finalText == "Recovered.", "the next task works after the crash (“\(finalText)”)")
                done()
            }
        }
    }

    func cliForeign(_ kind: AgentCLIKind, _ done: @escaping () -> Void) {
        let name = "foreign-\(kind.binary)"
        var steps: [[String: Any]] = [["foreign": kind == .claudeCode ? "Bash" : "shell"], ["say": "Should not be reached."]]
        if kind == .codex { steps.insert(["elicit": true], at: 0) }
        cliStart(kind, name, [steps])
        untilIdle(15) { [self] in
            if case .stopped = run.state { cliCheck(kind, true, "a tool that isn't Airc's stops the run") }
            else { cliCheck(kind, false, "a tool that isn't Airc's stops the run (state \(run.state))") }
            cliCheck(kind, run.steps.contains { $0.kind == .warning && $0.text.contains("tried to use") }, "the panel says what it tried (“\(run.steps.last { $0.kind == .warning }?.text.prefix(80) ?? "")”)")
            cliCheck(kind, cliEvents(name, "foreign-not-stopped").isEmpty, "the turn was interrupted at once")
            cliCheck(kind, !run.steps.contains { $0.text == "Should not be reached." }, "nothing after it ran")
            if kind == .codex {
                let answers = cliEvents(name, "answer").compactMap { $0["result"] as? [String: Any] }
                cliCheck(kind, answers.contains { $0["decision"] as? String == "decline" }, "Codex's command approval request was declined")
                cliCheck(kind, answers.filter { $0["action"] != nil }.map { $0["action"] as? String ?? "" } == ["accept", "decline"],
                         "elicitations: Airc's own server accepted (its card decides), anyone else's declined")
            }
            done()
        }
    }
}
#endif
