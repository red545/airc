// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// asidepass: the Command Bar's Ask mode (docs/user/agents.md, "Ask from the Command Bar"). A Search | Ask switch at
/// the end of the field; in Ask, Return hands what's typed to the Airc Agent and opens its task view, the chips under
/// the field say what it may use and who runs it, and Recent tasks shows this Space's newest tasks as cards.
///
/// Tab keeps every job it has in Arc (actions on an empty field, a site's search, accepting a completion); it switches
/// to Ask only where it would do nothing else, and back from Ask always. Nothing here runs per keystroke in Search:
/// the switch is drawn once, its "Tab" hint shows only when the bar already offers "Ask Airc to…".
final class CommandBarModeToggle: NSView {
    private let searchLabel = NSTextField(labelWithString: "Search")
    private let askLabel = NSTextField(labelWithString: "Ask")
    private let key = NSTextField(labelWithString: "Tab")
    private let hint = NSTextField(labelWithString: "to switch")
    private let track = CALayer()
    private let knob = CALayer()
    private let keyCap = CALayer()
    var onPick: ((Bool) -> Void)?

    var ask = false { didSet { if ask != oldValue { place(animated: true) } } }
    var showsTabHint = false {
        didSet {
            guard showsTabHint != oldValue else { return }
            key.isHidden = !showsTabHint
            hint.isHidden = !showsTabHint
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            keyCap.isHidden = !showsTabHint
            CATransaction.commit()
        }
    }
    var palette: Palette? { didSet { applyPalette() } }

    static let segment = CGSize(width: 58, height: 24)
    static let hintWidth: CGFloat = 92

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(keyCap)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        for l in [searchLabel, askLabel, key, hint] {
            l.alignment = .center
            l.setAccessibilityElement(false)
            addSubview(l)
        }
        searchLabel.font = AircFont.caption.appFont
        askLabel.font = AircFont.caption.appFont
        key.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        hint.font = AircFont.caption.appFont
        hint.alignment = .left
        track.cornerRadius = 8
        knob.cornerRadius = 6.5
        keyCap.cornerRadius = 4
        key.isHidden = true
        hint.isHidden = true
        keyCap.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Search or Ask")
        toolTip = "Search the web, or ask the Airc Agent to do it (Tab switches)"
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.hintWidth + Self.segment.width * 2 + 4, height: Self.segment.height + 4) }

    override func accessibilityValue() -> Any? { ask ? "Ask" : "Search" }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard track.frame.contains(p) else { return }
        let pickAsk = p.x > track.frame.midX
        onPick?(pickAsk)
    }

    override func accessibilityPerformPress() -> Bool { onPick?(!ask); return true }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    private func place(animated: Bool) {
        let h = Self.segment.height + 4
        let trackRect = NSRect(x: bounds.width - Self.segment.width * 2 - 4, y: (bounds.height - h) / 2, width: Self.segment.width * 2 + 4, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if animated { CATransaction.setAnimationDuration(0.22); CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)) }
        track.frame = trackRect
        knob.frame = NSRect(x: trackRect.minX + 2 + (ask ? Self.segment.width : 0), y: trackRect.minY + 2, width: Self.segment.width, height: Self.segment.height)
        CATransaction.commit()
        searchLabel.sizeToFit()
        askLabel.sizeToFit()
        searchLabel.frame = NSRect(x: trackRect.minX + 2, y: trackRect.midY - searchLabel.frame.height / 2, width: Self.segment.width, height: searchLabel.frame.height)
        askLabel.frame = NSRect(x: trackRect.minX + 2 + Self.segment.width, y: trackRect.midY - askLabel.frame.height / 2, width: Self.segment.width, height: askLabel.frame.height)
        key.sizeToFit()
        hint.sizeToFit()
        let capW = key.frame.width + 10
        let hintX = trackRect.minX - 8 - hint.frame.width
        hint.frame.origin = NSPoint(x: hintX, y: trackRect.midY - hint.frame.height / 2)
        let capRect = NSRect(x: hintX - 5 - capW, y: trackRect.midY - 9, width: capW, height: 18)
        key.frame = NSRect(x: capRect.minX, y: capRect.midY - key.frame.height / 2, width: capW, height: key.frame.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyCap.frame = capRect
        CATransaction.commit()
        applyColors()
    }

    private func applyPalette() { applyColors() }

    private func applyColors() {
        guard let p = palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = p.resolved.surfaceHover.cgColor
        knob.backgroundColor = p.panelBackground.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = p.resolved.isDark ? 0.4 : 0.12
        knob.shadowRadius = 2
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        keyCap.backgroundColor = p.resolved.surfaceHover.cgColor
        CATransaction.commit()
        searchLabel.textColor = ask ? p.panelSecondary : p.panelText
        askLabel.textColor = ask ? p.panelText : p.panelSecondary
        key.textColor = p.panelSecondary
        hint.textColor = p.panelSecondary
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }

    func refreshLabels() { applyColors() }
}

/// What Ask mode shows under the field.
final class CommandBarAskModel: ObservableObject {
    @Published var attached: [AgentAskContext] = []
    @Published var theme: ResolvedTheme
    @Published var spaceID = ""
    weak var controller: WindowController?
    var openTask: ((AgentTaskRecord) -> Void)?
    var showAll: (() -> Void)?

    init(theme: ResolvedTheme) { self.theme = theme }
}

struct CommandBarAskContent: View {
    @ObservedObject var model: CommandBarAskModel
    @ObservedObject private var recorder = AgentTaskRecorder.shared
    @ObservedObject private var chips = AgentAskChipsModel.shared

    var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 12) {
            AgentAskChips(attached: $model.attached, tabs: { model.controller.map(AgentAskContext.spaceTabs) ?? [] },
                          profileName: model.controller.map { $0.store.profile(ofSpace: $0.currentSpaceID).name } ?? "")
            if CommandBarAskPanel.hasRecent(spaceID: model.spaceID) {
                AgentRecentTasks(spaceID: model.spaceID, open: { model.openTask?($0) }, showAll: model.showAll)
            } else {
                Text(chips.connected ? "Airc works in your signed-in sites in a window of its own, and asks before it pays, sends, posts or deletes."
                                     : "Connect your AI first: your ChatGPT subscription through your own Codex, your own Claude Code, or an API key.")
                    .aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .testAnchor("agentask.empty")
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.aircTheme, theme)
        .testAnchorRoot()
    }
}

/// The SwiftUI part under the field, made on the first switch to Ask (⌘T never pays for it).
final class CommandBarAskPanel: NSView {
    let model: CommandBarAskModel
    private let hosting: NSHostingView<CommandBarAskContent>

    static let chipsHeight: CGFloat = 50
    static let recentHeight: CGFloat = 262

    static func hasRecent(spaceID: String) -> Bool {
        AgentTaskRecorder.shared.tasks.contains { $0.spaceID == spaceID || $0.spaceID.isEmpty }
    }

    /// The panel's height for this Space (known before SwiftUI lays it out, so the bar's frame is right at once).
    static func height(spaceID: String) -> CGFloat { chipsHeight + (hasRecent(spaceID: spaceID) ? recentHeight : 30) }

    init(theme: ResolvedTheme) {
        model = CommandBarAskModel(theme: theme)
        hosting = NSHostingView(rootView: CommandBarAskContent(model: model))
        super.init(frame: .zero)
        hosting.safeAreaRegions = []
        addSubview(hosting)
        setAccessibilityIdentifier("commandbar-ask")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

extension CommandBarView {
    /// The window Ask mode works for (private windows have no agent).
    var askWindow: WindowController? { host?.commandBarAgent == nil ? nil : host as? WindowController }

    /// Return in Ask: a new task with what's typed (and the attached tabs), shown in its task view. Not connected, or
    /// the agent busy with another task: the pane takes the text (its Connect card, or its field).
    static func startAgentTask(_ text: String, attached: [AgentAskContext], in c: WindowController) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let run = AgentRunCenter.shared
        guard run.hasKey, run.canSend else { return AgentUI.ask(c, t) }
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        if !run.steps.isEmpty { run.newConversation() }
        AgentTaskRecorder.shared.willAsk(spaceID: c.currentSpaceID, profileID: p.id)
        AgentAttention.taskAsked(in: c)
        run.ask(t + AgentAskContext.promptLine(attached), profileID: p.id, profileName: p.name)
        // The task's record appears with its first step (AgentTaskRecorder follows the run on the main queue).
        var tries = 0
        func open() {
            if let id = AgentTaskRecorder.shared.currentID { AgentTasksPage.openTask(id, in: c); return }
            tries += 1
            if tries < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: open) } else { AgentPaneController.show(c) }
        }
        DispatchQueue.main.async(execute: open)
    }
}
