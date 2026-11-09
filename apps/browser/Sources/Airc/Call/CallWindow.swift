// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import SwiftUI

/// The call window (SB-55, §2.16b's call fallback): when a call's page leaves the screen (a tab or Space switch, or the
/// window minimized, hidden, ordered out or covered by another app's window) and the site shows no picture in picture
/// of its own, the call's page moves, live,
/// into a resizable floating window with its own call controls, and a separate Airc bar: Back to Tab
/// and ✕ (the call goes on in its tab). Going back to the tab puts the same page back. Engine pass 13 moves
/// pages between windows without touching the call (engine/PASS13.md "Full call window"); nothing reloads.
///
/// Settings → Picture in Picture applies: off, or a site set to never, means no call window. A site's own picture in
/// picture (Meet's Document PiP) wins: the call window waits a moment for it on a page that can open one, and gives
/// the page back if one opens. Airc merely going to the background is not leaving the screen: Notification Center,
/// Spotlight, Control Center, a menu-bar extra or a system alert take the focus with the page still in view. The window
/// counts as gone by its occlusion state, after a short settle (a window passing over it doesn't count).
final class CallWindowController: NSObject {
    /// The tab left the window's card, or the whole window left the screen.
    enum Reason { case left, hidden }

    private weak var library: MediaLibrary?
    private var panel: CallPanel?
    private var engineWindow: EngineWindow?
    /// The call in the window, and its page.
    private(set) var tabID: String?
    private(set) var page: EngineTab?
    private(set) var reason: Reason = .left
    /// The profile whose call window frame is remembered (the call's).
    private var frameProfile: String?
    /// Tabs whose site shows its own picture in picture now.
    private(set) var sitePictureInPicture: Set<String> = []
    /// Closed with ✕: not again until the tab has been on screen.
    private var dismissed: Set<String> = []
    private var pending: [String: DispatchWorkItem] = [:]
    private var visible: Set<String> = []
    private var chained = false
    /// Pages whose engine picture in picture is open now (counted once per opening).
    private var engineActive: Set<ObjectIdentifier> = []
    /// Whether the main window is on screen (its occlusion state, not minimized, the app not hidden).
    private(set) var windowOnScreen = true
    /// How long a page that can open its own picture in picture gets to do it (Chromium enters it as the tab hides).
    static var siteGrace: TimeInterval = 1.2
    /// How long the main window must stay off screen before its call goes to the call window.
    static var hiddenSettle: TimeInterval = 0.6
    /// Scripted runs set this off (the owner's own windows cover the test window at random) and simulate the changes.
    static var followsWindowVisibility = true
    static let frameKey = "callWindowFrame"

    init(library: MediaLibrary) {
        self.library = library
        super.init()
    }

    private var controller: WindowController? { library?.controller }
    var window: NSWindow? { panel }
    var isShowing: Bool { panel?.isVisible == true && tabID != nil }

    func holds(_ tabID: String) -> Bool { self.tabID == tabID }

    /// The engine's picture-in-picture news, after the window's own handler (WindowController.init installs it first).
    func chainPictureInPicture() {
        guard !chained else { return }
        chained = true
        #if canImport(AircCore)
        if let chromium = controller?.app?.engine as? ChromiumEngine {
            let previous = chromium.pictureInPictureDidChange
            chromium.pictureInPictureDidChange = { [weak self] page, state in
                previous?(page, state)
                self?.pictureInPictureChanged(page, active: (state["active"] as? Bool) ?? false, kind: state["kind"] as? String)
            }
        }
        #endif
    }

    // MARK: When

    /// The tabs on screen changed: a call that left them goes to its window.
    func visibleTabsChanged(_ now: Set<String>) {
        let left = visible.subtracting(now), entered = now.subtracting(visible)
        visible = now
        for id in entered {
            dismissed.remove(id)
            pending.removeValue(forKey: id)?.cancel()
        }
        for id in left { consider(id, .left) }
    }

    /// The main window's occlusion, miniaturization or the app's hidden state changed.
    func mainWindowVisibilityChanged() {
        guard Self.followsWindowVisibility, let w = controller?.window else { return }
        windowVisibility(w.isVisible && !w.isMiniaturized && !NSApp.isHidden && w.occlusionState.contains(.visible))
    }

    /// The main window left the screen (its call, if on screen there, goes to the call window once that holds for
    /// `hiddenSettle`) or came back (the call comes back to its card).
    func windowVisibility(_ onScreen: Bool) {
        guard onScreen != windowOnScreen else { return }
        windowOnScreen = onScreen
        if onScreen {
            for id in visible { pending.removeValue(forKey: id)?.cancel() }
            if let id = tabID, reason == .hidden, visible.contains(id) { returnPage(showing: false) }
        } else if tabID == nil {
            for id in visible { consider(id, .hidden) }
        }
    }

    /// The main window is the key window again: a call on its screen comes back from the call window.
    func mainWindowBecameKey() {
        guard let id = tabID, visible.contains(id) else { return }
        returnPage(showing: false)
    }

    func sessionChanged(_ id: String, _ s: EngineMediaSession) {
        guard id == tabID else { return }
        if s.isCall {
            panel?.view.update(s)
        } else {
            // The call ended (left from the page or here): the page goes back to its tab.
            DispatchQueue.main.async { [weak self] in if self?.tabID == id { self?.returnPage(showing: false) } }
        }
    }

    /// The engine's picture in picture for `page` (a video's, or the site's Document PiP) opened or closed.
    func pictureInPictureChanged(_ page: EngineTab, active: Bool, kind: String? = nil) {
        let key = ObjectIdentifier(page)
        if active, engineActive.insert(key).inserted {
            if WindowController.canPersistMiniPlayerSite(for: page) {
                Telemetry.shared.record(.featureUsed(.pictureInPicture(kind == "document" ? .document : .video)))
            }
        } else if !active {
            engineActive.remove(key)
        }
        guard let id = controller?.tabID(for: page) else { return }
        if active {
            sitePictureInPicture.insert(id)
            pending.removeValue(forKey: id)?.cancel()
            // Never both: the site's own picture in picture has the call.
            if tabID == id { DispatchQueue.main.async { [weak self] in self?.returnPage(showing: false) } }
        } else {
            sitePictureInPicture.remove(id)
        }
    }

    private func consider(_ id: String, _ why: Reason, triedSite: Bool = false) {
        guard tabID == nil, pending[id] == nil, mayOpen(id) else { return }
        let waits = siteMayOpenItsOwn(id)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[id] = nil
            guard self.tabID == nil, self.mayOpen(id) else { return }
            switch why {
            case .left: if self.visible.contains(id) { return }
            case .hidden: if self.windowOnScreen || !self.visible.contains(id) { return }
            }
            // Native auto-PiP has additional eligibility gates. A registered site
            // handler still deserves an explicit Media Session request before we
            // move its entire call page into the fallback panel.
            if waits && !triedSite, let page = self.controller?.engineTab(for: id),
               let media = self.controller?.app?.engine as? EngineMedia,
               media.performMediaAction("enterpictureinpicture", value: 0, in: page) {
                self.consider(id, why, triedSite: true)
                return
            }
            self.open(id, why)
        }
        pending[id] = work
        // Never inside the window's own show(): the next turn at the earliest; a window off screen settles first.
        let delay = max(waits ? Self.siteGrace : 0.05, why == .hidden ? Self.hiddenSettle : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A call, allowed by the settings, not already in the site's picture in picture or closed with ✕.
    private func mayOpen(_ id: String) -> Bool {
        guard let c = controller, let page = c.engineTab(for: id), !page.isClosed, c.app?.engine is EngineCallHosting,
              let s = library?.media?.sessions[id]?.session, s.isCall,
              !dismissed.contains(id), !sitePictureInPicture.contains(id) else { return false }
        return c.callWindowAllowed(for: page.url)
    }

    /// A registered site handler can provide its own PiP, including on trustworthy loopback origins.
    private func siteMayOpenItsOwn(_ id: String) -> Bool {
        guard controller?.engineTab(for: id) != nil,
              library?.media?.sessions[id]?.session.actions.contains("enterpictureinpicture") == true else { return false }
        #if canImport(AircCore)
        return controller?.app?.engine is ChromiumEngine
        #else
        return false
        #endif
    }

    // MARK: Moving the page

    func open(_ id: String, _ why: Reason) {
        guard let c = controller, let page = c.engineTab(for: id), let hosting = c.app?.engine as? EngineCallHosting else { return }
        let (panel, ew) = ensureWindow(hosting, c)
        // Where this profile's call window was last (PIP.md: the settled frame, per profile).
        frameProfile = c.store.tab(id)?.profileID
        panel.savedFrame = frameProfile.flatMap { c.store.localValue(Self.frameKey + "." + $0) }
            .map { $0.split(separator: " ").compactMap { Double($0) } }
            .flatMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        panel.pageHitTest = { [weak self] point, answer in self?.pageHasControl(at: point, answer) ?? answer(false) }
        ew.prepareProfile(page.profile)
        ew.activeProfile = page.profile
        do {
            try ew.moveTab(page, profile: page.profile, to: ew.hostView)
        } catch {
            NSLog("Airc: the call window couldn't take the page (\(error))")
            return
        }
        ew.activateTab(page)
        c.app?.engine.setPictureInPictureWindowActive(page, active: true)
        // On screen in its own window: the dev engine's unload timer (MEM-3) mustn't free it as a hidden tab.
        c.hiddenSince[id] = nil
        tabID = id
        self.page = page
        reason = why
        Telemetry.shared.record(.featureUsed(.pictureInPicture(.call)))
        panel.view.configure(title: page.title.isEmpty ? (c.store.tab(id)?.title ?? "") : page.title,
                             session: library?.media?.sessions[id]?.session ?? EngineMediaSession())
        panel.present(near: c.window)
        if why == .hidden { c.showCallAway(true) }
    }

    /// Back into the main window: shown (`showing`, the caller shows its tab next), or hidden behind what the card shows.
    func returnPage(showing: Bool) {
        guard let c = controller, let page, tabID != nil else { return }
        do {
            try c.engineWindow.moveTab(page, profile: page.profile, to: c.engineWindow.hostView)
        } catch {
            NSLog("Airc: the call page couldn't go back to its tab (\(error))")
        }
        HiddenMiniPlayers.forget(page)
        tabID = nil
        self.page = nil
        panel?.view.controls.miniPlayer.setMinimized(false, animated: false)
        panel?.dismiss()
        c.showCallAway(false)
        if !showing { c.reshowCurrentPage() }
    }

    /// Back to Tab: its Space and tab, in the front window.
    func backToTab() {
        guard let c = controller, let id = tabID, let tab = c.store.tab(id) else { return }
        if let sid = tab.spaceID, sid != c.currentSpaceID { c.switchToSpace(sid, animated: false) }
        c.show(id)
        if c.app?.options.isAutomated == true { c.window.orderFront(nil) } else {
            c.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// ✕: the window goes; the call goes on in its tab (the tray still has its controls).
    func dismiss() {
        guard let id = tabID else { return }
        dismissed.insert(id)
        returnPage(showing: false)
    }

    func perform(_ action: String) {
        guard let id = tabID, let p = library?.media?.sessions[id] else { return }
        library?.media?.perform(action, p)
    }

    func mutePlayback() {
        guard let page else { return }
        page.isMuted.toggle()
        if let id = tabID, let s = library?.media?.sessions[id]?.session { panel?.view.update(s) }
    }

    func suppressSite() {
        if let page { controller?.suppressMiniPlayer(for: page) }
        dismiss()
    }

    func systemPictureInPicture() {
        guard let page else { return }
        #if canImport(AircCore)
        if let chromium = controller?.app?.engine as? ChromiumEngine {
            chromium.enterPictureInPictureForHost(page) { _, _ in }
            return
        }
        #endif
        page.evaluate("""
        (function(){ const v = document.querySelector('video');
          if (v && v.requestPictureInPicture) v.requestPictureInPicture().catch(function(){});
          else if (v && v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'))
            v.webkitSetPresentationMode('picture-in-picture'); })()
        """, completion: nil)
    }

    private func ensureWindow(_ hosting: EngineCallHosting, _ c: WindowController) -> (CallPanel, EngineWindow) {
        if let panel, let engineWindow { return (panel, engineWindow) }
        let p = CallPanel()
        let ew = hosting.makeWindow(hosting: p)
        ew.delegate = self
        p.view.embed(ew.hostView)
        p.view.controller = self
        p.delegate = self
        p.moved = { [weak self] in self?.saveFrame() }
        panel = p
        engineWindow = ew
        return (p, ew)
    }
}

extension CallWindowController: NSWindowDelegate {
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    /// Once a drag (or its snap) has settled, not on every frame of it.
    fileprivate func saveFrame() {
        guard let f = panel?.frame, panel?.isVisible == true, panel?.view.controls.miniPlayer.state.isMinimized != true, let pid = frameProfile else { return }
        panel?.savedFrame = f
        controller?.store.setLocalValue(Self.frameKey + "." + pid, "\(f.minX) \(f.minY) \(f.width) \(f.height)")
    }

    /// Whether the page has a control under `point` (window coordinates): a button, link, field, slider, a video with
    /// its own controls, or a pointer cursor. Those keep the press (and its drag); the background moves the window.
    fileprivate func pageHasControl(at point: NSPoint, _ answer: @escaping (Bool) -> Void) {
        guard let page else { return answer(false) }
        let v = page.view
        var p = v.convert(point, from: nil)
        if !v.isFlipped { p.y = v.bounds.height - p.y }
        let z = max(0.25, page.zoomFactor)
        let js = """
        (function(x, y){ var e = document.elementFromPoint(x, y); if (!e) return false;
          if (e.closest('button,a[href],input,textarea,select,summary,label,[contenteditable],[role=button],[role=link],[role=slider],' +
            '[role=checkbox],[role=switch],[role=menuitem],[role=tab],[role=option],[tabindex]:not([tabindex="-1"]),video[controls],iframe')) return true;
          var c = getComputedStyle(e).cursor; return c === 'pointer' || c === 'text' || c === 'grab'; })(\(p.x / z), \(p.y / z))
        """
        page.evaluate(js) { answer(($0 as? Bool) == true) }
    }
}

extension CallWindowController: EngineWindowDelegate {
    /// A link the call opens goes to the main window, in the call's Space (as Little Arc's).
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let c = self.controller, let id = self.tabID else { return tab.close() }
            let sid = c.store.tab(id)?.spaceID ?? c.currentSpaceID
            if !c.adoptMovedPage(tab, inSpace: sid) {
                let url = tab.url
                tab.close()
                if let url { c.openExternal(url, inSpace: sid) }
            }
        }
    }

    /// The page closed (the person closed its tab, or the page itself): the window goes and the tab's close finishes.
    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        guard tab === page, let c = controller else { return }
        tabID = nil
        page = nil
        panel?.view.controls.miniPlayer.setMinimized(false, animated: false)
        panel?.dismiss()
        c.showCallAway(false)
        c.engineWindow(c.engineWindow, tabRequestedClose: tab)
    }

    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {
        guard tab === page, let c = controller else { return }
        c.engineWindow(c.engineWindow, tabCancelledClose: tab)
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
}

// MARK: - The window

/// A floating panel over every Space and other apps' full-screen Spaces, that never activates Airc (clicking it doesn't
/// bring the browser forward), with the page clipped to a rounded card like Arc's picture in picture.
///
/// Any drag moves it (a trackpad's three-finger drag too), and on release it springs to the nearest corner of the
/// screen; ⌘ while dragging places it freely. A press that doesn't move is a click, for the page or the buttons: it's
/// held until the window knows which (released, or held still for a moment, when the page gets it as is).
final class CallPanel: NSPanel {
    let view = CallWindowView()
    var savedFrame: NSRect?
    /// After a drag or snap settled (to remember the place).
    var moved: (() -> Void)?
    static let defaultSize = NSSize(width: 800, height: 600)
    static let minimumSize = NSSize(width: 640, height: 480)
    static let cornerInset: CGFloat = 20
    /// Points the pointer moves before a press becomes a drag; how long a still press waits before the page gets it;
    /// the band at the edge that resizes (engine/PIP.md's values).
    static let dragSlop: CGFloat = 3
    static let holdDelay: TimeInterval = 0.35
    static let resizeBorder: CGFloat = 8
    /// A release faster than this flings: the corner is picked 250 ms ahead.
    static let flingSpeed: CGFloat = 650
    /// Asks the page whether a press at a window point is on one of its controls (they keep their events).
    var pageHitTest: ((NSPoint, @escaping (Bool) -> Void) -> Void)?
    private var commandHeld = false
    private var held: NSEvent?
    private var holdWork: DispatchWorkItem?
    private var dragging = false
    private var dragStart: (mouse: NSPoint, origin: NSPoint) = (.zero, .zero)
    private var lastDrag: (point: NSPoint, time: TimeInterval) = (.zero, 0)
    private var velocity = CGVector.zero
    private lazy var springs = FrameAnimator(view: view)

    init() {
        // Titled (its title bar hidden): the window server rounds a titled window's corners and clips everything in it to
        // them, Chromium's page layers included, which a rounded container view doesn't.
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        // Only our drag moves it (sendEvent), not AppKit's title-bar drag.
        isMovable = false
        isFloatingPanel = true
        level = .floating
        // engine/PIP.md's floating panel: every Space and other apps' full-screen Spaces, out of the window cycle.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .canJoinAllApplications]
        #if AIRC_TESTING
        if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true {
            // Automated checks must stay on their own desktop, below the owner's work.
            level = .normal
            collectionBehavior = [.stationary, .ignoresCycle]
        }
        #endif
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        minSize = Self.minimumSize
        title = "Call"
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where held == nil && !dragging && !nearEdge(event.locationInWindow) && !onControl(event.locationInWindow):
            // Holding the down event for drag arbitration also delays AppKit's
            // ordinary key-window transition. Establish it now so the web view
            // receives the first click, rather than consuming it just for focus.
            // NSPanel's nonactivating style keeps the main browser in the background.
            if !isKeyWindow { makeKey() }
            springs.cancel("snap")
            held = event
            commandHeld = event.modifierFlags.contains(.command)
            // The page's own controls keep the press and its drag; ask it (a slow answer leaves the drag policy on).
            pageHitTest?(event.locationInWindow) { [weak self, weak event] onControl in
                guard onControl, let self, let event, self.held === event, !self.dragging else { return }
                self.releaseHeld()
            }
            let m = convertPoint(toScreen: event.locationInWindow)
            dragStart = (m, frame.origin)
            lastDrag = (m, event.timestamp)
            velocity = .zero
            let work = DispatchWorkItem { [weak self] in self?.releaseHeld() }
            holdWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
            return
        case .leftMouseDragged where held != nil || dragging:
            // In screen points: AppKit gives the location against the window's frame as it is now (it moves).
            let m = convertPoint(toScreen: event.locationInWindow)
            if !dragging, hypot(m.x - dragStart.mouse.x, m.y - dragStart.mouse.y) >= Self.dragSlop {
                dragging = true
                holdWork?.cancel()
                held = nil
            }
            guard dragging else { return }
            if event.modifierFlags.contains(.command) { commandHeld = true }
            let dt = event.timestamp - lastDrag.time
            if dt > 0.001 {
                let v = CGVector(dx: (m.x - lastDrag.point.x) / dt, dy: (m.y - lastDrag.point.y) / dt)
                velocity = CGVector(dx: 0.6 * velocity.dx + 0.4 * v.dx, dy: 0.6 * velocity.dy + 0.4 * v.dy)
            }
            lastDrag = (m, event.timestamp)
            setFrameOrigin(NSPoint(x: dragStart.origin.x + m.x - dragStart.mouse.x, y: dragStart.origin.y + m.y - dragStart.mouse.y))
            return
        case .leftMouseUp where held != nil || dragging:
            if dragging {
                dragging = false
                // ⌘ at any point of the gesture places it freely.
                if commandHeld || event.modifierFlags.contains(.command) { moved?() } else { snapToCorner() }
            } else if let down = held {
                // A click: the press and its release, to whatever is under them.
                holdWork?.cancel()
                held = nil
                super.sendEvent(down)
                super.sendEvent(event)
            }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// The edge band where a press resizes the window (AppKit's own handling).
    private func nearEdge(_ p: NSPoint) -> Bool {
        let e = Self.resizeBorder
        return p.x < e || p.y < e || p.x > frame.width - e || p.y > frame.height - e
    }

    /// On one of our own buttons (Back to Tab, ✕, the call's): it keeps the press.
    private func onControl(_ p: NSPoint) -> Bool {
        guard let frameView = contentView?.superview, let hit = frameView.hitTest(frameView.convert(p, from: nil)) else { return false }
        return hit is GlyphButton || hit is PiPInteractive
    }

    /// Held still: the page (or button) gets the press after all, and the rest of the gesture with it.
    private func releaseHeld() {
        guard let down = held, !dragging else { return }
        // A drag or release already waiting in the queue (a busy main thread) decides it instead.
        if NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: false) != nil {
            return
        }
        held = nil
        super.sendEvent(down)
    }

    /// The corner nearest to where it's heading (a fling carries it 250 ms on), on the visible part of the display it
    /// was dropped on.
    func snapToCorner() {
        let f = frame, i = Self.cornerInset
        let drop = NSPoint(x: f.midX, y: f.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(drop) } ?? self.screen ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let fling = hypot(velocity.dx, velocity.dy) > Self.flingSpeed ? 0.25 : 0
        let aim = NSPoint(x: f.midX + velocity.dx * fling, y: f.midY + velocity.dy * fling)
        let target = NSPoint(x: aim.x < v.midX ? v.minX + i : v.maxX - i - f.width,
                             y: aim.y < v.midY ? v.minY + i : v.maxY - i - f.height)
        let from = f.origin
        // PIP.md's spring: mass 1, stiffness 320, damping 30 (response 0.351 s, damping ratio 0.839).
        springs.spring("snap", from: 0, to: 1, spring: Spring(response: 2 * .pi / 320.0.squareRoot(), dampingRatio: 30 / (2 * 320.0.squareRoot())),
                       update: { [weak self] t in
            self?.setFrameOrigin(NSPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t))
        }, completion: { [weak self] in
            self?.setFrameOrigin(target)
            self?.moved?()
        })
    }

    /// Where it was last, else the bottom-right of the screen (SB-55's default), 20 pt in.
    func present(near main: NSWindow) {
        let screen = main.screen ?? NSScreen.main
        var f = savedFrame ?? .zero
        if f == .zero || !(NSScreen.screens.contains { $0.visibleFrame.intersects(f) }) {
            let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            f = NSRect(x: v.maxX - Self.defaultSize.width - 20, y: v.minY + 20, width: Self.defaultSize.width, height: Self.defaultSize.height)
        }
        // Migrate old video-sized frames, and keep remembered windows usable on
        // smaller or disconnected displays. Preserve the nearest corner.
        let area = (NSScreen.screens.first { $0.visibleFrame.contains(NSPoint(x: f.midX, y: f.midY)) }
                    ?? screen)?.visibleFrame.insetBy(dx: Self.cornerInset, dy: Self.cornerInset)
                    ?? NSRect(x: 20, y: 20, width: 1400, height: 860)
        let right = f.midX >= area.midX, top = f.midY >= area.midY
        let old = f
        if f.width < Self.minimumSize.width || f.height < Self.minimumSize.height {
            f.size = Self.defaultSize
        }
        minSize = NSSize(width: min(Self.minimumSize.width, area.width), height: min(Self.minimumSize.height, area.height))
        f.size = NSSize(width: min(area.width, max(minSize.width, f.width)), height: min(area.height, max(minSize.height, f.height)))
        if right { f.origin.x = old.maxX - f.width }
        if top { f.origin.y = old.maxY - f.height }
        f.origin.x = max(area.minX, min(f.minX, area.maxX - f.width))
        f.origin.y = max(area.minY, min(f.minY, area.maxY - f.height))
        setFrame(f, display: false)
        alphaValue = 0
        if (NSApp.delegate as? AppDelegate)?.options.isAutomated == true { orderFront(nil) }
        else { orderFrontRegardless() }
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AircCurve.previewIn.duration * 2
            animator().alphaValue = 1
        }
        view.flashControls()
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = AircCurve.toastOut.duration * 2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}

/// The full call page below a permanent window bar. The site supplies the only
/// microphone/camera/leave row; Airc never draws controls over the page.
final class CallWindowView: NSView {
    weak var controller: CallWindowController? { didSet { wire() } }
    private let clip = NSView()
    let controls = PiPControlsView()
    private var session = EngineMediaSession()
    // The buttons by name (the scripted checks press them).
    var back: PiPButton { controls.back }
    var close: PiPButton { controls.close }
    var mic: PiPButton { controls.mic }
    var camera: PiPButton { controls.camera }
    var leave: PiPButton { controls.leave }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(clip)
        controls.fullPage = true
        addSubview(controls)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private func wire() {
        var a = PiPControlsView.Actions()
        a.backToTab = { [weak self] in self?.controller?.backToTab() }
        a.close = { [weak self] in self?.controller?.dismiss() }
        a.stopPlayback = { [weak self] in
            self?.controller?.page?.evaluate("document.querySelectorAll('audio,video').forEach(v => v.pause())", completion: nil)
        }
        a.microphone = { [weak self] in self?.controller?.perform("togglemicrophone") }
        a.camera = { [weak self] in self?.controller?.perform("togglecamera") }
        a.leave = { [weak self] in self?.controller?.perform("hangup") }
        a.mute = { [weak self] in self?.controller?.mutePlayback() }
        a.suppressSite = { [weak self] in self?.controller?.suppressSite() }
        a.pictureInPicture = { [weak self] in self?.controller?.systemPictureInPicture() }
        controls.actions = a
    }

    func embed(_ host: NSView) {
        host.frame = clip.bounds
        host.autoresizingMask = [.width, .height]
        clip.addSubview(host)
    }

    func configure(title: String, session: EngineMediaSession) {
        controls.miniPlayer.playbackPage = controller?.page
        controls.mediaTitle = title
        controls.canSuppressSite = controller?.page?.url.flatMap { MiniPlayerSite.origin($0.absoluteString) } != nil
        update(session)
    }

    /// The buttons the page handles, showing what its microphone and camera do.
    func update(_ s: EngineMediaSession) {
        session = s
        var st = PiPOverlays.state(s, muted: controller?.page?.isMuted ?? false, at: CACurrentMediaTime())
        // Always the call's buttons here, even before the page says it's one.
        st.call = true
        st.canMute = false
        controls.update(st)
    }

    override func layout() {
        super.layout()
        let h = min(bounds.height, PiPControlsView.fullPageBarHeight)
        clip.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    }

    /// On arrival: shown for a moment, so you see what's there.
    func flashControls() { controls.flashControls() }

    var controlsVisible: Bool { controls.controlsVisible }
}

// MARK: - The card while its call is away

extension WindowController {
    /// The window left the screen with the call on it and the call went to its window: the card says where it is.
    func showCallAway(_ shown: Bool) {
        let tag = "airc.callAway"
        if !shown {
            card.subviews.filter { $0.identifier?.rawValue == tag }.forEach { $0.removeFromSuperview() }
            return
        }
        guard !card.subviews.contains(where: { $0.identifier?.rawValue == tag }) else { return }
        let v = AircFirstClickHostingView(rootView: CallAwayView(theme: currentPalette.resolved) {
            MediaLibrary.shared.calls.returnPage(showing: false)
        })
        v.identifier = NSUserInterfaceItemIdentifier(tag)
        v.safeAreaRegions = []
        v.wantsLayer = true
        v.layer?.cornerRadius = AircMetrics.Window.cardRadius
        v.layer?.masksToBounds = true
        v.frame = card.bounds
        v.autoresizingMask = [.width, .height]
        card.addSubview(v)
    }

    /// SB-55: picture-in-picture settings for the call window (off, or this site set to never, means no window).
    func callWindowAllowed(for url: URL?) -> Bool {
        guard let values = app?.settings.values, values.pipAutomatic else { return false }
        return MiniPlayerSite.allowed(url, automatic: values.pipAutomatic, sites: values.pipSites)
    }
}

private struct CallAwayView: View {
    let theme: ResolvedTheme
    let bringBack: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "pip.fill").font(.system(size: 24, weight: .light)).foregroundStyle(theme.textTertiary.color)
            Text("This call is in its own window").aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            Button("Bring It Back", action: bringBack).buttonStyle(.airc(.secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .aircTheme(theme)
    }
}
