// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
#if canImport(AircCore)
import AircCore

/// Docked DevTools, the way Chrome's DevtoolsUIController and ContentsContainerView dock them into a browser window:
/// the frontend's WebContents fills the page's host (the card, a split pane, Little Airc's page), and the page sits on
/// top of it at the bounds the frontend asks for (DevToolsContentsResizingStrategy, read with
/// `devToolsLayout(for:devTools:page:)`). So the frontend draws its own splitter, its ⋮ › Dock side menu and ⌘⇧D, and
/// keeps its side and size in the profile's DevTools preferences, as in Chrome. Undocked, it's Chrome's own DevTools
/// window, and docking again brings it back here.
///
/// It follows the page: a page that's hidden (another tab, another Space) hides its DevTools with it, and one that
/// moves to another host (a split, Little Airc's "Open in Airc") takes them along. A display-rate sync runs while any
/// page of the window has DevTools, so a splitter drag or a dock-side change lays out on the next frame.
final class ChromiumDevToolsDock: NSObject {
    private weak var window: ChromiumWindow?
    private var link: CADisplayLink?
    /// Every frontend view docked in a window now: the keyboard goes to DevTools first while one has it (KeyMonitor).
    static let docked = NSHashTable<NSView>.weakObjects()

    init(window: ChromiumWindow) { self.window = window }

    /// Starts following the window's pages' DevTools (after a command that may open them), and syncs now.
    func watch() {
        sync()
        // A command's frontend docks a moment later: keep watching at least that long.
        watchUntil = CACurrentMediaTime() + 3
        guard link == nil, let window else { return }
        // The window's link, not a host view's: a split's panes and Little Airc have their own hosts, and the main
        // host may be out of the window then (its link wouldn't fire).
        let l = window.window.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    private var watchUntil: CFTimeInterval = 0

    @objc private func tick() {
        let busy = sync()
        if !busy, CACurrentMediaTime() > watchUntil { link?.invalidate(); link = nil }
    }

    /// Lays out every page of the window that has docked DevTools. True while one needs frames: docked on screen, or
    /// undocked (it may dock again from its own window). A hidden page's come back with its page (activate → watch).
    @discardableResult func sync() -> Bool {
        guard let window else { return false }
        var busy = false
        for tab in window.dockTabs { if sync(tab) { busy = true } }
        return busy
    }

    private func sync(_ tab: ChromiumTab) -> Bool {
        let page = tab.core.view
        let tools = tab.isClosed ? nil : tab.core.devToolsView
        if let old = tab.dockedTools, old !== tools {
            // Closed, or undocked to Chrome's DevTools window (which now has the view: never touch it again).
            Self.docked.remove(old)
            tab.dockedTools = nil
            if old.superview === page.superview, old.window === page.window { old.removeFromSuperview() }
            tab.undockedTools = old
            Self.restore(page)
        }
        guard let tools else { return tab.isDevToolsUndocked }
        tab.undockedTools = nil
        tab.dockedTools = tools
        guard let host = page.superview, page.window != nil, !page.isHidden else {
            // The page isn't on screen: neither are its DevTools.
            if tools.superview != nil, !tools.isHidden, tools.window == nil || tools.window === window?.window { tools.isHidden = true }
            Self.docked.remove(tools)
            return false
        }
        if tools.superview !== host {
            tab.core.attachDevTools(to: host)   // the engine shows the frontend's WebContents in the host
        }
        Self.docked.add(tools)
        if let i = host.subviews.firstIndex(of: tools), let j = host.subviews.firstIndex(of: page), i > j {
            host.addSubview(tools, positioned: .below, relativeTo: page)
        }
        // Opened by a command with the window key: the keyboard goes to DevTools, as in Chrome.
        if tab.focusToolsWhenDocked, let w = page.window, w.isKeyWindow {
            tab.focusToolsWhenDocked = false
            if let v = Self.responder(in: tools) { w.makeFirstResponder(v) }
        }
        if tools.isHidden { tools.isHidden = false }
        tools.autoresizingMask = [.width, .height]
        if tools.frame != host.bounds { tools.frame = host.bounds }
        var toolsRect = NSRect.zero, pageRect = NSRect.zero
        tab.core.devToolsLayout(for: host.bounds.size, devTools: &toolsRect, page: &pageRect)
        // The engine's rects are top-left (DIPs); the host may not be flipped.
        let r = host.isFlipped ? pageRect
            : NSRect(x: pageRect.minX, y: host.bounds.height - pageRect.maxY, width: pageRect.width, height: pageRect.height)
        page.autoresizingMask = []
        if page.frame != r { page.frame = r }
        return true
    }

    /// The frontend's view that takes the keyboard (Chromium's render widget view inside its WebContents view).
    static func responder(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for v in view.subviews { if let r = responder(in: v) { return r } }
        return nil
    }

    /// The page fills its host again (DevTools closed or undocked).
    static func restore(_ page: NSView) {
        page.autoresizingMask = [.width, .height]
        if let host = page.superview, page.frame != host.bounds { page.frame = host.bounds }
    }

    /// The view with the keyboard is a docked DevTools frontend's (the keys go to DevTools first, as in Chrome).
    static func hasKeyboard(_ window: NSWindow?) -> Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return docked.allObjects.contains { r === $0 || r.isDescendant(of: $0) }
    }
}
#endif
