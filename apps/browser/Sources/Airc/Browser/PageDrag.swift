// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// W07: the window drags from the top of the page, as Arc's does (2023: "You can now drag the Arc window from the top
/// bar of webpages themselves. Toggle this off in Preferences or opt out temporarily by holding CMD"; its setting
/// "Allow window dragging from the top of webpages", on by default).
///   - The strip is the page's part of the window's title-bar band: the window server's 28 pt at the top, less the
///     card's 10 pt margin, so about 18 pt of the page. Arc doesn't say how tall its strip is; this one ends where a
///     standard title bar would. With the toolbar shown, in full screen or with the setting off the card doesn't reach
///     the band, or the strip stands aside.
///   - A press that moves 3 pt drags the window (`performDrag`); the page never sees it. A click (press and release in
///     place) goes to the page as if the strip weren't there: links, buttons and fields work. A window that wasn't key
///     only becomes key, as AppKit does for a page that takes no first click.
///   - A double-click does what the system's "Double-click a window's title bar" says (AppleActionOnDoubleClick: zoom
///     for Zoom and Fill, minimize, or nothing).
///   - ⌘ held (Arc's opt-out), or another modifier: the page has the press, for selecting text, dragging a link out of
///     the strip, ⇧-click or ⌃-click. Right and middle presses, scrolling, hovering and drops always reach the page.
/// Below the strip the page is untouched. The window's margin and the sidebar's empty top area drag as before (the
/// window server, in the band no view claims).
final class PageTopDragStrip: NSView {
    /// The page the strip lies over: a click goes to its view under the pointer.
    weak var page: NSView?
    /// Pressed this far, it's a window drag.
    static let dragDistance: CGFloat = 3
    /// How far down the page the strip's view reaches; only its part in the title-bar band acts (`activeRect`).
    static let height: CGFloat = 40

    /// The strip over the top of `container`'s page, added above it (`page` is set when the page view is embedded).
    static func install(in container: NSView) -> PageTopDragStrip {
        let s = PageTopDragStrip(frame: NSRect(x: 0, y: container.isFlipped ? 0 : container.bounds.height - height,
                                               width: container.bounds.width, height: height))
        s.autoresizingMask = container.isFlipped ? [.width, .maxYMargin] : [.width, .minYMargin]
        container.addSubview(s)
        return s
    }

    #if AIRC_TESTING
    /// For the checks: what a drag or a double-click would do, instead of moving the owner's window, and the double-click
    /// setting and full screen as a check sets them.
    static var dragOverride: ((NSWindow, NSEvent) -> Void)?
    static var doubleClickOverride: ((NSWindow, String) -> Void)?
    static var doubleClickSetting: String?
    static var fullScreenOverride: Bool?
    /// What the strip did with the last press: "drag", "click → <view>", "first click only", "double-click: <action>".
    static var last: String?
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The window server mustn't drag the window from here itself: the strip decides (a click is the page's).
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The part of the strip in the window's title-bar band, in the strip's coordinates (empty when it's off).
    var activeRect: NSRect {
        guard let w = window, isOn(in: w) else { return .zero }
        let band = convert(NSRect(x: 0, y: w.contentLayoutRect.maxY, width: w.frame.width, height: w.frame.height - w.contentLayoutRect.maxY), from: nil)
        return bounds.intersection(band)
    }

    private func isOn(in w: NSWindow) -> Bool {
        guard !isHiddenOrHasHiddenAncestor, page?.isHiddenOrHasHiddenAncestor == false else { return false }
        #if AIRC_TESTING
        if let fs = Self.fullScreenOverride { if fs { return false } } else if w.styleMask.contains(.fullScreen) { return false }
        #else
        if w.styleMask.contains(.fullScreen) { return false }
        #endif
        guard let app = NSApp.delegate as? AppDelegate, app.settings.values.dragsWindowFromPageTop else { return false }
        // Main windows only, with the toolbar hidden (with it, the toolbar is the window's top).
        guard let c = app.controller(for: w) else { return false }
        return c.pageToolbar == nil
    }

    /// Only a plain left press in the band; everything else (⌘, other buttons, scrolling, hovering, drags arriving) goes
    /// on to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let e = NSApp.currentEvent, e.type == .leftMouseDown,
              e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
        let p = convert(point, from: superview)
        return activeRect.contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        if event.clickCount >= 2 { return titleBarDoubleClick(w) }
        let wasKey = w.isKeyWindow
        let start = event.locationInWindow
        // (A release always comes; the limit only keeps a lost one from holding the app.)
        while let next = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(timeIntervalSinceNow: 10), inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { return click(event, up: next, wasKey: wasKey) }
            let p = next.locationInWindow
            if hypot(p.x - start.x, p.y - start.y) >= Self.dragDistance { return drag(w, event) }
        }
    }

    private func drag(_ w: NSWindow, _ press: NSEvent) {
        #if AIRC_TESTING
        Self.last = "drag"
        if let o = Self.dragOverride { return o(w, press) }
        #endif
        w.performDrag(with: press)
    }

    /// The page's view under the press gets it, down and up, as AppKit would have sent them; a window that wasn't key
    /// passes the first click on only to a view that takes first clicks.
    private func click(_ down: NSEvent, up: NSEvent, wasKey: Bool) {
        guard let page, let target = page.hitTest(page.superview?.convert(down.locationInWindow, from: nil) ?? .zero) else { return }
        guard wasKey || target.acceptsFirstMouse(for: down) else {
            #if AIRC_TESTING
            Self.last = "first click only"
            #endif
            return
        }
        #if AIRC_TESTING
        Self.last = "click → " + String(describing: type(of: target))
        #endif
        target.mouseDown(with: down)
        target.mouseUp(with: up)
    }

    /// System Settings → Desktop & Dock → "Double-click a window's title bar to": Fill, Zoom, Minimize or Do Nothing.
    static var doubleClickAction: String {
        #if AIRC_TESTING
        if let s = doubleClickSetting { return s }
        #endif
        let d = UserDefaults.standard
        if let s = d.string(forKey: "AppleActionOnDoubleClick") { return s }
        return d.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize"
    }

    private func titleBarDoubleClick(_ w: NSWindow) {
        let action = Self.doubleClickAction
        #if AIRC_TESTING
        Self.last = "double-click: " + action
        if let o = Self.doubleClickOverride { return o(w, action) }
        #endif
        switch action {
        case "Minimize": w.miniaturize(nil)
        case "None": break
        default: w.zoom(nil)   // Maximize (Zoom) and Fill: the screen's visible frame, and back
        }
    }
}
