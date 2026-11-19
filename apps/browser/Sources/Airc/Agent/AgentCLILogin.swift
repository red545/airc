// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// Installing and signing in to the person's own Claude Code and Codex from the agent pane (docs/design/agent-ux.md §8,
/// M4). Airc never runs an installer by itself, never uses sudo, and never sees a password or token: it shows the
/// install command from the CLI's own docs (Copy, or Terminal with a `.command` file that waits for Return), and starts
/// the CLI's own sign-in: `claude auth login` in Terminal; Codex's app-server `account/login/start` (its sign-in page in
/// a normal tab, the app-server listening for the callback on its own loopback port), else `codex login` in Terminal.
/// Terminal is opened with NSWorkspace (no Apple Events, so no Automation prompt).
enum AgentCLISetupFiles {
    /// Opens a file in Terminal; checks replace it to record the file instead (no Terminal launch in tests).
    static var openInTerminal: (URL) -> Void = { url in
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        if FileManager.default.fileExists(atPath: terminal.path) {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The last file written (checks read its content).
    private(set) static var lastFile: URL?

    /// A one-time 0700 `.command` file in a 0700 temporary folder.
    static func write(_ name: String, _ body: (String) -> String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-cli-setup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(name) - \(UUID().uuidString.prefix(8)).command")
        do {
            try Data(body(file.path).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return nil }
        lastFile = file
        return file
    }

    /// "Open Terminal with this command": the install command, run only after Return.
    @discardableResult
    static func openInstall(_ kind: AgentCLIKind) -> Bool {
        guard let f = write("Install \(kind.name)", { AgentCLIScript.install(kind, file: $0) }) else { return false }
        openInTerminal(f)
        AgentCenter.shared.onEvent?("cli-install-terminal \(kind.rawValue)")
        return true
    }

    @discardableResult
    static func openLogin(_ kind: AgentCLIKind, executable: String) -> Bool {
        guard let f = write("Sign in to \(kind.name)", { AgentCLIScript.login(kind, executable: executable, file: $0) }) else { return false }
        openInTerminal(f)
        AgentCenter.shared.onEvent?("cli-login-terminal \(kind.rawValue)")
        return true
    }
}

/// One sign-in in progress: started, then waits (polling the CLI's own status every 3 s for Claude Code; Codex's
/// `account/login/completed`) for up to 10 minutes. `onDone(true)` once the CLI reports ready.
final class AgentCLILogin {
    enum Route: Equatable { case terminal, browser(URL) }

    let kind: AgentCLIKind
    let executable: String
    private(set) var route: Route = .terminal
    private(set) var startedAt = Date()
    var onRoute: ((Route) -> Void)?
    var onDone: ((Bool, String?) -> Void)?
    private var process: AgentCLIProcess?
    private var loginID: String?
    private var poll: Timer?
    private var finished = false
    private let rpc = CodexRPC()
    static let timeout: TimeInterval = 600

    init(kind: AgentCLIKind, executable: String) {
        self.kind = kind
        self.executable = executable
    }

    func start() {
        startedAt = Date()
        switch kind {
        case .claudeCode:
            terminal()
        case .codex:
            startCodex()
        }
        // The CLI's own status, every 3 s (cheap for Claude Code; Codex mostly answers with its notification).
        let t = Timer(timeInterval: kind == .claudeCode ? 3 : 6, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func terminal() {
        route = .terminal
        onRoute?(.terminal)
        if !AgentCLISetupFiles.openLogin(kind, executable: executable) { finish(false, "Couldn't open Terminal.") }
    }

    private func tick() {
        guard !finished else { return }
        if Date().timeIntervalSince(startedAt) > Self.timeout { return finish(false, "Signing in took longer than 10 minutes.") }
        // While Codex's app-server waits for its callback, its own notification ends it.
        if kind == .codex, process != nil { return }
        AgentCLIDetector.shared.check(kind, maxAge: 0) { [weak self] s in
            if s.isReady { self?.finish(true, nil) }
        }
    }

    /// Codex: the app-server's own browser sign-in (`account/login/start`, type chatgpt), its page in a normal tab.
    private func startCodex() {
        let env = AgentCLIDetector.shared.environment(for: .codex, executable: executable)
        let p: AgentCLIProcess
        do { p = try AgentCLIProcess(executable: executable, args: ["app-server"], env: env, cwd: AgentCLIRun.workFolder().path) } catch {
            return terminal()
        }
        process = p
        let initialize = rpc.request("initialize", CodexCLI.initialize(version: AgentCLIDetector.appVersion))
        var startID = -1
        p.onLine = { [weak self] line in
            guard let self, !self.finished else { return }
            switch CodexRPC.parse(line) {
            case .response(let id, let result, let error)?:
                if id == initialize.id {
                    p.write(CodexRPC.notification("initialized"))
                    let r = self.rpc.request("account/login/start", ["type": "chatgpt"])
                    startID = r.id
                    p.write(r.line)
                } else if id == startID {
                    guard error == nil, let raw = result?["authUrl"] as? String, let url = URL(string: raw),
                          ["https", "http"].contains(url.scheme ?? "") else {
                        // No browser sign-in in this Codex: its CLI login in Terminal.
                        self.stopProcess()
                        return self.terminal()
                    }
                    self.loginID = result?["loginId"] as? String
                    self.route = .browser(url)
                    self.onRoute?(.browser(url))
                    AgentCenter.shared.onEvent?("cli-login-browser codex")
                }
            case .notification(let method, let params)?:
                guard method == "account/login/completed" else { return }
                if let mine = self.loginID, let id = params["loginId"] as? String, id != mine { return }
                let ok = params["success"] as? Bool == true
                self.stopProcess()
                guard ok else { return self.finish(false, (params["error"] as? String).map { "Codex didn't sign in: \($0)" } ?? "Codex didn't sign in.") }
                // Confirm with Codex's own account/read (the credential can land a moment after the notification).
                self.confirm(tries: 5)
            default:
                return
            }
        }
        p.onExit = { [weak self] _, _ in
            guard let self, self.process === p else { return }
            self.process = nil
        }
        p.write(initialize.line)
    }

    private func confirm(tries: Int) {
        AgentCLIDetector.shared.check(kind, maxAge: 0) { [weak self] s in
            guard let self, !self.finished else { return }
            if s.isReady { return self.finish(true, nil) }
            if tries <= 1 { return self.finish(false, "Codex still says it's signed out.") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.confirm(tries: tries - 1) }
        }
    }

    private func stopProcess() {
        guard let p = process else { return }
        process = nil
        p.onLine = nil
        p.terminate(grace: 1)
    }

    /// Cancel: Codex's pending login is cancelled and its app-server ends; a Terminal sign-in is the person's to close.
    func cancel() {
        guard !finished else { return }
        if let p = process, let id = loginID { p.write(rpc.request("account/login/cancel", ["loginId": id]).line) }
        finish(false, nil)
    }

    private func finish(_ ok: Bool, _ why: String?) {
        guard !finished else { return }
        finished = true
        poll?.invalidate()
        poll = nil
        stopProcess()
        AgentCenter.shared.onEvent?("cli-login-\(ok ? "done" : "ended") \(kind.rawValue)")
        onDone?(ok, why)
    }

    deinit { poll?.invalidate() }
}
