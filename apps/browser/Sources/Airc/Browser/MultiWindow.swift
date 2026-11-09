// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

// WIN-7 (spec §2.1): several browser windows, Arc's way.
// - Every window shows the same Spaces, Favorites, pinned tabs and Today tabs (one store), and keeps its own Space, tab
//   and sidebar width. ⌘N opens one on the current Space with the Command Bar, as ⌘T.
// - A tab's live page is in one window at a time. Picking a tab another window shows (a row, ⌘1–9, the Command Bar,
//   Back to Tab) moves its page here without a reload (the engines' moveTab), and that window's card says "Open in
//   another window" with Show Here, as Arc's placeholder for reparented content. A page another window only keeps
//   hidden moves silently.
// - Switching Space, a swipe, a closed tab's neighbour and session restore never take a page another window shows:
//   the window shows its own tab of that Space, or the placeholder.
// - Commands act on the key window; links from other apps go to the window used last. Closing the last window leaves
//   Airc running (⌘N or the Dock brings it back); the session keeps every window's frame, Space and tab.
// - ⌃⌘N opens a blank window (Arc: "blank windows are separate"): a window on a Space of its own (Space.blankWindow),
//   so its Today tabs are its own and no other window lists them. It pages through that Space only; its Space goes,
//   its Today tabs to the Archive, when the person closes it, and comes back with it after a relaunch.
// - SB-35: a tab dragged out of the sidebar and dropped outside every Airc window moves its page (live) to a new window
//   at the drop point; dropped on another browser window, it moves there (on its sidebar: to the row the line marks).
// - Each window's title is its Space's name and its page's title, so the Window menu and Mission Control tell them apart.

/// How a browser window opens: its Space, its tab and its sidebar (nil: the defaults of the store's window state).
struct WindowOpening {
    enum Tab: Equatable {
        /// The Space's last tab, unless another window shows it (the first window at launch).
        case spaceLast
        /// No tab: the empty Space (⌘N).
        case none
        /// This tab: shown if no other window shows it, else "Open in another window" (session restore).
        case id(String)
    }
    var spaceID: String?
    var tab: Tab = .spaceLast
    var sidebarWidth: Double?
    var sidebarHidden: Bool?
}

/// A browser window's own part of WIN-7 (WindowController.multiWindow).
struct MultiWindowState {
    /// Space ID → the tab this window showed there last: each window comes back to its own tab (SP-23 per window).
    var tabBySpace: [String: String] = [:]
    /// The tab whose page another window has, while this window's card says so ("Open in another window").
    var elsewhereTabID: String?
    var elsewhereView: ElsewhereCardView?
    /// When the window opened (the oldest one runs auto-archive for pages no window has).
    var openedAt = 0
}

/// The app's part of WIN-7 (AppDelegate.windowSession).
struct WindowSessionState {
    var saveScheduled = false
    /// The quit is closing the windows: they stay in the session.
    var quitting = false
    /// The first browser window has opened (links before it wait; after it, a link with no window opens one).
    var browserReady = false
    var hooksInstalled = false
    var unloadHooksInstalled = false
    var openCount = 0
    /// Chromium only: the hidden window that keeps every loaded profile alive, whichever windows are open.
    var profileKeeper: EngineWindow?
    /// What the store has now (no read back before each write).
    var lastSaved: WindowSession?
}

/// The open browser windows, for the next launch: the store's device-local value "windows" (never synced).
struct WindowSession: Codable, Equatable {
    struct Window: Codable, Equatable {
        var frame: [Double]
        var spaceID: String
        var tabID: String?
        /// Its tab's page was in another window ("Open in another window").
        var elsewhere: Bool?
        var sidebarWidth: Double
        var sidebarHidden: Bool
    }
    var version = 1
    /// The window used last first.
    var windows: [Window]
    static let key = "windows"
}

// MARK: - The app's windows

extension AppDelegate {
    /// The browser window of `window` (nil: another kind of window, or none).
    func controller(for window: NSWindow?) -> WindowController? {
        guard let window else { return nil }
        return controllers.first { $0.window === window }
    }

    /// The window other than `except` whose card shows `tabID`'s page (alone or in a split).
    func window(showing tabID: String, except: WindowController? = nil) -> WindowController? {
        controllers.first { $0 !== except && $0.visibleTabIDs.contains(tabID) }
    }

    /// The window other than `except` whose engine window has `tabID`'s page, shown or not.
    func pageOwner(of tabID: String, except: WindowController? = nil) -> WindowController? {
        controllers.first { $0 !== except && $0.engineTab(for: tabID) != nil }
    }

    /// The window that has `page`.
    func controller(owning page: EngineTab) -> WindowController? { controllers.first { $0.tabID(for: page) != nil } }

    /// The window used last, or (after the last one closed) the last session's windows again.
    func browserWindow() -> WindowController? {
        if let c = controller { return c }
        guard windowSession.browserReady, onboarding == nil else { return nil }
        return reopenWindows()
    }

    /// ⌘N, the Dock menu, a Space's or a tab's Open in New Window: a window on `spaceID` (default: `source`'s Space),
    /// cascaded from `source`, with its sidebar width. With no tab it opens the Command Bar, as ⌘T: a new window is a
    /// new tab's worth of window. `frame`: where it goes instead (a tab dropped outside every window, SB-35).
    @discardableResult
    func openNewWindow(from source: WindowController?, spaceID: String? = nil, tab: WindowOpening.Tab = .none,
                       commandBar: Bool = true, frame explicitFrame: NSRect? = nil) -> WindowController? {
        guard store != nil, onboarding == nil else { return nil }
        let base = source ?? controller
        let frame = explicitFrame ?? base.map { cascade(from: $0.window) } ?? savedSession()?.windows.first.flatMap(restorableFrame) ?? defaultFrame()
        // ⌘N from a blank window: a window on the listed Spaces (only ⌃⌘N names a blank Space).
        let baseSpace = base.flatMap { $0.isBlankWindow ? nil : $0.currentSpaceID }
        let opening = WindowOpening(spaceID: spaceID ?? baseSpace, tab: tab,
                                    sidebarWidth: base.map { Double($0.sidebarWidth) }, sidebarHidden: base?.sidebarHidden)
        let c = makeController(frame: frame, opening: opening)
        present(c)
        if commandBar, tab == .none { c.openCommandBar(mode: .newTab) }
        scheduleSessionSave()
        return c
    }

    /// ⌃⌘N (Arc's New Blank Window): a window on a new Space of its own, empty, with `source`'s profile and theme, and
    /// the Command Bar open, as ⌘N.
    @discardableResult
    func openBlankWindow(from source: WindowController?) -> WindowController? {
        guard let store, onboarding == nil else { return nil }
        let base = source ?? controller
        guard let space = try? store.createBlankWindowSpace(from: base?.currentSpaceID) else { NSSound.beep(); return nil }
        return openNewWindow(from: base, spaceID: space.id, tab: .none)
    }

    /// The next window's frame: the same size, 22 pt down and right (AppKit's cascade), on the same screen.
    private func cascade(from w: NSWindow) -> NSRect {
        var f = w.frame.offsetBy(dx: 22, dy: -22)
        if let s = (w.screen ?? NSScreen.main)?.visibleFrame {
            if f.maxX > s.maxX || f.minY < s.minY { f.origin = NSPoint(x: s.minX + 40, y: s.maxY - f.height - 40) }
            f.size = NSSize(width: min(f.width, s.width), height: min(f.height, s.height))
        }
        return f
    }

    func present(_ c: WindowController) {
        // Scripted runs never take focus on the owner's Mac.
        if options.isAutomated { c.window.orderFront(nil) } else { c.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    /// A browser window became key: commands, links and the panels the app has once (downloads card, media tray's
    /// actions) follow it.
    func browserWindowBecameKey(_ c: WindowController) {
        if controllers.first !== c, let i = controllers.firstIndex(where: { $0 === c }) {
            controllers.remove(at: i)
            controllers.insert(c, at: 0)
            MediaLibrary.shared.follow(c)
            DefaultBrowserReminder.attach(c)
            scheduleSessionSave()
        }
        c.reclaimElsewhereTab()
    }

    /// A browser window is closing. Closed by the person, it leaves the session (the last one stays in it, so the Dock
    /// brings it back); closed by the quit, every window stays for the next launch.
    func browserWindowWillClose(_ c: WindowController) {
        let last = controllers.count == 1 && controllers.first === c
        if !windowSession.quitting, last { saveSession() }
        controllers.removeAll { $0 === c }
        if let next = controllers.first {
            MediaLibrary.shared.follow(next)
            DefaultBrowserReminder.attach(next)
        }
        // Its pages are gone: the other windows' auto-archive takes their tabs (WindowController.archiveProtected).
        controllers.forEach { $0.queueArchiveReschedule() }
        if !windowSession.quitting, !last { saveSession() }
        // A blank window closed by the person: its Space goes, its Today tabs to the Archive (after the window has gone,
        // so its own reload doesn't see it). The quit keeps it for the next launch.
        if !windowSession.quitting, c.isBlankWindow {
            let id = c.currentSpaceID
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.controllers.contains(where: { $0.currentSpaceID == id }) else { return }
                try? self.store.closeBlankWindowSpace(id)
            }
        }
    }

    /// The Dock icon with no browser window open (as Chrome): the last session's windows come back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if controllers.isEmpty, windowSession.browserReady, onboarding == nil { reopenWindows() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard windowSession.browserReady else { return nil }
        let m = NSMenu()
        m.addItem(DockMenuItem("New Window") { [weak self] in self?.openNewWindow(from: nil) })
        m.addItem(DockMenuItem("New Private Window") { [weak self] in if let self { PrivateBrowsing.shared.open(app: self) } })
        LittleArcGlobalActions.shared.addDockItems(to: m)
        #if AIRC_TESTING
        AgentCenter.shared.addDockItems(to: m)   // agentspike: Agents (dev builds)
        #endif
        return m
    }

    /// A command from the menu with no browser window open: the ones that open a window run; the rest wait for one.
    func runWithoutWindow(_ command: BrowserCommand) {
        switch command.title {
        case "New Window", "New Tab", "Open Location…": openNewWindow(from: nil)
        case "New Blank Window": openBlankWindow(from: nil)
        case "New Private Window": PrivateBrowsing.shared.open(app: self)
        case "New Little Airc Window": openLittleArc(url: nil)
        default: break
        }
    }

    /// Opens the last session's windows (after the last one closed): every window, or one on the last Space.
    @discardableResult
    func reopenWindows() -> WindowController? {
        let opened = restoreWindows()
        presentRestored(opened)
        return controller
    }

    // MARK: Session

    /// Launch: the windows of the last session (most recent in front), or one window on the last Space.
    func restoreWindows() -> [WindowController] {
        let saved = (savedSession()?.windows ?? []).filter { store.space($0.spaceID) != nil }
        // Blank windows' Spaces no saved window has (the session was lost): their tabs go to the Archive. The ones of
        // windows open now stay (a reopen with a window still open).
        let kept = Set(saved.map(\.spaceID) + controllers.map(\.currentSpaceID))
        for s in store.blankWindowSpaces where !kept.contains(s.id) { try? store.closeBlankWindowSpace(s.id) }
        guard !saved.isEmpty else { return [makeController(frame: initialFrame(), opening: WindowOpening())] }
        var made: [Int: WindowController] = [:]
        // Oldest first, so the window used last ends up first in `controllers`; windows whose page another window had
        // come after the one that has it.
        let order = saved.indices.reversed().filter { saved[$0].elsewhere != true } + saved.indices.reversed().filter { saved[$0].elsewhere == true }
        for i in order {
            let w = saved[i]
            let opening = WindowOpening(spaceID: w.spaceID, tab: w.tabID.map { .id($0) } ?? .none,
                                        sidebarWidth: w.sidebarWidth, sidebarHidden: w.sidebarHidden)
            made[i] = makeController(frame: restorableFrame(w) ?? (made.isEmpty ? initialFrame() : defaultFrame()), opening: opening)
        }
        let restored = saved.indices.compactMap { made[$0] }
        controllers = restored + controllers.filter { c in !restored.contains { $0 === c } }
        if let first = restored.first { MediaLibrary.shared.follow(first) }
        return restored
    }

    /// The restored windows on screen, the one used last in front (and key, unless this is a scripted run).
    func presentRestored(_ windows: [WindowController]) {
        for c in windows.dropFirst().reversed() { c.window.orderFront(nil) }
        if let first = windows.first { present(first) }
    }

    func savedSession() -> WindowSession? {
        guard let text = store?.localValue(WindowSession.key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WindowSession.self, from: data)
    }

    func saveSession() {
        guard let store, !controllers.isEmpty else { return }
        let s = WindowSession(windows: controllers.map(\.sessionWindow))
        guard s != windowSession.lastSaved, let data = try? JSONEncoder().encode(s) else { return }
        store.setLocalValue(WindowSession.key, String(decoding: data, as: UTF8.self))
        windowSession.lastSaved = s
    }

    /// A window moved, switched Space or tab, or opened: the session is written a second later (never during the quit,
    /// which closes the windows one by one).
    func scheduleSessionSave() {
        guard !windowSession.saveScheduled, !windowSession.quitting else { return }
        windowSession.saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.windowSession.saveScheduled = false
            if !self.windowSession.quitting { self.saveSession() }
        }
    }

    /// Chromium destroys a profile when its last browser goes (DestroyProfileOnBrowserClose, on by default on Mac), and
    /// each engine window holds browsers only for the profiles it used: closing one of several windows (a Work Space's
    /// Open in New Window) or the last one would unload a profile, and its pages elsewhere, Little Arc and private
    /// windows would show "Unable to open page" until a relaunch (review2 P1). So from the first window to the quit a
    /// hidden engine window, internal (no extension or history sees it), holds a browser for every loaded profile, and
    /// for each one that loads later. A profile goes only when the person deletes it (the engine's deletion closes its
    /// browsers, this one's too).
    func keepProfilesLoaded() {
        #if canImport(AircCore)
        guard engine is ChromiumEngine else { return }
        let keeper = windowSession.profileKeeper ?? {
            let w = engine.makeWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320))
            (w as? ChromiumWindow)?.core.internal = true
            w.window.isExcludedFromWindowsMenu = true
            windowSession.profileKeeper = w
            return w
        }()
        profiles.loadedProfiles.forEach(keeper.prepareProfile)
        profiles.keepLoaded = { [weak keeper] p in keeper?.prepareProfile(p) }
        #endif
    }

    /// A browser window is closing (by the person): the keeper is there already (made with the first window); this
    /// only makes sure, so no close can unload a profile.
    func keepProfilesIfLastWindowCloses(_ c: WindowController) {
        guard !windowSession.quitting else { return }
        keepProfilesLoaded()
    }

    /// The quit: the session as it is now; the windows' closing doesn't change it.
    func quitWillCloseWindows() {
        guard !windowSession.quitting else { return }
        saveSession()
        windowSession.quitting = true
    }

    /// The quit was cancelled (a page asked "Leave site?" and the person stayed).
    func quitCancelled() { windowSession.quitting = false }

    private func restorableFrame(_ w: WindowSession.Window) -> NSRect? {
        guard w.frame.count == 4 else { return nil }
        let r = NSRect(x: w.frame[0], y: w.frame[1], width: w.frame[2], height: w.frame[3])
        return NSScreen.screens.contains { $0.visibleFrame.intersects(r) } ? r : nil
    }

    private func defaultFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(1440, screen.width - 80), h = min(900, screen.height - 60)
        return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }

    /// Engine callbacks the app takes once (WindowController.init used to set them per window, so a second window
    /// replaced the first's and the call window's chain): picture in picture's Back to Tab goes to the window with the
    /// page.
    func installWindowHooksOnce() {
        guard !windowSession.hooksInstalled else { return }
        windowSession.hooksInstalled = true
        // Every loaded profile stays loaded, whichever windows close (keepProfilesLoaded); right after the first window,
        // off its launch path.
        DispatchQueue.main.async { [weak self] in self?.keepProfilesLoaded() }
        #if canImport(AircCore)
        guard let chromium = engine as? ChromiumEngine else { return }
        chromium.pictureInPictureRequestsTab = { [weak self] page in
            // A Little Arc window's mini player comes back to its own window.
            if let little = self?.littleArcs.first(where: { $0.page === page }) { return little.restoreFromMiniPlayer() }
            (self?.controller(owning: page) ?? self?.controller)?.showPictureInPictureTab(page)
        }
        chromium.pictureInPictureDidChange = { [weak self] page, state in
            self?.littleArcs.first { $0.page === page }?.pictureInPictureChanged(active: (state["active"] as? Bool) ?? false)
        }
        #endif
    }
}

/// A Dock menu row with its action.
private final class DockMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

// MARK: - A window's part

extension WindowController {
    /// A blank window (⌃⌘N): its Space is its own.
    var isBlankWindow: Bool { store.space(currentSpaceID)?.isBlankWindow == true }

    /// The Spaces this window pages through (the Space bar, swipes, ⌥⌘←→): every listed Space, or a blank window's own.
    var windowSpaces: [Space] {
        if let s = store.space(currentSpaceID), s.isBlankWindow { return [s] }
        return store.orderedSpaces
    }

    /// `show` for a tab of a Space this window doesn't page through (a blank window's tab picked in another window, a
    /// listed Space's tab picked in a blank window, from the Command Bar or Back to Tab): it shows in its own window,
    /// on its Space, which comes to the front. False: it belongs here. Automatic paths (`takeOver` false) never move it.
    func routeToItsWindow(_ tab: LiveTab, focus: Bool, updatesRows: Bool, takeOver: Bool) -> Bool {
        guard let sid = tab.spaceID, sid != currentSpaceID, let space = store.space(sid), let app else { return false }
        let home: WindowController?
        if space.isBlankWindow {
            home = app.controllers.first { $0 !== self && $0.currentSpaceID == sid }
        } else if isBlankWindow {
            home = app.controllers.first { !$0.isBlankWindow }
                ?? (takeOver ? app.openNewWindow(from: self, spaceID: sid, tab: .none, commandBar: false) : nil)
        } else {
            return false
        }
        guard let home else { return false }
        guard takeOver else { showEmpty(updatesRows: updatesRows); return true }
        if home.currentSpaceID != sid { home.switchToSpace(sid, animated: false) }
        home.show(tab.id, focus: focus, updatesRows: updatesRows, takeOver: true)
        app.present(home)
        return true
    }

    /// The window's title, for the Window menu, Mission Control and ⌘`: its Space's name, then its page's title.
    func updateWindowTitle() {
        let space = store.space(currentSpaceID)?.name ?? "Airc"
        let page = shownTabID.flatMap { id -> String? in
            let live = pages[id]?.title ?? ""
            return live.isEmpty ? store.tab(id)?.displayTitle : live
        }
        let title = page.map { "\(space) — \($0)" } ?? space
        if window.title != title { window.title = title }
    }

    /// The tab this window shows in `spaceID` when it switches there: its own last one there (even if another window has
    /// its page now: then "Open in another window"), else the Space's last tab unless another window shows it.
    func preferredTab(forSpace spaceID: String) -> String? {
        guard let app, app.controllers.contains(where: { $0 !== self }) else { return store.lastActiveTab(ofSpace: spaceID)?.id }
        if let id = multiWindow.tabBySpace[spaceID], let t = store.tab(id), t.spaceID == nil || t.spaceID == spaceID { return id }
        if let t = store.lastActiveTab(ofSpace: spaceID), app.window(showing: t.id, except: self) == nil { return t.id }
        return nil
    }

    /// After `tabID` closes here: the next row below it (else above) that no other window shows.
    func nextFreeTab(afterClosing tabID: String, inSpace spaceID: String) -> LiveTab? {
        guard let app, app.controllers.contains(where: { $0 !== self }) else { return store.tabToSelect(afterClosing: tabID, inSpace: spaceID) }
        let live = store.sidebarEntries(ofSpace: spaceID, skippingCollapsed: false).compactMap(\.liveTab)
        let free = { (t: LiveTab) in t.id != tabID && app.window(showing: t.id, except: self) == nil }
        guard let i = live.firstIndex(where: { $0.id == tabID }) else { return live.first(where: free) }
        return live[(i + 1)...].first(where: free) ?? live[..<i].reversed().first(where: free)
    }

    /// The tab is on screen here now (show, Show Here): remembered for this Space, and in the session.
    func noteShown(_ tabID: String) {
        multiWindow.tabBySpace[currentSpaceID] = tabID
        app?.scheduleSessionSave()
        linkPreviewShownChanged()   // every show path: a link preview card whose page isn't shown any more goes
    }

    /// `tabID`'s page from the window that has it, into this one, live (no reload). Nil: no other window has it, or the
    /// engine couldn't move it (then it's closed there and opens again here).
    func takePageFromOtherWindow(_ tabID: String) -> EngineTab? {
        guard let app, let owner = app.pageOwner(of: tabID, except: self) else { return nil }
        if owner.visibleTabIDs.contains(tabID) { owner.pageLeaving(tabID) }
        // A call in the call window goes back to its window first (CallWindow.swift moves it from there).
        let calls = MediaLibrary.shared.calls
        if calls.holds(tabID), MediaLibrary.shared.controller === owner { calls.returnPage(showing: true) }
        guard let page = owner.releasePage(tabID) else { return nil }
        do {
            try engineWindow.moveTab(page, profile: page.profile, to: engineWindow.hostView)
        } catch {
            NSLog("Airc: a page couldn't move between windows (\(error)); it opens again")
            page.close()
            return nil
        }
        adopt(page, as: tabID)
        // Its address is already in history (the other window recorded it).
        lastRecordedURL[tabID] = page.url?.absoluteString
        if store.tab(tabID)?.isMuted == true { page.isMuted = true }
        return page
    }

    /// Another window takes this page: it stops being this window's (nil if it has closed).
    func releasePage(_ tabID: String) -> EngineTab? {
        guard let p = engineTab(for: tabID) else { return nil }
        prompts.dropAll(for: p)
        removePageMapping(tabID)
        hiddenSince[tabID] = nil
        p.delegate = nil
        queueArchiveReschedule()
        return p.isClosed ? nil : p
    }

    /// Another window takes `tabID`'s page off this window's card: the card says where it went.
    func pageLeaving(_ tabID: String) {
        guard visibleTabIDs.contains(tabID), let shown = shownTabID else { return }
        showElsewhere(shown, updatesRows: false)
    }

    /// The card's "Open in another window" (built on first use, then reused).
    func presentElsewhere(_ tabID: String) {
        let v = multiWindow.elsewhereView ?? {
            let v = ElsewhereCardView()
            v.onShowHere = { [weak self] in self?.showHere() }
            v.onGoToWindow = { [weak self] in self?.goToWindowShowingElsewhereTab() }
            card.addSubview(v)
            multiWindow.elsewhereView = v
            return v
        }()
        v.frame = card.bounds
        v.autoresizingMask = [.width, .height]
        let tab = store.tab(tabID)
        let title = tab.map { $0.title.isEmpty ? URLRules.displayHost($0.url) : $0.title } ?? ""
        v.configure(title: title, palette: currentPalette)
        v.isHidden = false
    }

    func hideElsewhere() {
        multiWindow.elsewhereTabID = nil
        multiWindow.elsewhereView?.isHidden = true
    }

    /// Show Here: the page comes back to this window (and leaves the other one).
    func showHere() {
        guard let id = multiWindow.elsewhereTabID else { return }
        show(id, focus: true, takeOver: true)
    }

    /// Go to Window: the window that has the page comes to the front.
    func goToWindowShowingElsewhereTab() {
        guard let id = multiWindow.elsewhereTabID, let other = app?.window(showing: id, except: self) else { return showHere() }
        app?.present(other)
    }

    /// The window became key: a page that left it for another window, and isn't on screen there any more, comes back.
    func reclaimElsewhereTab() {
        guard let id = multiWindow.elsewhereTabID, store.tab(id) != nil, app?.window(showing: id, except: self) == nil else { return }
        show(id, focus: false, takeOver: true)
    }

    /// After a store change another window made: the tab this window showed is gone (closed, archived, deleted with its
    /// Space), so it shows its Space's next free tab; pages of tabs that no longer exist close.
    func reconcileWithOtherWindows() {
        guard let app, app.controllers.count > 1 else { return }
        for id in Array(pages.keys) where store.tab(id) == nil && !closingTabs.contains(id) { dropPage(id) }
        guard let shown = shownTabID, store.tab(shown) == nil else { return }
        if let t = preferredTab(forSpace: currentSpaceID).flatMap({ store.tab($0) }) ?? nextFreeTab(afterClosing: shown, inSpace: currentSpaceID) {
            show(t.id, focus: false, updatesRows: false, takeOver: false)
        } else {
            showEmpty(updatesRows: false)
        }
    }

    /// What another window's auto-archive must leave to this one (SB-43): what it shows or plays, and every page it has.
    var tabsKeptByThisWindow: Set<String> {
        var kept = visibleTabIDs.union(pages.keys)
        if let id = multiWindow.elsewhereTabID { kept.insert(id) }
        return kept
    }

    /// The oldest window archives tabs no window has a page for; every window archives its own pages.
    var runsAutoArchiveForPagelessTabs: Bool {
        guard let app else { return true }
        return app.controllers.min(by: { $0.multiWindow.openedAt < $1.multiWindow.openedAt }) === self || app.controllers.isEmpty
    }

    /// What this window's auto-archive leaves alone because of the other windows.
    var tabsKeptByOtherWindows: Set<String> {
        guard let app, app.controllers.contains(where: { $0 !== self }) else { return [] }
        var kept: Set<String> = []
        for c in app.controllers where c !== self { kept.formUnion(c.tabsKeptByThisWindow) }
        if !runsAutoArchiveForPagelessTabs { kept.formUnion(store.state.tabs.keys.filter { pages[$0] == nil }) }
        return kept
    }

    /// This window in the session.
    var sessionWindow: WindowSession.Window {
        let f = window.frame
        let elsewhere = multiWindow.elsewhereTabID != nil
        return WindowSession.Window(frame: [f.origin.x, f.origin.y, f.width, f.height], spaceID: currentSpaceID,
                                    tabID: shownTabID, elsewhere: elsewhere ? true : nil,
                                    sidebarWidth: Double(sidebarWidth), sidebarHidden: sidebarHidden)
    }

    /// A tab's Move to New Window (Arc), and a tab dragged out of the sidebar (SB-35, at `frame`): a window on its Space
    /// showing it (its page moves there, live); this window goes on to the next tab. A blank window's tab gets a blank
    /// window of its own, the tab moved into its Space.
    @discardableResult
    func openInNewWindow(_ tabID: String, frame: NSRect? = nil, returnTo: String? = nil) -> WindowController? {
        guard let tab = store.tab(tabID), let app else { return nil }
        let wasShown = visibleTabIDs.contains(tabID)
        var spaceID = tab.spaceID ?? currentSpaceID
        if store.space(spaceID)?.isBlankWindow == true {
            guard let blank = try? store.createBlankWindowSpace(from: spaceID) else { return nil }
            _ = try? store.moveTab(tabID, toSpace: blank.id)
            spaceID = blank.id
        }
        guard let w = app.openNewWindow(from: self, spaceID: spaceID, tab: .none, commandBar: false, frame: frame) else { return nil }
        w.show(tabID, focus: true, takeOver: true)
        if wasShown, multiWindow.elsewhereTabID != nil { goOnAfterPageLeft(tabID, returnTo: returnTo) }
        return w
    }

    /// This window's page went to another window for good (Move to New Window, a drag out): `returnTo` (the tab it
    /// showed before the drag's press) if it's still here and free, else the next free tab.
    func goOnAfterPageLeft(_ tabID: String, returnTo: String? = nil) {
        if let back = returnTo, back != tabID, let t = store.tab(back), t.spaceID == nil || t.spaceID == currentSpaceID,
           app?.window(showing: back, except: self) == nil {
            return show(back, focus: false, takeOver: false)
        }
        if let next = nextFreeTab(afterClosing: tabID, inSpace: currentSpaceID) { show(next.id, focus: false, takeOver: false) } else { showEmpty() }
    }

    /// A Space's Open in New Window: a window on it, showing its last tab no other window shows. (A blank window's
    /// Space is in its own window only.)
    func openSpaceInNewWindow(_ spaceID: String) {
        guard store.space(spaceID)?.isBlankWindow != true else { return NSSound.beep() }
        app?.openNewWindow(from: self, spaceID: spaceID, tab: .spaceLast, commandBar: false)
    }
}

// MARK: - "Open in another window"

/// The card of a window whose tab's page another window has: Arc's placeholder for moved content.
final class ElsewhereCardView: NSView {
    var onShowHere: (() -> Void)?
    var onGoToWindow: (() -> Void)?
    private var host: AircFirstClickHostingView<AnyView>?
    /// What the card says (the checks read it).
    private(set) var title = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Inside the page card's rounded corners (WIN-1).
        wantsLayer = true
        layer?.cornerRadius = AircMetrics.Window.cardRadius
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    func configure(title: String, palette: Palette) {
        self.title = title
        let view = AnyView(ElsewhereCard(title: title, showHere: { [weak self] in self?.onShowHere?() },
                                         goToWindow: { [weak self] in self?.onGoToWindow?() })
            .aircTheme(palette.resolved))
        if let host {
            host.rootView = view
        } else {
            let h = AircFirstClickHostingView(rootView: view)
            h.frame = bounds
            h.autoresizingMask = [.width, .height]
            addSubview(h)
            host = h
        }
    }
}

private struct ElsewhereCard: View {
    let title: String
    let showHere: () -> Void
    let goToWindow: () -> Void
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(theme.surfaceTextTertiary.color)
                .frame(height: AircMetrics.EmptySpace.emoji + 8)
            Text("Open in another window")
                .aircFont(AircFont.title3)
                .foregroundStyle(theme.surfaceText.color)
                .padding(.top, AircMetrics.EmptySpace.nameGap)
            if !title.isEmpty {
                Text(title)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .padding(.top, 4)
            }
            HStack(spacing: 8) {
                Button("Go to Window", action: goToWindow).buttonStyle(.airc(.secondary, size: .small))
                Button("Show Here", action: showHere).buttonStyle(.airc(.primary, size: .small))
            }
            .padding(.top, AircMetrics.EmptySpace.hintGap)
        }
        .padding(.bottom, AircMetrics.EmptySpace.liftAboveCentre)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .accessibilityElement(children: .contain)
    }
}
