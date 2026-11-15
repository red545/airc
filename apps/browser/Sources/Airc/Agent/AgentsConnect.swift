// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// "How do I connect Claude to this browser?" (feedback inbox): every way in leads to Settings › Agents with Set up on
/// top. The Command Bar ("claude", "mcp", "agent", "ai app", "connect"…: "Connect Claude and other AI apps…"),
/// Help › Use Airc with Claude…, and, until an app has ever connected, the sidebar footer's "+" menu › Connect Claude….
/// Once one has, the Agents folder takes over.
enum AgentsConnect {
    static let commandTitle = "Connect Claude and other AI apps…"
    static let helpTitle = "Use Airc with Claude…"
    static let plusTitle = "Connect Claude…"

    /// No app was ever allowed (an answered "Don't Allow" doesn't count as connected).
    static var neverConnected: Bool { !AgentCenter.shared.settings.clients.contains { $0.allowed } }

    /// Settings › Agents, Set up first.
    static func open(app: AppDelegate, from source: String) {
        AgentsSettingsModel.shared.setUpFirst = true
        app.showSettings(page: .agents)
        AgentCenter.shared.onEvent?("connect-opened \(source)")
    }
}

extension AgentCenter {
    /// Settings › Agents › Access: what's true now. Who is connected, else who may connect, else that none has yet.
    var accessStatus: String {
        guard isOn else { return "Off: no app can use Airc." }
        let names = connectedNames
        if !names.isEmpty { return "On · " + names.joined(separator: ", ") + " connected now" }
        let allowed = settings.clients.filter(\.allowed)
        if allowed.count == 1 { return "On · " + allowed[0].name + " allowed" }
        if allowed.count > 1 { return "On · \(allowed.count) apps allowed" }
        return "On. No app has connected yet."
    }
}

extension WindowController {
    /// The Command Bar's entry (CommandBar.swift's actions list).
    func agentsCommandActions() -> [CommandAction] {
        [.init(title: AgentsConnect.commandTitle, symbol: "sparkles", hint: "",
               keywords: ["claude", "claude desktop", "claude code", "connect claude", "use airc with claude", "mcp", "mcp server",
                          "agent", "agents", "ai agent", "ai app", "ai apps", "connect", "codex", "cursor"]) { [weak self] in
            guard let app = self?.app else { return }
            AgentsConnect.open(app: app, from: "command-bar")
        }]
    }

    /// The footer "+" menu's entry, only while no AI app has ever connected (WindowActions.plusMenu).
    func addConnectClaudeItem(to m: NSMenu) {
        guard AgentsConnect.neverConnected else { return }
        m.addItem(.separator())
        m.add(AgentsConnect.plusTitle) { [weak self] in
            guard let app = self?.app else { return }
            AgentsConnect.open(app: app, from: "plus-menu")
        }
    }
}
