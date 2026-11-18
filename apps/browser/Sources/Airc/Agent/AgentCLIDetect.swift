// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import AircKit

/// Finds the person's Claude Code and Codex and reads whether they're logged in (docs/design/agent-cli.md §3–4), for
/// Settings › AI › Agent and the panel. Only the CLIs' own reports are read (`--version`, `claude auth status --json`,
/// Codex app-server `account/read`): no credential file, no Keychain item, no model request.
final class AgentCLIDetector {
    static let shared = AgentCLIDetector()
    static let changed = Notification.Name("AircAgentCLIStatusChanged")

    private(set) var statuses: [AgentCLIKind: AgentCLIStatus] = [:]
    private var checkedAt: [AgentCLIKind: Date] = [:]
    private var waiting: [AgentCLIKind: [(AgentCLIStatus) -> Void]] = [:]
    private let queue = DispatchQueue(label: "airc.agent.cli.detect", qos: .userInitiated)
    private var shellPATH: String?
    /// Test builds: `--agent-cli-dir=<dir>` makes Airc look only there (the fake CLIs), never at a real install.
    private(set) var onlyDir: String?

    private init() {
        #if AIRC_TESTING
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--agent-cli-dir=") }) { onlyDir = String(a.dropFirst("--agent-cli-dir=".count)) }
        #endif
    }

    #if AIRC_TESTING
    /// Checks: switch the folder the fakes live in (a folder without them = "not installed").
    func setDirForTesting(_ dir: String?) {
        onlyDir = dir
        statuses = [:]
        checkedAt = [:]
    }
    #endif

    func status(_ kind: AgentCLIKind) -> AgentCLIStatus? { statuses[kind] }

    /// Re-reads a CLI's status unless it was read in the last `maxAge` seconds. `done` gets it on the main thread.
    func check(_ kind: AgentCLIKind, maxAge: TimeInterval = 30, _ done: ((AgentCLIStatus) -> Void)? = nil) {
        if let s = statuses[kind], s != .checking, let at = checkedAt[kind], Date().timeIntervalSince(at) < maxAge {
            done?(s)
            return
        }
        if let done { waiting[kind, default: []].append(done) }
        guard statuses[kind] != .checking else { return }
        statuses[kind] = .checking
        post()
        queue.async { [weak self] in
            guard let self else { return }
            let path = self.locate(kind)
            let finish: (AgentCLIStatus) -> Void = { s in
                DispatchQueue.main.async {
                    self.statuses[kind] = s
                    self.checkedAt[kind] = Date()
                    let w = self.waiting[kind] ?? []
                    self.waiting[kind] = nil
                    self.post()
                    w.forEach { $0(s) }
                }
            }
            guard let path else { return finish(.notInstalled) }
            switch kind {
            case .claudeCode: finish(self.probeClaude(path))
            case .codex:
                DispatchQueue.main.async { self.probeCodex(path, finish) }
            }
        }
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }

    // MARK: Finding

    /// The PATH a Terminal of this person gets (apps started from the Dock get /usr/bin:/bin:/usr/sbin:/sbin only, and
    /// an npm-installed `claude` needs `node` on the PATH).
    var searchPATH: String {
        if let p = shellPATH { return p }
        var p = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if onlyDir == nil, let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasSuffix("zsh") || shell.hasSuffix("bash") {
            let r = Self.run(shell, ["-l", "-c", "printf '%s' \"$PATH\""], env: ["HOME": NSHomeDirectory(), "TERM": "dumb"], timeout: 3)
            if r.code == 0, !r.out.isEmpty, !r.out.contains("\n") { p = r.out + ":" + p }
        }
        if let d = onlyDir { p = d + ":" + p }
        shellPATH = p
        return p
    }

    func locate(_ kind: AgentCLIKind) -> String? {
        let fm = FileManager.default
        if let d = onlyDir {
            let p = (d as NSString).appendingPathComponent(kind.binary)
            return fm.isExecutableFile(atPath: p) ? p : nil
        }
        for dir in searchPATH.split(separator: ":") where !dir.isEmpty {
            let p = (String(dir) as NSString).appendingPathComponent(kind.binary)
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return kind.candidates(home: NSHomeDirectory()).first { fm.isExecutableFile(atPath: $0) }
    }

    /// The environment a CLI runs with: Airc's own, minus API keys (the CLI uses the login the person made in it) and
    /// Airc's internals, with the person's PATH.
    func environment(for kind: AgentCLIKind, executable: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("AIRC_") || k.hasPrefix("DYLD_") || k == "ANTHROPIC_API_KEY" || k == "ANTHROPIC_AUTH_TOKEN"
            || k == "OPENAI_API_KEY" || k == "CLAUDECODE" || k == "CLAUDE_CODE_ENTRYPOINT" { env[k] = nil }
        let dir = (executable as NSString).deletingLastPathComponent
        env["PATH"] = dir + ":" + searchPATH
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        if kind == .claudeCode {
            // An approval card may wait up to 5 minutes inside a tool call.
            env["MCP_TOOL_TIMEOUT"] = "330000"
            env["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
            env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        }
        return env
    }

    // MARK: Probes

    private func probeClaude(_ path: String) -> AgentCLIStatus {
        let env = environment(for: .claudeCode, executable: path)
        let v = Self.run(path, ["--version"], env: env, timeout: 15)
        guard v.code == 0 else {
            return v.code == -2 ? .broken(path: path, message: "timed out") : .broken(path: path, message: AgentCLIProcess.lastLine(v.err + "\n" + v.out))
        }
        let version = AgentCLIKind.parseVersion(v.out)
        if let m = AgentCLIKind.major(version), m < 2 { return .tooOld(path: path, version: version) }
        let a = Self.run(path, ["auth", "status", "--json"], env: env, timeout: 15)
        guard let auth = AgentCLIAuth.claude(json: Data(a.out.utf8), exitCode: a.code) else {
            return a.err.lowercased().contains("unknown") ? .tooOld(path: path, version: version)
                : .broken(path: path, message: AgentCLIProcess.lastLine(a.err + "\n" + a.out))
        }
        return auth.loggedIn ? .ready(path: path, version: version, account: auth.label) : .notLoggedIn(path: path, version: version)
    }

    /// `codex --version`, then `codex app-server`: initialize, account/read, gone (no thread, no turn).
    private func probeCodex(_ path: String, _ done: @escaping (AgentCLIStatus) -> Void) {
        let env = environment(for: .codex, executable: path)
        queue.async {
            let v = Self.run(path, ["--version"], env: env, timeout: 15)
            let version = AgentCLIKind.parseVersion(v.out)
            DispatchQueue.main.async {
                guard v.code == 0 else { return done(.broken(path: path, message: v.code == -2 ? "timed out" : AgentCLIProcess.lastLine(v.err + "\n" + v.out))) }
                let work = AgentCLIRun.workFolder()
                let p: AgentCLIProcess
                do { p = try AgentCLIProcess(executable: path, args: ["app-server"], env: env, cwd: work.path) } catch {
                    return done(.broken(path: path, message: "\(error)"))
                }
                let rpc = CodexRPC()
                var answered = false
                let finish: (AgentCLIStatus) -> Void = { s in
                    guard !answered else { return }
                    answered = true
                    p.terminate(grace: 1)
                    done(s)
                }
                let initialize = rpc.request("initialize", CodexCLI.initialize(version: Self.appVersion))
                var accountID = -1
                p.onLine = { line in
                    guard case .response(let id, let result, let error)? = CodexRPC.parse(line) else { return }
                    if id == initialize.id {
                        if error != nil { return finish(.tooOld(path: path, version: version)) }
                        p.write(CodexRPC.notification("initialized"))
                        let r = rpc.request("account/read", ["refreshToken": false])
                        accountID = r.id
                        p.write(r.line)
                    } else if id == accountID {
                        guard let result else { return finish(.tooOld(path: path, version: version)) }
                        let a = AgentCLIAuth.codex(accountRead: result)
                        finish(a.loggedIn ? .ready(path: path, version: version, account: a.label) : .notLoggedIn(path: path, version: version))
                    }
                }
                p.onExit = { code, err in
                    finish(code == 0 ? .tooOld(path: path, version: version) : .broken(path: path, message: AgentCLIProcess.lastLine(err)))
                    p.onLine = nil
                    p.onExit = nil
                }
                p.write(initialize.line)
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish(.broken(path: path, message: "Codex didn't answer.")) }
            }
        }
    }

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// A short command: exit code (-2 on timeout), stdout, stderr. Off the main thread.
    static func run(_ exe: String, _ args: [String], env: [String: String], timeout: TimeInterval) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = AgentCLIRun.workFolder()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let group = DispatchGroup()
        var o = Data(), e = Data()
        group.enter()
        DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            kill(p.processIdentifier, SIGKILL)
            return (-2, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: e, as: UTF8.self))
    }
}
