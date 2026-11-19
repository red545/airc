// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign

/// WIN-8 (winclose): with the sidebar hidden (⌘S), the window's top-left corner (the traffic lights' row, up to where
/// the sidebar toggle would start) shows the traffic lights while the pointer is in it, over the page, so a window
/// without its sidebar (a tab dragged out of a sidebar-hidden window, say) can still be closed, minimised or zoomed with
/// the mouse. The strip takes no clicks: the lights themselves are AppKit's, above the content, and the page under it
/// keeps its own clicks while they're hidden. It works with the window in the background too, like the lights do.
final class TrafficLightHoverZone {
    private weak var controller: WindowController?
    private let strip = Strip()
    private(set) var isInside = false

    final class Strip: NSView {
        var onChange: ((Bool) -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    init(controller: WindowController) {
        self.controller = controller
        strip.isHidden = true
        controller.root.addSubview(strip)
        strip.onChange = { [weak self] inside in self?.set(inside) }
    }

    /// The traffic lights' row: from the window's left edge to just before the sidebar toggle, 44 pt down (plus the
    /// revealed sidebar's inset the lights move by, WindowController.trafficLightInset).
    func layout() {
        guard let c = controller else { return }
        let b = c.root.bounds
        let inset = c.trafficLightInset
        let height = AircMetrics.Window.trafficLightCenters[0].y * 2 - 4 + inset
        let width = AircMetrics.Sidebar.toggleX + inset
        let frame = NSRect(x: 0, y: c.root.isFlipped ? 0 : b.height - height, width: width, height: height)
        if strip.frame != frame { strip.frame = frame }
        let active = c.sidebarHidden && c.sidebarFraction <= 0.001 && !c.isFullscreen
        if strip.isHidden == active { strip.isHidden = !active }
        if !active, isInside { set(false) }
    }

    private func set(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside && !strip.isHidden
        controller?.positionTrafficLights()
    }

    #if AIRC_TESTING
    /// WinCloseCheck.swift: the strip in the root view's coordinates (zero while it's off).
    var testFrame: NSRect { strip.isHidden ? .zero : strip.frame }
    #endif
}
