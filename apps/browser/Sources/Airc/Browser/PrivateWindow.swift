// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import SwiftUI

/// PW-1 Private windows (⇧⌘N, spec §2.16c). A dark window of its own, built like Little Arc's (LittleArc.swift): a simple
/// sidebar with the address field, this window's tabs and New Tab; no Spaces, Favorites or pinned items. Its pages use
/// the off-the-record profile of the current Space's profile (Chromium's incognito; on the WebKit dev engine, a data
/// store that never touches the disk). Airc keeps nothing of it: no history (Airc's or the engine's), no session
/// restore, no Archive, nothing in the Library or in ⌘T's history, and no telemetry about its pages. Its cookies and
/// site data go when the last private window of that profile closes.
///
/// Every private window of one profile shares one session, as in Chrome: signing in in one is signing in in all of
/// them, until the last one closes.
final class PrivateBrowsing {
    static let shared = PrivateBrowsing()

    private(set) var windows: [PrivateWindowController] = []
    /// One private session per Space profile (its ID) while any of its windows is open.
    private var sessions: [String: EngineProfile] = [:]
    /// Sessions whose last window closed and that the engine hasn't destroyed yet: a new window waits for them, so no
    /// cookie carries over.
    private var ending: [String: EngineProfile] = [:]

    func window(for w: NSWindow?) -> PrivateWindowController? {
        guard let w else { return nil }
        return windows.first { $0.window === w }
    }

    /// ⇧⌘N: a private window for the current Space's profile, or for `source`'s when it comes from a private window.
    func open(app: AppDelegate, from source: PrivateWindowController? = nil,
              completion: ((PrivateWindowController?) -> Void)? = nil) {
        let profileID = source?.profileID
            ?? app.controller.map { $0.store.profile(ofSpace: $0.currentSpaceID).id }
            ?? app.store.defaultProfile.id
        session(for: profileID, app: app) { [weak self, weak app] profile in
            guard let self, let app else { completion?(nil); return }
            guard let profile else {
                app.controller?.showToast("Airc couldn’t open a private window")
                completion?(nil)
                return
            }
            let w = PrivateWindowController(app: app, profileID: profileID, profile: profile,
                                            frame: self.nextFrame(app: app, after: source))
            self.windows.append(w)
            Telemetry.shared.record(.featureUsed(.privateWindowOpen))
            w.show()
            completion?(w)
        }
    }

    private func session(for profileID: String, app: AppDelegate, completion: @escaping (EngineProfile?) -> Void) {
        if let p = sessions[profileID] { return completion(p) }
        if let old = ending[profileID] {
            return whenEnded(old, profileID: profileID, app: app, deadline: Date().addingTimeInterval(5)) { [weak self, weak app] in
                guard let self, let app else { return completion(nil) }
                self.session(for: profileID, app: app, completion: completion)
            }
        }
        guard let parent = app.profiles.engineProfile(for: profileID) else { return completion(nil) }
        #if canImport(AircCore)
        if let chromium = app.engine as? ChromiumEngine {
            chromium.offTheRecordProfile(for: parent) { [weak self] p in
                guard let self else { return completion(nil) }
                if let p, self.sessions[profileID] == nil { self.sessions[profileID] = p }
                completion(self.sessions[profileID])
            }
            return
        }
        #endif
        if let webKit = app.engine as? WebKitEngine {
            let p = webKit.makePrivateProfile()
            sessions[profileID] = p
            return completion(p)
        }
        completion(nil)
    }

    /// The window closed (its pages are gone or going). The last one of its profile ends the session.
    func closed(_ w: PrivateWindowController) {
        windows.removeAll { $0 === w }
        let pid = w.profileID
        guard !windows.contains(where: { $0.profileID == pid }), let p = sessions.removeValue(forKey: pid) else { return }
        #if canImport(AircCore)
        if let chromium = w.app?.engine as? ChromiumEngine {
            ending[pid] = p
            chromium.releaseOffTheRecordProfile(p)
            // The window's browser may still be closing: ask again shortly (once it's gone, asking does nothing).
            for delay in [0.25, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak chromium] in
                    guard let self, let chromium, self.ending[pid] === p else { return }
                    if chromium.isDestroyed(p) { self.ending[pid] = nil } else { chromium.releaseOffTheRecordProfile(p) }
                }
            }
        }
        #endif
        // WebKit: the non-persistent store goes with its last web view.
    }

    private func whenEnded(_ p: EngineProfile, profileID: String, app: AppDelegate, deadline: Date,
                           then: @escaping () -> Void) {
        #if canImport(AircCore)
        if let chromium = app.engine as? ChromiumEngine, !chromium.isDestroyed(p) {
            guard Date() < deadline else {
                NSLog("Airc: the previous private session is still closing; a new one can't start yet")
                ending[profileID] = nil
                return then()
            }
            chromium.releaseOffTheRecordProfile(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak app] in
                guard let self, let app else { return }
                self.whenEnded(p, profileID: profileID, app: app, deadline: deadline, then: then)
            }
            return
        }
        #endif
        ending[profileID] = nil
        then()
    }

    #if AIRC_TESTING
    /// Whether the session of `profileID` is over: no window, and the engine has destroyed its profile.
    func sessionEnded(_ profileID: String, app: AppDelegate?) -> Bool {
        guard sessions[profileID] == nil else { return false }
        #if canImport(AircCore)
        if let p = ending[profileID], let chromium = app?.engine as? ChromiumEngine { return chromium.isDestroyed(p) }
        #endif
        return true
    }
    #endif

    /// The main window's size, a little down and to the right of it (or of `source`), on its screen.
    private func nextFrame(app: AppDelegate, after source: PrivateWindowController?) -> NSRect {
        let base = source?.window.frame ?? app.controller?.window.frame ?? NSRect(x: 80, y: 80, width: 1280, height: 820)
        let screen = (source?.window.screen ?? app.controller?.window.screen ?? NSScreen.main)?.visibleFrame
        let step = CGFloat(windows.count % 6 + 1) * 26
        var f = NSRect(x: base.minX + step, y: base.minY - step, width: base.width, height: base.height)
        if let s = screen, s.intersects(base) {
            f.size = NSSize(width: min(f.width, s.width), height: min(f.height, s.height))
            f.origin.x = min(max(s.minX, f.minX), s.maxX - f.width)
            f.origin.y = min(max(s.minY, f.minY), s.maxY - f.height)
        }
        return f
    }
}

/// One private window: its pages (newest first, as Today), the shown one in the page card, and its own Command Bar.
final class PrivateWindowController: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    /// The Space profile this window's private session comes from (its search engine and settings).
    let profileID: String
    /// The engine's private profile (shared by this profile's private windows).
    let profile: EngineProfile
    let engineWindow: EngineWindow
    var window: NSWindow { engineWindow.window }

    struct Page {
        let id: String
        let tab: EngineTab
        /// The page that opened it (a link in a new tab): new tabs line up after their opener (SB-42).
        let openerID: String?
    }
    private(set) var pages: [Page] = []
    private(set) var shownID: String?
    private var nextID = 0
    /// Asked to close, waiting for the page's unload handlers (it may ask "Leave site?").
    private var closingIDs: Set<String> = []
    private var closing = false

    let root = PrivateRootView()
    let background: ThemeBackgroundView
    let sidebar = PrivateSidebarView()
    let card = PageCardView()
    private let empty: NSHostingView<PrivateEmptyView>
    let toast = ToastView()
    private(set) var commandBar: CommandBarView?
    lazy var prompts = PromptPresenter(host: self)
    private var lights: TrafficLights?
    /// Its own key for live search suggestions: nothing typed here shares a session or cache with the profile's.
    private let suggestionKey = "private-" + UUID().uuidString

    /// Dark whatever the system's appearance: a near-black slate (Arc's incognito windows are dark).
    static let theme: AircKit.SpaceTheme = DesignTheme(colors: [AircColor(0x3B3E4C), AircColor(0x191A20)], intensity: 0.86,
                                                        grain: 0.18, appearance: .dark).model
    static var privatePalette: Palette { Palette(theme: theme, systemDark: true) }
    let palette = PrivateWindowController.privatePalette

    init(app: AppDelegate, profileID: String, profile: EngineProfile, frame: NSRect) {
        self.app = app
        self.profileID = profileID
        self.profile = profile
        engineWindow = app.engine.makeWindow(contentRect: frame)
        let pal = Self.privatePalette
        background = ThemeBackgroundView(theme: pal.resolved)
        empty = NSHostingView(rootView: PrivateEmptyView(theme: pal.resolved, onNewTab: {}))
        super.init()
        engineWindow.delegate = self
        empty.rootView = PrivateEmptyView(theme: pal.resolved) { [weak self] in self?.openCommandBar(mode: .newTab) }
        setUpWindow(frame: frame)
        app.promptCenter?.register(prompts)
        engineWindow.activeProfile = profile
        engineWindow.prepareProfile(profile)
        refresh()
    }

    private var sidebarWidth: CGFloat {
        let w = app?.controller?.sidebarWidth ?? AircMetrics.Sidebar.defaultWidth
        return min(max(w, AircMetrics.Sidebar.minWidth), AircMetrics.Sidebar.maxWidth)
    }

    private func setUpWindow(frame: NSRect) {
        let w = window
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        // As the main window: a page click must reach the page; the background and the sidebar's empty parts drag it.
        w.isMovableByWindowBackground = false
        w.tabbingMode = .disallowed
        w.isRestorable = false
        w.minSize = NSSize(width: 640, height: 420)
        w.title = "Private Window"
        // Menus, alerts and popovers over it are dark too.
        w.appearance = NSAppearance(named: .darkAqua)
        w.delegate = self
        root.controller = self
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.wantsLayer = true
        w.contentView = root
        root.addSubview(background)
        root.addSubview(card)
        root.addSubview(empty)
        root.addSubview(sidebar)
        root.addSubview(toast)
        card.palette = palette
        card.embed(engineWindow.hostView)
        empty.wantsLayer = true
        empty.layer?.cornerRadius = AircMetrics.Window.cardRadius
        empty.layer?.cornerCurve = .continuous
        empty.layer?.masksToBounds = true
        sidebar.controller = self
        sidebar.palette = palette
        lights = TrafficLights(window: w)
    }

    func show() {
        if app?.options.isAutomated == true {
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // A new private window starts in the Command Bar, as ⌘T: there's nothing to show yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pages.isEmpty, self.app?.options.isAutomated != true else { return }
            self.openCommandBar(mode: .newTab)
        }
    }

    func layout() {
        let b = root.bounds
        background.frame = b
        let s = sidebarWidth
        sidebar.frame = NSRect(x: 0, y: 0, width: s, height: b.height)
        let i = AircMetrics.Window.cardInset
        card.frame = NSRect(x: s, y: i, width: max(0, b.width - s - i), height: max(0, b.height - 2 * i))
        empty.frame = card.frame
        commandBar?.layoutIn(b, sidebarFrame: sidebar.frame, contentFrame: card.frame)
        prompts.layout()
        lights?.place()
    }

    // MARK: Pages

    var shownPage: EngineTab? { pages.first { $0.id == shownID }?.tab }
    func page(_ id: String) -> Page? { pages.first { $0.id == id } }

    /// A new tab in this window (⌘T's pick), shown unless `foreground` is false.
    @discardableResult
    func openPage(_ url: URL?, foreground: Bool = true) -> EngineTab {
        engineWindow.activeProfile = profile
        let tab = engineWindow.openTab(url: url, profile: profile, foreground: false)
        adopt(tab, opener: nil, show: foreground)
        return tab
    }

    private func adopt(_ tab: EngineTab, opener: String?, show: Bool) {
        guard !closing else { tab.close(); return }
        tab.delegate = self
        nextID += 1
        let page = Page(id: "private-\(nextID)", tab: tab, openerID: opener)
        if let opener, let i = pages.firstIndex(where: { $0.id == opener }) {
            var j = i + 1
            while j < pages.count, pages[j].openerID == opener { j += 1 }
            pages.insert(page, at: j)
        } else {
            pages.insert(page, at: 0)
        }
        if show { select(page.id) } else { refresh() }
    }

    func select(_ id: String, focus: Bool = true) {
        guard let p = page(id), !closing else { return }
        shownID = id
        engineWindow.activateTab(p.tab)
        app?.engine.setPictureInPictureWindowActive(p.tab, active: window.isKeyWindow)
        prompts.refresh()
        if focus, commandBar == nil { p.tab.focus() }
        refresh()
    }

    func selectAdjacent(_ offset: Int) {
        guard let i = pages.firstIndex(where: { $0.id == shownID }) ?? (pages.isEmpty ? nil : 0) else { return NSSound.beep() }
        select(pages[(i + offset + pages.count) % pages.count].id)
    }

    func selectTab(number n: Int) {
        guard !pages.isEmpty else { return NSSound.beep() }
        select(pages[n == 9 ? pages.count - 1 : min(n, pages.count) - 1].id)
    }

    /// ⌥⌘W: every tab but the shown one.
    func closeOtherTabs() {
        for p in pages where p.id != shownID { closeTab(p.id) }
    }

    /// ⌘W: the shown tab; with none, the window.
    func closeCurrent() {
        if let id = shownID { closeTab(id) } else { closeWindow() }
    }

    func closeTab(_ id: String) {
        guard let p = page(id), !closingIDs.contains(id) else { return }
        if app?.engine.reportsCloseOutcome == true {
            // The engine reports the end (tabRequestedClose), or that the page kept it (tabCancelledClose).
            closingIDs.insert(id)
            p.tab.close()
        } else {
            p.tab.delegate = nil
            p.tab.close()
            removePage(id)
        }
    }

    private func removePage(_ id: String) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        let p = pages.remove(at: i)
        closingIDs.remove(id)
        p.tab.delegate = nil
        prompts.dropAll(for: p.tab)
        guard !closing else { return }
        if shownID == id {
            shownID = nil
            // The tab below takes its place (Arc's Today), else the one above.
            if !pages.isEmpty { return select(pages[min(i, pages.count - 1)].id) }
            engineWindow.deactivateAll()
        }
        refresh()
    }

    /// The sidebar, the address field and the empty state from the pages.
    func refresh() {
        let shown = shownPage
        empty.isHidden = shown != nil
        sidebar.update(pages: pages, shownID: shownID, closing: closingIDs)
        sidebar.header(canGoBack: shown?.canGoBack ?? false, canGoForward: shown?.canGoForward ?? false,
                       loading: shown?.isLoading ?? false, hasPage: shown != nil)
        let url = shown?.url?.absoluteString ?? ""
        sidebar.urlField.configure(host: URLRules.isNewTab(url) ? "" : URLRules.displayHost(url),
                                   loading: shown?.isLoading == true ? shown?.progress : nil, palette: palette)
        root.needsLayout = true
    }

    func navigate(_ url: URL) {
        guard let page = shownPage else { openPage(url); return }
        // The engine window may open it in the other engine (a DRM service: `replace` brings the new page).
        engineWindow.load(url, in: page)
        shownPage?.focus()
    }

    // MARK: Command Bar (⌘T, ⌘L)

    func openCommandBar(mode: CommandBarMode) {
        if let bar = commandBar {
            // ⌘T / ⌘L again closes it (Arc ref §5).
            let same = bar.mode == mode
            closeCommandBar()
            if same { return }
        }
        CommonSitesIndex.shared.prepare()
        LetterTile.prewarm()
        let bar = CommandBarView(mode: mode, palette: palette, host: self)
        commandBar = bar
        root.addSubview(bar, positioned: .below, relativeTo: toast)
        bar.layoutIn(root.bounds, sidebarFrame: sidebar.frame, contentFrame: card.frame)
        if mode == .editURL { bar.grow(from: sidebar.urlField.convert(sidebar.urlField.bounds, to: bar)) }
        let current = mode == .editURL ? (shownPage?.url?.absoluteString ?? "") : ""
        bar.focus(with: URLRules.isNewTab(current) ? "" : current)
        sidebar.newTabActive = mode == .newTab
    }

    func closeCommandBar() {
        guard let bar = commandBar else { return }
        commandBar = nil
        if let r = window.firstResponder as? NSView, r === bar || r.isDescendant(of: bar) { window.makeFirstResponder(nil) }
        bar.removeFromSuperview()
        sidebar.newTabActive = false
        shownPage?.focus()
    }

    // MARK: Window

    func closeWindow() {
        guard !closing else { return }
        if windowShouldClose(window) { window.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closing = true
        closeCommandBar()
        #if canImport(AircCore)
        // The engine closes the window once the pages' unload handlers have run (one may ask "Leave site?").
        if app?.engine is ChromiumEngine { return ChromiumRuntime.closeWindow(engineWindow) }
        #endif
        for p in pages { p.tab.delegate = nil; p.tab.close() }
        pages = []
        return true
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        commandBar?.removeFromSuperview()
        commandBar = nil
        prompts.dropAll()
        for p in pages { p.tab.delegate = nil }
        pages = []
        shownID = nil
        lights = nil
        PrivateBrowsing.shared.closed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let page = shownPage { app?.engine.setPictureInPictureWindowActive(page, active: true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let page = shownPage { app?.engine.setPictureInPictureWindowActive(page, active: false) }
    }

    func showToast(_ text: String) { toast.show(text, palette: palette, in: card.frame) }

    func copyURL() {
        guard let url = shownPage?.url?.absoluteString, !URLRules.isNewTab(url) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showToast("Copied Current URL")
    }

    func printPage() {
        guard let page = shownPage else { return NSSound.beep() }
        if !page.printPage(from: window) { showToast("Printing isn't available in this engine yet") }
    }

    func zoom(step: Int) {
        guard let page = shownPage else { return }
        page.zoom(step: step)
        showToast(String(format: "%.0f %%", page.zoomFactor * 100))
    }

    func reloadOrStop() {
        guard let p = shownPage else { return }
        if p.isLoading { p.stop() } else { p.reload() }
    }

    private func bringMainWindowForward() {
        guard let w = app?.controller?.window else { return }
        w.makeKeyAndOrderFront(nil)
    }

    /// The private window's own shortcuts while it's the key window (the main window's commands don't reach into it).
    func handleKey(_ event: NSEvent) -> Bool {
        var mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty, var key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // ⌘+ is ⇧⌘= on most layouts.
        if key == "+", mods.contains(.command) { key = "="; mods.remove(.shift) }
        switch (key, mods) {
        case ("t", .command): openCommandBar(mode: .newTab)
        case ("l", .command): openCommandBar(mode: .editURL)
        case ("w", .command): closeCurrent()
        case ("w", [.command, .shift]): closeWindow()
        case ("w", [.command, .option]): closeOtherTabs()
        case ("n", [.command, .shift]): if let app { PrivateBrowsing.shared.open(app: app, from: self) }
        case ("n", .command): bringMainWindowForward()
        case ("r", .command): reloadOrStop()
        case ("r", [.command, .shift]): shownPage?.reloadIgnoringCache()
        case ("[", .command): shownPage?.goBack()
        case ("]", .command): shownPage?.goForward()
        case (BrowserCommand.down, [.command, .option]): selectAdjacent(1)
        case (BrowserCommand.up, [.command, .option]): selectAdjacent(-1)
        case ("=", .command): zoom(step: 1)
        case ("-", .command): zoom(step: -1)
        case ("0", .command): zoom(step: 0)
        case ("p", .command): printPage()
        case ("s", [.command, .shift]): SavePage.offer(for: shownPage, in: window, toast: { [weak self] in self?.showToast($0) })
        case ("c", [.command, .shift]): copyURL()
        case ("i", [.command, .option]): _ = shownPage?.showDevTools(console: false)
        case ("j", [.command, .option]): _ = shownPage?.showDevTools(console: true)
        default:
            if mods == .command, let n = Int(key), (1...9).contains(n) { selectTab(number: n); return true }
            return false
        }
        return true
    }

    /// A main-menu click while this window is in front: the commands that make sense here, by title. False: not one.
    func perform(menuTitle title: String) -> Bool {
        switch title {
        case "New Tab": openCommandBar(mode: .newTab)
        case "Open Location…": openCommandBar(mode: .editURL)
        case "New Private Window": if let app { PrivateBrowsing.shared.open(app: app, from: self) }
        case "Close Tab": closeCurrent()
        case "Close Window": closeWindow()
        case "Close Other Tabs": closeOtherTabs()
        case "Save Page As…": SavePage.offer(for: shownPage, in: window, toast: { [weak self] in self?.showToast($0) })
        case "Print…": printPage()
        case "Copy URL": copyURL()
        case "Reload Page": reloadOrStop()
        case "Reload Ignoring Cache": shownPage?.reloadIgnoringCache()
        case "Back": shownPage?.goBack()
        case "Forward": shownPage?.goForward()
        case "Zoom In": zoom(step: 1)
        case "Zoom Out": zoom(step: -1)
        case "Actual Size": zoom(step: 0)
        case "Next Tab": selectAdjacent(1)
        case "Previous Tab": selectAdjacent(-1)
        case "Developer Tools": _ = shownPage?.showDevTools(console: false)
        case "JavaScript Console": _ = shownPage?.showDevTools(console: true)
        default: return false
        }
        return true
    }
}

// MARK: - Engine callbacks

extension PrivateWindowController: EngineWindowDelegate {
    /// A link in a new tab, or a popup (sign-in windows too): a tab of this window, in its private session.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        let openerID = opener.flatMap { o in pages.first { $0.tab === o }?.id }
        adopt(tab, opener: openerID, show: disposition != .background)
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        guard let p = pages.first(where: { $0.tab === tab }) else { return }
        removePage(p.id)
    }

    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {
        if let p = pages.first(where: { $0.tab === tab }) { closingIDs.remove(p.id) }
        // A page that asked "Leave site?" and was kept also keeps the window.
        closing = false
        refresh()
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}

    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { !closing }

    /// A page opened again in the other engine (a DRM service plays in WebKit, in this session's own non-persistent
    /// store): the same row shows the new page.
    func engineWindow(_ window: EngineWindow, replace old: EngineTab, with new: EngineTab) -> Bool {
        guard !closing, let i = pages.firstIndex(where: { $0.tab === old }) else { return false }
        let p = pages[i]
        prompts.dropAll(for: old)
        old.delegate = nil
        new.delegate = self
        pages[i] = Page(id: p.id, tab: new, openerID: p.openerID)
        if p.id == shownID {
            engineWindow.activateTab(new)
            app?.engine.setPictureInPictureWindowActive(new, active: self.window.isKeyWindow)
            prompts.refresh()
        }
        refresh()
        return true
    }
}

/// Nothing a page does here is recorded: these only redraw the window.
extension PrivateWindowController: EngineTabDelegate {
    func tabDidChangeTitle(_ tab: EngineTab) { refresh() }
    func tabDidChangeURL(_ tab: EngineTab) {
        prompts.pageNavigated(tab)
        refresh()
    }
    func tabDidChangeLoading(_ tab: EngineTab) { refresh() }
    func tabDidChangeFavicon(_ tab: EngineTab) { refresh() }
    func tabDidChangeNavigationState(_ tab: EngineTab) { refresh() }
    func tabDidChangeAudio(_ tab: EngineTab) { refresh() }
    func tabDidChangeThemeColor(_ tab: EngineTab) {}
}

extension PrivateWindowController: PromptHost {
    var promptRoot: NSView { root }
    var promptSibling: NSView? { toast }
    var promptEngineWindow: EngineWindow { engineWindow }
    var promptShownPage: EngineTab? { shownPage }
    var promptTheme: ResolvedTheme { palette.resolved }
    func promptAnchor() -> (view: NSView, rect: NSRect) { (sidebar.urlField, sidebar.urlField.bounds) }
    func promptProfileName(for page: EngineTab) -> String? { "Private" }
    func promptOwns(_ page: EngineTab) -> Bool { pages.contains { $0.tab === page } }
    func promptToast(_ text: String) { showToast(text) }
}

// MARK: - Command Bar host

/// ⌘T here lists this window's own tabs, the built-in sites and the profile's search engine, never any history: this
/// window's pages aren't in history, and the profile's history doesn't show in a private window.
extension PrivateWindowController: CommandBarHost {
    var commandBarChip: String? { "Private" }
    var commandBarAnchorsToURLField: Bool { true }
    var commandBarHistory: (store: HistoryStore, profileID: String)? { nil }
    var commandBarSuggestions: (engine: SearchEngine, profileID: String)? {
        guard app?.settings.values.suggestionsEnabled ?? true else { return nil }
        return (searchEngine, suggestionKey)
    }

    var searchEngine: SearchEngine { app?.store.profile(profileID)?.searchEngine ?? .google }

    private var openURLs: [String] { pages.compactMap { $0.tab.url?.absoluteString }.filter { !URLRules.isNewTab($0) } }

    func inlineCompletion(for typed: String) -> InlineCompletion.Match? {
        guard !typed.isEmpty, !typed.hasPrefix("/") else { return nil }
        return InlineCompletion.complete(typed, candidates: openURLs.map { ($0, 1) })
    }

    func siteCompletion(for typed: String, history: [HistoryMatch]) -> CommonSites.Completion? {
        guard !typed.hasPrefix("/"), let index = WindowController.commonSites,
              let s = index.inlineCompletion(for: typed, region: WindowController.siteRegion) else { return nil }
        if openURLs.contains(where: { s.site.covers(url: $0) }) { return nil }
        return s
    }

    /// Rows never fetch an icon (the app's favicon cache is on disk, and outside the private session): a site or an
    /// address gets a globe; an open tab, the icon its page already has.
    private func siteRow(_ site: CommonSites.Site, matches: [Int]) -> CommandResult? {
        guard let url = URL(string: site.url) else { return nil }
        return CommandResult(title: site.name, subtitle: URLRules.displayURL(site.url), badge: "Open",
                             icon: .symbol("globe"), matches: matches, action: .open(url))
    }

    private func actions() -> [WindowController.CommandAction] {
        var a: [WindowController.CommandAction] = [
            .init(title: "New Private Window", symbol: "eye.slash", hint: "⇧⌘N", keywords: ["incognito", "window"]) { [weak self] in
                guard let self, let app = self.app else { return }
                PrivateBrowsing.shared.open(app: app, from: self)
            },
            .init(title: "Close Private Window", symbol: "xmark.square", hint: "⇧⌘W", keywords: ["incognito", "window"]) { [weak self] in
                self?.closeWindow()
            },
        ]
        if shownPage != nil {
            a += [
                .init(title: "Copy URL", symbol: "link", hint: "⇧⌘C", keywords: ["link"]) { [weak self] in self?.copyURL() },
                .init(title: "Reload", symbol: "arrow.clockwise", hint: "⌘R", keywords: ["refresh"]) { [weak self] in self?.reloadOrStop() },
                .init(title: "Close Tab", symbol: "xmark", hint: "⌘W", keywords: ["tab"]) { [weak self] in self?.closeCurrent() },
            ]
        }
        return a
    }

    func commandResults(for query: String, mode: CommandBarMode, inline: InlineCompletion.Match?,
                        inlineSite: CommonSites.Site?, suggestions: [String], history: [HistoryMatch]) -> [CommandResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let acts = actions()
        if q.hasPrefix("/") {
            let rest = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            let candidates = acts.enumerated().map { i, a in
                CommandSearch.Candidate(id: "\(i)", kind: .action, title: a.title, keywords: a.keywords, boost: -Double(i) * 0.01)
            }
            return CommandSearch.rank(rest, candidates).compactMap { r in
                guard let i = Int(r.candidate.id) else { return nil }
                let a = acts[i]
                return CommandResult(title: a.title, subtitle: "", badge: "Run", icon: .symbol(a.symbol),
                                     matches: r.titleMatches, action: .run(a.run), shortcut: CommandResult.keys(of: a.hint))
            }
        }
        var candidates: [CommandSearch.Candidate] = []
        var rows: [String: CommandResult] = [:]
        for (i, p) in pages.enumerated() where p.id != shownID {
            let url = p.tab.url?.absoluteString ?? ""
            let title = p.tab.title.isEmpty ? URLRules.displayHost(url) : p.tab.title
            candidates.append(.init(id: p.id, kind: .openTab, title: title, subtitle: URLRules.displayURL(url), boost: -Double(i) * 0.01))
            rows[p.id] = CommandResult(title: title, subtitle: URLRules.displayHost(url), badge: "Switch to Tab",
                                       icon: .favicon(image: p.tab.favicon, url: nil, page: nil), matches: [], action: .tab(p.id))
        }
        for a in acts {
            let id = "action:" + a.title
            candidates.append(.init(id: id, kind: .action, title: a.title, keywords: a.keywords))
            rows[id] = CommandResult(title: a.title, subtitle: "", badge: "Run", icon: .symbol(a.symbol),
                                     matches: [], action: .run(a.run), shortcut: CommandResult.keys(of: a.hint))
        }
        // ⌘T on its own: this window's other tabs.
        if q.isEmpty {
            return CommandSearch.rank("", candidates.filter { $0.kind == .openTab }, limit: 6).compactMap { rows[$0.candidate.id] }
        }
        let engine = searchEngine
        let search = { (text: String, subtitle: String) in
            CommandResult(title: text, subtitle: subtitle, badge: "Search", icon: .symbol("magnifyingglass"), matches: [],
                          action: .open(engine.searchURL(for: text)))
        }
        var out: [CommandResult] = []
        if inline != nil, let site = inlineSite, let row = siteRow(site, matches: CommandSearch.score(q, in: site.name)?.matches ?? []) {
            out.append(row)
            out.append(search(q, AircCommandText.searchSubtitle(engine: engine.name)))
        } else if let m = inline, let url = URL(string: m.url) {
            out.append(CommandResult(title: m.text, subtitle: "", badge: "Open", icon: .symbol("globe"),
                                     matches: Array(0..<m.typedCount), action: .open(url)))
            out.append(search(q, AircCommandText.searchSubtitle(engine: engine.name)))
        } else if let u = URLRules.normalizeInput(q), let url = URL(string: u) {
            out.append(CommandResult(title: q, subtitle: "", badge: "Open", icon: .symbol("globe"),
                                     matches: [], action: .open(url)))
        } else {
            out.append(search(q, AircCommandText.searchSubtitle(engine: engine.name)))
        }
        let personal = CommandSearch.rank(q, candidates, limit: 5)
        var sites: [CommonSites.Match] = []
        if let index = WindowController.commonSites {
            let typedURL = URLRules.normalizeInput(q)
            sites = index.search(q, region: WindowController.siteRegion, limit: CommandSearch.maxSitesForName + 1).filter { m in
                m.site != inlineSite && !(typedURL.map { m.site.covers(url: $0) } ?? false)
            }
        }
        var ranked = CommandSearch.blend(personal, sites: sites, personalURLs: openURLs + [inline?.url].compactMap { $0 }, limit: 6)
            .compactMap { b -> CommandResult? in
                switch b {
                case .personal(let r):
                    guard var row = rows[r.candidate.id] else { return nil }
                    row.matches = r.titleMatches
                    return row
                case .site(let m):
                    return siteRow(m.site, matches: m.matches)
                }
            }
        out += ranked.prefix(3)
        ranked.removeFirst(min(3, ranked.count))
        for s in suggestions.prefix(3) where s.lowercased() != q.lowercased() { out.append(search(s, "")) }
        out += ranked
        return Array(out.prefix(AircMetrics.CommandBar.maxRows))
    }

    func performCommand(_ action: CommandResult.Action, newTab: Bool, typed: Bool) {
        switch action {
        case .open(let url): if newTab { openPage(url) } else { navigate(url) }
        case .tab(let id): select(id)
        case .run(let block): block()
        case .item, .space: break
        }
    }
}

// MARK: - Views

/// The window's root: lays out the sidebar and the page; a press nothing takes drags the window (like RootView).
final class PrivateRootView: NSView {
    weak var controller: PrivateWindowController?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func layout() {
        super.layout()
        controller?.layout()
    }
}

/// The sidebar: Back, Forward and Reload where the main window has them, the address field, the "Private" row (Arc's
/// incognito label, its eye-slash icon), New Tab and this window's tabs, and a line saying what's kept.
final class PrivateSidebarView: NSView {
    weak var controller: PrivateWindowController?
    var palette: Palette! { didSet { restyle() } }
    let back = GlyphButton(symbol: "arrow.left", size: 14)
    let forward = GlyphButton(symbol: "arrow.right", size: 14)
    let reload = GlyphButton(symbol: "arrow.clockwise", size: 14)
    let urlField = PrivateURLField()
    let badge = PrivateBadgeRow()
    private let divider = CALayer()
    let newTab = PrivateNewTabRow()
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private(set) var rows: [PrivateTabRow] = []
    private let note = NSTextField(wrappingLabelWithString: "Airc doesn’t keep this window’s history. Its cookies and site data go when you close it.")

    var newTabActive = false { didSet { newTab.isSelected = newTabActive } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [back, forward, reload] { addSubview(b) }
        back.toolTip = "Back"
        forward.toolTip = "Forward"
        reload.toolTip = "Reload"
        back.action = { [weak self] in self?.controller?.shownPage?.goBack() }
        forward.action = { [weak self] in self?.controller?.shownPage?.goForward() }
        reload.action = { [weak self] in self?.controller?.reloadOrStop() }
        addSubview(urlField)
        urlField.onClick = { [weak self] in self?.controller?.openCommandBar(mode: .editURL) }
        addSubview(badge)
        wantsLayer = true
        layer?.addSublayer(divider)
        addSubview(newTab)
        newTab.onClick = { [weak self] in self?.controller?.openCommandBar(mode: .newTab) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        addSubview(scroll)
        note.font = AircFont.caption.appFont
        note.isSelectable = false
        addSubview(note)
        setAccessibilityLabel("Private window sidebar")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func restyle() {
        guard let palette else { return }
        for b in [back, forward, reload] {
            b.tint = palette.glyph
            b.hoverFill = palette.hover
        }
        badge.palette = palette
        newTab.palette = palette
        newTab.updateStyle()
        note.textColor = palette.textMuted
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.backgroundColor = palette.separator.cgColor
        CATransaction.commit()
        rows.forEach { $0.palette = palette; $0.updateStyle() }
    }

    func header(canGoBack: Bool, canGoForward: Bool, loading: Bool, hasPage: Bool) {
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        reload.isEnabled = hasPage
        reload.symbol = loading ? "xmark" : "arrow.clockwise"
    }

    func update(pages: [PrivateWindowController.Page], shownID: String?, closing: Set<String>) {
        while rows.count < pages.count {
            let r = PrivateTabRow()
            r.palette = palette
            r.onSelect = { [weak self, weak r] in if let id = r?.pageID { self?.controller?.select(id) } }
            r.onClose = { [weak self, weak r] in if let id = r?.pageID { self?.controller?.closeTab(id) } }
            r.onToggleMute = { [weak r] in if let t = r?.tab { t.isMuted.toggle(); r?.refresh() } }
            list.addSubview(r)
            rows.append(r)
        }
        while rows.count > pages.count { rows.removeLast().removeFromSuperview() }
        for (r, p) in zip(rows, pages) {
            r.configure(id: p.id, tab: p.tab, palette: palette, selected: p.id == shownID, closing: closing.contains(p.id))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let s = AircMetrics.Sidebar.headerButton
        let y = AircMetrics.Sidebar.headerCenterY - s / 2
        reload.frame = NSRect(x: w - DesignGaps.headerButtonEndInset - s, y: y, width: s, height: s)
        forward.frame = reload.frame.offsetBy(dx: -AircMetrics.Sidebar.headerButtonPitch, dy: 0)
        back.frame = forward.frame.offsetBy(dx: -AircMetrics.Sidebar.headerButtonPitch, dy: 0)
        // Clear of the traffic lights (they end at x 73).
        back.isHidden = back.frame.minX < 76
        forward.isHidden = forward.frame.minX < 76
        let inset = AircMetrics.Sidebar.inset
        urlField.frame = NSRect(x: inset, y: AircMetrics.Sidebar.urlFieldTop, width: w - 2 * inset, height: AircMetrics.Sidebar.urlFieldHeight)
        // Where the Space name row is in the main window (DesignGaps.favoritesTop below the field: no Favorites here).
        var top = urlField.frame.maxY + AircMetrics.Sidebar.inset
        badge.frame = NSRect(x: 0, y: top, width: w, height: AircMetrics.Row.height)
        top = badge.frame.maxY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        divider.frame = NSRect(x: inset + 10, y: top + 7, width: w - 2 * inset - 20, height: 1)
        CATransaction.commit()
        top += DesignGaps.dividerBlock
        newTab.frame = NSRect(x: 0, y: top, width: w, height: AircMetrics.Row.height)
        top = newTab.frame.maxY + (AircMetrics.Row.pitch - AircMetrics.Row.height)
        let noteSize = note.sizeThatFits(NSSize(width: w - 36, height: 200))
        let noteY = bounds.height - 14 - noteSize.height
        note.frame = NSRect(x: 18, y: noteY, width: w - 36, height: noteSize.height)
        scroll.frame = NSRect(x: 0, y: top, width: w, height: max(0, noteY - 10 - top))
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.frame.height, CGFloat(rows.count) * AircMetrics.Row.pitch))
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * AircMetrics.Row.pitch, width: w, height: AircMetrics.Row.height)
        }
    }
}

/// The address field: the host only, 36 pt (SB-2); a click opens the Command Bar over it.
final class PrivateURLField: NSView {
    private let label = AircAddressFieldLabel(theme: PrivateWindowController.privatePalette.resolved)
    private let progress = CALayer()
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.row
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(label)
        layer?.addSublayer(progress)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Address")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    var host: String? { label.host }

    func configure(host: String, loading: Double?, palette: Palette) {
        layer?.backgroundColor = palette.urlFieldFill.cgColor
        label.theme = palette.resolved
        label.host = host.isEmpty ? nil : host
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.backgroundColor = palette.textSecondary.withAlphaComponent(0.35).cgColor
        if let loading, loading < 1 {
            progress.isHidden = false
            progress.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width * max(0.08, loading), height: 2)
        } else {
            progress.isHidden = true
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = AircAddressFieldLabel.frame(inField: bounds, trailingControlMinX: nil)
    }
}

/// "Private" with the eye-slash, where a Space's name row is: what this window is, in the sidebar only (Arc).
final class PrivateBadgeRow: NSView {
    private let icon = CALayer()
    private let label = NSTextField(labelWithString: "Private")
    var palette: Palette? { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.contentsGravity = .center
        icon.actions = LayerImage.noActions
        layer?.addSublayer(icon)
        label.font = AircFont.spaceName.appFont
        addSubview(label)
        toolTip = "A private window: Airc doesn’t keep its history, and its cookies and site data go when you close it."
        setAccessibilityElement(true)
        setAccessibilityLabel("Private window")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    private func restyle() {
        guard let palette else { return }
        label.textColor = palette.spaceName
        LayerImage.set(LayerImage.symbol("eye.slash", size: 14, weight: .semibold, color: palette.spaceName), on: icon, in: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if LayerImage.scaleChanged(icon, in: self) { restyle() }
    }

    override func layout() {
        super.layout()
        let f = AircMetrics.SpaceHeader.iconFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = NSRect(x: AircMetrics.SpaceHeader.iconCenterX - f / 2, y: (bounds.height - f) / 2, width: f, height: f)
        CATransaction.commit()
        let x = AircMetrics.SpaceHeader.nameX - DesignGaps.labelInset
        label.frame = NSRect(x: x, y: (bounds.height - 18) / 2, width: max(0, bounds.width - x - 12), height: 18)
    }
}

/// "+ New Tab" (SB-41): opens the Command Bar.
final class PrivateNewTabRow: SidebarRowView {
    private let plus = CALayer()
    private let label = NSTextField(labelWithString: "New Tab")
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.contentsGravity = .center
        plus.actions = LayerImage.noActions
        layer?.addSublayer(plus)
        label.font = AircFont.row.appFont
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New Tab")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateStyle() {
        super.updateStyle()
        guard let palette else { return }
        LayerImage.set(LayerImage.symbol("plus", size: 15, weight: .regular, color: palette.textFaint), on: plus, in: self)
        label.textColor = palette.textMuted
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plus.frame = NSRect(x: AircMetrics.Row.faviconX - 1, y: (h - 20) / 2, width: 20, height: 20)
        CATransaction.commit()
        let x = AircMetrics.Row.titleX - DesignGaps.labelInset
        label.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, bounds.width - x - 17), height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        pressAnimation()
        onClick?()
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }
}

/// One tab of the window (SB-44's row): its icon from the engine only (never fetched by the app, so no request leaves
/// the private session), the title, the loading ring, the speaker, ✕ on hover.
final class PrivateTabRow: SidebarRowView {
    private(set) var pageID: String?
    private(set) weak var tab: EngineTab?
    private let favicon = FaviconView()
    private let title = AircFadingLabel(style: AircFont.row)
    private let loading = AircLoadingIndicator()
    private let close = GlyphButton(symbol: "xmark", size: 11)
    private let audio = GlyphButton(symbol: "speaker.wave.2.fill", size: 11)
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleMute: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = AircFont.row.appFont
        title.lineBreakMode = .byClipping
        addSubview(favicon)
        addSubview(title)
        layer?.addSublayer(loading.layer)
        loading.onVisibilityChange = { [weak self] on in
            NSAnimationContext.runAnimationGroup {
                $0.duration = AircMetrics.Loading.fade
                self?.favicon.animator().alphaValue = on ? 0 : 1
            }
        }
        close.action = { [weak self] in self?.onClose?() }
        close.isHidden = true
        close.toolTip = "Close Tab (⌘W)"
        addSubview(close)
        audio.action = { [weak self] in self?.onToggleMute?() }
        audio.isHidden = true
        addSubview(audio)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(id: String, tab: EngineTab, palette: Palette, selected: Bool, closing: Bool) {
        pageID = id
        self.tab = tab
        self.palette = palette
        refresh()
        alphaValue = closing ? 0.5 : 1
        isSelected = selected
        updateStyle()
    }

    func refresh() {
        guard let tab, let palette else { return }
        let url = tab.url?.absoluteString ?? ""
        let text = !tab.title.isEmpty ? tab.title : URLRules.isNewTab(url) ? "New Tab" : URLRules.displayHost(url)
        if title.stringValue != text { title.stringValue = text }
        title.textColor = palette.textPrimary
        setAccessibilityLabel(text)
        favicon.set(image: tab.favicon, url: nil, fallbackPage: nil, palette: palette)
        for b in [close, audio] {
            b.tint = palette.textSecondary
            b.hoverFill = palette.hover
        }
        audio.symbol = tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        audio.isHidden = !(tab.isAudible || tab.isMuted)
        loading.apply(palette.resolved)
        loading.setLoading(tab.isLoading)
        needsLayout = true
    }

    override func updateStyle() {
        super.updateStyle()
        close.isHidden = !isHovered
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let fs = AircMetrics.Row.favicon
        favicon.frame = NSRect(x: AircMetrics.Row.faviconX, y: (h - fs) / 2, width: fs, height: fs)
        var x = AircMetrics.Row.titleX - DesignGaps.labelInset
        if !audio.isHidden {
            audio.frame = NSRect(x: x - 4, y: (h - 22) / 2, width: 22, height: 22)
            x += 22
        }
        let right = bounds.width - AircMetrics.Row.titleTrailing - (isHovered ? AircMetrics.Row.closeButton : 0)
        title.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - x), height: 18)
        let cb = AircMetrics.Row.closeButton
        close.frame = NSRect(x: bounds.width - AircMetrics.Sidebar.inset - 5 - cb, y: (h - cb) / 2, width: cb, height: cb)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loading.layer.position = CGPoint(x: favicon.frame.midX, y: favicon.frame.midY)
        CATransaction.commit()
    }

    // A tab activates on press, not release (SB-44).
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        pressAnimation()
        onSelect?()
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }
}

/// The page card with no tab: what this window is, and ⌘T.
struct PrivateEmptyView: View {
    let theme: ResolvedTheme
    var onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "eye.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.surfaceTextSecondary.color)
                .frame(height: 48)
            Text("You’re browsing privately")
                .aircFont(AircFont.title2)
                .foregroundStyle(theme.surfaceText.color)
                .padding(.top, AircMetrics.EmptySpace.nameGap + 4)
            Text("Pages you open in this window stay out of your history, and their cookies and site data are deleted when you close the last private window. Files you download stay in your Downloads folder.")
                .aircFont(AircFont.body)
                .foregroundStyle(theme.surfaceTextSecondary.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, AircMetrics.EmptySpace.profileGap)
            Button(action: onNewTab) {
                HStack(spacing: 4) {
                    AircKeycap("⌘")
                    AircKeycap("T")
                    Text("New Tab").aircFont(AircFont.body).foregroundStyle(theme.surfaceTextTertiary.color).padding(.leading, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, AircMetrics.EmptySpace.hintGap)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, AircMetrics.EmptySpace.liftAboveCentre)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.color)
        .aircTheme(theme)
        .accessibilityElement(children: .combine)
    }
}

/// The traffic lights where the main window has them (AircMetrics.Window.trafficLightCenters), kept there when AppKit
/// lays out the titlebar again (WindowController.positionTrafficLights, without its full-screen and sidebar cases).
final class TrafficLights {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var placing = false

    init(window: NSWindow) {
        self.window = window
        place()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func place() {
        guard let window, !placing else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let container = first.superview?.superview else { return }
        guard !window.styleMask.contains(.fullScreen) else { return }
        placing = true
        defer { placing = false }
        if observers.isEmpty {
            for v in [container] + buttons {
                v.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v,
                                                                        queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { DispatchQueue.main.async { self?.place() } }
                })
            }
        }
        let h = first.frame.height
        let top = AircMetrics.Window.trafficLightCenters[0].y
        let containerHeight = top + h / 2 + 2
        var cf = container.frame
        cf.size.height = containerHeight
        cf.origin.y = window.frame.height - containerHeight
        if container.frame != cf { container.frame = cf }
        for (b, c) in zip(buttons, AircMetrics.Window.trafficLightCenters) {
            let o = NSPoint(x: c.x - b.frame.width / 2, y: containerHeight - c.y - h / 2)
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
    }
}
