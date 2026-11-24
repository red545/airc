// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class AgentCLITests: XCTestCase {
    private func j(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    private func obj(_ d: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: d) as! [String: Any] }
    private let server = AgentCLIMCPServer(helper: "/A/airc-mcp", socket: "/T/run.sock", client: "claude-code-airc", token: "t0k")

    // MARK: Finding and status

    func testVersions() {
        XCTAssertEqual(AgentCLIKind.parseVersion("2.1.322 (Claude Code)\n"), "2.1.322")
        XCTAssertEqual(AgentCLIKind.parseVersion("codex-cli 0.165.0"), "0.165.0")
        XCTAssertEqual(AgentCLIKind.parseVersion("claude v1.0.44"), "1.0.44")
        XCTAssertNil(AgentCLIKind.parseVersion("command not found"))
        XCTAssertEqual(AgentCLIKind.major("2.1.322"), 2)
    }

    func testCandidates() {
        let c = AgentCLIKind.claudeCode.candidates(home: "/H")
        XCTAssertEqual(c.first, "/H/.local/bin/claude")
        XCTAssertTrue(c.contains("/H/.claude/local/claude"))
        XCTAssertTrue(c.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(AgentCLIKind.codex.candidates(home: "/H").contains("/Applications/Codex.app/Contents/Resources/codex"))
    }

    func testClaudeAuthStatus() {
        // The shape `claude auth status --json` prints when logged out (exit 1).
        let out = j(["loggedIn": false, "authMethod": "none", "apiProvider": "firstParty", "loginExpiresAt": NSNull()])
        XCTAssertEqual(AgentCLIAuth.claude(json: out, exitCode: 1)?.loggedIn, false)
        let max = j(["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max", "email": "p@example.com"])
        let r = AgentCLIAuth.claude(json: max, exitCode: 0)
        XCTAssertEqual(r?.loggedIn, true)
        XCTAssertEqual(r?.label, "Max")
        XCTAssertFalse((r?.label ?? "").contains("example.com"), "never the email")
        XCTAssertEqual(AgentCLIAuth.claude(json: j(["loggedIn": true, "authMethod": "api-key"]), exitCode: 0)?.label, "API key")
        XCTAssertEqual(AgentCLIAuth.claude(json: j(["loggedIn": false, "apiProvider": "bedrock"]), exitCode: 0)?.loggedIn, true)
        XCTAssertNil(AgentCLIAuth.claude(json: Data("error: unknown command".utf8), exitCode: 1))
    }

    func testCodexAccount() {
        XCTAssertEqual(AgentCLIAuth.codex(accountRead: ["account": NSNull(), "requiresOpenaiAuth": true]).loggedIn, false)
        let plus = AgentCLIAuth.codex(accountRead: ["account": ["type": "chatgpt", "email": "p@example.com", "planType": "plus"], "requiresOpenaiAuth": true])
        XCTAssertEqual(plus.loggedIn, true)
        XCTAssertEqual(plus.label, "ChatGPT Plus")
        XCTAssertEqual(AgentCLIAuth.codex(accountRead: ["account": ["type": "apiKey"], "requiresOpenaiAuth": true]).label, "API key")
        // A custom provider that needs no OpenAI login.
        XCTAssertEqual(AgentCLIAuth.codex(accountRead: ["account": NSNull(), "requiresOpenaiAuth": false]).loggedIn, true)
    }

    func testStatusLines() {
        XCTAssertEqual(AgentCLIStatus.ready(path: "/x", version: "2.1.3", account: "Max").summary(.claudeCode), "Claude Code 2.1.3, logged in (Max)")
        XCTAssertEqual(AgentCLIStatus.notInstalled.summary(.codex), "Codex: not installed")
        XCTAssertTrue(AgentCLIStatus.notLoggedIn(path: "/x", version: nil).fix(.claudeCode)!.contains("run `claude` in Terminal"))
        XCTAssertTrue(AgentCLIStatus.notInstalled.fix(.codex)!.contains("npm install -g @openai/codex"))
        XCTAssertNil(AgentCLIStatus.ready(path: "/x", version: nil, account: nil).fix(.codex))
    }

    /// The pane's Install… shows each CLI's documented command (never sudo) and its Terminal file waits for Return.
    func testInstallCommandsAndScripts() {
        XCTAssertEqual(AgentCLIKind.claudeCode.install.command, "curl -fsSL https://claude.ai/install.sh | bash")
        XCTAssertEqual(AgentCLIKind.codex.install.command, "npm install -g @openai/codex")
        XCTAssertEqual(AgentCLIKind.claudeCode.install.docs.host, "code.claude.com")
        for k in AgentCLIKind.allCases {
            XCTAssertFalse(([k.install.command] + k.install.alternatives).contains { $0.contains("sudo") }, "\(k): no sudo")
            let file = "/tmp/airc-test-home/Install \(k.name).command"
            let s = AgentCLIScript.install(k, file: file)
            XCTAssertTrue(s.hasPrefix("#!/bin/zsh\n"))
            XCTAssertTrue(s.contains("rm -f '\(file)'"), "it deletes itself")
            XCTAssertTrue(s.contains("\n" + k.install.command + "\n"), "it runs the documented command")
            let wait = s.range(of: "read -r")!, run = s.range(of: "\n" + k.install.command + "\n")!
            XCTAssertTrue(wait.lowerBound < run.lowerBound, "only after Return")
            XCTAssertTrue(s.contains("|| exit 1"), "closing the window (EOF) cancels")
            XCTAssertFalse(s.contains("sudo"))
        }
    }

    func testLoginScripts() {
        XCTAssertEqual(AgentCLIKind.claudeCode.loginArguments, ["auth", "login"])
        XCTAssertEqual(AgentCLIKind.codex.loginArguments, ["login"])
        let s = AgentCLIScript.login(.claudeCode, executable: "/tmp/airc-test-home/my bin/claude", file: "/tmp/x.command")
        XCTAssertTrue(s.contains("\n'/tmp/airc-test-home/my bin/claude' auth login\n"), s)
        XCTAssertTrue(s.contains("rm -f /tmp/x.command"))
        XCTAssertFalse(s.contains("sudo"))
        XCTAssertEqual(AgentCLIScript.quote("it's"), "'it'\\''s'")
    }

    // MARK: Claude Code

    func testClaudeArgumentsAllowOnlyAircTools() {
        let a = ClaudeCLI.arguments(mcpConfig: "/T/mcp.json", system: "rules", maxTurns: 25, resume: nil)
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(a.first, "-p")
        XCTAssertEqual(value("--input-format"), "stream-json")
        XCTAssertEqual(value("--output-format"), "stream-json")
        XCTAssertEqual(value("--tools"), "", "no built-in tools")
        XCTAssertEqual(value("--allowedTools"), "mcp__airc")
        XCTAssertEqual(value("--permission-mode"), "dontAsk")
        XCTAssertTrue(a.contains("--strict-mcp-config"))
        XCTAssertTrue(value("--disallowedTools")!.split(separator: ",").contains("Bash"))
        XCTAssertEqual(value("--max-turns"), "25")
        XCTAssertNil(value("--resume"))
        XCTAssertFalse(a.contains("--dangerously-skip-permissions"))
        let r = ClaudeCLI.arguments(mcpConfig: "/T/mcp.json", system: "rules", maxTurns: 200, resume: "abc")
        XCTAssertEqual(r[r.firstIndex(of: "--resume")! + 1], "abc")
    }

    func testClaudeMCPConfigHasOnlyAirc() {
        let o = obj(ClaudeCLI.mcpConfig(server))
        let servers = o["mcpServers"] as! [String: Any]
        XCTAssertEqual(Array(servers.keys), ["airc"])
        let airc = servers["airc"] as! [String: Any]
        XCTAssertEqual(airc["command"] as? String, "/A/airc-mcp")
        XCTAssertEqual(airc["args"] as? [String], ["--socket", "/T/run.sock", "--client", "claude-code-airc"])
        XCTAssertEqual((airc["env"] as? [String: String])?["AIRC_MCP_TOKEN"], "t0k")
    }

    func testClaudeInput() {
        let m = obj(ClaudeCLI.userMessage("Find the price", session: "s1"))
        XCTAssertEqual(m["type"] as? String, "user")
        XCTAssertEqual(((m["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String, "Find the price")
        XCTAssertEqual(obj(ClaudeCLI.interrupt(id: "i1"))["type"] as? String, "control_request")
        XCTAssertTrue(ClaudeCLI.userMessage("x", session: nil).last == 0x0A, "one line")
    }

    private func claudeTurn() -> [Data] {
        [
            j(["type": "system", "subtype": "init", "session_id": "s1", "model": "claude-opus-5-5",
               "mcp_servers": [["name": "airc", "status": "connected"]], "tools": ["mcp__airc__read_page"]]),
            j(["type": "stream_event", "session_id": "s1", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Let me "]]]),
            j(["type": "stream_event", "session_id": "s1", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "look."]]]),
            j(["type": "assistant", "session_id": "s1", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Let me look."],
                ["type": "tool_use", "id": "tu1", "name": "mcp__airc__read_page", "input": [:]]]]]),
            j(["type": "user", "session_id": "s1", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "tu1", "content": "page"]]]]),
            j(["type": "stream_event", "session_id": "s1", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "It costs 12 €."]]]),
            j(["type": "assistant", "session_id": "s1", "message": ["role": "assistant", "content": [["type": "text", "text": "It costs 12 €."]]]]),
            j(["type": "result", "subtype": "success", "is_error": false, "result": "It costs 12 €.", "session_id": "s1",
               "total_cost_usd": 0.0123, "usage": ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 50, "cache_creation_input_tokens": 5]])
        ]
    }

    func testClaudeStreamTurn() {
        let p = ClaudeStreamParser()
        let events = claudeTurn().flatMap { p.feed($0) }
        XCTAssertEqual(events, [
            .started(session: "s1", model: "claude-opus-5-5"),
            .text("Let me "), .text("look."),
            .say("Let me look."), .tool(name: "read_page"),
            .text("It costs 12 €."),
            .usage(AgentUsage(input: 100, output: 20, cacheRead: 50, cacheWrite: 5), cost: 0.0123),
            .turnEnded(AgentCLITurnEnd(.completed, text: "It costs 12 €."))
        ])
        XCTAssertEqual(p.sessionID, "s1")
    }

    func testClaudeLinesSplitAnywhereStillParse() {
        // The app splits stdout into lines; a line is parsed only when whole, so a partial one yields nothing.
        let p = ClaudeStreamParser()
        let line = claudeTurn()[1]
        XCTAssertEqual(p.feed(line.prefix(10)), [])
        XCTAssertEqual(p.feed(line), [.text("Let me ")])
    }

    func testClaudeForeignToolAndMissingServer() {
        let p = ClaudeStreamParser()
        XCTAssertEqual(p.feed(j(["type": "system", "subtype": "init", "session_id": "s", "mcp_servers": [["name": "airc", "status": "failed"]]])),
                       [.started(session: "s", model: nil), .toolsUnavailable("failed")])
        XCTAssertEqual(p.feed(j(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "x", "name": "Bash", "input": ["command": "ls"]]]]])),
                       [.foreignTool("Bash")])
        XCTAssertEqual(p.feed(j(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "y", "name": "mcp__other__x", "input": [:]]]]])),
                       [.foreignTool("mcp__other__x")])
    }

    func testClaudeTurnEnds() {
        func end(_ o: [String: Any]) -> AgentCLITurnEnd? {
            for e in ClaudeStreamParser().feed(j(o)) { if case .turnEnded(let t) = e { return t } }
            return nil
        }
        XCTAssertEqual(end(["type": "result", "subtype": "error_max_turns", "is_error": true])?.outcome, .maxTurns)
        XCTAssertEqual(end(["type": "result", "subtype": "success", "is_error": true, "result": "Invalid API key · Please run /login"])?.outcome, .loginNeeded)
        XCTAssertEqual(end(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in · Please run /login"])?.outcome, .loginNeeded)
        XCTAssertEqual(end(["type": "result", "subtype": "error_during_execution", "is_error": true])?.outcome, .interrupted)
        XCTAssertEqual(end(["type": "result", "subtype": "error_during_execution", "is_error": true, "errors": ["boom"]])?.outcome, .failed("boom"))
    }

    func testClaudePermissionRequestsAreDenied() {
        let p = ClaudeStreamParser()
        _ = p.feed(j(["type": "control_request", "request_id": "c1", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": [:]]]))
        let replies = p.takeReplies()
        XCTAssertEqual(replies.count, 1)
        let r = obj(replies[0])["response"] as! [String: Any]
        XCTAssertEqual(r["request_id"] as? String, "c1")
        XCTAssertEqual((r["response"] as? [String: Any])?["behavior"] as? String, "deny")
        XCTAssertTrue(p.takeReplies().isEmpty)
    }

    // MARK: Codex

    func testCodexRequestsAndThreadStart() {
        let rpc = CodexRPC()
        let a = rpc.request("initialize", CodexCLI.initialize(version: "0.1"))
        let b = rpc.request("account/read", [:])
        XCTAssertEqual(a.id, 1)
        XCTAssertEqual(b.id, 2)
        XCTAssertNil(obj(a.line)["jsonrpc"], "Codex's app-server leaves out the jsonrpc member")
        let p = CodexCLI.threadStart(cwd: "/W", instructions: "rules", server: server, disable: ["github", "airc"])
        XCTAssertEqual(p["approvalPolicy"] as? String, "never")
        XCTAssertEqual(p["sandbox"] as? String, "read-only")
        let servers = (p["config"] as! [String: Any])["mcp_servers"] as! [String: Any]
        XCTAssertEqual((servers["github"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((servers["airc"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual(CodexCLI.mcpServerNames(configRead: ["config": ["mcp_servers": ["b": [:], "a": [:]]]]), ["a", "b"])
        XCTAssertTrue(CodexCLI.arguments.contains("shell_tool"))
    }

    func testCodexParseAndAnswers() {
        guard case .response(let id, let r, nil)? = CodexRPC.parse(j(["id": 2, "result": ["account": NSNull(), "requiresOpenaiAuth": true]])) else { return XCTFail() }
        XCTAssertEqual(id, 2)
        XCTAssertEqual(r?["requiresOpenaiAuth"] as? Bool, true)
        guard case .response(_, nil, "nope")? = CodexRPC.parse(j(["id": 3, "error": ["code": -1, "message": "nope"]])) else { return XCTFail() }
        guard case .request(let rid, let m, _)? = CodexRPC.parse(j(["id": "srv-1", "method": "item/commandExecution/requestApproval", "params": ["command": "ls"]])) else { return XCTFail() }
        XCTAssertEqual(rid as? String, "srv-1")
        let declined = obj(CodexRPC.answer(id: rid, method: m, params: [:]))
        XCTAssertEqual(declined["id"] as? String, "srv-1")
        XCTAssertEqual((declined["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertEqual((obj(CodexRPC.answer(id: 5, method: "item/fileChange/requestApproval", params: [:]))["result"] as? [String: Any])?["decision"] as? String, "decline")
        XCTAssertEqual((obj(CodexRPC.answer(id: 6, method: "mcpServer/elicitation/request", params: ["serverName": "airc"]))["result"] as? [String: Any])?["action"] as? String, "accept")
        XCTAssertEqual((obj(CodexRPC.answer(id: 7, method: "mcpServer/elicitation/request", params: ["serverName": "fs"]))["result"] as? [String: Any])?["action"] as? String, "decline")
        XCTAssertNotNil(obj(CodexRPC.answer(id: 8, method: "item/tool/call", params: [:]))["error"])
        guard case .notification("turn/started", _)? = CodexRPC.parse(j(["method": "turn/started", "params": ["turn": ["id": "t1"]]])) else { return XCTFail() }
    }

    func testCodexTurnEvents() {
        let rpc = CodexRPC()
        var ev: [AgentCLIEvent] = []
        ev += rpc.events("turn/started", ["threadId": "th", "turn": ["id": "t1", "status": "inProgress", "items": []]])
        XCTAssertEqual(rpc.turnID, "t1")
        ev += rpc.events("item/agentMessage/delta", ["delta": "Looking", "itemId": "m1", "threadId": "th", "turnId": "t1"])
        ev += rpc.events("item/completed", ["item": ["type": "agentMessage", "id": "m1", "text": "Looking."]])
        ev += rpc.events("item/started", ["item": ["type": "mcpToolCall", "id": "c1", "server": "airc", "tool": "read_page", "arguments": [:], "status": "inProgress"]])
        ev += rpc.events("thread/tokenUsage/updated", ["tokenUsage": ["total": ["inputTokens": 1000, "cachedInputTokens": 400, "outputTokens": 50, "reasoningOutputTokens": 0, "totalTokens": 1050],
                                                                      "last": [:]]])
        ev += rpc.events("item/completed", ["item": ["type": "agentMessage", "id": "m2", "text": "It costs 12 €."]])
        ev += rpc.events("turn/completed", ["threadId": "th", "turn": ["id": "t1", "status": "completed", "items": []]])
        XCTAssertEqual(ev, [.text("Looking"), .say("Looking."), .tool(name: "read_page"),
                            .usage(AgentUsage(input: 600, output: 50, cacheRead: 400), cost: nil),
                            .turnEnded(AgentCLITurnEnd(.completed, text: "It costs 12 €."))])
        XCTAssertNil(rpc.turnID)
        // Usage is per turn: the next update counts only what's new.
        XCTAssertEqual(rpc.events("thread/tokenUsage/updated", ["tokenUsage": ["total": ["inputTokens": 1500, "cachedInputTokens": 400, "outputTokens": 60]]]),
                       [.usage(AgentUsage(input: 500, output: 10, cacheRead: 0), cost: nil)])
    }

    func testCodexForeignItemsAndFailures() {
        let rpc = CodexRPC()
        XCTAssertEqual(rpc.events("item/started", ["item": ["type": "commandExecution", "id": "x", "command": "ls"]]), [.foreignTool("commandExecution")])
        XCTAssertEqual(rpc.events("item/started", ["item": ["type": "mcpToolCall", "id": "y", "server": "github", "tool": "x"]]), [.foreignTool("github.x")])
        XCTAssertEqual(rpc.events("turn/completed", ["turn": ["id": "t", "status": "interrupted"]]), [.turnEnded(AgentCLITurnEnd(.interrupted))])
        _ = rpc.events("error", ["error": ["message": "unexpected status 401 Unauthorized"], "willRetry": false])
        XCTAssertEqual(rpc.events("turn/completed", ["turn": ["id": "t", "status": "failed"]]), [.turnEnded(AgentCLITurnEnd(.loginNeeded))])
        XCTAssertEqual(rpc.events("turn/completed", ["turn": ["id": "t", "status": "failed", "error": ["message": "context window exceeded"]]]),
                       [.turnEnded(AgentCLITurnEnd(.failed("context window exceeded")))])
        // A retried error isn't the turn's failure.
        _ = rpc.events("error", ["error": ["message": "reconnecting"], "willRetry": true])
        XCTAssertEqual(rpc.events("turn/completed", ["turn": ["id": "t", "status": "failed"]]), [.turnEnded(AgentCLITurnEnd(.failed("The turn failed.")))])
    }
}
