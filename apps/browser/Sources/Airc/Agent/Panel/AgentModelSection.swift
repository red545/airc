// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// Settings › AI › Agent: the Airc Agent's model (your own API key), default level and blocked sites.
struct AgentModelSection: View {
    @State private var values = AgentModelSettings.shared.values
    @State private var keyField = ""
    @State private var keyHint = AgentModelSettings.shared.keyHint(AgentModelSettings.shared.values.provider)
    @State private var siteField = ""
    @State private var status: String?
    @State private var cliRev = 0

    private var settings: AgentModelSettings { .shared }

    var body: some View {
        SettingsSection(title: "Agent",
                        help: helpText) {
            SettingsRow(title: "Use", subtitle: values.backend == .apiKey ? nil : "Airc runs your own \(values.backend.cli!.name) with the login you made in it, and gives it only Airc's browser tools.") {
                Picker("", selection: Binding(get: { values.backend }, set: { b in
                    settings.update { $0.backend = b }
                    if let k = b.cli { AgentCLIDetector.shared.check(k, maxAge: 0) }
                    reload()
                })) {
                    ForEach(AgentBackend.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize().testAnchor("ai.agent.backend")
            }
            if let kind = values.backend.cli {
                cliRow(kind)
            } else {
            SettingsRow(title: "Provider") {
                Picker("", selection: Binding(get: { values.provider }, set: { p in
                    settings.update { $0.provider = p }
                    reload()
                })) {
                    ForEach(AgentProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize().testAnchor("ai.agent.provider")
            }
            SettingsRow(title: "API key", subtitle: keyHint.map { "Saved in your Keychain (\($0))." } ?? "Get one at \(values.provider.keyPage.replacingOccurrences(of: "https://", with: "")).") {
                HStack(spacing: 6) {
                    SecureField(keyHint == nil ? "Paste key" : "Replace key", text: $keyField)
                        .textFieldStyle(.roundedBorder).frame(width: 180).onSubmit(saveKey).testAnchor("ai.agent.key")
                    Button("Save", action: saveKey).buttonStyle(.airc(.secondary)).disabled(keyField.isEmpty)
                    if keyHint != nil {
                        Button("Remove") { settings.setKey("", for: values.provider); reload() }.buttonStyle(.airc(.secondary))
                    }
                }
            }
            SettingsRow(title: "Model", subtitle: status) {
                Picker("", selection: Binding(get: { settings.model.id }, set: { id in
                    settings.update { v in if v.provider == .anthropic { v.anthropicModel = id } else { v.openaiModel = id } }
                    reload()
                })) {
                    ForEach(values.provider.models) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize().testAnchor("ai.agent.model")
            }
            }
            SettingsRow(title: "Tasks", subtitle: AgentLevel.help) {
                Picker("", selection: Binding(get: { values.level }, set: { l in
                    settings.update { $0.level = l }
                    for r in AgentTaskCenter.shared.runs where !r.isBusy { r.level = l }
                    reload()
                })) {
                    ForEach(AgentLevel.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingsRow(title: "Stop after", subtitle: values.stepCap.map { "A task stops after \($0) steps; Continue gives it \($0) more. Stop is always there." }
                         ?? "Off: a task keeps going until it's done, you stop it, or it needs you. Stop is always there.") {
                Picker("", selection: Binding(get: { values.stepCap ?? 0 }, set: { n in
                    settings.update { $0.stepCap = n > 0 ? n : nil }
                    reload()
                })) {
                    ForEach(Array(Set(AgentBudget.capChoices.map { $0 ?? 0 } + [values.stepCap ?? 0])).sorted(), id: \.self) { n in
                        Text(n == 0 ? "Off" : "\(n) steps").tag(n)
                    }
                }
                .labelsHidden().fixedSize().help("Stop after N steps (off by default)").testAnchor("ai.agent.stepcap")
            }
            SettingsRow(title: "Memory", subtitle: values.memory
                         ? "On: the agent reads its notes at the start of a task (they go to \(values.provider.name) with it) and adds short lines you can undo. Never passwords, card numbers or codes."
                         : "Off: every task starts fresh. On, it keeps short notes about people and sites in Markdown files you can edit.") {
                HStack(spacing: 6) {
                    Toggle("Remember things between tasks", isOn: Binding(get: { values.memory }, set: { on in
                        settings.update { $0.memory = on }
                        reload()
                    }))
                    .toggleStyle(.switch).labelsHidden().help("Remember things between tasks").testAnchor("ai.agent.memory")
                    Button("Open Folder") { AgentMemoryUI.openFolder() }.buttonStyle(.airc(.secondary)).testAnchor("ai.agent.memory.open")
                    Button("Clear…") { if AgentMemoryUI.clear(in: NSApp.keyWindow) { status = "Memory cleared." } }
                        .buttonStyle(.airc(.secondary)).testAnchor("ai.agent.memory.clear")
                }
            }
            SettingsRow(title: "Never use these sites", subtitle: values.blockedSites.isEmpty ? "The agent stops instead of acting on a site listed here." : values.blockedSites.joined(separator: ", ")) {
                HStack(spacing: 6) {
                    TextField("example.com", text: $siteField).textFieldStyle(.roundedBorder).frame(width: 140).onSubmit(addSite)
                    Button("Add", action: addSite).buttonStyle(.airc(.secondary)).disabled(siteField.isEmpty)
                    if !values.blockedSites.isEmpty {
                        Button("Clear") { settings.update { $0.blockedSites = [] }; reload() }.buttonStyle(.airc(.secondary))
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentModelSettings.changed)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: AgentCLIDetector.changed)) { _ in cliRev += 1 }
        .onAppear { if let k = values.backend.cli { AgentCLIDetector.shared.check(k) } }
    }

    private var helpText: String {
        if let k = values.backend.cli {
            return "The Airc Agent (⌥⌘A) does tasks in your signed-in sites with your own \(k.name), as if you ran it in Terminal: it uses the login you made in it, and its use counts against your account with \(k.vendor). Airc never sees that login. Your task, the pages it reads, its screenshots and what it finds in your history go from this Mac to \(k.vendor). It can search this profile's history and open tabs to find a page you saw before, without asking, like reading a page. It may only use Airc's browser tools, asks before paying, sending, posting or deleting, and never sees saved passwords, cookies or private windows."
        }
        return "The Airc Agent (⌥⌘A) does tasks in your signed-in sites with your own AI. Your task, the pages it reads, its screenshots and what it finds in your history go from this Mac to \(values.provider.name), billed to your key; your key stays in your Keychain. It can search this profile's history and open tabs to find a page you saw before, without asking, like reading a page. It asks before paying, sending, posting or deleting, and never sees saved passwords, cookies or private windows."
    }

    /// The person's CLI: what Airc found ("Claude Code 2.1.322, logged in (Max)") and what to do when it isn't ready.
    private func cliRow(_ kind: AgentCLIKind) -> some View {
        let s = AgentCLIDetector.shared.status(kind) ?? .checking
        return SettingsRow(title: kind.name, subtitle: (s.fix(kind) ?? "Ready. Memory isn't used with \(kind.name) yet.") + (cliRev < 0 ? "" : "")) {
            HStack(spacing: 6) {
                Text(s.summary(kind)).aircFont(AircFont.callout).lineLimit(1).testAnchor("ai.agent.cli.status")
                Button("Check Again") { AgentCLIDetector.shared.check(kind, maxAge: 0) }
                    .buttonStyle(.airc(.secondary)).disabled(s == .checking).testAnchor("ai.agent.cli.check")
            }
        }
    }

    private func reload() {
        values = settings.values
        keyHint = settings.keyHint(values.provider)
    }

    private func saveKey() {
        let k = keyField
        keyField = ""
        guard !k.isEmpty else { return }
        status = settings.setKey(k, for: values.provider) ? "Key saved." : "The Keychain didn't take the key."
        reload()
    }

    private func addSite() {
        let raw = siteField.trimmingCharacters(in: .whitespaces).lowercased()
        siteField = ""
        let host = URL(string: raw.contains("://") ? raw : "https://" + raw)?.host ?? raw
        guard !host.isEmpty else { return }
        settings.update { if !$0.blockedSites.contains(host) { $0.blockedSites.append(host) } }
        reload()
    }
}
