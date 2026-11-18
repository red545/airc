// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// Settings › Agents (docs/user/agents.md): AI apps using Airc through its MCP connector. The switch (on by default),
/// the apps that asked and their answers, the profiles agents may use, and one-click setup for Claude.
final class AgentsSettingsModel: ObservableObject {
    /// One per app: the page and the demo clip (`--agent-demo=setup`) press the same buttons.
    static let shared = AgentsSettingsModel()

    @Published var setupMessage: String?
    @Published var copied: String?
    /// Opened from a Connect entry (Command Bar, Help, the "+" menu): Set up shows first.
    @Published var setUpFirst = false
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: AgentCenter.changed, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
        activityObserver = NotificationCenter.default.addObserver(forName: AgentActivity.changed, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private var activityObserver: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
    }

    var center: AgentCenter { .shared }

    func copy(_ text: String, as what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.copied == what { self?.copied = nil } }
    }

    /// Asks first (a sheet on the Settings window), then writes Claude Desktop's config.
    func addToClaudeDesktop(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Add Airc to Claude Desktop?"
        alert.informativeText = "Airc adds itself to Claude Desktop's settings file and keeps a copy of the old one next to it. Quit and reopen Claude Desktop to use it."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let run = { [weak self] (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn else { return }
            let outcome = AgentSetup.addToClaudeDesktop(home: AgentSetup.home)
            var next = ""
            if case .added = outcome { next = " Restart Claude Desktop, then ask it to open a page in Airc." }
            self?.setupMessage = "Claude Desktop: " + outcome.message + next
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    // MARK: Other devices

    private var pairingTimer: Timer?

    var pairingCode: String? { center.remote?.pairingCode }
    var pairingUntil: String {
        center.remote?.pairingExpires.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? ""
    }

    /// A new one-time code; the page redraws when it expires or is used.
    func startPairing() {
        _ = center.remote?.startPairing()
        objectWillChange.send()
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.objectWillChange.send()
            if self.pairingCode == nil { t.invalidate(); self.pairingTimer = nil }
        }
    }

    func cancelPairing() {
        center.remote?.cancelPairing()
        pairingTimer?.invalidate(); pairingTimer = nil
        objectWillChange.send()
    }

    func addToClaudeCode(window: NSWindow?) {
        guard let cli = AgentSetup.findClaudeCLI() else {
            copy(AgentSetup.claudeCodeCommand, as: "command")
            setupMessage = "Claude Code wasn't found on this Mac. The command is copied: paste it in Terminal."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Airc to Claude Code?"
        alert.informativeText = "Airc runs this in Claude Code (\(cli.path)):\n\n\(AgentSetup.claudeCodeCommand)"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let run = { [weak self] (r: NSApplication.ModalResponse) in
            guard r == .alertFirstButtonReturn else { return }
            self?.setupMessage = "Claude Code: adding…"
            AgentSetup.addToClaudeCode(cli: cli) { outcome in self?.setupMessage = "Claude Code: " + outcome.message }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }
}

struct AgentsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var agents = AgentsSettingsModel.shared
    @Environment(\.aircTheme) private var theme

    private var center: AgentCenter { agents.center }

    var body: some View {
        // A Connect entry's "Set up first" lasts while the page shows.
        content.onDisappear { agents.setUpFirst = false }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AI apps like Claude can use Airc to browse for you: open pages, read them, click and type, in the sites you're signed in to. They work in their own windows, out of your way. Airc asks you once before a new app can use it, never shows an app your saved passwords, and never lets one into a private window.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            // Until an app has connected (or when a Connect entry opened this page), setting one up comes first.
            if setUpOnTop { setUpSection }
            SettingsSection(title: "Access") {
                SettingsRow(title: "Let AI apps use Airc", subtitle: status) {
                    AircSwitch(isOn: Binding(get: { center.isOn }, set: { center.setEnabled($0) }))
                        .accessibilityLabel("Let AI apps use Airc")
                }
                SettingsRow(title: "Show agent pages in front", subtitle: "An agent's page opens live in your window as it starts, in the sidebar's Agents folder. Off: agents work out of sight, and you can watch any time from the Agents folder.") {
                    AircSwitch(isOn: Binding(get: { center.settings.showInFront }, set: { center.setShowInFront($0) }))
                        .accessibilityLabel("Show agent pages in front")
                }
                SettingsRow(title: "Keep finished agents for", subtitle: "How long an agent stays in the sidebar's Agents folder after it's done. One you're watching stays. Settings › Agents › Activity keeps the last 7 days.") {
                    AircPopUp(options: [("1 minute", 1), ("5 minutes", 5), ("30 minutes", 30), ("Until I clear", 0)],
                              selection: center.settings.keepFinishedMinutes, width: 150) { center.setKeepFinished(minutes: $0) }
                        .accessibilityLabel("Keep finished agents for")
                        .testAnchor("agents.keepFinished")
                }
                if center.connectedCount > 0 || !center.windows.isEmpty {
                    SettingsRow(title: "Stop what agents are doing", subtitle: "Ends every connection and closes their windows. Apps can connect again.") {
                        Button("Stop Agents") { center.stopAgents(reason: "person") }.buttonStyle(.airc(.secondary))
                    }
                }
            }
            SettingsSection(title: "Apps", help: "The first time an app connects, Airc asks you. Remove an app to be asked again.") {
                if center.settings.clients.isEmpty {
                    SettingsRow(title: "No apps yet", subtitle: "Set one up below, then ask it to use Airc.") { EmptyView() }
                } else {
                    ForEach(center.settings.clients.sorted { $0.decided > $1.decided }) { c in
                        SettingsRow(title: c.name, subtitle: clientLine(c)) {
                            HStack(spacing: 6) {
                                if c.allowed { AgentAppRulesButton(client: c, center: center) }
                                if c.stopped == true {
                                    Button("Allow Again") { center.allowAgain(c.key) }.buttonStyle(.airc(.secondary))
                                        .accessibilityLabel("Allow \(c.name) again")
                                }
                                Button("Remove") { center.removeClient(c.key) }.buttonStyle(.airc(.plain))
                                    .accessibilityLabel("Remove \(c.name)")
                            }
                        }
                    }
                }
            }
            SettingsSection(title: "Files", help: "Agents never get your files unless you say so here, and their downloads stay out of your Downloads list.") {
                SettingsRow(title: "Files agents may upload", subtitle: center.settings.uploadFolder.map { "From \(($0 as NSString).abbreviatingWithTildeInPath) and each app's own folder." }
                            ?? "Only from each app's own folder (what it downloaded). Choose a folder to let apps upload its files too.") {
                    HStack(spacing: 6) {
                        Button(center.settings.uploadFolder == nil ? "Choose Folder…" : "Change…") { chooseUploadFolder() }
                            .buttonStyle(.airc(.secondary)).testAnchor("agents.uploadFolder")
                        if center.settings.uploadFolder != nil {
                            Button("Clear") { center.setUploadFolder(nil) }.buttonStyle(.airc(.plain)).accessibilityLabel("Clear the upload folder")
                        }
                    }
                }
                SettingsRow(title: "Agents' downloads", subtitle: "What an agent's page downloads goes to its app's own folder in \((AgentCenter.agentsDownloads.path as NSString).abbreviatingWithTildeInPath), and the app is told where.") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AgentCenter.agentsDownloads, withIntermediateDirectories: true)
                        DownloadCenter.reveal([AgentCenter.agentsDownloads])
                    }.buttonStyle(.airc(.secondary))
                }
            }
            SettingsSection(title: "Profiles", help: "Agents use the logins and cookies of the profile they work in. Private windows are never open to agents.") {
                ForEach(center.profiles, id: \.id) { p in
                    SettingsRow(title: (p.emoji.isEmpty ? "" : p.emoji + " ") + p.name) {
                        AircSwitch(isOn: Binding(get: { center.isGranted(p) }, set: { center.setGranted(p.id, $0) }))
                            .accessibilityLabel("Agents may use \(p.name)")
                    }
                }
            }
            activitySection
            if !setUpOnTop { setUpSection }
            otherDevicesSection
        }
    }

    /// Other devices on the Tailscale network (Agent/AgentRemote.swift): off by default, below the local setup.
    @ViewBuilder private var otherDevicesSection: some View {
        let devices = center.remoteDevices
        SettingsSection(title: "Other devices", help: "Claude Code on your other computers can use Airc on this Mac over Tailscale, after you pair them. Only devices on your Tailscale network can reach it, and each one is asked about once, like an app here.") {
            SettingsRow(title: "Allow other devices on your Tailscale network", subtitle: center.remoteStatus) {
                AircSwitch(isOn: Binding(get: { center.remoteWanted }, set: { center.setRemoteEnabled($0) }))
                    .disabled(!center.isOn)
                    .accessibilityLabel("Allow other devices on your Tailscale network")
                    .testAnchor("agents-remote-switch")
            }
            if center.remoteListening, let base = center.remoteBaseURL {
                if let code = agents.pairingCode {
                    SettingsRow(title: "Pairing code  \(code)", subtitle: "Works once, until \(agents.pairingUntil). On the other device, paste this in Terminal; it pairs and adds Airc to Claude Code:") {
                        Button("Cancel") { agents.cancelPairing() }.buttonStyle(.airc(.plain))
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Text(AgentCenter.remoteCommand(base: base, code: code))
                            .aircFont(AircFont.mono).foregroundStyle(theme.surfaceTextSecondary.color)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .testAnchor("agents-remote-command")
                        Spacer(minLength: 8)
                        Button(agents.copied == "remote" ? "Copied" : "Copy") { agents.copy(AgentCenter.remoteCommand(base: base, code: code), as: "remote") }
                            .buttonStyle(.airc(.secondary))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                } else {
                    SettingsRow(title: "Pair a device", subtitle: "Shows a one-time code, and the command that pairs Claude Code on the other device. Other MCP apps: POST the code to \(base)/pair, then use \(base)/mcp with the token as a Bearer header.") {
                        Button("Pair a Device") { agents.startPairing() }.buttonStyle(.airc(.secondary))
                            .testAnchor("agents-remote-pair")
                    }
                }
            }
            ForEach(devices) { d in
                SettingsRow(title: d.name, subtitle: deviceLine(d)) {
                    Button("Revoke") { center.revokeDevice(d.id) }.buttonStyle(.airc(.plain))
                        .accessibilityLabel("Revoke \(d.name)")
                        .testAnchor("agents-remote-revoke")
                }
            }
        }
    }

    private func deviceLine(_ d: RemoteDevice) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let used = d.lastUsed.map { " · last used " + f.localizedString(for: $0, relativeTo: Date()) } ?? ""
        return "Paired " + f.localizedString(for: d.paired, relativeTo: Date()) + used + (d.lastAddress.map { " · " + $0 } ?? "")
    }

    /// Claude Desktop first (the clear first step), then Claude Code and other MCP apps.
    @ViewBuilder private var setUpSection: some View {
        SettingsSection(title: setUpOnTop ? "Connect Claude" : "Set up", help: agents.setupMessage) {
            SettingsRow(title: "Claude Desktop",
                        subtitle: AgentSetup.claudeDesktopInstalled
                            ? "Airc adds itself to Claude Desktop's settings, after asking. Restart Claude Desktop, then ask it to open a page in Airc."
                            : "Claude Desktop isn't installed in Applications. Install it, or use Claude Code below.") {
                Button("Add to Claude Desktop") { agents.addToClaudeDesktop(window: model.app?.settingsWindow?.window) }
                    .buttonStyle(.airc(.primary))
                    .testAnchor("agents-add-claude-desktop")
            }
            SettingsRow(title: "Claude Code", subtitle: "Adds Airc to Claude Code with its “claude mcp add” command, after asking. Copy gives you the command for Terminal.") {
                HStack(spacing: 6) {
                    Button(agents.copied == "command" ? "Copied" : "Copy") { agents.copy(AgentSetup.claudeCodeCommand, as: "command") }
                        .buttonStyle(.airc(.plain))
                    Button("Add to Claude Code") { agents.addToClaudeCode(window: model.app?.settingsWindow?.window) }
                        .buttonStyle(.airc(.secondary))
                }
            }
            SettingsRow(title: "Other apps", subtitle: "Cursor, Codex, VS Code and other MCP apps: paste this into their MCP settings.") {
                Button(agents.copied == "json" ? "Copied" : "Copy JSON") { agents.copy(AgentSetup.otherAppsJSON, as: "json") }
                    .buttonStyle(.airc(.secondary))
            }
        }
    }

    private var setUpOnTop: Bool { agents.setUpFirst || AgentsConnect.neverConnected }

    /// What each app did lately: when, where (the site only) and what kinds of things; never page content or text.
    @ViewBuilder private var activitySection: some View {
        let groups = AgentActivity.shared.history.byClient(limit: 6)
        SettingsSection(title: "Activity", help: "What agents did in the last 7 days: sites and kinds of actions, never what they read or typed. Kept on this Mac only.") {
            if groups.isEmpty {
                SettingsRow(title: "Nothing yet", subtitle: "When an app uses Airc, its recent work shows here.") { EmptyView() }
            } else {
                ForEach(groups) { g in
                    ForEach(g.entries) { e in
                        SettingsRow(title: g.client + " · " + e.site, subtitle: activityTime(e) + "\n" + e.line) { EmptyView() }
                    }
                }
                SettingsRow(title: "Clear history", subtitle: "Removes the activity list. Agents keep working.") {
                    Button("Clear History") { AgentActivity.shared.clearHistory() }.buttonStyle(.airc(.secondary))
                        .accessibilityLabel("Clear agent activity history")
                }
            }
        }
    }

    private func activityTime(_ e: AgentHistoryEntry) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        let end = DateFormatter.localizedString(from: e.end, dateStyle: .none, timeStyle: .short)
        return f.string(from: e.start) + (e.end.timeIntervalSince(e.start) >= 60 ? "–" + end : "")
    }

    private var status: String { center.accessStatus }

    private func chooseUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Agents may upload the files in this folder (and its subfolders)."
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .OK, let url = panel.url { center.setUploadFolder(url.path) }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: done) } else { done(panel.runModal()) }
    }

    private func clientLine(_ c: AgentClient) -> String {
        var rules: [String] = []
        if let id = c.profile, let p = center.profiles.first(where: { $0.id == id }) { rules.append("Only \(p.name)") }
        if let sites = c.blockedSites, !sites.isEmpty { rules.append("Never opens " + sites.joined(separator: ", ")) }
        return clientLineBase(c) + (rules.isEmpty ? "" : "\n" + rules.joined(separator: " · "))
    }

    private func clientLineBase(_ c: AgentClient) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        let when = (c.allowed ? c.lastUsed : c.decided).map { f.localizedString(for: $0, relativeTo: Date()) } ?? ""
        return (c.allowed ? "Allowed" : "Not allowed") + (when.isEmpty ? "" : " · " + (c.allowed ? "last used " : "") + when) + "\n" + c.detail
    }
}

/// An allowed app's rules (Settings › Agents › Apps › Rules…): the one profile it may use and the sites it may never
/// open. Airc enforces both in the agent tools (AgentCenter.siteRefusal, the hello's profile rule); the Airc Agent's own
/// "never use" list (Settings › AI) applies to every app too.
struct AgentAppRulesButton: View {
    let client: AgentClient
    let center: AgentCenter
    @State private var shown = false

    var body: some View {
        Button("Rules…") { shown = true }.buttonStyle(.airc(.secondary))
            .accessibilityLabel("Rules for \(client.name)")
            .testAnchor("agents.rules.\(client.name)")
            .popover(isPresented: $shown, arrowEdge: .bottom) { AgentAppRules(key: client.key, center: center) }
    }
}

struct AgentAppRules: View {
    let key: String
    let center: AgentCenter
    @ObservedObject private var agents = AgentsSettingsModel.shared
    @State private var field = ""
    @Environment(\.colorScheme) private var scheme

    private var theme: ResolvedTheme { DesignTheme.default.resolved(systemIsDark: scheme == .dark) }
    private var c: AgentClient? { center.client(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rules for \(c?.name ?? "this app")").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            VStack(alignment: .leading, spacing: 4) {
                Text("Profile").aircFont(AircFont.callout).foregroundStyle(theme.surfaceText.color)
                AircPopUp(options: [("Any open profile", "")] + center.grantedProfiles.map { ((($0.emoji.isEmpty ? "" : $0.emoji + " ") + $0.name), $0.id) },
                          selection: c?.profile ?? "", width: 220) { center.setProfileRule(key, $0.isEmpty ? nil : $0) }
                    .accessibilityLabel("Profile \(c?.name ?? "") may use")
                Text("Any: the app picks one when there are several (or uses the only one).")
                    .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Never open these sites").aircFont(AircFont.callout).foregroundStyle(theme.surfaceText.color)
                ForEach(c?.blockedSites ?? [], id: \.self) { site in
                    HStack {
                        Text(site).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                        Spacer()
                        Button("Remove") { center.setBlockedSites(key, (c?.blockedSites ?? []).filter { $0 != site }) }
                            .buttonStyle(.airc(.plain)).accessibilityLabel("Remove \(site)")
                    }
                }
                HStack(spacing: 6) {
                    TextField("example.com", text: $field).textFieldStyle(.roundedBorder).onSubmit(add)
                        .accessibilityLabel("Site \(c?.name ?? "") may never open")
                        .testAnchor("agents.rules.site")
                    Button("Add", action: add).buttonStyle(.airc(.secondary)).disabled(field.isEmpty)
                }
                Text("Subdomains too. Sites on the Airc Agent's “never use” list (Settings › AI) are closed to every app.")
                    .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(theme.surface.color)
    }

    private func add() {
        defer { field = "" }
        guard let host = AgentCenter.siteHost(field) else { return }
        var sites = c?.blockedSites ?? []
        if !sites.contains(host) { sites.append(host) }
        center.setBlockedSites(key, sites)
    }
}
