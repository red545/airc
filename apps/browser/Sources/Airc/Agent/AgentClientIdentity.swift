// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Security

/// Which app is asking: the identity an approval is remembered under (docs/user/agents.md, "Asks once per app").
///
/// An MCP client (Claude Desktop, Claude Code…) starts Airc's `airc-mcp` helper, which connects to the socket. The
/// socket's peer is therefore the helper; the app is the helper's parent. Airc checks the peer by its audit token (no
/// recycled pid): when it is Airc's own helper (same team and identifier, or in a dev build the bundled file name), the
/// parent is the client, after skipping shells and launchers (sh, zsh, env, npx…). The client is identified by its code
/// signature: a Developer ID app or tool by its team and identifier (stable across its updates); an Apple program
/// (python3, a shell tool) or an unsigned one by its path plus the name it reports, which is the weakest case.
///
/// The threat this blocks: any local program silently driving the person's signed-in accounts through Airc. A program
/// that connects directly (not through Airc's helper) is identified as itself, so it can't borrow another app's
/// approval. What it can't block: code already running as the same user can tamper with an approved app (edit its
/// config, inject into it). Approval is consent, not authentication against such code.
struct AgentClientIdentity {
    enum Kind: String { case app, signed, apple, unsigned, ssh, airc, remote }
    /// What the answer is remembered under.
    let key: String
    /// "Claude", "Claude Code", "Cursor"…: the name in the prompt and in Settings.
    let displayName: String
    /// Who signed it, or its path: shown small under the name.
    let detail: String
    let kind: Kind
    /// The client process (not the helper), when known.
    let pid: pid_t?

    /// Launchers between an app and the helper it starts.
    static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "login",
                                        "nohup", "npx", "npm", "pnpm", "pnpx", "bunx", "uvx", "uv", "caffeinate",
                                        "script", "arch", "xcrun", "exec", "timeout", "gtimeout", "stdbuf"]
    /// Interpreters: the script they run names the client (`node …/claude-code/cli.js`).
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl", "java"]

    static func resolve(session: AgentSession) -> AgentClientIdentity {
        let reported = session.client == "unknown" || session.client == "mcp-client" ? nil : session.client
        if let r = session.remote {
            // Another device of the tailnet (AgentRemote.swift): its own app, per device and per client it names.
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
        // Shells and launchers between the app and the helper.
        var hops = 0
        while let p = pid, p > 1, hops < 12 {
            let name = (path(of: p) as NSString?)?.lastPathComponent ?? ""
            if name.hasPrefix("sshd") {
                let n = reported ?? "An app"
                return AgentClientIdentity(key: "ssh|name:\(n)", displayName: "\(n) (over SSH)",
                                           detail: "Another computer, signed in to this Mac as you over SSH", kind: .ssh, pid: p)
            }
            guard wrappers.contains(name) else { break }
            pid = parent(of: p)
            hops += 1
        }
        guard let client = pid, client > 1, let exe = path(of: client) else {
            let n = reported ?? "An unknown app"
            return AgentClientIdentity(key: "unknown|name:\(n)", displayName: n, detail: "Airc couldn't see which program this is",
                                       kind: .unsigned, pid: nil)
        }
        if client == getpid() {
            let n = reported ?? "Airc"
            return AgentClientIdentity(key: "airc|name:\(n)", displayName: n, detail: "Started by Airc itself", kind: .airc, pid: client)
        }
        return identify(pid: client, path: exe, reported: reported)
    }

    /// What MCP clients call themselves ("claude-code") as people know them.
    static func prettyName(_ reported: String) -> String {
        switch reported.lowercased() {
        case "claude-code", "claude code": return "Claude Code"
        case "claude-ai", "claude", "claude desktop": return "Claude"
        case "codex", "codex-mcp-client": return "Codex"
        case "cursor", "cursor-vscode": return "Cursor"
        default: return reported
        }
    }

    private static func identify(pid: pid_t, path exe: String, reported: String?) -> AgentClientIdentity {
        let sig = code(pid: pid).map(signing) ?? Signing()
        let exeName = (exe as NSString).lastPathComponent
        // The outermost .app the program lives in (a helper inside Claude.app is Claude).
        var appURL: URL?
        if let r = exe.range(of: ".app/") { appURL = URL(fileURLWithPath: String(exe[..<r.lowerBound]) + ".app") }
        let bundle = appURL.flatMap(Bundle.init(url:))
        let appName = bundle.flatMap { ($0.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? $0.object(forInfoDictionaryKey: "CFBundleName")) as? String }
            ?? appURL.map { $0.deletingPathExtension().lastPathComponent }
        var script: String?
        if interpreters.contains(exeName) { script = arguments(of: pid).dropFirst().first { !$0.hasPrefix("-") } }
        let name: String = {
            if let appName { return appName }
            let id = sig.identifier?.lowercased() ?? ""
            if id.contains("claude-code") || exe.contains("/claude/versions/") || exeName == "claude" { return "Claude Code" }
            if exeName == "codex" || id.hasSuffix(".codex") { return "Codex" }
            if let script {
                let s = script.lowercased()
                if s.contains("claude-code") || s.hasSuffix("/claude") { return "Claude Code" }
                return reported ?? (script as NSString).lastPathComponent
            }
            if sig.apple { return reported ?? exeName }
            return reported ?? exeName
        }()
        let place = appURL?.path ?? exe
        if sig.valid, let team = sig.team {
            let id = bundle?.bundleIdentifier ?? sig.identifier ?? exeName
            return AgentClientIdentity(key: "team:\(team):\(id)", displayName: name,
                                       detail: "Signed by \(sig.signer ?? team) · \(place)", kind: appURL == nil ? .signed : .app, pid: pid)
        }
        let named = reported.map { "|name:\($0)" } ?? ""
        let scripted = script.map { "|script:\($0)" } ?? ""
        if sig.valid, sig.apple {
            return AgentClientIdentity(key: "apple:\(sig.identifier ?? exe)\(scripted)\(named)", displayName: name,
                                       detail: "An Apple program, \(exe)\(reported.map { ", calling itself ‘\($0)’" } ?? "")", kind: .apple, pid: pid)
        }
        return AgentClientIdentity(key: "path:\(place)\(scripted)\(named)", displayName: name,
                                   detail: "Not signed by a known developer · \(script ?? place)", kind: .unsigned, pid: pid)
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

    /// A process's arguments (KERN_PROCARGS2), for an interpreter's script.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }        // the executable path
        while i < size, buffer[i] == 0 { i += 1 }        // its padding
        var args: [String] = []
        while i < size, args.count < min(argc, 8) {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
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
