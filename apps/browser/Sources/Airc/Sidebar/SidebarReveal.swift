// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// SB-61: with the sidebar hidden, holding the pointer at the window's left edge slides a floating
/// sidebar over the page (spring 0.175 s, ζ 0.8). It leaves when the pointer moves ~22 pt past it.
final class SidebarRevealController {
    private weak var controller: WindowController?
    private let edge = EdgeView()
    private let floating = NSView()
    private let floatingBackground = ThemeBackgroundView(theme: DesignTheme.default.resolved(systemIsDark: false))
    private(set) var isRevealed = false
    private var pending: DispatchWorkItem?
    private var monitor: Any?
    private var offset: CGFloat = 0   // 0 = shown, 1 = off to the left

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
        controller.root.addSubview(floating)
        edge.onMove = { [weak self] in self?.armReveal() }
        edge.onExit = { [weak self] in self?.pending?.cancel() }
    }

    func layout() {
        guard let c = controller else { return }
        let b = c.root.bounds
        edge.frame = NSRect(x: 0, y: 0, width: DesignGaps.revealEdge, height: b.height)
        edge.isHidden = !(c.sidebarHidden && c.sidebarFraction <= 0.001)
        let w = c.sidebarWidth
        let x = AircMetrics.Sidebar.floatingInset - (w + AircMetrics.Sidebar.floatingInset + 4) * offset
        floating.frame = NSRect(x: x, y: AircMetrics.Sidebar.floatingInset, width: w, height: b.height - 2 * AircMetrics.Sidebar.floatingInset)
        floatingBackground.frame = floating.bounds
        if isRevealed { c.sidebar.frame = floating.bounds }
    }

    private func armReveal() {
        guard let c = controller, c.sidebarHidden, !isRevealed, pending == nil || pending!.isCancelled else { return }
        let work = DispatchWorkItem { [weak self] in self?.reveal() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignGaps.revealDelay, execute: work)
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
        if p.x > floating.frame.maxX + AircMetrics.Sidebar.floatingKeepAlive { hide() }
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

/// The sidebar's right edge: drag to resize (164–500), past the minimum hides it, double-click resets (WIN-4).
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
            let w = startWidth + (e.locationInWindow.x - startX)
            if w < AircMetrics.Sidebar.minWidth - 40 {
                if !c.sidebarHidden { c.toggleSidebar() }
                break
            }
            c.setSidebarWidth(w)
        }
    }
}
