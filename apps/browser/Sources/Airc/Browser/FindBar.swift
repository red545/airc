// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// ⌘F (CB-2): a find field over the page's top-right corner. ↩ / ⌘G next, ⇧↩ / ⇧⌘G previous, Esc closes.
final class FindBarView: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let previous = GlyphButton(symbol: "chevron.up", size: 11)
    private let next = GlyphButton(symbol: "chevron.down", size: 11)
    private let close = GlyphButton(symbol: "xmark", size: 10)
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    static let size = NSSize(width: 340, height: 40)

    init(palette: Palette) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = palette.panelBackground.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = palette.panelBorder.cgColor
        layer?.applyAircShadow(.popover)
        field.placeholderString = "Find on page"
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        status.font = AircFont.callout.appFont
        status.textColor = palette.panelSecondary
        status.alignment = .right
        for b in [previous, next, close] {
            b.tint = palette.panelSecondary
            b.hoverFill = palette.panelSelection
        }
        previous.toolTip = "Previous (⇧⌘G)"
        next.toolTip = "Next (⌘G)"
        close.toolTip = "Close (Esc)"
        previous.action = { [weak self] in self?.find(forward: false) }
        next.action = { [weak self] in self?.find(forward: true) }
        close.action = { [weak self] in self?.onClose?() }
        for v in [field, status, previous, next, close] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let h = bounds.height
        close.frame = NSRect(x: bounds.width - 8 - 24, y: (h - 24) / 2, width: 24, height: 24)
        next.frame = NSRect(x: close.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
        previous.frame = NSRect(x: next.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
        status.frame = NSRect(x: previous.frame.minX - 84, y: (h - 16) / 2, width: 78, height: 16)
        field.frame = NSRect(x: 8, y: (h - 24) / 2, width: status.frame.minX - 14, height: 24)
    }

    /// `active`: the 1-based match the page is on, when the engine reports it (Chromium): "2 of 5".
    func setStatus(found: Bool?, matches: Int?, active: Int? = nil) {
        switch (found, matches) {
        case (nil, _): status.stringValue = ""
        case (false?, _): status.stringValue = "No matches"
        case (true?, let n?):
            if let active, active > 0 { status.stringValue = "\(active) of \(n)" }
            else { status.stringValue = n == 1 ? "1 match" : "\(n) matches" }
        case (true?, nil): status.stringValue = ""
        }
    }

    var statusText: String { status.stringValue }

    func find(forward: Bool) { onFind?(field.stringValue, forward) }

    @objc private func changed() { find(forward: true) }

    #if canImport(AircCore)
    /// Chromium reports which match is active as the page moves between them: the bar of the window showing that
    /// page (the main window or a private one) shows "2 of 5".
    static func routeFindState(_ tab: EngineTab, _ state: [String: Any]) {
        let c = (NSApp.delegate as? AppDelegate)?.controller
        let bar = c.flatMap { c in c.shownTabID.flatMap { c.engineTab(for: $0) } === tab ? c.findBar : nil }
            ?? PrivateBrowsing.shared.windows.first { $0.shownPage === tab }?.findBar
        guard let bar, (state["text"] as? String) == bar.field.stringValue else { return }
        let matches = (state["matches"] as? NSNumber)?.intValue ?? 0
        let active = (state["active"] as? NSNumber)?.intValue ?? 0
        bar.setStatus(found: matches > 0, matches: matches, active: active)
    }
    #endif

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            find(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        default:
            return false
        }
    }
}

extension WindowController {
    /// ⌘F: opens (or focuses) the find field over the page.
    func showFind() {
        guard let id = shownTabID, engineTab(for: id) != nil else { return NSSound.beep() }
        Telemetry.shared.record(.featureUsed(.find))
        if let bar = findBar {
            window.makeFirstResponder(bar.field)
            bar.field.currentEditor()?.selectAll(nil)
            return
        }
        let bar = FindBarView(palette: currentPalette)
        bar.onFind = { [weak self] text, forward in self?.find(text, forward: forward) }
        #if canImport(AircCore)
        (app?.engine as? ChromiumEngine)?.findStateDidChange = FindBarView.routeFindState
        #endif
        bar.onClose = { [weak self] in self?.closeFind(refocusPage: true) }
        findBar = bar
        root.addSubview(bar, positioned: .below, relativeTo: toast)
        layoutFindBar()
        bar.layer?.fade(from: 0, to: 1, duration: 0.12)
        window.makeFirstResponder(bar.field)
    }

    func layoutFindBar() {
        guard let bar = findBar else { return }
        let s = FindBarView.size
        // SV-1: over the focused pane, which it searches.
        var page = card.frame
        if shownSplitID != nil, let id = shownTabID, let pane = splitContainer.pane(for: id) {
            page = splitContainer.convert(pane.frame, to: root)
        }
        bar.frame = NSRect(x: page.maxX - s.width - 12, y: page.minY + 12, width: s.width, height: s.height)
    }

    /// ⌘G / ⇧⌘G.
    func findAgain(forward: Bool) {
        guard let bar = findBar, !bar.field.stringValue.isEmpty else { return showFind() }
        bar.find(forward: forward)
    }

    private func find(_ text: String, forward: Bool) {
        guard let id = shownTabID, let page = engineTab(for: id) else { return }
        guard !text.isEmpty else {
            page.stopFinding()
            findBar?.setStatus(found: nil, matches: nil)
            return
        }
        page.find(text, forward: forward) { [weak self] found, matches in self?.findBar?.setStatus(found: found, matches: matches) }
    }

    /// Esc, the ✕, or another tab shown.
    func closeFind(refocusPage: Bool) {
        guard let bar = findBar else { return }
        findBar = nil
        if let id = shownTabID, let page = engineTab(for: id) {
            page.stopFinding()
            if refocusPage { page.focus() }
        }
        bar.layer?.fade(from: 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bar.removeFromSuperview() }
    }

    // MARK: Chrome's page commands (CB-2)

    private var shownPage: EngineTab? { shownTabID.flatMap { engineTab(for: $0) } }

    func reloadIgnoringCache() { shownPage?.reloadIgnoringCache() }

    func zoom(step: Int) {
        guard let page = shownPage else { return }
        page.zoom(step: step)
        showToast(String(format: "%.0f %%", page.zoomFactor * 100))
    }

    func showDevTools(console: Bool) {
        guard let page = shownPage else { return }
        if !page.showDevTools(console: console) {
            showToast("Right-click the page and choose Inspect Element")
        }
    }

    func viewSource() {
        guard let url = shownPage?.url, url.scheme == "http" || url.scheme == "https" else { return NSSound.beep() }
        if app?.engine.name.hasPrefix("Chromium") == true, let source = URL(string: "view-source:" + url.absoluteString) {
            navigate(to: source, newTab: true)
        } else {
            showToast("View Source needs the Chromium engine")
        }
    }

    func printPage() {
        guard let page = shownPage else { return NSSound.beep() }
        if !page.printPage(from: window) { showToast("Printing isn't available in this engine yet") }
    }

    /// ⌘Y: Chromium's history page; the Command Bar's history on the dev engine.
    func showHistory() {
        if app?.engine.name.hasPrefix("Chromium") == true, let url = URL(string: "chrome://history") {
            navigate(to: url, newTab: true)
        } else {
            openCommandBar(mode: .newTab)
        }
    }
}
