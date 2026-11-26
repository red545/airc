// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// A page attached to the next prompt (the Command Bar's Ask mode, the task view's composer): read once at send time as
/// the pane does, by its title and address.
struct AgentAskContext: Equatable, Identifiable {
    let tabID: String
    let title: String
    let url: URL
    var id: String { tabID }
    var host: String { url.host.map(AgentPaneTimeline.trimmed) ?? url.absoluteString }

    /// The prompt's tail that tells the agent which page the person means (the pane's own line, so the task title and
    /// the bubble leave it out).
    static func promptLine(_ pages: [AgentAskContext]) -> String {
        guard !pages.isEmpty else { return "" }
        return AgentPaneItem.pageLine + pages.map { "“\($0.title)” — \($0.url.absoluteString)" }.joined(separator: "; ")
    }

    /// The window's shown page, when it's a web page.
    static func shownPage(of c: WindowController) -> AgentAskContext? {
        guard let id = c.shownTabID else { return nil }
        return tab(id, in: c)
    }

    static func tab(_ id: String, in c: WindowController) -> AgentAskContext? {
        guard let tab = c.store.tab(id), let url = URL(string: tab.url), ["http", "https", "file"].contains(url.scheme ?? "") else { return nil }
        return AgentAskContext(tabID: id, title: tab.title.isEmpty ? (url.host ?? url.absoluteString) : tab.title, url: url)
    }

    /// This Space's web tabs for the + menu, most recent first (at most 12).
    static func spaceTabs(of c: WindowController) -> [AgentAskContext] {
        let tabs = c.store.state.tabs.values.filter { $0.spaceID == c.currentSpaceID }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        return tabs.prefix(24).compactMap { tab($0.id, in: c) }.prefix(12).map { $0 }
    }
}

/// The chips under an Ask field (asidepass; docs/user/agents.md, "Ask from the Command Bar"): + attaches a tab, then
/// where the task runs (this Mac, in the Space's profile), what it asks you first (Airc's approval rule), and on the
/// right who runs it and how long it may go on. The same row sits under the task view's composer.
struct AgentAskChips: View {
    @Binding var attached: [AgentAskContext]
    /// The tabs + offers (this Space's, shown page first).
    let tabs: () -> [AgentAskContext]
    let profileName: String
    var disabled = false
    var compact = false
    @ObservedObject private var run = AgentRunCenter.shared
    @ObservedObject private var settings = AgentAskChipsModel.shared
    @Environment(\.aircTheme) private var theme

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            attach
            ForEach(attached) { a in attachedChip(a) }
            chipMenu(symbol: "laptopcomputer", label: compact ? nil : "This Mac", anchor: "agentask.where") {
                Text("Runs on this Mac, in its own background window")
                Text("Signed in as your “\(profileName)” profile")
                Divider()
                Button("Agent Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai) }
            }
            .help("Runs on this Mac in your “\(profileName)” profile, in a tab of this window")
            chipMenu(symbol: "checkmark.shield", label: compact ? nil : "Asks first", anchor: "agentask.safety") {
                Text("Asks you before it pays, sends, posts or deletes")
                Text("Never sees your passwords: saved logins fill in by name")
                Divider()
                Button("Blocked Sites and Approvals…") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai) }
            }
            .help("Airc asks you before the agent pays, sends, posts or deletes anything")
            Spacer(minLength: 6)
            providerMenu
            levelMenu
        }
        .disabled(disabled)
        .testAnchor("agentask.chips")
    }

    private var attach: some View {
        Menu {
            let list = tabs()
            if list.isEmpty { Text("No pages in this Space") }
            ForEach(list) { t in
                Button {
                    if !attached.contains(t) { attached.append(t) }
                } label: { Text(t.title) + Text("  \(t.host)") }
                .disabled(attached.contains(t))
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(theme.surfaceTextSecondary.color)
        .background(Circle().fill(theme.tileFill.color.opacity(0.0001)))
        .help("Attach a tab (or type @)")
        .accessibilityLabel("Attach a tab")
        .testAnchor("agentask.attach")
    }

    private func attachedChip(_ a: AgentAskContext) -> some View {
        HStack(spacing: 4) {
            AgentPaneSiteIcon(host: a.url.host, size: 12)
            Text(a.title).aircFont(AircFont.caption).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150, alignment: .leading)
            Button { attached.removeAll { $0 == a } } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                .buttonStyle(.plain).help("Don't attach this page").accessibilityLabel("Remove \(a.title)")
                .testAnchor("agentask.attached.remove")
        }
        .foregroundStyle(theme.surfaceText.color)
        .padding(.leading, 6).padding(.trailing, 7).padding(.vertical, 3)
        .background(Capsule().fill(theme.tileFill.color))
        .overlay(Capsule().strokeBorder(theme.surfaceBorder.color))
        .testAnchor("agentask.attached")
    }

    private func chipMenu<Content: View>(symbol: String, label: String?, anchor: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .medium))
                if let label { Text(label).aircFont(AircFont.caption) }
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(theme.surfaceTextSecondary.color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .contentShape(Capsule())
        .testAnchor(anchor)
    }

    private var providerMenu: some View {
        let providers = settings.providers
        return Menu {
            Section("On this Mac") {
                ForEach(providers.filter { $0.group == .plan }) { p in
                    Button { pick(p) } label: { Text(p.selected ? "✓ \(p.title)" : p.title) + Text(p.ready ? "  \(p.subtitle)" : "  \(p.fix ?? "")") }
                }
            }
            Section("API keys") {
                ForEach(providers.filter { $0.group == .key }) { p in
                    Button { pick(p) } label: { Text(p.selected ? "✓ \(p.name)" : p.name) + Text(p.ready ? "  \(p.status)" : "  \(p.fix ?? "")") }
                }
            }
            Divider()
            Button("Manage in Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .medium))
                Text(settings.providerLabel).aircFont(AircFont.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(theme.surfaceTextTertiary.color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .disabled(run.state.isActive)
        .help("Who runs the agent")
        .testAnchor("agentask.provider")
    }

    private var levelMenu: some View {
        Menu {
            ForEach(AgentLevel.allCases, id: \.self) { l in
                Button(l == run.level ? "✓ \(l.name)" : l.name) { run.level = l }
            }
        } label: {
            HStack(spacing: 3) {
                Text(run.level.name).aircFont(AircFont.caption)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(theme.surfaceTextTertiary.color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .disabled(run.state.isActive)
        .help(AgentLevel.help)
        .testAnchor("agentask.level")
    }

    private func pick(_ p: AgentPaneProvider) {
        if p.ready { p.choose(); settings.changed() } else { p.setUp() }
    }
}

/// The provider list and label for the chips, refreshed when settings or the CLI detector change (never per keystroke).
final class AgentAskChipsModel: ObservableObject {
    static let shared = AgentAskChipsModel()
    @Published private(set) var providers: [AgentPaneProvider] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        for n in [AgentModelSettings.changed, AgentCLIDetector.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.changed() })
        }
        changed()
    }

    func changed() { providers = AgentPaneProvider.all() }

    /// "Codex", "Claude Code", "Anthropic · Claude Opus 5.5", or "Connect your AI".
    var providerLabel: String {
        guard let p = providers.first(where: \.selected) else { return "Connect your AI" }
        if p.cli != nil { return p.name }
        return p.name.replacingOccurrences(of: " API key", with: "") + " · " + AgentModelSettings.shared.model.name
    }

    var connected: Bool { AgentRunCenter.shared.hasKey }
}
