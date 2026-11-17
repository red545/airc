// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// "Hand to Claude" (docs/design/agent.md, "UI"): with no API key, the person's own Claude Desktop or Claude Code does the
/// task through Airc's MCP connector, on their own Claude plan. Airc never signs in to Claude itself.
/// - Not connected yet (the app's config has no `airc` server, or "Let AI apps use Airc" is off): Settings › Agents with
///   Set up on top, so the connector is in place before any task goes over.
/// - Connected: Claude Desktop opens on a new chat with the task filled in (its `claude://claude.ai/new?q=` link), and the
///   task is on the clipboard too in case it isn't; Claude Code starts in Terminal with the task as its first prompt (a
///   `.command` file Terminal runs; no Apple Events, so no Automation prompt).
enum AgentHandoff {
    enum Target: String, CaseIterable {
        case desktop = "claude-desktop"
        case code = "claude-code"

        var name: String { self == .desktop ? "Claude Desktop" : "Claude Code" }

        var installed: Bool {
            switch self {
            case .desktop: return AgentSetup.claudeDesktopInstalled
            case .code: return AgentHandoff.claudeCLI != nil
            }
        }
    }

    /// The task as Claude gets it: it says which connector to use.
    static func prompt(_ task: String) -> String {
        "Use the Airc browser connector (the airc tools) to do this in my Airc browser: " + task.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where Claude Code's CLI is (in the setup home, so checks can stand one in).
    static var claudeCLI: URL? { AgentSetup.findClaudeCLI(home: AgentSetup.home) }

    /// Whether Airc's connector is set up in that app's own config, and AI apps may use Airc.
    static func isConnected(_ t: Target) -> Bool {
        guard AgentCenter.shared.isOn else { return false }
        switch t {
        case .desktop: return hasAirc(in: AgentSetup.claudeDesktopConfig(home: AgentSetup.home))
        case .code: return hasAirc(in: AgentSetup.home.appendingPathComponent(".claude.json"))
        }
    }

    /// A config file (JSON) with an `mcpServers.airc` entry.
    static func hasAirc(in file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (o["mcpServers"] as? [String: Any])?["airc"] != nil
    }

    /// Settings › Agents, Set up on top (and "Let AI apps use Airc" in the same place).
    static func connect(_ t: Target?) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        AgentsConnect.open(app: app, from: "panel-handoff-" + (t?.rawValue ?? "none"))
    }

    /// Opens a URL; checks replace it to record instead of launching another app.
    static var opener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }

    /// Hands the task over; returns what the panel says about it.
    @discardableResult
    static func hand(_ task: String, to t: Target) -> String {
        let text = prompt(task)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        switch t {
        case .desktop:
            var c = URLComponents()
            c.scheme = "claude"
            c.host = "claude.ai"
            c.path = "/new"
            c.queryItems = [URLQueryItem(name: "q", value: text)]
            guard let url = c.url else { return "Couldn't open Claude Desktop. Your task is on the clipboard." }
            opener(url)
            AgentCenter.shared.onEvent?("handoff claude-desktop")
            return "Opened Claude Desktop with your task. If it isn't in the message field, paste it (⌘V): it's on the clipboard."
        case .code:
            guard let cli = claudeCLI, let script = commandFile(cli: cli, prompt: text) else {
                return "Couldn't start Claude Code. Your task is on the clipboard."
            }
            opener(script)
            AgentCenter.shared.onEvent?("handoff claude-code")
            return "Started Claude Code in Terminal with your task."
        }
    }

    /// A one-time `.command` file: Terminal runs it, it deletes itself and starts Claude Code with the task.
    static func commandFile(cli: URL, prompt: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-handoff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("Claude Code - \(UUID().uuidString.prefix(8)).command")
        let q = AgentSetup.shellQuote
        let body = """
            #!/bin/zsh
            rm -f \(q(file.path))
            cd ~
            exec \(q(cli.path)) \(q(prompt))

            """
        do {
            try Data(body.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { return nil }
        return file
    }
}
