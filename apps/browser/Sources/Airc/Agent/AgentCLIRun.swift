// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit
import Security

/// One Airc Agent conversation on the person's own Claude Code or Codex (docs/design/agent-cli.md): the CLI process
/// (kept between tasks, resumed after Stop or a crash), the run's own MCP socket that the bundled airc-mcp helper
/// connects to from inside the CLI, and the protocol in between. What the tools do, and every approval, stays with
/// `AgentRunCenter` (`tools`), so the CLI can only reach Airc's browser tools, through the same gate as the API path.
final class AgentCLIRun {
    let kind: AgentCLIKind
    let executable: String
    /// The system rules (Claude Code `--append-system-prompt`, Codex developer instructions).
    var system = ""
    /// Claude Code `--max-turns` for a new process (Airc's own step budget applies on top, in the gate).
    var maxTurns = 30
    /// What happened, for the panel (main thread).
    var onEvent: ((AgentCLIEvent) -> Void)?
    /// The turn ended without the CLI saying so: it quit, didn't start, or broke the protocol.
    var onFailure: ((String) -> Void)?

    private let tools: () -> [AgentTool]
    private let token: String
    private let socketPath: String
    private var server: AgentServer?
    private var process: AgentCLIProcess?
    private var claude = ClaudeStreamParser()
    private var rpc = CodexRPC()
    private var pending: [Int: ([String: Any]?, String?) -> Void] = [:]
    /// Claude Code's session / Codex's thread: what `--resume` / `thread/resume` continue after a new process.
    private(set) var sessionID: String?
    private var turnOpen = false
    private var interrupting = false
    private var killWork: DispatchWorkItem?
    private var configFile: URL?
    private var closed = false
    /// Checks follow along.
    var onTrace: ((String) -> Void)?

    init(kind: AgentCLIKind, executable: String, tools: @escaping () -> [AgentTool]) {
        self.kind = kind
        self.executable = executable
        self.tools = tools
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
        socketPath = AgentCLIRun.temporaryPath("airc-run-\(token.prefix(12)).sock")
    }

    deinit { close() }

    /// `<data folder>/AgentCLI/work`: an empty folder Airc owns, the CLIs' working directory (no project settings,
    /// no CLAUDE.md, nothing to read).
    static func workFolder() -> URL {
        let u = AppPaths.dataDirectory.appendingPathComponent("AgentCLI/work", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    /// The per-user temporary folder (short enough for a socket address; only this user can enter it).
    static func temporaryPath(_ name: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let dir = n > 0 ? String(cString: buffer) : NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent(name)
    }

    var isRunning: Bool { process != nil }
    var turnInProgress: Bool { turnOpen }
    var pid: pid_t? { process?.pid }

    // MARK: The run's MCP socket

    private var mcpServer: AgentCLIMCPServer {
        AgentCLIMCPServer(helper: AgentSetup.helperPath, socket: socketPath, client: kind.clientID, token: token)
    }

    private func ensureServer() -> String? {
        if server != nil { return nil }
        let token = self.token
        let kind = self.kind
        let s = AgentServer(socketPath: socketPath, handler: { [weak self] line, session, reply in
            guard let self, !self.closed else { return reply(nil) }
            AgentMCP.handle(line, session: session, tools: self.tools(), log: { _, _, _ in }, reply: reply, timeout: 330)
        }, hello: { session, answer in
            // Only the helper this run started (it has the token from the CLI's MCP config).
            guard let t = session.helloToken, AgentCLIRun.same(t, token) else { return answer("This socket belongs to another Airc Agent run.") }
            session.client = kind.clientID
            session.clientName = kind.clientName
            session.clientKey = AgentBridge.clientKey
            session.via = "panel"
            answer(nil)
        })
        if let why = s.start() { return "Airc couldn't open its tools for \(kind.name) (\(why))." }
        server = s
        return nil
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    // MARK: Turns

    /// One task (or "Continue the task.") as a new turn.
    func send(_ text: String) {
        guard !closed else { return }
        if let why = ensureServer() { return onFailure?(why) ?? () }
        turnOpen = true
        interrupting = false
        switch kind {
        case .claudeCode:
            if process == nil, let why = launchClaude() { turnOpen = false; return onFailure?(why) ?? () }
            process?.write(ClaudeCLI.userMessage(text, session: sessionID))
            onTrace?("cli send")
        case .codex:
            if process == nil {
                launchCodex { [weak self] why in
                    guard let self else { return }
                    if let why { self.turnOpen = false; return self.onFailure?(why) ?? () }
                    self.startCodexTurn(text)
                }
            } else {
                startCodexTurn(text)
            }
        }
    }

    /// Stop: the CLI is asked to interrupt its turn; if it hasn't ended the turn 1.5 s later, its process group goes.
    func stop() {
        guard turnOpen, !interrupting else { return }
        interrupting = true
        onTrace?("cli interrupt")
        guard let p = process else { return }
        switch kind {
        case .claudeCode:
            p.write(ClaudeCLI.interrupt(id: "airc-stop-\(Int(Date().timeIntervalSince1970 * 1000))"))
        case .codex:
            if let thread = sessionID, let turn = rpc.turnID {
                p.write(rpc.request("turn/interrupt", ["threadId": thread, "turnId": turn]).line)
            } else {
                p.terminate(grace: 1)
            }
        }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.turnOpen, let p = self.process else { return }
            self.onTrace?("cli kill")
            p.terminate(grace: 2)
        }
        killWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    /// The conversation is over: the process group, the socket and the config file go.
    func close() {
        guard !closed else { return }
        closed = true
        killWork?.cancel()
        process?.onLine = nil
        process?.onExit = nil
        process?.terminate(grace: 1)
        process = nil
        server?.stop()
        server = nil
        unlink(socketPath)
        unlink(socketPath + ".lock")
        if let f = configFile { try? FileManager.default.removeItem(at: f) }
        pending = [:]
    }

    private func turnEnded() {
        turnOpen = false
        interrupting = false
        killWork?.cancel()
        killWork = nil
    }

    private func spawn(_ args: [String]) -> Result<AgentCLIProcess, AgentCLIError> {
        let env = AgentCLIDetector.shared.environment(for: kind, executable: executable)
        do {
            let p = try AgentCLIProcess(executable: executable, args: args, env: env, cwd: AgentCLIRun.workFolder().path)
            process = p
            onTrace?("cli spawned \(p.pid)")
            p.onExit = { [weak self, weak p] code, err in
                guard let self, let p, self.process === p else { return }
                self.processExited(code, err)
            }
            return .success(p)
        } catch {
            return .failure(AgentCLIError("\(kind.name) didn't start: \(error)."))
        }
    }

    private func processExited(_ code: Int32, _ err: String) {
        process = nil
        pending = [:]
        onTrace?("cli exited \(code)")
        guard turnOpen else { return }
        let wasInterrupting = interrupting
        turnEnded()
        if wasInterrupting {
            onEvent?(.turnEnded(AgentCLITurnEnd(.interrupted)))
        } else {
            let line = AgentCLIProcess.lastLine(err)
            if AgentCLIAuth.looksLikeLogin(line) { return onEvent?(.turnEnded(AgentCLITurnEnd(.loginNeeded))) ?? () }
            onFailure?("\(kind.name) quit unexpectedly (exit \(code))" + (line.isEmpty ? "." : ": \(line)"))
        }
    }

    // MARK: Claude Code

    private func launchClaude() -> String? {
        let file = URL(fileURLWithPath: AgentCLIRun.temporaryPath("airc-run-\(token.prefix(12))-mcp.json"))
        guard AgentPaths.writePrivate(ClaudeCLI.mcpConfig(mcpServer), to: file.path) else { return "Airc couldn't write \(kind.name)'s tool config." }
        configFile = file
        claude = ClaudeStreamParser()
        let args = ClaudeCLI.arguments(mcpConfig: file.path, system: system, maxTurns: maxTurns, resume: sessionID)
        switch spawn(args) {
        case .failure(let why): return why.description
        case .success(let p):
            p.onLine = { [weak self, weak p] line in
                guard let self, let p, self.process === p else { return }
                let events = self.claude.feed(line)
                for r in self.claude.takeReplies() { p.write(r) }
                if let s = self.claude.sessionID { self.sessionID = s }
                self.deliver(events)
            }
            return nil
        }
    }

    private func deliver(_ events: [AgentCLIEvent]) {
        for e in events {
            if case .turnEnded = e {
                guard turnOpen else { continue }
                turnEnded()
            }
            onEvent?(e)
        }
    }

    // MARK: Codex

    private func call(_ method: String, _ params: [String: Any], _ done: @escaping ([String: Any]?, String?) -> Void) {
        guard let p = process else { return done(nil, "\(kind.name) isn't running.") }
        let r = rpc.request(method, params)
        pending[r.id] = done
        p.write(r.line)
    }

    private func launchCodex(_ done: @escaping (String?) -> Void) {
        rpc = CodexRPC()
        switch spawn(CodexCLI.arguments) {
        case .failure(let why): return done(why.description)
        case .success(let p):
            p.onLine = { [weak self, weak p] line in
                guard let self, let p, self.process === p else { return }
                self.codexLine(line, p)
            }
        }
        var answered = false
        let finish: (String?) -> Void = { why in
            guard !answered else { return }
            answered = true
            done(why)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard !answered else { return }
            self?.process?.terminate(grace: 1)
            finish("\(self?.kind.name ?? "Codex") didn't start in 30 seconds.")
        }
        let cwd = AgentCLIRun.workFolder().path
        call("initialize", CodexCLI.initialize(version: AgentCLIDetector.appVersion)) { [weak self] _, error in
            guard let self else { return }
            if let error { return finish("Codex didn't start: \(error)") }
            self.process?.write(CodexRPC.notification("initialized"))
            self.call("config/read", ["includeLayers": false, "cwd": cwd]) { [weak self] config, _ in
                guard let self else { return }
                let theirs = config.map(CodexCLI.mcpServerNames) ?? []
                let start = { [weak self] in
                    guard let self else { return }
                    self.call("thread/start", CodexCLI.threadStart(cwd: cwd, instructions: self.system, server: self.mcpServer, disable: theirs)) { [weak self] r, error in
                        guard let self else { return }
                        guard let thread = (r?["thread"] as? [String: Any])?["id"] as? String else {
                            let m = error ?? "no thread"
                            return finish(AgentCLIAuth.looksLikeLogin(m) ? self.kind.loginHint : "Codex couldn't start a conversation: \(m)")
                        }
                        self.sessionID = thread
                        self.rpc.setThread(thread)
                        finish(nil)
                    }
                }
                guard let thread = self.sessionID else { return start() }
                self.call("thread/resume", CodexCLI.threadResume(thread: thread, cwd: cwd, instructions: self.system, server: self.mcpServer, disable: theirs)) { [weak self] r, _ in
                    guard let self else { return }
                    guard ((r?["thread"] as? [String: Any])?["id"] as? String) != nil else { self.sessionID = nil; return start() }
                    self.rpc.setThread(thread)
                    finish(nil)
                }
            }
        }
    }

    private func startCodexTurn(_ text: String) {
        guard let thread = sessionID else { turnOpen = false; return onFailure?("Codex has no conversation.") ?? () }
        onTrace?("cli send")
        call("turn/start", CodexCLI.turnStart(thread: thread, text: text)) { [weak self] r, error in
            guard let self, self.turnOpen else { return }
            if let error {
                self.turnEnded()
                if AgentCLIAuth.looksLikeLogin(error) { return self.onEvent?(.turnEnded(AgentCLITurnEnd(.loginNeeded))) ?? () }
                return self.onFailure?("Codex: \(error)") ?? ()
            }
            // Stop pressed before Codex said which turn this is: interrupt it now.
            if self.interrupting, let turn = (r?["turn"] as? [String: Any])?["id"] as? String {
                self.process?.write(self.rpc.request("turn/interrupt", ["threadId": thread, "turnId": turn]).line)
            }
        }
    }

    private func codexLine(_ line: Data, _ p: AgentCLIProcess) {
        guard let m = CodexRPC.parse(line) else { return }
        switch m {
        case .response(let id, let result, let error):
            pending.removeValue(forKey: id)?(result, error)
        case .request(let id, let method, let params):
            onTrace?("cli request \(method)")
            p.write(CodexRPC.answer(id: id, method: method, params: params))
        case .notification(let method, let params):
            // Notifications of other threads (none expected) are ignored.
            if let t = params["threadId"] as? String, let mine = sessionID, t != mine { return }
            deliver(rpc.events(method, params))
        }
    }
}
