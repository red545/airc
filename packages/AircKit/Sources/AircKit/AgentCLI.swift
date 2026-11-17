// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// The Airc Agent on the person's own Claude Code or Codex CLI (docs/design/agent-cli.md): which CLI, how to find it and
// read its status, the command lines and MCP config Airc gives it, and the two wire protocols (Claude Code's
// stream-json, Codex's app-server JSON-RPC) turned into the same events for the panel. No processes or I/O here.

/// Which agent loop the Airc Agent uses (Settings › AI › Agent › Use).
public enum AgentBackend: String, Codable, Sendable, CaseIterable {
    case apiKey = "api-key"
    case claudeCode = "claude-code"
    case codex

    public var name: String {
        switch self {
        case .apiKey: return "Your API key"
        case .claudeCode: return "Your Claude Code"
        case .codex: return "Your Codex"
        }
    }
    public var cli: AgentCLIKind? {
        switch self {
        case .apiKey: return nil
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        }
    }
}

public enum AgentCLIKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex

    public var name: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var binary: String { self == .claudeCode ? "claude" : "codex" }
    /// How the run's session is named in the Agents folder, Watch and Activity.
    public var clientName: String { "\(name) (in Airc)" }
    /// The helper's `--client` (Activity's key for it).
    public var clientID: String { self == .claudeCode ? "claude-code-airc" : "codex-airc" }
    /// Where the vendor's model provider is, for Settings' "your task goes to …" line.
    public var vendor: String { self == .claudeCode ? "Anthropic" : "OpenAI" }

    /// Places installers put the CLI, after the login shell's PATH (which the app searches first).
    public func candidates(home: String) -> [String] {
        let h = (home as NSString)
        var dirs = [h.appendingPathComponent(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                    h.appendingPathComponent(".npm-global/bin"), h.appendingPathComponent(".volta/bin"),
                    h.appendingPathComponent(".bun/bin"), h.appendingPathComponent("bin")]
        if self == .claudeCode { dirs.insert(h.appendingPathComponent(".claude/local"), at: 1) }
        var out = dirs.map { ($0 as NSString).appendingPathComponent(binary) }
        if self == .codex { out.append("/Applications/Codex.app/Contents/Resources/codex") }
        return out
    }

    public var installHint: String {
        self == .claudeCode
            ? "Install Claude Code (claude.com/claude-code), e.g. `npm install -g @anthropic-ai/claude-code`, then run `claude` once in Terminal."
            : "Install Codex (developers.openai.com/codex), e.g. `npm install -g @openai/codex` or `brew install codex`, then run `codex` once in Terminal."
    }
    public var loginHint: String {
        self == .claudeCode
            ? "Not logged in: run `claude` in Terminal and log in (/login), then come back."
            : "Not logged in: run `codex` in Terminal and sign in (Sign in with ChatGPT), then come back."
    }
    public var updateHint: String {
        self == .claudeCode ? "Too old for Airc: run `claude update` in Terminal." : "Too old for Airc: update Codex (`npm install -g @openai/codex@latest` or `brew upgrade codex`)."
    }

    /// "2.1.322 (Claude Code)" → "2.1.322"; "codex-cli 0.165.0" → "0.165.0".
    public static func parseVersion(_ output: String) -> String? {
        for token in output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "(" || $0 == ")" }) {
            var t = Substring(token)
            if t.first == "v" { t = t.dropFirst() }
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }),
                  Int(parts[0]) != nil, Int(parts[1]) != nil else { continue }
            return String(t)
        }
        return nil
    }

    /// The major version, for "too old" (Claude Code before 2 has no `auth status`).
    public static func major(_ version: String?) -> Int? { version.flatMap { Int($0.split(separator: ".").first ?? "") } }
}

/// What Settings and the panel show about a CLI.
public enum AgentCLIStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case notLoggedIn(path: String, version: String?)
    case tooOld(path: String, version: String?)
    case broken(path: String, message: String)
    case ready(path: String, version: String?, account: String?)

    public var isReady: Bool { if case .ready = self { return true }; return false }
    public var path: String? {
        switch self {
        case .checking, .notInstalled: return nil
        case .notLoggedIn(let p, _), .tooOld(let p, _), .broken(let p, _), .ready(let p, _, _): return p
        }
    }

    /// "Claude Code 2.1.322, logged in (Max)" / "Claude Code: not installed".
    public func summary(_ kind: AgentCLIKind) -> String {
        func name(_ v: String?) -> String { v.map { "\(kind.name) \($0)" } ?? kind.name }
        switch self {
        case .checking: return "\(kind.name): checking…"
        case .notInstalled: return "\(kind.name): not installed"
        case .notLoggedIn(_, let v): return "\(name(v)), not logged in"
        case .tooOld(_, let v): return "\(name(v)), too old"
        case .broken(_, let m): return "\(kind.name) didn't start: \(m)"
        case .ready(_, let v, let a): return "\(name(v)), logged in" + (a.map { " (\($0))" } ?? "")
        }
    }

    /// What the person can do about it, or nil when it's ready.
    public func fix(_ kind: AgentCLIKind) -> String? {
        switch self {
        case .checking, .ready: return nil
        case .notInstalled: return kind.installHint
        case .notLoggedIn: return kind.loginHint
        case .tooOld: return kind.updateHint
        case .broken: return "Run `\(kind.binary)` in Terminal to see what's wrong."
        }
    }
}

/// Reading the CLIs' own account reports. Only "logged in or not", the method and the plan's name: never the email.
public enum AgentCLIAuth {
    /// `claude auth status --json`: `{"loggedIn": bool, "authMethod": "claude.ai" | "api-key" | "none" …,
    /// "apiProvider": "firstParty" | "bedrock" …, "subscriptionType"?}`; exit 1 when logged out.
    public static func claude(json: Data, exitCode: Int32) -> (loggedIn: Bool, label: String?)? {
        guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let provider = o["apiProvider"] as? String
        if let p = provider, p != "firstParty", !p.isEmpty {
            return (true, p.lowercased().contains("bedrock") ? "Amazon Bedrock" : p.lowercased().contains("vertex") ? "Google Vertex" : p)
        }
        guard let loggedIn = o["loggedIn"] as? Bool else { return exitCode == 0 ? (true, nil) : (false, nil) }
        guard loggedIn else { return (false, nil) }
        if let s = o["subscriptionType"] as? String, !s.isEmpty { return (true, planName(s)) }
        let method = (o["authMethod"] as? String ?? "").lowercased()
        if method.contains("key") { return (true, "API key") }
        return (true, nil)
    }

    /// Codex app-server `account/read`: `{"account": {"type":"chatgpt","planType":…} | {"type":"apiKey"} | null,
    /// "requiresOpenaiAuth": bool}`.
    public static func codex(accountRead r: [String: Any]) -> (loggedIn: Bool, label: String?) {
        guard let a = r["account"] as? [String: Any] else {
            return ((r["requiresOpenaiAuth"] as? Bool) == false, nil)
        }
        switch a["type"] as? String {
        case "chatgpt": return (true, (a["planType"] as? String).map { "ChatGPT " + planName($0) } ?? "ChatGPT")
        case "apiKey": return (true, "API key")
        case "amazonBedrock": return (true, "Amazon Bedrock")
        case "gcp": return (true, "Google Vertex")
        default: return (true, nil)
        }
    }

    static func planName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// Text in a failed turn that means the CLI isn't logged in (or its login expired).
    public static func looksLikeLogin(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["/login", "not logged in", "invalid api key", "authentication_error", "please log in", "please login",
                "oauth token has expired", "unauthorized", "codex login", "not signed in"].contains { t.contains($0) }
    }
}

/// One thing that happened in a CLI turn, for the panel.
public enum AgentCLIEvent: Equatable {
    /// The session is up (Claude Code's `system/init`, Codex's thread).
    case started(session: String?, model: String?)
    /// More of the agent's visible answer (live line).
    case text(String)
    /// A finished piece of the agent's answer that was followed by more work (a "say" step).
    case say(String)
    /// The CLI calls one of Airc's tools (the step itself shows when the call reaches Airc's gate).
    case tool(name: String)
    /// The CLI tried a tool that isn't Airc's (shell, files, web…): Airc stops the turn.
    case foreignTool(String)
    /// Airc's MCP server didn't start in the CLI.
    case toolsUnavailable(String)
    case usage(AgentUsage, cost: Double?)
    case turnEnded(AgentCLITurnEnd)
}

public struct AgentCLITurnEnd: Equatable {
    public enum Outcome: Equatable { case completed, interrupted, maxTurns, loginNeeded, failed(String) }
    public var outcome: Outcome
    /// The final answer (the last text of the turn).
    public var text: String
    public init(_ outcome: Outcome, text: String = "") { self.outcome = outcome; self.text = text }
}

/// The helper as both CLIs start it: Airc's bundled `airc-mcp`, on the run's own socket, with the run's token.
public struct AgentCLIMCPServer: Equatable {
    public var helper: String
    public var socket: String
    public var client: String
    public var token: String
    public init(helper: String, socket: String, client: String, token: String) {
        self.helper = helper; self.socket = socket; self.client = client; self.token = token
    }
    public var args: [String] { ["--socket", socket, "--client", client] }
    public var env: [String: String] { ["AIRC_MCP_TOKEN": token] }
    /// The MCP server's name in both CLIs: tools are `mcp__airc__<tool>` in Claude Code, server "airc" in Codex.
    public static let name = "airc"
}

// MARK: - Claude Code (stream-json)

public enum ClaudeCLI {
    /// Built-in tools named again as disallowed, in case a future Claude Code ignores `--tools ""`.
    public static let disallowed = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Glob", "Grep",
                                    "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite", "Skill", "SlashCommand"]

    /// `claude -p` for one conversation (docs/design/agent-cli.md §3).
    public static func arguments(mcpConfig: String, system: String, maxTurns: Int, resume: String?, model: String? = nil) -> [String] {
        var a = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                 "--mcp-config", mcpConfig, "--strict-mcp-config",
                 "--tools", "",
                 "--allowedTools", "mcp__\(AgentCLIMCPServer.name)",
                 "--disallowedTools", disallowed.joined(separator: ","),
                 "--permission-mode", "dontAsk",
                 "--disable-slash-commands",
                 "--append-system-prompt", system,
                 "--max-turns", String(maxTurns)]
        if let resume, !resume.isEmpty { a += ["--resume", resume] }
        if let model, !model.isEmpty { a += ["--model", model] }
        return a
    }

    /// The `--mcp-config` file: only Airc's server.
    public static func mcpConfig(_ s: AgentCLIMCPServer) -> Data {
        let o: [String: Any] = ["mcpServers": [AgentCLIMCPServer.name: ["type": "stdio", "command": s.helper, "args": s.args, "env": s.env]]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    public static func userMessage(_ text: String, session: String?) -> Data {
        var o: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]],
                                "parent_tool_use_id": NSNull()]
        o["session_id"] = session ?? ""
        return line(o)
    }

    public static func interrupt(id: String) -> Data {
        line(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    /// A `control_request` the CLI sends us (only with a permission-prompt host, which Airc doesn't set): denied.
    public static func denyControl(_ o: [String: Any]) -> Data? {
        guard o["type"] as? String == "control_request", let id = o["request_id"] as? String else { return nil }
        let sub = (o["request"] as? [String: Any])?["subtype"] as? String
        if sub == "can_use_tool" {
            return line(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                                                                  "response": ["behavior": "deny", "message": "Airc allows only its own browser tools."]]])
        }
        return line(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Not supported by Airc."]])
    }

    static func line(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    /// Airc's tool name from Claude Code's (`mcp__airc__read_page` → `read_page`); nil for anything else.
    public static func aircTool(_ name: String) -> String? {
        let p = "mcp__\(AgentCLIMCPServer.name)__"
        return name.hasPrefix(p) ? String(name.dropFirst(p.count)) : nil
    }
}

/// Claude Code's stream-json output, one line at a time.
public final class ClaudeStreamParser {
    public private(set) var sessionID: String?
    public private(set) var model: String?
    /// The turn's latest finished text, held until we know whether more follows (then it's a "say" step) or the turn
    /// ends (then it's the answer).
    private var held: String?
    /// The line asked for: control answers to write back (denials), in order.
    public private(set) var replies: [Data] = []

    public init() {}

    public func takeReplies() -> [Data] { defer { replies = [] }; return replies }

    public func feed(_ line: Data) -> [AgentCLIEvent] {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = o["type"] as? String else { return [] }
        if let s = o["session_id"] as? String, !s.isEmpty { sessionID = s }
        var out: [AgentCLIEvent] = []
        func flushHeld() { if let h = held { held = nil; if !h.isEmpty { out.append(.say(h)) } } }
        switch type {
        case "system":
            guard o["subtype"] as? String == "init" else { break }
            model = o["model"] as? String
            out.append(.started(session: sessionID, model: model))
            if let servers = o["mcp_servers"] as? [[String: Any]] {
                let airc = servers.first { $0["name"] as? String == AgentCLIMCPServer.name }
                let status = airc?["status"] as? String ?? "missing"
                if status != "connected" && status != "pending" { out.append(.toolsUnavailable(status)) }
            }
        case "stream_event":
            guard let e = o["event"] as? [String: Any] else { break }
            if e["type"] as? String == "content_block_delta", let d = e["delta"] as? [String: Any],
               d["type"] as? String == "text_delta", let t = d["text"] as? String, !t.isEmpty {
                flushHeld()
                out.append(.text(t))
            }
        case "assistant":
            guard let m = o["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { break }
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    flushHeld()
                    held = t
                case "tool_use":
                    flushHeld()
                    let name = block["name"] as? String ?? ""
                    if let tool = ClaudeCLI.aircTool(name) { out.append(.tool(name: tool)) } else { out.append(.foreignTool(name)) }
                default: continue
                }
            }
        case "control_request":
            if let r = ClaudeCLI.denyControl(o) { replies.append(r) }
        case "result":
            let subtype = o["subtype"] as? String ?? ""
            let isError = o["is_error"] as? Bool ?? false
            let resultText = (o["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = o["usage"] as? [String: Any] {
                out.append(.usage(AgentUsage(input: cliInt(u["input_tokens"]), output: cliInt(u["output_tokens"]),
                                             cacheRead: cliInt(u["cache_read_input_tokens"]), cacheWrite: cliInt(u["cache_creation_input_tokens"])),
                                  cost: (o["total_cost_usd"] as? NSNumber)?.doubleValue))
            }
            let final = held ?? resultText
            held = nil
            let errors = (o["errors"] as? [String] ?? []).joined(separator: " ")
            let outcome: AgentCLITurnEnd.Outcome
            if subtype == "error_max_turns" {
                outcome = .maxTurns
            } else if subtype == "success" && !isError {
                outcome = .completed
            } else if AgentCLIAuth.looksLikeLogin(resultText + " " + errors) {
                outcome = .loginNeeded
            } else if subtype == "error_during_execution" && resultText.isEmpty && errors.isEmpty {
                outcome = .interrupted
            } else {
                let why = [resultText, errors].first { !$0.isEmpty } ?? subtype
                outcome = .failed(String(why.prefix(300)))
            }
            out.append(.turnEnded(AgentCLITurnEnd(outcome, text: outcome == .completed ? final : "")))
        default:
            break
        }
        return out
    }
}

func cliInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

// MARK: - Codex (app-server JSON-RPC)

public enum CodexCLI {
    /// `codex app-server` with the tools Airc doesn't want off (docs/design/agent-cli.md §4).
    public static let arguments = ["app-server", "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "apps",
                                   "--disable", "plugins", "--disable", "multi_agent", "--disable", "image_generation",
                                   "-c", "web_search=\"disabled\""]

    /// Item types that mean Codex is doing something other than calling Airc's tools.
    public static let foreignItems: Set<String> = ["commandExecution", "fileChange", "webSearch", "dynamicToolCall",
                                                   "collabAgentToolCall", "imageGeneration", "subAgentActivity"]

    public static func initialize(version: String) -> [String: Any] {
        ["clientInfo": ["name": "airc", "title": "Airc", "version": version]]
    }

    /// `thread/start`: read-only, never asks, Airc's rules as developer instructions, only Airc's MCP server (the
    /// person's own servers are switched off for this thread).
    public static func threadStart(cwd: String, instructions: String, server s: AgentCLIMCPServer, disable: [String], model: String? = nil) -> [String: Any] {
        var servers: [String: Any] = [AgentCLIMCPServer.name: ["command": s.helper, "args": s.args, "env": s.env, "enabled": true,
                                                                        // An approval card may wait up to 5 minutes inside a call.
                                                                        "tool_timeout_sec": 330, "startup_timeout_sec": 20]]
        for name in disable where name != AgentCLIMCPServer.name { servers[name] = ["enabled": false] }
        var p: [String: Any] = ["cwd": cwd, "approvalPolicy": "never", "sandbox": "read-only",
                                "developerInstructions": instructions, "config": ["mcp_servers": servers]]
        if let model, !model.isEmpty { p["model"] = model }
        return p
    }

    /// `thread/resume` after Stop or a crash: the same thread, the same overrides.
    public static func threadResume(thread: String, cwd: String, instructions: String, server s: AgentCLIMCPServer, disable: [String]) -> [String: Any] {
        var p = threadStart(cwd: cwd, instructions: instructions, server: s, disable: disable)
        p["threadId"] = thread
        p["excludeTurns"] = true
        return p
    }

    public static func turnStart(thread: String, text: String) -> [String: Any] {
        ["threadId": thread, "input": [["type": "text", "text": text]]]
    }

    /// The names of the person's MCP servers in a `config/read` result.
    public static func mcpServerNames(configRead r: [String: Any]) -> [String] {
        let config = r["config"] as? [String: Any] ?? r
        return ((config["mcp_servers"] as? [String: Any]) ?? [:]).keys.sorted()
    }
}

/// Codex's JSON-RPC lines: our requests (numbered), its answers, notifications and its own requests (which Airc
/// answers: approvals declined, Airc's own elicitations accepted).
public final class CodexRPC {
    public enum Incoming {
        case response(id: Int, result: [String: Any]?, error: String?)
        case notification(method: String, params: [String: Any])
        case request(id: Any, method: String, params: [String: Any])
    }

    private var nextID = 1
    public private(set) var threadID: String?
    public private(set) var turnID: String?
    /// The latest agent message of the turn, held until more follows (a "say" step) or the turn ends (the answer).
    private var held: String?
    /// Agent message items whose text already streamed (not shown twice).
    private var streamed: Set<String> = []
    private var lastTotal = AgentUsage()
    private var lastError: String?

    public init() {}

    public func setThread(_ id: String?) { threadID = id }

    public func request(_ method: String, _ params: [String: Any]) -> (id: Int, line: Data) {
        let id = nextID
        nextID += 1
        return (id, Self.line(["id": id, "method": method, "params": params]))
    }

    public static func notification(_ method: String, _ params: [String: Any]? = nil) -> Data {
        var o: [String: Any] = ["method": method]
        if let params { o["params"] = params }
        return line(o)
    }

    public static func parse(_ line: Data) -> Incoming? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        let params = o["params"] as? [String: Any] ?? [:]
        if let method = o["method"] as? String {
            if let id = o["id"], !(id is NSNull) { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        guard let id = (o["id"] as? NSNumber)?.intValue else { return nil }
        if let e = o["error"] as? [String: Any] { return .response(id: id, result: nil, error: e["message"] as? String ?? "error") }
        return .response(id: id, result: o["result"] as? [String: Any] ?? [:], error: nil)
    }

    /// The answer to one of Codex's own requests.
    public static func answer(id: Any, method: String, params: [String: Any]) -> Data {
        func result(_ r: [String: Any]) -> Data { line(["id": id, "result": r]) }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return result(["decision": "decline"])
        case "execCommandApproval", "applyPatchApproval":
            return result(["decision": "denied"])
        case "mcpServer/elicitation/request":
            // Airc's own tools ask Airc's card; anyone else's server is declined.
            return result(["action": params["serverName"] as? String == AgentCLIMCPServer.name ? "accept" : "decline"])
        default:
            return line(["id": id, "error": ["code": -32601, "message": "Airc doesn't support \(method)."]])
        }
    }

    /// One notification → panel events.
    public func events(_ method: String, _ params: [String: Any]) -> [AgentCLIEvent] {
        var out: [AgentCLIEvent] = []
        func flushHeld() { if let h = held { held = nil; if !h.isEmpty { out.append(.say(h)) } } }
        switch method {
        case "thread/started":
            if let t = params["thread"] as? [String: Any], let id = t["id"] as? String { threadID = id }
            out.append(.started(session: threadID, model: (params["thread"] as? [String: Any])?["model"] as? String))
        case "turn/started":
            if let t = params["turn"] as? [String: Any], let id = t["id"] as? String { turnID = id }
            lastError = nil
        case "item/agentMessage/delta":
            if let d = params["delta"] as? String, !d.isEmpty {
                flushHeld()
                if let item = params["itemId"] as? String { streamed.insert(item) }
                out.append(.text(d))
            }
        case "item/started":
            guard let item = params["item"] as? [String: Any], let type = item["type"] as? String else { break }
            if type == "mcpToolCall" {
                flushHeld()
                let server = item["server"] as? String ?? ""
                let tool = item["tool"] as? String ?? ""
                out.append(server == AgentCLIMCPServer.name ? .tool(name: tool) : .foreignTool("\(server).\(tool)"))
            } else if CodexCLI.foreignItems.contains(type) {
                flushHeld()
                out.append(.foreignTool(type))
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage" else { break }
            let t = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { flushHeld(); held = t }
        case "thread/tokenUsage/updated":
            guard let u = params["tokenUsage"] as? [String: Any], let total = u["total"] as? [String: Any] else { break }
            let cached = cliInt(total["cachedInputTokens"])
            let now = AgentUsage(input: max(0, cliInt(total["inputTokens"]) - cached), output: cliInt(total["outputTokens"]), cacheRead: cached)
            let delta = AgentUsage(input: now.input - lastTotal.input, output: now.output - lastTotal.output,
                                   cacheRead: now.cacheRead - lastTotal.cacheRead)
            lastTotal = now
            if delta.total > 0 { out.append(.usage(delta, cost: nil)) }
        case "error":
            if params["willRetry"] as? Bool == true { break }
            lastError = ((params["error"] as? [String: Any])?["message"] as? String).map { String($0.prefix(300)) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "completed"
            let message = ((turn["error"] as? [String: Any])?["message"] as? String) ?? lastError
            let final = held ?? ""
            held = nil
            streamed = []
            turnID = nil
            lastError = nil
            switch status {
            case "completed": out.append(.turnEnded(AgentCLITurnEnd(.completed, text: final)))
            case "interrupted": out.append(.turnEnded(AgentCLITurnEnd(.interrupted)))
            default:
                let m = message ?? "The turn failed."
                out.append(.turnEnded(AgentCLITurnEnd(AgentCLIAuth.looksLikeLogin(m) ? .loginNeeded : .failed(m))))
            }
        default:
            break
        }
        return out
    }

    static func line(_ o: [String: Any]) -> Data {
        var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }
}
