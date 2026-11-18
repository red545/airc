// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// The Airc Agent panel (⌥⌘A, View › Airc Agent; docs/user/agents.md, "Ask Airc"): docked to the right edge of a browser
/// window, a child panel that moves and resizes with it. The conversation is AgentRunCenter's (one at a time); the panel
/// is only its view. Private windows have no panel (they aren't WindowControllers).
final class AgentPanelController: NSObject {
    private static var panels: [ObjectIdentifier: AgentPanelController] = [:]
    static let width: CGFloat = 380

    weak var controller: WindowController?
    let panel: AgentPanelWindow
    private let look = AgentPanelLook()
    private weak var effect: NSVisualEffectView?
    private var observers: [NSObjectProtocol] = []

    /// The panel of a window, if it's open.
    static func panel(of c: WindowController) -> AgentPanelController? { panels[ObjectIdentifier(c)] }

    /// ⌥⌘A: open (and focus the field) or close.
    static func toggle(_ c: WindowController) {
        if let p = panels[ObjectIdentifier(c)] { p.close() } else { show(c) }
    }

    @discardableResult
    static func show(_ c: WindowController) -> AgentPanelController {
        if let p = panels[ObjectIdentifier(c)] { p.focus(); return p }
        let p = AgentPanelController(c)
        panels[ObjectIdentifier(c)] = p
        p.attach()
        return p
    }

    private init(_ c: WindowController) {
        controller = c
        panel = AgentPanelWindow(contentRect: .zero, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .utilityWindow
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: AgentPanelView(look: look, profile: { [weak self] in self?.profile() }, close: { [weak self] in self?.close() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        panel.contentView = effect
        self.effect = effect
        panel.onEscape = { [weak self] in self?.escape() }
    }

    /// The Command Bar's "Ask Airc to…" (or any caller): the task runs now if the agent is free, else it waits in the field.
    func ask(_ text: String) {
        let run = AgentRunCenter.shared
        focus()
        guard run.canSend, run.hasKey, let p = profile() else {
            look.draft = text
            // The task waits in the field with the caret after it: the next key goes on from it, never over it
            // (cbflicker2: the field selected all of it, so the first key typed replaced the task).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.caretToEnd() }
            return
        }
        run.ask(text, profileID: p.id, profileName: p.name)
    }

    #if AIRC_TESTING
    /// What waits in the field (cbflicker: the Command Bar's task, kept while there's no key).
    var draftForTesting: String? { look.draft }
    #endif

    /// The Space's profile the agent acts in.
    func profile() -> (id: String, name: String)? {
        guard let c = controller else { return nil }
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        return (p.id, p.name)
    }

    private func attach() {
        guard let c = controller else { return }
        let w = c.window
        layout()
        w.addChildWindow(panel, ordered: .above)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in self?.layout() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in self?.close() })
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        focus()
    }

    /// Right edge of the window's content, 8 pt in, below the title bar.
    func layout() {
        guard let c = controller else { return }
        let w = c.window
        // The window's own theme (the Space's), light or dark as it draws.
        let theme = c.promptTheme
        if look.theme != theme { look.theme = theme }
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        let content = w.contentLayoutRect
        let inWindow = NSRect(x: content.maxX - Self.width - 8, y: 8, width: Self.width, height: max(240, content.height - 16))
        panel.setFrame(w.convertToScreen(inWindow), display: true)
    }

    func focus() {
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = Self.findField(in: self.panel.contentView) else { return }
            self.panel.makeFirstResponder(field)
        }
    }

    private func caretToEnd() {
        guard let tv = panel.firstResponder as? NSTextView else { return }
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    }

    private static func findField(in v: NSView?) -> NSView? {
        guard let v else { return nil }
        if v is NSTextView || v is NSTextField, v.acceptsFirstResponder { return v }
        for s in v.subviews { if let f = findField(in: s) { return f } }
        return nil
    }

    /// Esc: decline a waiting approval, else stop a run, else close.
    private func escape() {
        let run = AgentRunCenter.shared
        if run.approval != nil { return run.answerApproval(allow: false) }
        if run.state.isActive { return run.stop() }
        close()
    }

    func close() {
        guard let c = controller else { return }
        Self.panels[ObjectIdentifier(c)] = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        c.window.removeChildWindow(panel)
        panel.orderOut(nil)
        c.window.makeKey()
    }
}

/// A borderless panel that can take the keyboard (the field) without a title bar.
final class AgentPanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: The view

/// The panel's theme, the window's (it changes with the Space).
final class AgentPanelLook: ObservableObject {
    @Published var theme: ResolvedTheme?
    /// Text for the field from outside (the Command Bar's row while a task runs).
    @Published var draft: String?
}

extension WindowController {
    /// The Command Bar's "Ask Airc to…" row, key or not (owner, 0.1.26: without a key nobody found it). With no key the
    /// panel opens at its setup (key fields, Hand to Claude Desktop / Claude Code) with the task kept in its field.
    /// Private windows have none (CommandBarHost's default).
    var commandBarAgent: ((String) -> Void)? {
        { [weak self] text in
            guard let self else { return }
            AgentPanelController.show(self).ask(text)
        }
    }
}

struct AgentPanelView: View {
    @ObservedObject var look: AgentPanelLook
    let profile: () -> (id: String, name: String)?
    let close: () -> Void
    @ObservedObject private var run = AgentRunCenter.shared
    @State private var text = ""
    @State private var settingsRev = 0
    @State private var handoffNote: String?
    @Environment(\.aircTheme) private var envTheme
    private var theme: ResolvedTheme { look.theme ?? envTheme }

    var body: some View {
        if let t = look.theme { content.environment(\.aircTheme, t) } else { content }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !run.hasKey || settingsRev < 0 { connectCard.padding(14) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if run.steps.isEmpty && run.hasKey { empty }
                        ForEach(run.steps) { StepRow(step: $0).id($0.id) }
                        if !run.partial.isEmpty {
                            // The answer as it streams in.
                            Text(run.partial).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
                                .fixedSize(horizontal: false, vertical: true).id("partial").testAnchor("agent.partial")
                        }
                        if let a = run.approval { ApprovalCard(request: a).id("approval") }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: run.steps.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
                .onChange(of: run.approval) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
                .onChange(of: run.partial.count / 80) { _, _ in proxy.scrollTo("bottom") }
            }
            Divider().opacity(0.5)
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentModelSettings.changed)) { _ in settingsRev += 1 }
        .onReceive(look.$draft) { d in if let d { text = d; look.draft = nil } }
        // Back from Settings › Agents (or Claude's own setup): the hand-off buttons read the configs again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in if !run.hasKey { settingsRev += 1 } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in if !run.hasKey { settingsRev += 1 } }
        .testAnchor("agent.panel")
        .testAnchorRoot()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 0) {
                Text("Airc Agent").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
                Text(subtitle).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).lineLimit(1)
            }
            Spacer()
            Button { run.newConversation() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).help("New task").disabled(run.steps.isEmpty).testAnchor("agent.new")
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close (Esc)").testAnchor("agent.close")
        }
        .foregroundStyle(theme.surfaceTextSecondary.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        if run.stepCount > 0 { return run.usageLine }
        let m = AgentModelSettings.shared.model.name
        let p = profile()?.name ?? ""
        return p.isEmpty ? m : "\(m) · in \(p)"
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask Airc to do something on the web.").aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color)
            Text("It works in a window of this profile, where your sites are signed in. It asks before paying, sending, posting or deleting, and never sees your passwords.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your AI").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Text("Add an Anthropic or OpenAI API key in Settings › AI › Agent. Requests go from this Mac to that provider, billed to your key.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .ai) }.buttonStyle(.airc(.primary))
                .testAnchor("agent.connect")
            handoff
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tileFill.color))
    }

    /// No key: the person's own Claude can do the task through Airc's connector (their app, their plan).
    private var handoff: some View {
        let targets = AgentHandoff.Target.allCases.filter(\.installed)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.5).padding(.vertical, 2)
            Text(targets.isEmpty ? "Or use Claude Desktop or Claude Code, which can use Airc once they're connected."
                 : "Or hand this task to Claude. It uses Airc through its connector, with your Claude plan.")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
            ForEach(targets, id: \.self) { t in
                let ready = AgentHandoff.isConnected(t)
                HStack(spacing: 8) {
                    Button(ready ? "Hand to \(t.name)" : "Connect \(t.name)…") {
                        if ready { handoffNote = AgentHandoff.hand(text, to: t) } else { AgentHandoff.connect(t) }
                    }
                    .buttonStyle(.airc(.secondary))
                    .disabled(ready && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(ready ? "Opens \(t.name) with your task in it." : "Set up Airc's connector in Settings › Agents first.")
                    .testAnchor("agent.handoff.\(t.rawValue)")
                    if !ready {
                        Text("Not set up yet").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                    }
                }
            }
            if targets.isEmpty {
                Button("Settings › Agents") { AgentHandoff.connect(nil) }.buttonStyle(.airc(.secondary)).testAnchor("agent.handoff.settings")
            }
            if let handoffNote {
                Text(handoffNote).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
                    .fixedSize(horizontal: false, vertical: true).testAnchor("agent.handoff.note")
            }
        }
        .id(settingsRev)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .stopped(let why) = run.state, why.contains("limit") {
                Button("Continue") { run.continueRun() }.buttonStyle(.airc(.secondary)).testAnchor("agent.continue")
            }
            TextField(run.hasKey ? "Ask Airc to…" : "Your task, to hand to Claude…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .aircFont(AircFont.body)
                .lineLimit(1...6)
                .onSubmit(send)
                .disabled(run.state.isActive)
                .testAnchor("agent.field")
            HStack(spacing: 8) {
                Picker("", selection: $run.level) {
                    ForEach(AgentLevel.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(run.state.isActive)
                .help("Quick: up to 25 steps and 3 minutes. Keep going: up to 200 steps and 30 minutes.")
                .testAnchor("agent.level")
                Spacer()
                if run.state.isActive {
                    Button("Stop") { run.stop() }.buttonStyle(.airc(.destructive)).keyboardShortcut(".", modifiers: .command).testAnchor("agent.stop")
                } else {
                    Button("Send", action: send).buttonStyle(.airc(.primary))
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !run.hasKey).testAnchor("agent.send")
                }
            }
        }
        .padding(14)
    }

    private func send() {
        guard let p = profile(), run.canSend else { return }
        let t = text
        text = ""
        run.ask(t, profileID: p.id, profileName: p.name)
    }
}

private struct StepRow: View {
    let step: AgentStep
    @Environment(\.aircTheme) private var theme

    var body: some View {
        switch step.kind {
        case .user:
            HStack { Spacer(minLength: 40)
                Text(step.text).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(theme.selectedFill.color))
            }
        case .say, .final:
            Text(step.text).aircFont(AircFont.body).foregroundStyle(theme.surfaceText.color).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .action:
            line("circle.fill", step.text, step.detail, theme.surfaceTextTertiary.color, small: true)
        case .warning:
            line("exclamationmark.triangle.fill", step.text, step.detail, .orange)
                .testAnchor("agent.warning")
        case .approval:
            line("hand.raised.fill", step.text, step.detail, .orange)
        case .decision:
            line(step.text.hasPrefix("Allowed") ? "checkmark.circle.fill" : "xmark.circle.fill", step.text, nil, theme.surfaceTextSecondary.color)
        case .error:
            line("exclamationmark.circle.fill", step.text, nil, .red)
        case .info:
            line("info.circle", step.text, nil, theme.surfaceTextSecondary.color)
        case .memory:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                line("book.closed", step.text, step.detail, theme.surfaceTextSecondary.color)
                Spacer(minLength: 4)
                if step.memoryLine != nil {
                    Button("Undo") { AgentRunCenter.shared.undoMemory(step.id) }
                        .buttonStyle(.airc(.secondary, size: .small)).help("Remove this line from your Memory folder.")
                        .testAnchor("agent.memory.undo")
                } else if step.text.hasPrefix("Used memory") {
                    Button("Show") { AgentMemoryUI.openFolder() }
                        .buttonStyle(.airc(.secondary, size: .small)).help("Open the Memory folder in Finder.")
                }
            }
            .testAnchor("agent.memory")
        }
    }

    private func line(_ icon: String, _ text: String, _ detail: String?, _ tint: Color, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: small ? 5 : 11)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Pay, send, post, delete: the person's yes. Nothing is pre-selected; Esc declines.
private struct ApprovalCard: View {
    let request: AgentApprovalRequest
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            }
            Text(request.risk.reason).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("The agent waits for your answer, here or in Watch (the sidebar's Agents folder).")
                .aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextTertiary.color).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Deny") { AgentRunCenter.shared.answerApproval(allow: false) }.buttonStyle(.airc(.secondary)).testAnchor("agent.deny")
                Button("Allow Once") { AgentRunCenter.shared.answerApproval(allow: true) }.buttonStyle(.airc(.secondary)).testAnchor("agent.allow")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.35)))
        .testAnchor("agent.approval")
    }
}

/// Settings › AI › Agent › Memory and the panel's Show: the Memory folder in Finder, and Clear.
enum AgentMemoryUI {
    static func openFolder() {
        let folder = AgentModelSettings.shared.memoryStore.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(folder)
    }

    /// Asks first; true if cleared.
    @discardableResult
    static func clear(in window: NSWindow?) -> Bool {
        let a = NSAlert()
        a.messageText = "Clear the Airc Agent's memory?"
        a.informativeText = "Everything in the Memory folder (people, sites and dated notes) is deleted. This can't be undone."
        a.addButton(withTitle: "Clear Memory")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        AgentModelSettings.shared.memoryStore.clear()
        return true
    }
}
