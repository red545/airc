// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Security
import CryptoKit

/// Which app is asking: the identity an approval is remembered under (docs/user/agents.md, "Asks once per app").
///
/// An MCP client (Claude Desktop, Claude Code…) starts Airc's `airc-mcp` helper, which connects to the socket. The
/// socket's peer is therefore the helper; the app is the helper's parent. Airc checks the peer by its audit token (no
/// recycled pid): when it is Airc's own helper (same team and identifier, or in a dev build the bundled file name), the
/// parent is the client, after skipping what only starts other programs: `sh -c`, env, npx, and Apple's own command
/// line tools (time, nice, xargs…), which never speak MCP themselves.
///
/// The client is then identified by what runs, never by the name it reports (the hello's `--client`, MCP's
/// clientInfo), which any program can claim; that name is only shown, as "calls itself ‘…’":
/// - a script (a shell script, `python3 agent.py`, `node cli.js`, osascript, an Electron app run as node): the script
///   file's path and SHA-256, whatever signed the interpreter (approving Claude Code on node approves no other script);
/// - an app or tool signed by a developer: its team and identifier (stable across its updates);
/// - an Apple app: its bundle identifier; an unsigned program: its path and code hash (cdhash, or SHA-256);
/// - over SSH: the computer it comes from. What Airc can't pin down (inline `python3 -c`, a helper whose parent is
///   gone, SSH from this Mac itself) is asked every time and never remembered.
///
/// The threat this blocks: any local program silently driving the person's signed-in accounts through Airc, including
/// by borrowing another app's approval (mcpfeedback, 2026-11-18: a plain script got in without a question). What it
/// can't block: code already running as the same user can tamper with an approved app (edit its config, inject into
/// it). Approval is consent, not authentication against such code.
struct AgentClientIdentity {
    enum Kind: String { case app, signed, apple, unsigned, script, ssh, airc, remote }
    /// What the answer is remembered under.
    let key: String
    /// "Claude", "Claude Code", "agent.py"…: the name in the prompt and in Settings.
    let displayName: String
    /// Who signed it, or its path: shown small under the name.
    let detail: String
    let kind: Kind
    /// The client process (not the helper), when known.
    let pid: pid_t?
    /// false: Airc can't tell this client from others, so it asks on every connection and keeps no answer.
    var remember = true

    /// Launchers between an app and the helper it starts.
    static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "login",
                                        "nohup", "npx", "npm", "pnpm", "pnpx", "bunx", "uvx", "uv", "caffeinate",
                                        "script", "arch", "xcrun", "exec", "timeout", "gtimeout", "stdbuf", "yarn"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]
    /// Package runners that are themselves scripts (`node …/npm-cli.js`): launchers too.
    static let launcherScripts: Set<String> = ["npm-cli.js", "npx-cli.js", "npm", "npx", "pnpm.cjs", "pnpm.js", "pnpx.cjs",
                                               "yarn.js", "yarn.cjs", "yarn", "pnpm", "corepack", "corepack.js", "uvx"]

    /// Interpreters: the script they run is the client. Matched lowercased, versions included (python3.12, perl5.34).
    static func isInterpreter(_ name: String) -> Bool {
        let n = name.lowercased()
        if ["node", "nodejs", "bun", "deno", "python", "pythonw", "ruby", "perl", "php", "lua", "luajit", "java", "osascript",
            "tclsh", "wish", "rscript", "julia", "swift", "swift-frontend", "pwsh", "qjs", "tsx", "ts-node", "elixir", "dotnet",
            "ruby3", "irb"].contains(n) { return true }
        return n.range(of: #"^(python|pypy|perl|ruby|php|lua|tclsh|node)[0-9][0-9.]*$"#, options: .regularExpression) != nil
    }

    static func resolve(session: AgentSession) -> AgentClientIdentity {
        let reported = session.client == "unknown" || session.client == "mcp-client" ? nil : session.client
        let calls = reported.map { " · calls itself ‘\($0)’" } ?? ""
        if let r = session.remote {
            // Another device of the tailnet (AgentRemote.swift): its own app, per device and per client it names. Airc
            // sees no process there; the pairing is the trust, and the name only separates its apps.
            let n = reported.map(prettyName) ?? "An app"
            return AgentClientIdentity(key: "remote:\(r.deviceID)|name:\(reported ?? "app")", displayName: "\(n) on \(r.deviceName)",
                                       detail: "Another device on your Tailscale network, paired as ‘\(r.deviceName)’ (\(r.address))",
                                       kind: .remote, pid: nil)
        }
        guard session.persistent else {
            // Test builds' loopback HTTP: no process to look at; its token is the proof.
            return AgentClientIdentity(key: "http|name:\(reported ?? "http")", displayName: reported ?? "HTTP client",
                                       detail: "Loopback HTTP with the launch token", kind: .unsigned, pid: nil)
        }
        let peer = session.peerToken.flatMap { code(token: $0) } ?? session.peerPID.flatMap { code(pid: $0) }
        var pid = session.peerPID
        if let p = pid, isAircHelper(pid: p, code: peer) { pid = parent(of: p) }
        // Shells (`sh -c`) and launchers between the app and the helper.
        var hops = 0
        while let p = pid, p > 1, hops < 16 {
            let exe = path(of: p) ?? ""
            let name = (exe as NSString).lastPathComponent
            if name.hasPrefix("sshd") { return ssh(helper: session.peerPID, sshd: p, reported: reported) }
            if p == getpid() { break }
            if shells.contains(name) {
                // A shell running a script file is that script; `sh -c …`, `sh -s` and a login shell only start things.
                if case .file = shellScript(pid: p) { break }
            } else if !wrappers.contains(name) {
                guard isLauncher(pid: p, exe: exe) else { break }
            }
            pid = parent(of: p)
            hops += 1
        }
        guard let client = pid, client > 1, let exe = path(of: client) else {
            return AgentClientIdentity(key: "unknown", displayName: reported.map { "‘\($0)’" } ?? "An unknown program",
                                       detail: "Airc couldn't see which program this is, so it asks every time\(calls)",
                                       kind: .unsigned, pid: nil, remember: false)
        }
        if client == getpid() {
            // Only Airc's own checks start the helper themselves.
            let n = reported ?? "Airc"
            return AgentClientIdentity(key: "airc|name:\(n)", displayName: n, detail: "Started by Airc itself", kind: .airc, pid: client)
        }
        return identify(pid: client, path: exe, reported: reported)
    }

    /// What MCP clients call themselves ("claude-code") as people know them (remote devices only: there the name is all
    /// Airc has).
    static func prettyName(_ reported: String) -> String {
        switch reported.lowercased() {
        case "claude-code", "claude code": return "Claude Code"
        case "claude-ai", "claude", "claude desktop": return "Claude"
        case "codex", "codex-mcp-client": return "Codex"
        case "cursor", "cursor-vscode": return "Cursor"
        default: return reported
        }
    }

    /// Something that only starts other programs: Apple's command line tools (time, nice, xargs, find…) and package
    /// runners run by an interpreter (`node npm-cli.js exec …`). Apple's interpreters and apps are not.
    static func isLauncher(pid: pid_t, exe: String) -> Bool {
        let name = (exe as NSString).lastPathComponent
        if isInterpreter(name) {
            if case .file(let f) = scriptArgument(pid: pid, exe: exe), launcherScripts.contains((f as NSString).lastPathComponent) { return true }
            return false
        }
        guard !exe.contains(".app/"), ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/"].contains(where: exe.hasPrefix),
              let c = code(pid: pid) else { return false }
        return signing(c).apple
    }

    // MARK: Scripts

    enum ScriptArg: Equatable { case file(String), inline, none }

    /// The script a shell runs: `bash agent.sh` / a `#!/bin/sh` file is `.file`; `sh -c …` is `.inline`; an
    /// interactive or stdin shell `.none`.
    static func shellScript(pid: pid_t) -> ScriptArg {
        let args = arguments(of: pid).dropFirst()
        for a in args {
            if a == "-c" || (a.hasPrefix("-") && !a.hasPrefix("--") && a.dropFirst().contains("c")) { return .inline }
            if a == "-s" || a == "--" { return .none }
            if a.hasPrefix("-") || a.hasPrefix("+") { continue }
            return resolveFile(a, pid: pid).map(ScriptArg.file) ?? .none
        }
        return .none
    }

    /// The script an interpreter runs (`python3 agent.py`, `node …/cli.js`, `osascript run.scpt`). Inline code
    /// (-c, -e, --eval, -m) is `.inline`: nothing on disk names it.
    static func scriptArgument(pid: pid_t, exe: String) -> ScriptArg {
        let inline: Set<String> = ["-c", "-e", "-E", "--eval", "-p", "--print", "-m", "-i", "--interactive", "repl", "eval", "-"]
        let valued: Set<String> = ["-W", "-X", "-r", "--require", "--import", "--loader", "--experimental-loader", "-I", "-l",
                                   "-C", "--env-file", "--conditions", "--title", "--cwd", "--config"]
        var skip = false
        var args = Array(arguments(of: pid).dropFirst())
        // `bun run x.ts`, `deno run x.ts`: the subcommand comes first.
        if let first = args.first, ["run", "x"].contains(first) { args.removeFirst() }
        for a in args {
            if skip { skip = false; continue }
            if inline.contains(a) { return .inline }
            if valued.contains(a) { skip = true; continue }
            if a.hasPrefix("-") { continue }
            return resolveFile(a, pid: pid).map(ScriptArg.file) ?? .inline
        }
        return .inline
    }

    /// An argument as an existing regular file (relative to the process's working folder), symlinks resolved.
    static func resolveFile(_ arg: String, pid: pid_t) -> String? {
        var p = arg
        if !p.hasPrefix("/") {
            guard let cwd = workingDirectory(of: pid) else { return nil }
            p = (cwd as NSString).appendingPathComponent(p)
        }
        let real = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return real
    }

    /// SHA-256 of a file (its first 64 MB plus its size), hex: what an approved script is remembered by.
    static func fileHash(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var total = 0
        while total < 64 << 20, let d = try? h.read(upToCount: 1 << 20), !d.isEmpty {
            hasher.update(data: d)
            total += d.count
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? total
        hasher.update(data: Data("\(size)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "agent.py", or a package's name for its entry file (`…/node_modules/@scope/tool/cli.js` → "@scope/tool").
    static func scriptName(_ path: String) -> String {
        let parts = path.components(separatedBy: "/node_modules/")
        if parts.count > 1, let last = parts.last {
            let c = last.split(separator: "/")
            if c.count >= 2 { return c[0].hasPrefix("@") ? "\(c[0])/\(c[1])" : String(c[0]) }
        }
        return (path as NSString).lastPathComponent
    }

    private static func scriptIdentity(_ file: String?, runner: String, pid: pid_t, reported: String?) -> AgentClientIdentity {
        let calls = reported.map { " · calls itself ‘\($0)’" } ?? ""
        guard let file, let hash = fileHash(file) else {
            return AgentClientIdentity(key: "inline:\(runner)", displayName: "Code run by \(runner)",
                                       detail: "Code typed into \(runner), not a file, so Airc asks every time\(calls)",
                                       kind: .script, pid: pid, remember: false)
        }
        return AgentClientIdentity(key: "script:\(file)|sha256:\(hash.prefix(32))", displayName: scriptName(file),
                                   detail: "A script run by \(runner) · \(file)\(calls)", kind: .script, pid: pid)
    }

    private static func identify(pid: pid_t, path exe: String, reported: String?) -> AgentClientIdentity {
        let exeName = (exe as NSString).lastPathComponent
        let calls = reported.map { " · calls itself ‘\($0)’" } ?? ""
        // Scripts first: whoever signed the interpreter, the script is what acts.
        if shells.contains(exeName), case .file(let f) = shellScript(pid: pid) {
            return scriptIdentity(f, runner: exeName, pid: pid, reported: reported)
        }
        if isInterpreter(exeName) {
            let s = scriptArgument(pid: pid, exe: exe)
            if case .file(let f) = s { return scriptIdentity(f, runner: exeName, pid: pid, reported: reported) }
            return scriptIdentity(nil, runner: exeName, pid: pid, reported: reported)
        }
        // An Electron app run as node runs any script with the app's signature.
        if exe.contains(".app/"), environment(of: pid)["ELECTRON_RUN_AS_NODE"].map({ !$0.isEmpty && $0 != "0" }) == true {
            let s = scriptArgument(pid: pid, exe: exe)
            if case .file(let f) = s { return scriptIdentity(f, runner: exeName, pid: pid, reported: reported) }
            return scriptIdentity(nil, runner: exeName, pid: pid, reported: reported)
        }
        let sig = code(pid: pid).map(signing) ?? Signing()
        // The outermost .app the program lives in (a helper inside Claude.app is Claude).
        var appURL: URL?
        if let r = exe.range(of: ".app/") { appURL = URL(fileURLWithPath: String(exe[..<r.lowerBound]) + ".app") }
        let bundle = appURL.flatMap(Bundle.init(url:))
        let appName = bundle.flatMap { ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? $0.object(forInfoDictionaryKey: "CFBundleName")) as? String }
            ?? appURL.map { $0.deletingPathExtension().lastPathComponent }
        let place = appURL?.path ?? exe
        if sig.valid, let team = sig.team {
            let id = bundle?.bundleIdentifier ?? sig.identifier ?? exeName
            let name: String = {
                if let appName { return appName }
                let lower = id.lowercased()
                if lower.contains("claude-code") || exe.contains("/claude/versions/") || exeName == "claude" { return "Claude Code" }
                if exeName == "codex" || lower.hasSuffix(".codex") { return "Codex" }
                return exeName
            }()
            return AgentClientIdentity(key: "team:\(team):\(id)", displayName: name,
                                       detail: "Signed by \(sig.signer ?? team) · \(place)\(calls)", kind: appURL == nil ? .signed : .app, pid: pid)
        }
        if sig.valid, sig.apple {
            let id = bundle?.bundleIdentifier ?? sig.identifier ?? exe
            return AgentClientIdentity(key: "apple:\(id)", displayName: appName ?? exeName,
                                       detail: "An Apple program · \(place)\(calls)", kind: .apple, pid: pid)
        }
        // Unsigned or ad hoc: its path and the hash of its code, so a changed or swapped program is asked again.
        let hash = sig.cdhash ?? fileHash(exe).map { String($0.prefix(40)) } ?? "nohash"
        return AgentClientIdentity(key: "exe:\(place)|code:\(hash)", displayName: appName ?? exeName,
                                   detail: "Not signed by a known developer · \(place)\(calls)", kind: .unsigned, pid: pid)
    }

    /// Over SSH: the computer it comes from (SSH_CONNECTION's first address, from the helper's environment). SSH from
    /// this Mac itself could be any local program, so it is asked every time.
    private static func ssh(helper: pid_t?, sshd: pid_t, reported: String?) -> AgentClientIdentity {
        let n = reported ?? "An app"
        let from = helper.flatMap { environment(of: $0)["SSH_CONNECTION"] }?.split(separator: " ").first.map(String.init)
        let loopback = from.map { $0 == "::1" || $0.hasPrefix("127.") || $0 == "::ffff:127.0.0.1" } ?? true
        return AgentClientIdentity(key: loopback ? "ssh" : "ssh:\(from!)", displayName: "\(n) (over SSH)",
                                   detail: loopback ? "Signed in to this Mac over SSH from this Mac, so Airc asks every time"
                                                    : "Another computer (\(from!)), signed in to this Mac as you over SSH",
                                   kind: .ssh, pid: sshd, remember: !loopback)
    }

    /// Keys from before mcpfeedback (2026-11-18) that could cover more than one program: forgotten, so those apps are
    /// asked again under their precise identity. Signed apps' keys ("team:…", not an interpreter) stay.
    static func isLegacyKey(_ key: String) -> Bool {
        for p in ["path:", "unknown|", "ssh|"] where key.hasPrefix(p) { return true }
        if key.hasPrefix("apple:"), key.contains("|") { return true }
        if key.hasPrefix("team:"), let id = key.split(separator: ":", maxSplits: 2).last {
            let last = id.split(separator: ".").last.map(String.init) ?? String(id)
            return isInterpreter(String(id)) || isInterpreter(last) || last.lowercased().hasPrefix("python")
                || last.lowercased() == "electron"
        }
        return false
    }

    // MARK: Airc's own helper

    /// The peer is Airc's helper when it carries Airc's team and the helper's identifier; a dev build (ad hoc, no
    /// team) settles for the helper's file name.
    static func isAircHelper(pid: pid_t, code: SecCode?) -> Bool {
        let name = (path(of: pid) as NSString?)?.lastPathComponent ?? ""
        guard name == "airc-mcp" || name == "AircMCP" else { return false }
        guard let mine = ownTeam else { return true }
        guard let code else { return false }
        let s = signing(code)
        // codesign names a bare tool after its file, plus its hash ("airc-mcp-55554944…") when nothing else names it.
        let id = s.identifier ?? ""
        return s.valid && s.team == mine && (id == "airc-mcp" || id.hasPrefix("airc-mcp-") || id.hasSuffix(".airc-mcp")
                                             || id == "AircMCP" || id.hasPrefix("AircMCP-"))
    }

    static let ownTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        let s = signing(me)
        return s.valid ? s.team : nil
    }()

    // MARK: Processes

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let p = pid_t(info.pbi_ppid)
        return p > 0 ? p : nil
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// A process's arguments (KERN_PROCARGS2), for an interpreter's script.
    static func arguments(of pid: pid_t) -> [String] { procArgs(pid).args }

    /// A process's environment (after its arguments in KERN_PROCARGS2).
    static func environment(of pid: pid_t) -> [String: String] {
        var env: [String: String] = [:]
        for e in procArgs(pid).env {
            guard let i = e.firstIndex(of: "=") else { continue }
            env[String(e[..<i])] = String(e[e.index(after: i)...])
        }
        return env
    }

    private static func procArgs(_ pid: pid_t) -> (args: [String], env: [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ([], []) }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }        // the executable path
        while i < size, buffer[i] == 0 { i += 1 }        // its padding
        func next() -> String {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buffer[start..<min(i, size)], as: UTF8.self)
        }
        var args: [String] = [], env: [String] = []
        while i < size, args.count < min(argc, 64) { args.append(next()) }
        while i < size, env.count < 512 {
            let e = next()
            if e.isEmpty { break }                       // the environment's end
            env.append(e)
        }
        return (args, env)
    }

    // MARK: Code signatures

    static func code(pid: pid_t) -> SecCode? {
        var c: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        return SecCodeCopyGuestWithAttributes(nil, attrs, [], &c) == errSecSuccess ? c : nil
    }

    static func code(token: audit_token_t) -> SecCode? {
        var t = token
        let data = Data(bytes: &t, count: MemoryLayout<audit_token_t>.size)
        var c: SecCode?
        let attrs = [kSecGuestAttributeAudit: data] as CFDictionary
        return SecCodeCopyGuestWithAttributes(nil, attrs, [], &c) == errSecSuccess ? c : nil
    }

    struct Signing {
        var valid = false
        var identifier: String?
        var team: String?
        var apple = false
        /// "Anthropic PBC (TEAMID)": the leaf certificate's name without "Developer ID Application: ".
        var signer: String?
        /// The code directory hash (hex): what the kernel checks the running code against, ad hoc signatures included.
        var cdhash: String?
    }

    static func signing(_ code: SecCode) -> Signing {
        var s = Signing()
        s.valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return s }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return s }
        s.identifier = d[kSecCodeInfoIdentifier as String] as? String
        if let u = d[kSecCodeInfoUnique as String] as? Data { s.cdhash = u.map { String(format: "%02x", $0) }.joined() }
        s.team = d[kSecCodeInfoTeamIdentifier as String] as? String
        if let leaf = (d[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            s.signer = summary.replacingOccurrences(of: "Developer ID Application: ", with: "")
        }
        var apple: SecRequirement?
        if s.valid, SecRequirementCreateWithString("anchor apple" as CFString, [], &apple) == errSecSuccess, let apple {
            s.apple = SecCodeCheckValidity(code, [], apple) == errSecSuccess
        }
        // An ad hoc signature names no team and proves nothing about who made it.
        if s.team == nil, !s.apple { s.valid = false }
        return s
    }
}
