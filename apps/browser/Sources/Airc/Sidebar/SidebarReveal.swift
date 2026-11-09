// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// SB-61: with the sidebar hidden, holding the pointer at the window's left edge (the right one with the sidebar on the
/// right, WIN-5) slides a floating sidebar over the page (spring 0.175 s, ζ 0.8). It leaves when the pointer moves
/// ~22 pt past it.
final class SidebarRevealController {
    private weak var controller: WindowController?
    private let edge = EdgeView()
    private let floating = NSView()
    private let floatingBackground = ThemeBackgroundView(theme: DesignTheme.default.resolved(systemIsDark: false))
    private(set) var isRevealed = false
    private var pending: DispatchWorkItem?
    private var monitor: Any?
    private var offset: CGFloat = 0   // 0 = shown, 1 = off to the side it comes from
    /// Menus being tracked now (the main menu, a context menu, a pop-up button's).
    private var menusOpen = 0
    private var menuObservers: [NSObjectProtocol] = []
    #if AIRC_TESTING
    /// The checks (SidebarRightCheck.swift): the strip that reveals, and the floating panel, in the root view.
    var edgeFrame: NSRect { edge.isHidden ? .zero : edge.frame }
    var floatingFrame: NSRect { floating.frame }
    /// The snapshots draw it over the page's picture while it's out.
    var floatingView: NSView? { isRevealed ? floating : nil }
    /// SidebarPolishCheck.swift: the strip itself (its mouseMoved is what arms the dwell), stand-ins for what a scripted
    /// run can't make real (it's never the key window, and the pointer is the owner's), and each dwell's verdict.
    var edgeView: NSView { edge }
    var testConditions: ((inout SidebarRevealGate.Conditions) -> Void)?
    private(set) var dwellVerdicts: [SidebarRevealGate.Refusal?] = []
    var isDwelling: Bool { pending.map { !$0.isCancelled } ?? false }
    #endif

    final class EdgeView: NSView {
        var onMove: (() -> Void)?
        var onExit: (() -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
        // Only a pointer that moves inside the strip reveals (a jump there does nothing).
        override func mouseMoved(with event: NSEvent) { onMove?() }
        override func mouseExited(with event: NSEvent) { onExit?() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(controller: WindowController) {
        self.controller = controller
        controller.root.addSubview(edge)
        floating.wantsLayer = true
        floating.layer?.cornerRadius = AircMetrics.Sidebar.floatingRadius
        floating.layer?.cornerCurve = .continuous
        floating.layer?.masksToBounds = true
        floating.layer?.borderWidth = 0.5
        floating.addSubview(floatingBackground)
        floating.isHidden = true
        // Below the toast, like the docked sidebar: the cards and panels that go just below the toast (the downloads card,
        // the update question, a page's prompt at the URL field, Site Controls) show over the revealed sidebar, not under it.
        if controller.toast.superview === controller.root {
            controller.root.addSubview(floating, positioned: .below, relativeTo: controller.toast)
        } else {
            controller.root.addSubview(floating)
        }
        edge.onMove = { [weak self] in self?.armReveal() }
        edge.onExit = { [weak self] in self?.pending?.cancel() }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menusOpen += 1
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.menusOpen = max(0, self.menusOpen - 1)
            },
        ]
    }

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        // A window closed while its sidebar was revealed: its pointer monitor goes too.
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func layout() {
        guard let c = controller else { return }
        let b = c.root.bounds
        edge.frame = c.mirroredForSidebar(NSRect(x: 0, y: 0, width: DesignGaps.revealEdge, height: b.height))
        edge.isHidden = !(c.sidebarHidden && c.sidebarFraction <= 0.001)
        let w = c.sidebarWidth
        let x = AircMetrics.Sidebar.floatingInset - (w + AircMetrics.Sidebar.floatingInset + 4) * offset
        floating.frame = c.mirroredForSidebar(NSRect(x: x, y: AircMetrics.Sidebar.floatingInset, width: w,
                                                     height: b.height - 2 * AircMetrics.Sidebar.floatingInset))
        floatingBackground.frame = floating.bounds
        if isRevealed { c.sidebar.frame = floating.bounds }
        // The downloads card and the update question sit above the sidebar's footer while it shows, this one too: they
        // follow it in and out.
        MediaLibrary.shared.layoutPrompts()
        UpdateCenter.shared.confirm?.layoutInWindow()
    }

    private func armReveal() {
        guard let c = controller, c.sidebarHidden, !isRevealed, pending == nil || pending!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in self?.dwellEnded() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignGaps.revealDelay, execute: work)
    }

    /// The dwell is over: reveal only if what started it still holds (SB-61). The window may have lost key, the pointer
    /// may have left without an exit event (a jump, a window on top), ⌘S may have shown the sidebar, a sheet or menu
    /// may have come up, or a press may have turned into a drag.
    private func dwellEnded() {
        pending = nil
        guard let c = controller else { return }
        let p = c.root.convert(c.window.mouseLocationOutsideOfEventStream, from: nil)
        let now = SidebarRevealGate.Conditions(
            windowIsKey: c.window.isKeyWindow,
            sidebarHidden: c.sidebarHidden && c.sidebarFraction <= 0.001,
            alreadyRevealed: isRevealed,
            pointerInStrip: !edge.isHidden && edge.frame.insetBy(dx: -1, dy: 0).contains(p),
            sheetOrModal: c.window.attachedSheet != nil || NSApp.modalWindow != nil,
            menuOpen: menusOpen > 0,
            mouseButtonDown: NSEvent.pressedMouseButtons != 0)
        #if AIRC_TESTING
        var conditions = now
        testConditions?(&conditions)
        let refusal = SidebarRevealGate.refusal(conditions)
        dwellVerdicts.append(refusal)
        #else
        let refusal = SidebarRevealGate.refusal(now)
        #endif
        if refusal == nil { reveal() }
    }

    func reveal() {
        guard let c = controller, !isRevealed else { return }
        pending = nil
        isRevealed = true
        let space = c.store.space(c.currentSpaceID) ?? c.store.selectedSpace
        floatingBackground.show(c.palette(for: space).resolved)
        floating.layer?.borderColor = c.palette(for: space).separator.cgColor
        floating.isHidden = false
        c.sidebar.removeFromSuperview()
        floating.addSubview(c.sidebar)
        offset = 1
        layout()
        c.positionTrafficLights()
        c.sidebar.animatorSpring(from: 1, to: 0, spring: Spring(AircSpring.reveal)) { [weak self] v in
            self?.offset = CGFloat(v)
            self?.layout()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in
            self?.pointerMoved(e)
            return e
        }
    }

    private func pointerMoved(_ e: NSEvent) {
        guard let c = controller, isRevealed, e.window === c.window else { return }
        let p = c.root.convert(e.locationInWindow, from: nil)
        // The downloads card is wider than a narrow sidebar: the pointer on it (or on the update question) keeps it out.
        let cards = [MediaLibrary.shared.promptView as NSView?, UpdateCenter.shared.confirm as NSView?].compactMap { $0 }
        let away = c.sidebarOnRight ? p.x < floating.frame.minX - AircMetrics.Sidebar.floatingKeepAlive
            : p.x > floating.frame.maxX + AircMetrics.Sidebar.floatingKeepAlive
        if away, !cards.contains(where: { $0.superview === c.root && $0.frame.contains(p) }) { hide() }
    }

    func hide() {
        guard let c = controller, isRevealed else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        c.sidebar.animatorSpring(from: Double(offset), to: 1, spring: Spring(AircSpring.conceal)) { [weak self] v in
            self?.offset = CGFloat(v)
            self?.layout()
        } completion: { [weak self] in
            self?.finish()
        }
    }

    /// ⌘S while revealed docks at once (Arc ref §2.10).
    func dock() {
        guard let c = controller, isRevealed else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finish()
        c.sidebarHidden = false
        c.sidebarFraction = 1
        c.store.updateWindowState { $0.sidebarHidden = false }
        c.layoutRoot()
        c.positionTrafficLights()
    }

    private func finish() {
        guard let c = controller else { return }
        isRevealed = false
        floating.isHidden = true
        c.sidebar.removeFromSuperview()
        c.root.addSubview(c.sidebar, positioned: .below, relativeTo: c.toast)
        c.layoutRoot()
        c.positionTrafficLights()
    }
}

extension NSView {
    /// A one-off spring on a value, driven per frame.
    func animatorSpring(from: Double, to: Double, spring: Spring, update: @escaping (Double) -> Void,
                        completion: (() -> Void)? = nil) {
        let a = FrameAnimator(view: self)
        objc_setAssociatedObject(self, &animatorKey, a, .OBJC_ASSOCIATION_RETAIN)
        a.spring("v", from: from, to: to, spring: spring, epsilon: 0.002, update: update, completion: completion)
    }
}

private var animatorKey = 0

/// The sidebar's inner edge (its right one, its left one with the sidebar on the right): drag to resize (164–500), past
/// the minimum hides it (as soon as the drag goes below it, as in Arc), double-click resets (WIN-4).
final class SidebarResizeHandle: NSView {
    weak var controller: WindowController?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller, let window else { return }
        if event.clickCount == 2 {
            c.setSidebarWidth(AircMetrics.Sidebar.defaultWidth)
            return
        }
        let startX = event.locationInWindow.x
        let startWidth = c.sidebarWidth
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let w = startWidth + (e.locationInWindow.x - startX) * (c.sidebarOnRight ? -1 : 1)
            if SidebarResize.hides(proposedWidth: Double(w), minWidth: Double(AircMetrics.Sidebar.minWidth)) {
                if !c.sidebarHidden { c.toggleSidebar() }
                break
            }
            c.setSidebarWidth(w)
        }
    }
}
