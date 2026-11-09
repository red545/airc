// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// A classic address row above the whole page (also above Split View), independent of sidebar placement. As in Arc
/// ("How do you move your pinned extensions to the top right?": turn on the Toolbar), the pinned extensions leave the
/// sidebar's URL field for its top right while it shows, in their pin order, always visible, with the puzzle button
/// for ⌘E's list after them (Extensions.swift hands them over: `refreshExtensionButtons`).
final class PageToolbarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 38
    weak var controller: WindowController?
    lazy var fieldEditor: NSTextView = {
        let editor = NSTextView(frame: .zero)
        editor.isFieldEditor = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        if #available(macOS 14.0, *) { editor.inlinePredictionType = .no }
        return editor
    }()

    let address = NSTextField()
    let back = GlyphButton(symbol: "chevron.left", size: 12)
    let forward = GlyphButton(symbol: "chevron.right", size: 12)
    let reload = GlyphButton(symbol: "arrow.clockwise", size: 12)
    /// ⌘E's list, at the toolbar's trailing end.
    let puzzle = GlyphButton(symbol: "puzzlepiece.extension", size: 12)
    /// The profile's pinned, enabled actions, in pin order (left to right), reused while the pins don't change.
    private(set) var extensionButtons: [ExtensionButton] = []
    private var ink: NSColor = .black
    /// The extensions get at most what leaves the address this wide; pins beyond that are in ⌘E's list.
    static let minAddressWidth: CGFloat = 160
    static let extensionButtonSize: CGFloat = 26
    override var isFlipped: Bool { true }

    init(controller: WindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        for button in [back, forward, reload] { addSubview(button) }
        back.action = { [weak controller] in controller?.goBack() }
        forward.action = { [weak controller] in controller?.goForward() }
        reload.action = { [weak controller] in controller?.reloadOrStop() }
        back.toolTip = "Back"; forward.toolTip = "Forward"; reload.toolTip = "Reload or Stop"
        address.isBordered = false; address.drawsBackground = false
        address.font = .systemFont(ofSize: 13)
        address.focusRingType = .none
        address.cell?.isScrollable = true
        address.cell?.wraps = false
        address.contentType = .URL
        address.placeholderString = "Search or Enter URL…"
        address.setAccessibilityLabel("Full URL")
        address.delegate = self
        addSubview(address)
        puzzle.toolTip = "Extensions ⌘E"
        puzzle.setAccessibilityLabel("Extensions")
        puzzle.action = { [weak controller] in controller?.showExtensions() }
        addSubview(puzzle)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // On the right (or with the sidebar hidden), leave the native traffic lights room in windowed mode.
        let inset: CGFloat = controller.map { !$0.isFullscreen && ($0.sidebarOnRight || $0.sidebarHidden) ? 78 : 6 } ?? 6
        for (i, button) in [back, forward, reload].enumerated() {
            button.frame = NSRect(x: inset + CGFloat(i) * 28, y: 7, width: 24, height: 24)
        }
        // Trailing: the puzzle, then the pinned actions right to left (Chrome's order), as many as leave the address
        // its minimum width.
        let b = Self.extensionButtonSize, y = (Self.height - b) / 2
        puzzle.frame = NSRect(x: bounds.width - 6 - b, y: y, width: b, height: b)
        var minX = puzzle.frame.minX
        let addressX = inset + 90
        for e in extensionButtons.reversed() {
            e.isHidden = minX - b - 4 - addressX < Self.minAddressWidth
            guard !e.isHidden else { continue }
            e.frame = NSRect(x: minX - b, y: y, width: b, height: b)
            minX = e.frame.minX
        }
        address.frame = NSRect(x: addressX, y: 10, width: max(20, minX - 8 - addressX), height: 20)
    }

    /// The pinned actions to show (already filtered to enabled ones, in pin order). The buttons are kept while the
    /// pins are the same, so a refresh never rebuilds or reorders them.
    func setExtensions(_ actions: [ExtensionAction]) {
        if extensionButtons.map(\.id) != actions.map(\.id) {
            let old = Dictionary(uniqueKeysWithValues: extensionButtons.map { ($0.id, $0) })
            extensionButtons = actions.map { a in
                if let kept = old[a.id] { return kept }
                let v = ExtensionButton(id: a.id)
                v.action = { [weak self] button in
                    self?.controller?.runExtension(button.id, anchor: button, rect: button.bounds)
                }
                addSubview(v)
                return v
            }
            for (id, v) in old where !actions.contains(where: { $0.id == id }) { v.removeFromSuperview() }
        }
        for (button, a) in zip(extensionButtons, actions) {
            button.configure(a, glyph: ink.withAlphaComponent(0.7), hover: ink.withAlphaComponent(0.08))
            // Greyed out where the extension can't run (Chrome does the same), still there to click.
            button.alphaValue = a.isActive ? 1 : 0.4
        }
        needsLayout = true
    }

    /// Where an action's popup anchors: its button if it shows, else the puzzle.
    func extensionAnchor(for id: String) -> (view: NSView, rect: NSRect) {
        if let b = extensionButtons.first(where: { $0.id == id && !$0.isHidden }) { return (b, b.bounds) }
        return (puzzle, puzzle.bounds)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    func refresh() {
        guard let c = controller else { return }
        let page = c.shownTabID.flatMap { c.engineTab(for: $0) }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = page?.themeColor ?? .textBackgroundColor
            layer?.backgroundColor = color.cgColor
            let rgb = color.usingColorSpace(.deviceRGB)
            let dark = rgb.map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent < 0.45 } ?? false
            let ink: NSColor = dark ? .white : .black
            self.ink = ink
            address.textColor = ink.withAlphaComponent(0.85)
            for b in [back, forward, reload, puzzle] { b.tint = ink.withAlphaComponent(0.7); b.hoverFill = ink.withAlphaComponent(0.08) }
            for b in extensionButtons { b.restyle(glyph: ink.withAlphaComponent(0.7), hover: ink.withAlphaComponent(0.08)) }
        }
        back.isEnabled = page?.canGoBack == true
        forward.isEnabled = page?.canGoForward == true
        reload.isEnabled = page != nil
        reload.symbol = page?.isLoading == true ? "xmark" : "arrow.clockwise"
        if address.currentEditor() == nil {
            address.stringValue = page?.url?.absoluteString ?? c.currentTab?.url ?? ""
        }
        // The pinned actions' state (badges, greyed out) follows the shown page and Space: asked again a moment after
        // the last change, never on every refresh.
        c.scheduleToolbarExtensionsRefresh()
        needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let c = controller else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard let url = URLRules.resolve(address.stringValue, search: c.store.profile(ofSpace: c.currentSpaceID).defaultSearch) else { return true }
            c.window.makeFirstResponder(nil)
            c.navigate(to: url, newTab: c.currentTab == nil, typed: true)
            refresh()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            c.window.makeFirstResponder(nil); refresh(); return true
        }
        return false
    }
}

extension WindowController {
    /// ⇧⌘D. The pinned extensions move with it (toolbar ↔ URL field), same order; an open popup closes, its button
    /// having moved.
    func togglePageToolbar() {
        closeExtensionPopup()
        if let toolbar = pageToolbar {
            if toolbar.address.currentEditor() != nil { window.makeFirstResponder(nil) }
            toolbar.removeFromSuperview()
            pageToolbar = nil
        } else {
            let toolbar = PageToolbarView(controller: self)
            pageToolbar = toolbar
            root.addSubview(toolbar, positioned: .above, relativeTo: card)
        }
        layoutRoot()
        refreshExtensionButtons()
    }
}
