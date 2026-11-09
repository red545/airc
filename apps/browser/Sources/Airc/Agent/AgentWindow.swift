// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // agentspike: a dev-build prototype (docs/agent-ready.md); public builds compile none of Agent/
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
    // Agent input goes straight to the page's view; a key arriving here is one WebKit sent back unhandled: it stops
    // here (no beep, no responder chain).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged { return }
        super.sendEvent(event)
    }
}

/// One agent window: one profile's pages (tabs), shown one at a time at the window's size.
final class AgentWindow: NSObject, EngineWindowDelegate, EngineTabDelegate {
    struct Tab { let id: Int; let tab: EngineTab }
    private static var nextID = 1
    let id: Int
    let profileID: String
    let ownerKey: String
    let client: String
    let size: CGSize
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
        id = AgentWindow.nextID
        AgentWindow.nextID += 1
        self.profile = profile
        self.profileID = profileID
        self.ownerKey = ownerKey
        self.client = client
        self.size = size
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
            self.window.setFrameOrigin(AgentWindow.offscreenFrame(self.size).origin)
        }
    }

    deinit { if let o = screensObserver { NotificationCenter.default.removeObserver(o) } }

    /// Opens a page in this window and shows it.
    @discardableResult
    func openTab(_ url: URL?, show: Bool = true, completion: ((Int) -> Void)? = nil) -> Int {
        engineWindow.activeProfile = profile
        let tab = engineWindow.openTab(url: url, profile: profile, foreground: false)
        return adopt(tab, show: show, completion: completion)
    }

    private static var nextTabID = 1

    @discardableResult
    private func adopt(_ tab: EngineTab, show: Bool, completion: ((Int) -> Void)? = nil) -> Int {
        let id = AgentWindow.nextTabID
        AgentWindow.nextTabID += 1
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
        engineWindow.activateTab(t.tab)
        t.tab.view.frame = engineWindow.hostView.bounds
        t.tab.focus()
    }

    func closeTab(_ tabID: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
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

    func close() {
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

    // MARK: EngineWindowDelegate

    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        // A page's new tab or popup opens here, in the same profile, and a foreground one is shown.
        adopt(tab, show: disposition != .background)
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        if let t = tabs.first(where: { $0.tab === tab }) { closeTab(t.id) }
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}
    /// A page that would play in the other engine stays here (agent windows are one engine's).
    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { false }

    // MARK: EngineTabDelegate (nothing to show; the tools read the tab's state when asked)

    func tabDidChangeTitle(_ tab: EngineTab) {}
    func tabDidChangeURL(_ tab: EngineTab) {}
    func tabDidChangeLoading(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}
}
#endif
