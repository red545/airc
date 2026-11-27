// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit

/// The window an agent's pages live in. It can never become key or main, takes no clicks from the person's mouse,
/// isn't in the Window menu, ⌘` or Mission Control, and sits off every screen: ordered in (so pages are live and the
/// engine gives it a window number), but nowhere anyone can see it, and never in front of anything.
final class AgentHostWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Never let AppKit or a page bring it forward.
    override func makeKeyAndOrderFront(_ sender: Any?) { orderBack(sender) }
    override func makeKey() {}
    override func orderFrontRegardless() {}
    /// A window the engine hangs on this one (its passkey sheet, a permission bubble) asks for the person: macOS would
    /// put it on some other Space, top left, nobody knowing why (owner report 2026-11-23). It goes over the Watch that
    /// shows this window's page instead, or waits off screen until one opens (AgentPrompts).
    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(child, ordered: place)
        #if AIRC_TESTING
        if AgentWatchView.legacy { return }
        #endif
        AgentPrompts.shared.engineChild(child, of: self)
    }
    /// Back here while no Watch shows the page (AgentPrompts.watchChanged).
    func attachHeld(_ child: NSWindow) { super.addChildWindow(child, ordered: .above) }
    // Agent input goes straight to the page's view; a key arriving here is one WebKit sent back unhandled: it stops
    // here (no beep, no responder chain).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged { return }
        super.sendEvent(event)
    }
}

/// One agent window: one profile's pages (tabs), shown one at a time at the window's size.
///
/// agentmainview (owner decision 2026-11-23): the Airc Agent's own pages are *hosted*: each is a real tab in the person's
/// window (AgentMainView), shown in the main view while it's selected there, and parked here (off screen, kept live, at
/// the same viewport size) while the person looks at another tab. A hosted tab is in `tabs` all the time, so the tools
/// find it either way; `parked` says where its page is now. Outside apps' pages are never hosted.
final class AgentWindow: NSObject, EngineWindowDelegate, EngineTabDelegate {
    struct Tab {
        let id: Int
        let tab: EngineTab
        /// A page that belongs to a person's tab (AgentMainView) rather than to this window.
        var hosted = false
    }
    private static var nextID = 1
    let id: Int
    let profileID: String
    let ownerKey: String
    let client: String
    /// The viewport the agent sees (screenshots, coordinates): a hosted page's real size in the person's window while
    /// it's shown there, else this window's.
    var size: CGSize {
        if let t = tabs.first(where: { $0.id == activeTabID }), t.hosted, !isParked(t.tab) {
            let b = t.tab.view.bounds.size
            if b.width >= 1, b.height >= 1 { return b }
        }
        return baseSize
    }
    private(set) var baseSize: CGSize
    let window: AgentHostWindow
    let engineWindow: EngineWindow
    let profile: EngineProfile
    let driver: AgentPageDriver
    /// Pages stay visible and focused for the engine (off: the engine treats them as a hidden window's pages).
    let keepsVisible: Bool
    private(set) var tabs: [Tab] = []
    private(set) var activeTabID: Int?
    /// The computer-use cursor, in page points.
    var cursor = CGPoint.zero
    var lastUsed = Date()
    /// The app behind the connection, for the Agents folder ("Claude · Gmail") and Stop.
    var clientName: String?
    var clientKey: String?
    /// The Airc Agent's run window: its pages are hosted in the person's window (AgentMainView).
    var hostsInMainView = false
    /// agentparallel: the Airc Agent task whose run owns this window (nil for outside apps).
    var taskID: String?
    /// Tabs opened, closed, or a page's title or address changed (the Agents folder's rows follow).
    var onTabsChanged: (() -> Void)?
    private var screensObserver: NSObjectProtocol?

    var activeTab: EngineTab? { tabs.first { $0.id == activeTabID }?.tab }

    /// Left of every screen, so not even a corner shows.
    static func offscreenFrame(_ size: CGSize) -> NSRect {
        let union = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        return NSRect(x: union.minX - size.width - 4000, y: union.minY, width: size.width, height: size.height)
    }

    init(engine: BrowserEngine, profile: EngineProfile, profileID: String, ownerKey: String, client: String,
         size: CGSize, driver: AgentPageDriver, keepsVisible: Bool) {
        // watchfix: the page part that holds an agent page's passkey request for the person, before its first document.
        AgentPrompts.shared.install()
        id = AgentWindow.nextID
        AgentWindow.nextID += 1
        self.profile = profile
        self.profileID = profileID
        self.ownerKey = ownerKey
        self.client = client
        self.baseSize = size
        self.driver = driver
        self.keepsVisible = keepsVisible
        let frame = AgentWindow.offscreenFrame(size)
        let w = AgentHostWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isExcludedFromWindowsMenu = true
        w.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        w.ignoresMouseEvents = true
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.backgroundColor = .white
        w.title = "Agent window \(id)"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.autoresizesSubviews = true
        w.contentView = content
        window = w
        engineWindow = (engine as? EngineCallHosting)?.makeWindow(hosting: w) ?? engine.makeWindow(contentRect: frame)
        super.init()
        #if canImport(AircCore)
        ChromiumAgentDriver.markInternal(engineWindow)
        #endif
        let host = engineWindow.hostView
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        if host.superview !== content { content.addSubview(host) }
        engineWindow.delegate = self
        engineWindow.activeProfile = profile
        engineWindow.prepareProfile(profile)
        // Behind everything (an inactive app's orderFront would put it above other apps' windows), and off screen.
        w.orderBack(nil)
        w.setFrameOrigin(frame.origin)
        // A display added on the left later must not land on it.
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.window.setFrameOrigin(AgentWindow.offscreenFrame(self.baseSize).origin)
        }
    }

    deinit { if let o = screensObserver { NotificationCenter.default.removeObserver(o) } }

    /// Opens a page in this window and shows it.
    @discardableResult
    func openTab(_ url: URL?, show: Bool = true, completion: ((Int) -> Void)? = nil) -> Int {
        engineWindow.activeProfile = profile
        let tab = engineWindow.openTab(url: url, profile: profile, foreground: false)
        let id = adopt(tab, show: show, completion: completion)
        // open_tab in a hosted run: the new page is the person's tab too (the first one is placed by AgentMainView).
        if hostsInMainView { AgentMainView.shared.agentOpened(self, id, foreground: show) }
        return id
    }

    private static var nextTabID = 1

    @discardableResult
    private func adopt(_ tab: EngineTab, show: Bool, as wanted: Int? = nil, completion: ((Int) -> Void)? = nil) -> Int {
        let id: Int
        if let wanted, wanted < AgentWindow.nextTabID, !tabs.contains(where: { $0.id == wanted }) {
            id = wanted
        } else {
            id = AgentWindow.nextTabID
            AgentWindow.nextTabID += 1
        }
        tab.delegate = self
        tabs.append(Tab(id: id, tab: tab))
        if show || activeTabID == nil { select(id) }
        driver.prepare(tab, in: window, visible: keepsVisible) { _ in completion?(id) }
        onTabsChanged?()
        return id
    }

    func select(_ tabID: Int) {
        guard let t = tabs.first(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
        // A hosted page outside this window: the person's window shows it (if it showed the agent's last one).
        if t.hosted, !isParked(t.tab) { return AgentMainView.shared.agentSelected(self, t.tab) }
        defer { if t.hosted { AgentMainView.shared.agentSelected(self, t.tab) } }
        engineWindow.activateTab(t.tab)
        t.tab.view.frame = engineWindow.hostView.bounds
        t.tab.focus()
    }

    func closeTab(_ tabID: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabs[i].hosted { return unhost(tabID, closing: true) }
        let t = tabs.remove(at: i)
        driver.release(t.tab)
        // No "Leave site?" for an agent's page: nobody would see the question.
        driver.dropUnloadQuestion(t.tab) { [tab = t.tab] in tab.close() }
        if activeTabID == tabID {
            activeTabID = nil
            if let next = tabs.last { select(next.id) } else { engineWindow.deactivateAll() }
        }
        onTabsChanged?()
    }

    func tab(_ tabID: Int) -> EngineTab? { tabs.first { $0.id == tabID }?.tab }

    /// Take over: the tab leaves this window without closing (its page moves to the person's window). Nil when it's
    /// gone.
    func detach(_ tabID: Int) -> EngineTab? {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let t = tabs.remove(at: i)
        driver.release(t.tab)
        driver.handBack(t.tab)
        if t.tab.delegate === self { t.tab.delegate = nil }
        if activeTabID == tabID {
            activeTabID = nil
            if let next = tabs.last { select(next.id) }
        }
        onTabsChanged?()
        return t.tab
    }

    /// A detached page comes back: the person's window couldn't take it (a new tab id), or the person handed it back
    /// (`as`: the tab id it had here before, so the agent's list_tabs still knows it).
    @discardableResult
    func reattach(_ tab: EngineTab, as id: Int? = nil) -> Int {
        engineWindow.activeProfile = profile
        return adopt(tab, show: true, as: id)
    }

    func close() {
        // Hosted pages are the person's tabs: they stay (the run's end leaves them as ordinary tabs).
        for t in tabs where t.hosted { unhost(t.id, closing: false) }
        for t in tabs { closeTab(t.id) }
        // Let the pages' closes go out before the window does; this object lives until then (it holds the engine's
        // window and its tabs).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            window.orderOut(nil)
            #if canImport(AircCore)
            // Chromium closes its own window (after the pages' unload).
            if !ChromiumRuntime.closeWindow(engineWindow) { return }
            #endif
            window.close()
        }
    }

    // MARK: Hosted pages (agentmainview)

    /// A page in a person's window becomes one of this window's tabs (shown to the agent: the active one). Its delegate
    /// stays the person's window; AgentMainView forwards what this window needs.
    @discardableResult
    func host(_ page: EngineTab, as wanted: Int? = nil) -> Int {
        let id: Int
        if let wanted, wanted < AgentWindow.nextTabID, !tabs.contains(where: { $0.id == wanted }) { id = wanted } else {
            id = AgentWindow.nextTabID
            AgentWindow.nextTabID += 1
        }
        tabs.append(Tab(id: id, tab: page, hosted: true))
        outside.insert(ObjectIdentifier(page))
        activeTabID = id
        if let w = page.view.window { driver.prepare(page, in: w, visible: true) { _ in } }
        driver.holdFramesOnHide(page, true)
        onTabsChanged?()
        return id
    }

    func markHosted(_ id: Int) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].hosted = true } }
    func unmarkHosted(_ id: Int) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].hosted = false } }

    func isHosted(_ page: EngineTab) -> Bool { tabs.contains { $0.tab === page && $0.hosted } }
    func hostedID(_ page: EngineTab) -> Int? { tabs.first { $0.tab === page }?.id }

    /// Hosted pages whose page is in a person's window now (the others are here: parked).
    private var outside: Set<ObjectIdentifier> = []

    /// Whether a page is here now (parked), not in a person's window.
    func isParked(_ page: EngineTab) -> Bool { !outside.contains(ObjectIdentifier(page)) }

    /// The person looks at another tab: the page comes here at the size it had there, so the agent's coordinates stay
    /// right and the pane's card shows it live (kept visible, as Watch's pages are).
    func park(_ page: EngineTab, size: CGSize) -> Bool {
        guard isHosted(page), !page.isClosed else { return false }
        if size.width >= 320, size.height >= 240, size != baseSize {
            baseSize = size
            var f = window.frame
            f.size = size
            f.origin = AgentWindow.offscreenFrame(size).origin
            window.setFrame(f, display: false)
        }
        do { try engineWindow.moveTab(page, profile: profile, to: engineWindow.hostView) } catch { return false }
        outside.remove(ObjectIdentifier(page))
        page.delegate = self
        engineWindow.activeProfile = profile
        engineWindow.activateTab(page)
        page.view.frame = engineWindow.hostView.bounds
        driver.keepLive(page)
        rearmAfterMove(page)
        #if !canImport(AircCore)
        // WebKit: its occlusion detection goes off again for this window (the web view moved; it would throttle).
        driver.prepare(page, in: window, visible: true) { _ in }
        #else
        if !(driver is ChromiumAgentDriver) { driver.prepare(page, in: window, visible: true) { _ in } }
        #endif
        return true
    }

    /// The page leaves (the person's window took it back: it's still hosted).
    func unparked(_ page: EngineTab) {
        outside.insert(ObjectIdentifier(page))
        if page.delegate === self { page.delegate = nil }
        driver.keepLive(page)
        // agentmainfix: in the main view a navigation to a new view keeps the last frame until the new one draws (engine
        // patch 042, as the pane's card does): Chromium showed the card's empty fill for a frame at an early navigation.
        driver.holdFramesOnHide(page, true)
        rearmAfterMove(page)
    }

    /// A page that changed windows gets a fresh kept-visible session once the engine has moved it (Chromium: its old
    /// window hid it on the way out).
    private func rearmAfterMove(_ page: EngineTab) {
        #if canImport(AircCore)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak page] in
            guard let self, let page, !page.isClosed else { return }
            (self.driver as? ChromiumAgentDriver)?.rearm(page)
        }
        #endif
    }

    /// A hosted page stops being the agent's: the run ended (the person keeps the tab), the agent closed it, or the
    /// person closed it. Parked pages go back to their person's window first (AgentMainView).
    func unhost(_ tabID: Int, closing: Bool) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), tabs[i].hosted else { return }
        let t = tabs.remove(at: i)
        driver.release(t.tab)
        driver.handBack(t.tab)
        driver.holdFramesOnHide(t.tab, false)
        if t.tab.delegate === self { t.tab.delegate = nil }
        if activeTabID == tabID { activeTabID = tabs.last?.id }
        AgentMainView.shared.unhosted(self, t.tab, closing: closing)
        outside.remove(ObjectIdentifier(t.tab))
        onTabsChanged?()
    }

    /// The person's window reports a hosted page's address change (its delegate is theirs).
    func hostedURLChanged(_ page: EngineTab) {
        #if canImport(AircCore)
        if keepsVisible { (driver as? ChromiumAgentDriver)?.rearm(page) }
        #endif
        onTabsChanged?()
    }
    func hostedTitleChanged(_ page: EngineTab) { onTabsChanged?() }

    // MARK: EngineWindowDelegate

    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        // A page's new tab or popup opens here, in the same profile, and a foreground one is shown. A hosted run's
        // pages are the person's tabs: AgentMainView makes it one too.
        let id = adopt(tab, show: disposition != .background)
        if let opener, isHosted(opener) { AgentMainView.shared.agentOpened(self, id, foreground: disposition != .background) }
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        guard let t = tabs.first(where: { $0.tab === tab }) else { return }
        if t.hosted { return AgentMainView.shared.pageClosedItself(self, tab) }
        closeTab(t.id)
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
    /// A page that would play in the other engine stays here (agent windows are one engine's).
    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { false }

    // MARK: EngineTabDelegate (the tools read the tab's state when asked; the Agents folder follows titles and addresses)

    func tabDidChangeTitle(_ tab: EngineTab) {
        AgentMainView.shared.parkedTitleChanged(self, tab)
        onTabsChanged?()
    }
    func tabDidChangeURL(_ tab: EngineTab) {
        AgentMainView.shared.parkedTitleChanged(self, tab)
        #if canImport(AircCore)
        if keepsVisible { (driver as? ChromiumAgentDriver)?.rearm(tab) }
        #endif
        onTabsChanged?()
    }
    func tabDidChangeLoading(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}
}
