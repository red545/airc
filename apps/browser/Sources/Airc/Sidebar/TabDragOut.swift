// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircKit

/// SB-35's "out of the window → new window", the part of a sidebar drag (SpacePageView.beginPossibleDrag) past its
/// window's edge. The ghost leaves the window for a small floating panel that follows the pointer; over another browser
/// window's sidebar, that sidebar shows where the drop would land. At the release:
/// - outside every Airc window: the page moves, live, to a new window whose sidebar row sits under the pointer, on the
///   Space the person is on (macOS puts a new window there);
/// - on another browser window: it moves there (on its sidebar, to the row the line marks), and that window comes to
///   the front;
/// - on another kind of Airc window (Settings, Little Arc, a private window): nothing.
/// The window it left goes on to its next free tab (WIN-7). Folders don't leave the window; a multi-selection (SB-36)
/// goes only onto another window's sidebar, never into a new window.
final class TabDragOut {
    enum Target {
        case newWindow
        case window(WindowController)
        case none
    }

    private weak var controller: WindowController?
    private let source: DragSource
    /// SB-36: every dragged row, in order (one for a single row).
    private let sources: [DragSource]
    private let carriesFolder: Bool
    private let entry: SidebarEntry
    /// The press in the window (window coordinates): the new window puts the same point under the pointer.
    private let pressInWindow: NSPoint
    /// The tab on screen before the press showed the dragged one: the window shows it again once the page has gone.
    private let shownBefore: String?
    /// Where the pointer holds the ghost, from its top left.
    private var grab = CGPoint.zero
    private var panel: NSPanel?
    private weak var ghost: CALayer?
    private weak var overlay: NSView?
    private(set) var isOutside = false
    private(set) var target: Target = .none
    private(set) var destination: DropDestination?
    private weak var hoveredPage: SpacePageView?
    /// The panel's margin around the ghost, for its shadow.
    private static let margin: CGFloat = 16

    /// nil: this drag can't leave the window (a folder). `sources`: a multi-selection's rows, in order.
    init?(controller: WindowController, source: DragSource, entry: SidebarEntry, sources: [DragSource], carriesFolder: Bool,
          pressInWindow: NSPoint, shownBefore: String?) {
        if sources.count <= 1, case .item(let id) = source, controller.store.item(id)?.kind == .folder { return nil }
        self.controller = controller
        self.source = source
        self.sources = sources.count > 1 ? sources : [source]
        self.carriesFolder = carriesFolder
        self.entry = entry
        self.pressInWindow = pressInWindow
        self.shownBefore = shownBefore
    }

    /// The drag started: the lifted ghost, the window's overlay it floats in, and where the pointer holds it.
    func lift(ghost: CALayer, overlay: NSView, grab: CGPoint) {
        self.ghost = ghost
        self.overlay = overlay
        self.grab = grab
    }

    /// The pointer moved to `windowPoint` (the source window's coordinates). True while it's outside the window: the
    /// sidebar's own drop logic, the page's split zones and edge paging wait.
    @discardableResult
    func update(windowPoint: NSPoint) -> Bool {
        guard let c = controller else { return false }
        let p = c.window.convertPoint(toScreen: windowPoint)
        let outside = !c.window.frame.contains(p)
        if outside != isOutside {
            isOutside = outside
            moveGhost(outside: outside)
        }
        guard outside else {
            clearHover()
            target = .none
            return false
        }
        positionPanel(at: p)
        target = Self.target(at: p, from: c, below: panel?.windowNumber ?? 0)
        if case .window(let other) = target, let page = other.pageView(for: other.currentSpaceID),
           other.sidebar.frame.contains(other.root.convert(other.window.convertPoint(fromScreen: p), from: nil)) {
            if hoveredPage !== page { clearHover() }
            hoveredPage = page
            destination = page.dropDestination(at: page.convert(other.window.convertPoint(fromScreen: p), from: nil),
                                               source: source, entry: entry, carriesFolder: carriesFolder)
            // A selection lands in a list, never in a split.
            if sources.count > 1, case .split? = destination { destination = nil; page.hideDropIndicator() }
        } else {
            clearHover()
        }
        return true
    }

    /// The release (or Esc, `drop` false). True: the drop was outside the window, and was handled here.
    @discardableResult
    func finish(drop: Bool, windowPoint: NSPoint) -> Bool {
        defer { tearDown() }
        guard isOutside, let c = controller else { return false }
        guard drop else { return true }
        let p = c.window.convertPoint(toScreen: windowPoint)
        switch Self.target(at: p, from: c, below: panel?.windowNumber ?? 0) {
        case .newWindow where sources.count > 1: break
        case .newWindow: c.dropInNewWindow(source, at: p, pressInWindow: pressInWindow, returnTo: shownBefore)
        case .window(let other) where sources.count > 1: c.drop(sources, into: other, at: destination)
        case .window(let other): c.drop(source, into: other, at: destination, returnTo: shownBefore)
        case .none: break
        }
        return true
    }

    // MARK: Where

    /// What's under screen point `p`: another browser window, one of Airc's other windows (nothing happens), or no Airc
    /// window. Scripted runs share the owner's display, so there only Airc's own windows count, in their order.
    static func target(at p: NSPoint, from c: WindowController, below panel: Int) -> Target {
        let app = c.app
        func ours(_ w: NSWindow) -> Target {
            if let other = app?.controller(for: w), other !== c { return .window(other) }
            return w === c.window ? .newWindow : .none
        }
        if LaunchOptions.current.isAutomated {
            let hit = NSApp.orderedWindows.first { $0.isVisible && $0.windowNumber != panel && $0.frame.contains(p) && $0.alphaValue > 0 }
            return hit.map(ours) ?? .newWindow
        }
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: panel)
        guard let w = NSApp.windows.first(where: { $0.windowNumber == number }) else { return .newWindow }
        return ours(w)
    }

    // MARK: The ghost

    private func moveGhost(outside: Bool) {
        guard let ghost, let c = controller else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.removeFromSuperlayer()
        if outside {
            let panel = self.panel ?? makePanel(size: ghost.bounds.size, scale: c.window.backingScaleFactor)
            ghost.frame.origin = CGPoint(x: Self.margin, y: Self.margin)
            panel.contentView?.layer?.addSublayer(ghost)
            panel.orderFrontRegardless()
            // Rows of the window it left show no drop line while the pointer is away.
            c.pageView(for: c.currentSpaceID)?.hideDropIndicator()
        } else {
            panel?.orderOut(nil)
            overlay?.layer?.addSublayer(ghost)
        }
        CATransaction.commit()
    }

    private func makePanel(size: CGSize, scale: CGFloat) -> NSPanel {
        let m = Self.margin
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width + 2 * m, height: size.height + 2 * m),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.isExcludedFromWindowsMenu = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        // Flipped, as the window's overlay: the ghost's own layers are laid out top down.
        let v = FlippedView(frame: NSRect(origin: .zero, size: p.frame.size))
        v.wantsLayer = true
        v.layer?.contentsScale = scale
        p.contentView = v
        panel = p
        return p
    }

    /// The ghost under the pointer as it was held: its top left at the pointer less the grab.
    private func positionPanel(at p: NSPoint) {
        guard let panel, let ghost else { return }
        let m = Self.margin
        let origin = NSPoint(x: p.x - grab.x - m, y: p.y + grab.y - ghost.bounds.height - m)
        panel.setFrameOrigin(origin)
    }

    private func clearHover() {
        hoveredPage?.hideDropIndicator()
        hoveredPage = nil
        destination = nil
    }

    private func tearDown() {
        clearHover()
        panel?.orderOut(nil)
        panel = nil
    }
}

extension WindowController {
    /// The tab a dragged row stands for: a Today tab, a split's first pane, a pinned tab's or Favorite's live tab
    /// (opened if it has none). Folders have none.
    func dragOutTab(_ source: DragSource) -> String? {
        switch source {
        case .tab(let id): return store.tab(id)?.id
        case .split(let id): return store.split(id)?.tabIDs.first
        case .item(let id):
            guard let item = store.item(id), item.kind != .folder else { return nil }
            return try? store.openItem(id, inSpace: currentSpaceID, activate: false).id
        }
    }

    /// SB-35: dropped outside every Airc window. A window of this one's size, its press point under the pointer, on the
    /// screen of the drop; the page moves there live (Move to New Window).
    func dropInNewWindow(_ source: DragSource, at p: NSPoint, pressInWindow: NSPoint, returnTo: String? = nil) {
        guard let tabID = dragOutTab(source) else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? window.screen ?? NSScreen.main
        var f = NSRect(origin: NSPoint(x: p.x - pressInWindow.x, y: p.y - pressInWindow.y), size: window.frame.size)
        if let v = screen?.visibleFrame {
            f.size = NSSize(width: min(f.width, v.width), height: min(f.height, v.height))
            f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        }
        openInNewWindow(tabID, frame: f, returnTo: returnTo)
    }

    /// SB-35 with WIN-7: dropped on another browser window. On its sidebar (`destination`), the row goes where the line
    /// showed, as a drop inside that window; on its page, the tab shows there on its Space (in a blank window, it joins
    /// its Today). The page moves live; that window comes to the front.
    func drop(_ source: DragSource, into other: WindowController, at destination: DropDestination?, returnTo: String? = nil) {
        guard let tabID = dragOutTab(source), let app else { return }
        let wasShown = visibleTabIDs.contains(tabID)
        if let destination {
            // A split shows in the window it's made in; any other drop is the store's, run here, where the page is (a
            // move to another profile's Space reloads it here first).
            if case .split = destination { other.performDrop(source, to: destination) } else { performDrop(source, to: destination) }
        } else if let sid = store.tab(tabID)?.spaceID, !other.windowSpaces.contains(where: { $0.id == sid }) {
            performDrop(source, to: .today(spaceID: other.currentSpaceID, index: 0))
        } else if let sid = store.tab(tabID)?.spaceID, sid != other.currentSpaceID {
            other.switchToSpace(sid, animated: false)
        }
        guard store.tab(tabID) != nil else { return }
        // The drop may have made it a Favorite or a pinned tab of that Space: its live tab is the same one.
        if let sid = store.tab(tabID)?.spaceID, sid != other.currentSpaceID, other.windowSpaces.contains(where: { $0.id == sid }) {
            other.switchToSpace(sid, animated: false)
        }
        other.show(tabID, focus: true, takeOver: true)
        app.present(other)
        if wasShown, multiWindow.elsewhereTabID != nil { goOnAfterPageLeft(tabID, returnTo: returnTo) }
    }
}
