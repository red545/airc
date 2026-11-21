// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import Combine

/// The Airc Agent button (⌥⌘A) in the sidebar's header row, after Back, Forward and Reload (owner 2026-11-20: out of
/// the bottom bar, into the toolbar row). The same glyph button, size, pitch and hover plate as its neighbours. Opens and
/// closes the agent pane (accent while it's open in this window), shows a dot while a task runs; right-click: New Task,
/// Watch, Settings › Agents. Placed by `SidebarHeaderView`, which drops it last when the sidebar is narrow.
final class AgentToolbarButton {
    weak var controller: WindowController?
    let glyph = GlyphButton(symbol: "sparkles", size: 14)
    /// The 6 pt accent "working" dot at the glyph's top right, a sublayer of the button so it moves and dims with it.
    private let dot = CALayer()
    private var tint: NSColor = .secondaryLabelColor
    private var subs: [AnyCancellable] = []

    /// The button (the checks click it; the first-run hint points at it).
    var button: NSView { glyph }
    /// Whether its "working" dot shows.
    var dotShown: Bool { !dot.isHidden && !glyph.isHidden }

    init() {
        glyph.toolTip = "Airc Agent (⌥⌘A)"
        glyph.setAccessibilityElement(true)
        glyph.setAccessibilityRole(.button)
        glyph.setAccessibilityLabel("Airc Agent")
        glyph.setAccessibilityHelp("Opens or closes the Airc Agent beside the page (⌥⌘A)")
        glyph.action = { [weak self] in
            guard let self, let c = self.controller else { return }
            AgentUI.toggle(c)
            self.refresh()
        }
        glyph.contextMenuProvider = { [weak self] in self?.menu() }
        glyph.wantsLayer = true
        dot.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.cornerRadius = 3
        dot.isHidden = true
        dot.zPosition = 1
        glyph.layer?.addSublayer(dot)
        subs.append(AgentRunCenter.shared.$state.map(\.isActive).removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() })
        subs.append(NotificationCenter.default.publisher(for: AgentPaneController.visibilityChanged)
            .sink { [weak self] _ in self?.refresh() })
    }

    /// The header's colours (`SidebarHeaderView.configure`).
    func configure(palette: Palette) {
        tint = palette.glyph
        glyph.hoverFill = palette.hover
        refresh()
    }

    /// Where the dot goes in the button's own coordinates (not flipped): over the glyph's top right, as it sat in the bar.
    func layoutDot() {
        let b = glyph.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: b.maxX - 9, y: b.maxY - 10, width: 6, height: 6)
        CATransaction.commit()
    }

    /// The button follows the pane (accent while it's open in this window) and the run (the dot).
    func refresh() {
        let open = controller.map { AgentUI.isShown($0) } ?? false
        glyph.tint = open ? .controlAccentColor : tint
        glyph.setAccessibilityValue(open ? "open" : "closed")
        let working = AgentRunCenter.shared.state.isActive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.isHidden = !working
        CATransaction.commit()
        glyph.toolTip = working ? "Airc Agent (⌥⌘A): working" : "Airc Agent (⌥⌘A)"
    }

    /// Right-click on the button.
    private func menu() -> NSMenu {
        let m = NSMenu()
        m.add("New Task") { [weak self] in if let c = self?.controller { AgentUI.newTask(c); self?.refresh() } }
        let watch = m.add("Watch") { [weak self] in self?.watch() }
        watch.isEnabled = liveAgentRow != nil
        m.autoenablesItems = false
        m.addItem(.separator())
        m.add("Settings › Agents…") { (NSApp.delegate as? AppDelegate)?.showSettings(page: .agents) }
        return m
    }

    /// The Airc Agent's live page, for Watch.
    var liveAgentRow: String? {
        guard let w = AgentRunCenter.shared.runWindowID else { return nil }
        let rows = AgentActivity.shared.model.rows.filter { $0.window == w && $0.isLive }
        let active = AgentCenter.shared.windows[w]?.activeTabID
        return (rows.first { $0.tab == active } ?? rows.last)?.id
    }

    func watch() {
        guard let c = controller, let id = liveAgentRow else { return }
        c.sidebar.agents.openWatch(id)
    }
}
