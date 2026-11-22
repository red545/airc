// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// Which Airc Agent UI a window uses: the in-window pane (docs/design/agent-ux.md §3) or the old child panel
/// (Agent/Panel/AgentPanel.swift). Every entry point (⌥⌘A, ⇧⌥⌘A, the Command Bar's "Ask Airc to…") goes through here.
enum AgentUI {
    /// The pane, unless a test build asks for the old panel (`--agent-old-panel` / AIRC_AGENT_OLD_PANEL=1).
    static var usesPane: Bool {
        #if AIRC_TESTING
        if let forced = forcedForTesting { return forced }
        let env = ProcessInfo.processInfo.environment
        if CommandLine.arguments.contains("--agent-old-panel") || env["AIRC_AGENT_OLD_PANEL"] == "1" { return false }
        #endif
        return paneIsDefault
    }

    /// The pane is the Airc Agent's UI (agentux step 2); the old panel stays only behind the test-only switch above.
    static var paneIsDefault: Bool { true }

    #if AIRC_TESTING
    /// Checks switch between the two in one run.
    static var forcedForTesting: Bool?
    #endif

    /// ⌥⌘A.
    static func toggle(_ c: WindowController) {
        if usesPane { AgentPaneController.toggle(c) } else { AgentPanelController.toggle(c) }
    }

    /// ⇧⌥⌘A: the pane on a new, empty task.
    static func newTask(_ c: WindowController) {
        guard usesPane else { return AgentPanelController.toggle(c) }
        AgentPaneController.show(c).newTask()
    }

    /// The Command Bar's "Ask Airc to…": ↩ opens the pane and starts the task.
    static func ask(_ c: WindowController, _ text: String) {
        if usesPane { AgentPaneController.show(c).ask(text) } else { AgentPanelController.show(c).ask(text) }
    }

    /// Closes the window's agent UI, either kind.
    static func close(_ c: WindowController) {
        AgentPaneController.pane(of: c)?.close()
        AgentPanelController.panel(of: c)?.close()
    }

    #if AIRC_TESTING
    /// What waits in the agent UI's field (cbflicker: the Command Bar's task, kept while nothing is connected).
    static func draftForTesting(_ c: WindowController) -> String? {
        if let p = AgentPaneController.pane(of: c), p.isShown { return p.model.text }
        return AgentPanelController.panel(of: c)?.draftForTesting
    }
    #endif

    /// Whether the window shows its agent UI now (either kind).
    static func isShown(_ c: WindowController) -> Bool {
        AgentPaneController.pane(of: c)?.isShown == true || AgentPanelController.panel(of: c) != nil
    }
}

/// The agent pane of one browser window: a card in the content area beside the page, on the side away from the sidebar
/// (docs/design/agent-ux.md §3, M1). Open/closed is per window and Space; the width is per window (and remembered as
/// the default for new ones). Nothing exists until the pane first opens, and closing it removes its views, so a window
/// that never opens it pays nothing.
final class AgentPaneController: NSObject {
    private static var panes: [ObjectIdentifier: AgentPaneController] = [:]
    static let defaultWidth: CGFloat = 400
    /// The pane opened or closed in some window (the sidebar's Airc Agent button follows it).
    static let visibilityChanged = Notification.Name("AircAgentPaneVisibilityChanged")
    static let minWidth: CGFloat = 340
    static let maxWidth: CGFloat = 560
    /// Below this window width the pane overlays the page instead of squeezing it.
    static let overlayBelow: CGFloat = 900
    static let widthKey = "AircAgentPaneWidth"

    weak var controller: WindowController?
    let model: AgentPaneModel
    private(set) var card: AgentPaneCardView?
    private var openSpaces: Set<String> = []
    var width: CGFloat
    /// The pane covers the page (a narrow window) rather than sitting beside it.
    private(set) var overlays = false

    static func pane(of c: WindowController) -> AgentPaneController? { panes[ObjectIdentifier(c)] }

    /// Open in the window's current Space.
    var isShown: Bool { card != nil && controller.map { openSpaces.contains($0.currentSpaceID) } == true }

    static func toggle(_ c: WindowController) {
        if let p = pane(of: c), p.isShown { p.close() } else { show(c) }
    }

    @discardableResult
    static func show(_ c: WindowController) -> AgentPaneController {
        let p = panes[ObjectIdentifier(c)] ?? {
            let p = AgentPaneController(c)
            panes[ObjectIdentifier(c)] = p
            return p
        }()
        p.open()
        return p
    }

    private init(_ c: WindowController) {
        controller = c
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        width = saved >= Self.minWidth && saved <= Self.maxWidth ? CGFloat(saved) : Self.defaultWidth
        model = AgentPaneModel()
        _ = AgentTaskRecorder.shared
        super.init()
        model.pane = self
        let key = ObjectIdentifier(c)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: c.window, queue: .main) { [weak self] _ in
            self?.teardown()
            Self.panes[key] = nil
        }
    }

    private var closeObserver: NSObjectProtocol?
    deinit { closeObserver.map(NotificationCenter.default.removeObserver) }

    // MARK: Open, close

    func open() {
        guard let c = controller else { return }
        let fresh = !isShown
        Perf.time("agentpane.open") {
            openSpaces.insert(c.currentSpaceID)
            if card == nil { install(c) }
            model.windowOpened(from: c)
            c.layoutRoot()
            card?.isHidden = false
        }
        if fresh, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { card?.layer?.fade(from: 0, to: 1, duration: 0.16) }
        focus()
        NotificationCenter.default.post(name: Self.visibilityChanged, object: c)
    }

    func close() {
        guard let c = controller else { return }
        openSpaces.remove(c.currentSpaceID)
        teardown()
        c.layoutRoot()
        if c.window.firstResponder == nil || c.window.firstResponder === c.window { c.focusShownPage() }
        NotificationCenter.default.post(name: Self.visibilityChanged, object: c)
    }

    /// A Space switch: the pane shows if it was open in that Space.
    func spaceChanged() {
        guard let c = controller else { return }
        if openSpaces.contains(c.currentSpaceID) {
            if card == nil { install(c) }
            card?.isHidden = false
            model.windowOpened(from: c)
            c.layoutRoot()
        } else if card != nil {
            teardown()
            c.layoutRoot()
        }
        NotificationCenter.default.post(name: Self.visibilityChanged, object: c)
    }

    private func install(_ c: WindowController) {
        let v = AgentPaneCardView(pane: self, theme: c.promptTheme)
        c.root.addSubview(v, positioned: .above, relativeTo: c.card)
        card = v
    }

    private func teardown() {
        model.paneHidden()
        card?.removeFromSuperview()
        card = nil
    }

    func newTask() {
        model.newTask()
        focus()
    }

    /// The Command Bar's task: sent now if the agent is free and connected, else kept in the field.
    func ask(_ text: String) {
        model.ask(text)
        focus()
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in self?.card?.focusField() }
    }

    /// agentux3: a "needs you" click landed here (AgentAttention): the keys go to the approval card, its Allow once
    /// drawn as the default button; Return allows once, Esc denies, typing goes to the composer (sending = Deny + text).
    func focusApproval() {
        guard let id = AgentRunCenter.shared.approval?.id else { return }
        model.approvalFocused = true
        // Again for a moment (a Space switch or a closing Watch hands the keys to the page a little later), but never
        // after the person clicked or typed anywhere in Airc (AgentAttention.LandingFocus): a Return meant for a page
        // field must never allow, and a pane the person closed stays closed.
        AgentAttention.LandingFocus.run { [weak self] delay in
            guard let self, AgentRunCenter.shared.approval?.id == id else { return }
            if !self.isShown {
                guard delay == 0 else { return }
                self.open()
            }
            guard let card = self.card, let w = card.window, w.firstResponder !== card else { return }
            let had = w.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            card.approvalKeys = true
            self.model.approvalFocused = true
            let ok = w.makeFirstResponder(card)
            if !ok { card.approvalKeys = false; self.model.approvalFocused = false }
            AgentCenter.shared.onEvent?("focus-approval +\(delay) s: shown \(self.isShown), had \(had), took \(ok)")
        }
    }

    // MARK: Layout

    /// Called from WindowController.layoutRoot with the page's frame; returns the page's frame with the pane taken out.
    static func layout(_ c: WindowController, page: NSRect) -> NSRect {
        guard let p = pane(of: c), p.isShown, let card = p.card else { return page }
        return p.layout(card, page: page, in: c)
    }

    private func layout(_ card: AgentPaneCardView, page: NSRect, in c: WindowController) -> NSRect {
        let gap = AircMetrics.Window.cardInset
        let w = clampedWidth(for: page.width)
        overlays = c.root.bounds.width < Self.overlayBelow
        // The side away from the sidebar.
        let onLeft = c.sidebarOnRight
        let x = onLeft ? page.minX : page.maxX - w
        card.frame = NSRect(x: x, y: page.minY, width: w, height: page.height)
        card.onLeft = onLeft
        card.overlays = overlays
        let theme = c.promptTheme
        if card.theme != theme { card.theme = theme }
        if overlays { return page }
        var rest = page
        rest.size.width = max(0, page.width - w - gap)
        if onLeft { rest.origin.x = page.minX + w + gap }
        return rest
    }

    func clampedWidth(for available: CGFloat) -> CGFloat {
        let cap = max(Self.minWidth, min(Self.maxWidth, (available * 0.45).rounded()))
        return min(cap, max(Self.minWidth, width))
    }

    /// Dragging the inner edge.
    func resize(to w: CGFloat) {
        width = min(Self.maxWidth, max(Self.minWidth, w.rounded()))
        UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
        controller?.layoutRoot()
    }

    func resetWidth() { resize(to: Self.defaultWidth) }

    /// Esc in the pane: deny a waiting approval, else Stop on a second Esc while running, else close.
    func escape() {
        let run = AgentRunCenter.shared
        if run.approval != nil { return run.answerApproval(allow: false) }
        if run.state.isActive {
            if model.armedStop { model.armedStop = false; return run.stop() }
            model.armedStop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.model.armedStop = false }
            return
        }
        close()
    }

    /// The Space's profile the agent acts in.
    func profile() -> (id: String, name: String)? {
        guard let c = controller else { return nil }
        let p = c.store.profile(ofSpace: c.currentSpaceID)
        return (p.id, p.name)
    }
}

/// The pane's card: the page card's shadow, corner and hairline (AircPageCardView) around the SwiftUI pane, with a
/// resize handle on its inner edge.
final class AgentPaneCardView: NSView {
    weak var pane: AgentPaneController?
    private let edge: AircPageCardView
    private let host: NSHostingView<AgentPaneRoot>
    private let handle = AgentPaneResizeHandle()
    var onLeft = false { didSet { if onLeft != oldValue { needsLayout = true } } }
    var overlays = false
    var theme: ResolvedTheme {
        didSet {
            edge.theme = theme
            appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            pane?.model.theme = theme
        }
    }

    init(pane: AgentPaneController, theme: ResolvedTheme) {
        self.pane = pane
        self.theme = theme
        edge = AircPageCardView(theme: theme)
        host = NSHostingView(rootView: AgentPaneRoot(model: pane.model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        pane.model.theme = theme
        edge.frame = bounds
        edge.autoresizingMask = [.width, .height]
        addSubview(edge)
        host.safeAreaRegions = []
        edge.contentView = host
        handle.onDrag = { [weak self] dx in self?.drag(dx) }
        handle.onReset = { [weak self] in self?.pane?.resetWidth() }
        addSubview(handle)
        setAccessibilityElement(false)
        setAccessibilityLabel("Airc Agent")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // The inner edge: the one facing the page.
        handle.frame = NSRect(x: onLeft ? bounds.maxX - 4 : -4, y: 0, width: 8, height: bounds.height)
    }

    private var dragStartWidth: CGFloat = 0
    private func drag(_ dx: CGFloat?) {
        guard let pane else { return }
        guard let dx else { dragStartWidth = frame.width; return }
        // Dragging the inner edge toward the page widens the pane.
        pane.resize(to: dragStartWidth + (onLeft ? dx : -dx))
    }

    override func cancelOperation(_ sender: Any?) { pane?.escape() }

    /// The approval card has the keys (AgentPaneController.focusApproval).
    var approvalKeys = false
    override var acceptsFirstResponder: Bool { approvalKeys }

    override func keyDown(with event: NSEvent) {
        guard approvalKeys, AgentRunCenter.shared.approval != nil else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 36, 76: AgentRunCenter.shared.answerApproval(allow: true)    // Return, Enter
        case 53: AgentRunCenter.shared.answerApproval(allow: false)       // Esc
        default:
            // Typing: into the composer, as if it had the keys.
            focusField()
            if let field = window?.firstResponder as? NSView, field !== self { field.keyDown(with: event) }
        }
    }

    override func resignFirstResponder() -> Bool {
        if approvalKeys { AgentCenter.shared.onEvent?("focus-approval: the card gave up the keys") }
        approvalKeys = false
        if pane?.model.approvalFocused == true { pane?.model.approvalFocused = false }
        return true
    }

    func focusField() {
        guard let w = window, let field = Self.findField(in: host) else { return }
        w.makeFirstResponder(field)
        if let tv = w.firstResponder as? NSTextView { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
    }

    private static func findField(in v: NSView) -> NSView? {
        if v is NSTextView || v is NSTextField, v.acceptsFirstResponder { return v }
        for s in v.subviews { if let f = findField(in: s) { return f } }
        return nil
    }

    #if AIRC_TESTING
    var hostingView: NSView { host }
    #endif
}

/// The pane's inner edge: drag to resize (340–560 pt), double-click to reset to 400 pt.
final class AgentPaneResizeHandle: NSView {
    /// nil at the press, then the drag's x offset from it.
    var onDrag: ((CGFloat?) -> Void)?
    var onReset: (() -> Void)?
    private var start: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return onReset?() ?? () }
        start = event.locationInWindow.x
        onDrag?(nil)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x - start) }
}
