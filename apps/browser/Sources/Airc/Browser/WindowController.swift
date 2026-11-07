// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import Combine

/// The root view: themed background, sidebar, page card and overlays. Layout is driven by the
/// controller so the sidebar's hide/show can reflow the page every frame.
final class RootView: NSView {
    weak var controller: WindowController?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    /// A press no view takes (the margins, the sidebar's empty areas, the background) drags the window (Arc). It comes
    /// here up the responder chain; the window itself isn't movable by its background (setUpWindow).
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func layout() {
        super.layout()
        controller?.layoutRoot()
        controller?.positionTrafficLightsIfMoved()
    }
}

/// One browser window: owns the engine window, maps Airc tabs to engine tabs, and drives the
/// sidebar, page card, Command Bar and Space switching.
final class WindowController: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    let store: SpacesStore
    let profiles: ProfileHost
    let engineWindow: EngineWindow
    var window: NSWindow { engineWindow.window }

    let root = RootView()
    let background = ThemeBackgroundView(theme: DesignTheme.default.resolved(systemIsDark: false))
    let sidebar = SidebarView()
    let card = PageCardView()
    let toast = ToastView()
    let resizeHandle = SidebarResizeHandle()
    var commandBar: CommandBarView?
    /// The bar between openings (built at idle, reused: CommandBarView.reuse).
    var spareCommandBar: CommandBarView?
    var newSpacePanel: NewSpacePanelHost?
    /// Coalesces the New Space card's spare-page prerenders.
    var prerenderToken = 0
    /// Arc's Create Profile card (SP-11) while open.
    var createProfilePanel: CreateProfilePanelHost?
    var stepObserver: AnyCancellable?
    /// Renders the empty view of the Space the New Space card would make, a moment after its name, icon or profile
    /// changes.
    var newSpaceObserver: AnyCancellable?
    /// The theme picker (Create a Space, Edit Theme Color…) while open.
    var themePopover: ThemePickerPanel?
    /// ⌘F's field over the page while open.
    var findBar: FindBarView?
    /// "Spotify plays with Safari's engine" while it shows (ProtectedMediaUI.swift).
    var protectedMediaToast: ProtectedMediaToastView?
    var extensionsPopover: NSPopover?
    /// The install review card while it's open (scripted runs answer it).
    var pendingExtensionReview: ExtensionInstallPanelHost?
    /// MEM-3 on engines that don't unload by themselves: when each loaded tab stopped being shown.
    var hiddenSince: [String: Date] = [:]
    var unloadTimer: Timer?
    var unloadQueued = false
    var memoryPressure: DispatchSourceMemoryPressure?
    /// The Library (SB-62) while open, and how far it has slid in (0…1).
    var library: LibraryPanelHost?
    var libraryFraction: CGFloat = 0
    lazy var folderPreview = FolderPreviewController(controller: self)
    /// Tab rows that left a page, for the next one any page needs.
    let tabRowPool = TabRowPool()
    lazy var animator = FrameAnimator(view: root)

    /// Airc tab ID → engine page. A tab without a page is "unloaded".
    private(set) var pages: [String: EngineTab] = [:]
    private var tabIDByPage: [ObjectIdentifier: String] = [:]
    /// Tabs whose page was asked to close and hasn't closed yet. Chromium runs a page's beforeunload first; when the page
    /// asks ("Leave site?") the tab stays in the sidebar until the engine closes the page (`tabRequestedClose`), and if
    /// the person stays, nothing changes.
    private(set) var closingTabs: Set<String> = []
    /// Clear Today / Archive Tabs Below in progress: the tab whose page is deciding ("Leave site?"), the tabs after it,
    /// how they're archived, and the tab to go back to.
    private(set) var archiveQueue: ArchiveQueue?
    struct ArchiveQueue {
        var current: String
        var rest: [String]
        var reason: ArchiveReason
        var label: String
        var returnTo: String?
        var shownForDialog = false
    }
    private var archiveDialogObserver: NSObjectProtocol?
    /// SV-2: a pinned or Favorite split closing pane by pane, each page asked in turn (ItemSplitActions.swift).
    var paneCloseQueue: PaneCloseQueue?
    /// PK-1: the link open in Peek over the page (Peek.swift), and the last one closed (⌘Z brings it back).
    var peek: Peek?
    var recentlyClosedPeek: (url: URL?, undoCount: Int, at: Date)?
    /// SV-1: the split on screen, its panes (SplitView.swift), and the drop preview over the page while a tab is dragged
    /// there. `shownTabID` is then its focused pane.
    private(set) var shownSplitID: String?
    lazy var splitContainer: SplitContainerView = {
        let v = SplitContainerView(controller: self)
        v.isHidden = true
        root.addSubview(v, positioned: .above, relativeTo: card)
        return v
    }()
    lazy var splitDropPreview: SplitDropPreviewView = {
        let v = SplitDropPreviewView()
        root.addSubview(v, positioned: .below, relativeTo: sidebar)
        return v
    }()
    /// ⌃⇧+ / "+" → New Split View: the Command Bar's pick opens as a new pane next to this tab.
    var pendingSplit: PendingSplit?
    var paneClickMonitor: Any?
    private(set) var shownTabID: String?
    private(set) var currentSpaceID: String
    /// Profile ID → the Space of that profile shown last (M2).
    private var lastSpaceByProfile: [String: String] = [:]
    private var pageViews: [String: SpacePageView] = [:]

    // Sidebar geometry (WIN-4, SB-60).
    var sidebarWidth: CGFloat
    /// 1 = docked, 0 = hidden. Animated by ⌘S.
    var sidebarFraction: CGFloat
    var sidebarHidden: Bool
    /// WIN-5: the sidebar on the window's right, for every window (Browser/SidebarSide.swift).
    var sidebarOnRight: Bool
    var isFullscreen = false
    /// Native full screen: the traffic lights with the menu bar, Esc to leave, the toast (FullScreen.swift).
    lazy var fullScreen = FullScreenController(controller: self)
    var systemDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private var reloadScheduled = false
    /// > 0 while a Space switch runs: its own store writes (selection, last-active) change nothing on screen, so
    /// they don't trigger a sidebar reload (§2.12 budget).
    private var quiet = 0
    private var prewarmScheduled = false
    /// A refresh of the spare Command Bar's rows is due (scheduleSpareBarRefresh).
    var spareRefreshScheduled = false
    /// Sidebar or pane drags being tracked (their event loops run timers and the main queue too).
    var dragsInProgress = 0
    /// Tabs whose next committed URL was typed (Command Bar), for history's typed count.
    private var typedNavigations: Set<String> = []
    /// The address each tab last added to history (a page moved in from another window keeps its own, WIN-7).
    var lastRecordedURL: [String: String] = [:]
    private var colorAnimating = false
    private var colorToken = 0
    private var renderings: [String: (SpaceTheme, Bool, Palette)] = [:]
    /// The theme the New Space / theme sheet is previewing on the current Space, if any.
    var previewTheme: SpaceTheme?
    /// MEM-6: no repeating timers. Deferred store writes are flushed 2 s after they happen (a run-loop observer arms
    /// a one-shot when there are any), and auto-archive waits for the next Today tab's deadline.
    private var trafficLightObservers: [NSObjectProtocol] = []
    private var positioningTrafficLights = false
    private var trafficLightsNeedPositioning = false
    private var flushArmed = false
    private var flushObserver: CFRunLoopObserver?
    private var archiveTimer: Timer?
    private var archiveRescheduleQueued = false
    /// SB-43 auto-archive: pages asked to close (waiting for the engine), and pages that would have asked "Leave site?"
    /// with when to try them again.
    private(set) var autoArchiveClosing: Set<String> = []
    private(set) var autoArchiveRetryAt: [String: Date] = [:]
    var revealController: SidebarRevealController?
    /// WIN-7: this window's own tab per Space, and "Open in another window" (Browser/MultiWindow.swift).
    var multiWindow = MultiWindowState()
    /// SB-3: the engine's permission, password and autofill prompts, under the URL field (PagePrompts.swift).
    lazy var prompts = PromptPresenter(host: self)

    /// `opening` (WIN-7): the Space, tab and sidebar of a second window or a restored one; by default the last Space and
    /// its last tab.
    init(store: SpacesStore, profiles: ProfileHost, engine: BrowserEngine, frame: NSRect, app: AppDelegate? = nil,
         opening: WindowOpening = WindowOpening()) {
        self.app = app
        self.store = store
        self.profiles = profiles
        engineWindow = engine.makeWindow(contentRect: frame)
        currentSpaceID = opening.spaceID.flatMap { store.space($0)?.id } ?? store.selectedSpace.id
        sidebarWidth = CGFloat(opening.sidebarWidth ?? store.windowState.sidebarWidth)
        sidebarHidden = opening.sidebarHidden ?? store.windowState.sidebarHidden
        sidebarFraction = sidebarHidden ? 0 : 1
        sidebarOnRight = store.windowState.sidebarOnRight
        super.init()
        engineWindow.delegate = self
        // Picture in picture's Back to Tab and Little Arc's mini player: once for the app, to the window with the page.
        app?.installWindowHooksOnce()
        if let app { app.windowSession.openCount += 1; multiWindow.openedAt = app.windowSession.openCount }
        setUpWindow(frame: frame)
        if let t = app?.settings.translucency { background.translucency = t }
        rebuildPages()
        store.observe { [weak self] change in self?.storeDidChange(change) }
        let first: String? = switch opening.tab {
        case .spaceLast: preferredTab(forSpace: currentSpaceID)
        case .none: nil
        case .id(let id): store.tab(id) != nil ? id : preferredTab(forSpace: currentSpaceID)
        }
        applySpace(currentSpaceID)
        if let first { show(first, focus: false, takeOver: false) } else { showEmpty() }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.armFlush()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        flushObserver = observer
        scheduleArchive()
        revealController = SidebarRevealController(controller: self)
        setUpUnloading()
        setUpExtensionInstalls()
        setUpSplitFocus()
        DefaultBrowserReminder.attach(self)
        app?.promptCenter?.register(prompts)
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine { ProtectedMedia.installWidevineProbe() }
        #endif
        setUpMediaLibrary()
    }

    // MARK: Window

    private func setUpWindow(frame: NSRect) {
        let w = window
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        // Not movable by its background (owner P0, 2026-11-05: clicks into the page did nothing). With it, the window
        // server drags the window on a press over any view that answers mouseDownCanMoveWindow, without asking the
        // app, and Chromium's page view always does: a real click on a page moved the window by zero points instead of
        // reaching the page. RootView drags the window for the presses nothing else takes. (Scripted clicks are posted
        // to the app and never pass the window server, so the checks hadn't seen it.)
        w.isMovableByWindowBackground = false
        w.tabbingMode = .disallowed
        w.isRestorable = false
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.minSize = NSSize(width: 640, height: 420)
        w.title = "Airc"
        w.delegate = self
        root.controller = self
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.wantsLayer = true
        w.contentView = root
        root.addSubview(background)
        root.addSubview(card)
        root.addSubview(sidebar)
        root.addSubview(resizeHandle)
        root.addSubview(toast)
        resizeHandle.controller = self
        card.embed(engineWindow.hostView)
        card.onNewTab = { [weak self] in self?.openCommandBar(mode: .newTab) }
        sidebar.connect(self)
        sidebar.header.onRight = sidebarOnRight
        positionTrafficLights()
    }

    func layoutRoot() {
        let b = root.bounds
        background.frame = b
        let s = sidebarWidth
        let f = sidebarFraction
        // Laid out as for a sidebar on the left, then mirrored when it's on the right (WIN-5).
        if revealController?.isRevealed != true {
            sidebar.frame = mirroredForSidebar(NSRect(x: -s * (1 - f), y: 0, width: s, height: b.height))
        }
        let i = AircMetrics.Window.cardInset
        // The Library slides in from the left at 417 pt and pushes the card (Arc ref §5).
        let lw = AircMetrics.Library.width
        let docked = i + (s - i) * f
        let x = docked + max(0, lw - docked) * libraryFraction
        library?.frame = mirroredForSidebar(NSRect(x: -lw * (1 - libraryFraction), y: 0, width: lw, height: b.height))
        // Fully out, it doesn't draw at all (its controls poked out at the window's edge otherwise).
        library?.isHidden = libraryFraction <= 0.001
        // The sidebar gives way to the Library, which draws on the window's own theme like the sidebar does.
        let sidebarAlpha = 1 - min(1, libraryFraction * 1.6)
        if sidebar.alphaValue != sidebarAlpha { sidebar.alphaValue = sidebarAlpha }
        card.frame = mirroredForSidebar(NSRect(x: x, y: i, width: max(0, b.width - x - i), height: max(0, b.height - 2 * i)))
        if shownSplitID != nil, splitContainer.frame != card.frame { splitContainer.frame = card.frame }
        resizeHandle.frame = NSRect(x: (sidebarOnRight ? sidebar.frame.minX : sidebar.frame.maxX) - 4, y: 0, width: 8, height: b.height)
        resizeHandle.isHidden = f < 1 || revealController?.isRevealed == true
        commandBar?.layoutIn(root.bounds, sidebarFrame: sidebar.frame, contentFrame: card.frame)
        if let spare = spareCommandBar, !spare.isLaidOut(in: root.bounds, contentFrame: card.frame) { scheduleSpareBarRefresh() }
        newSpacePanel?.layoutIn(root.bounds, sidebarFrame: sidebar.frame)
        createProfilePanel?.layoutIn(page: card.frame)
        pendingExtensionReview?.layoutIn(page: card.frame)
        layoutFindBar()
        layoutProtectedMediaToast()
        revealController?.layout()
        layoutPeek()
        prompts.layout()
    }

    /// Traffic lights sit in the sidebar at Arc's centres (20,24), (43,24), (66,24).
    ///
    /// `-[NSThemeFrame layout]` tiles the titlebar again (`_updateSidebarPositionIfNeeded` → `_updateButtonPositions`)
    /// whenever the theme frame needs layout, which on Chromium happens after the engine has installed its views, and
    /// puts the buttons back at the macOS default spot (visual review #1). The buttons and their container are watched.
    /// A button ignores a move made from inside its own frame notification (`setFrameOrigin:ignoreRentry:`), so the
    /// last one AppKit moves (zoom) is put back from the root view's layout, which runs right after the theme frame's
    /// in the same pass, before anything is drawn.
    func positionTrafficLights() {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard let first = buttons.first, let container = first.superview?.superview else { return }
        guard !positioningTrafficLights else { return }
        positioningTrafficLights = true
        defer { positioningTrafficLights = false }
        if trafficLightObservers.isEmpty {
            for v in [container] + buttons {
                v.postsFrameChangedNotifications = true
                trafficLightObservers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: v, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trafficLightsMoved() }
                })
            }
        }
        // In full screen the buttons are in AppKit's titlebar window, which shows them only with the menu bar.
        let visible = isFullscreen || (sidebarFraction >= 1 && revealController?.isRevealed != true)
        buttons.forEach { $0.isHidden = !visible }
        guard !isFullscreen else { return }
        // Never lay out a titlebar AppKit keeps in its full-screen titlebar window (a transition, or one that failed):
        // moving it there makes AppKit tile it again, and the two called each other until the stack overflowed when
        // leaving full screen (fsexit, 2026-11-06).
        guard container.window === window, !window.styleMask.contains(.fullScreen) else { return }
        let h = first.frame.height
        let top = AircMetrics.Window.trafficLightCenters[0].y
        let containerHeight = top + h / 2 + 2
        var cf = container.frame
        cf.size.height = containerHeight
        cf.origin.y = window.frame.height - containerHeight
        container.frame = cf
        for (b, c) in zip(buttons, AircMetrics.Window.trafficLightCenters) {
            b.setFrameOrigin(NSPoint(x: c.x - b.frame.width / 2, y: containerHeight - c.y - h / 2))
        }
    }

    private func trafficLightsMoved() {
        guard !positioningTrafficLights else { return }
        // AppKit retiling its titlebar reports each move here. Where it and this layout want different frames, every
        // answer starts another round one level deeper (`_updateTitlebarContainerViewFrameIfNecessary` ↔
        // `_syncToolbarPosition`) and none returns: leaving full screen overflowed the main thread's stack that way
        // (fsexit, 2026-11-06). Past a quarter of the stack, stop answering; the next turn puts the buttons back.
        guard Self.stackInUse < Self.titlebarStackLimit else {
            trafficLightsNeedPositioning = true
            DispatchQueue.main.async { [weak self] in self?.positionTrafficLightsIfMoved() }
            return
        }
        positionTrafficLights()
        trafficLightsNeedPositioning = true
        root.needsLayout = true
        // In case no layout pass follows (the theme frame was tiled outside one).
        DispatchQueue.main.async { [weak self] in self?.positionTrafficLightsIfMoved() }
    }

    /// A quarter of the main thread's stack (8 MB), at least 1 MB: far above a layout pass, far below an overflow.
    private static let titlebarStackLimit = max(1 << 20, pthread_get_stacksize_np(pthread_self()) / 4)
    /// How much of this thread's stack is in use (it grows down from its top).
    private static var stackInUse: Int {
        var here = 0
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        return withUnsafeMutablePointer(to: &here) { Int(bitPattern: top &- UInt(bitPattern: $0)) }
    }

    /// Called from RootView.layout().
    func positionTrafficLightsIfMoved() {
        guard trafficLightsNeedPositioning else { return }
        trafficLightsNeedPositioning = false
        positionTrafficLights()
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    /// The Command Bar's field edits in its own editor, without text checking (CommandBarView.fieldEditor).
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        for bar in [commandBar, spareCommandBar].compactMap({ $0 }) where bar.isInput(client) { return bar.fieldEditor }
        return nil
    }
    func windowDidBecomeKey(_ notification: Notification) {
        positionTrafficLights()
        // WIN-7: commands, links and the app's panels follow the key window.
        app?.browserWindowBecameKey(self)
        pictureInPictureWindowActiveChanged()
        mediaLibraryWindowBecameKey()
    }
    func windowDidMove(_ notification: Notification) { app?.scheduleSessionSave() }
    func windowDidResignKey(_ notification: Notification) { pictureInPictureWindowActiveChanged() }

    /// SB-55: the engine enters automatic picture-in-picture only for a tab left in the active window (as Chrome);
    /// it hears the key state from the shown page (engine/PIP.md).
    private func pictureInPictureWindowActiveChanged() {
        guard let page = shownTabID.flatMap({ pages[$0] }) else { return }
        app?.engine.setPictureInPictureWindowActive(page, active: window.isKeyWindow)
    }

    /// SB-55: "back to tab" in a picture-in-picture window shows its tab, in its Space, in the front window.
    func showPictureInPictureTab(_ page: EngineTab) {
        guard let id = tabID(for: page), let tab = store.tab(id) else { return }
        if let sid = tab.spaceID, sid != currentSpaceID { switchToSpace(sid, animated: false) }
        show(id)
        // Scripted runs never activate the app: it would take focus on the owner's screen mid-suite (and change which
        // window is key for the checks after it).
        if LaunchOptions.current.isAutomated { window.orderFront(nil) } else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillEnterFullScreen(_ notification: Notification) { fullScreen.willEnter() }
    func windowDidEnterFullScreen(_ notification: Notification) { fullScreen.didEnter() }
    func windowWillExitFullScreen(_ notification: Notification) { fullScreen.willExit() }
    func windowDidExitFullScreen(_ notification: Notification) { fullScreen.didExit() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { fullScreen.didFailToEnter() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullScreen.didFailToExit() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if downloadsHoldClose() { return false }
        // WIN-7: the last window leaves Chromium's profiles loaded for the next one.
        app?.keepProfilesIfLastWindowCloses(self)
        #if canImport(AircCore)
        return ChromiumRuntime.closeWindow(engineWindow)
        #else
        return true
        #endif
    }

    func windowWillClose(_ notification: Notification) {
        if let m = paneClickMonitor { NSEvent.removeMonitor(m); paneClickMonitor = nil }
        prompts.dropAll()
        trafficLightObservers.forEach(NotificationCenter.default.removeObserver)
        trafficLightObservers = []
        saveWindowFrame()
        try? store.flush()
        // WIN-7: one of several windows (or the last, with Airc staying open): its timers go with it; its pages close
        // with the window (Chromium's engine closes them, the dev engine's go with their web views).
        if let o = flushObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes); flushObserver = nil }
        archiveTimer?.invalidate()
        archiveTimer = nil
        unloadTimer?.invalidate()
        unloadTimer = nil
        memoryPressure?.cancel()
        app?.browserWindowWillClose(self)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveWindowFrame()
        schedulePrewarm()
    }

    private func saveWindowFrame() {
        let f = window.frame
        store.updateWindowState { $0.frame = [f.origin.x, f.origin.y, f.width, f.height] }
        app?.scheduleSessionSave()
    }

    // MARK: Theme

    func palette(for space: Space) -> Palette {
        let dark = systemDark
        // TH-1: while a theme is being picked, the current Space draws with it: background *and* ink.
        if let preview = previewTheme, space.id == currentSpaceID { return Palette(theme: preview, systemDark: dark) }
        if let cached = renderings[space.id], cached.0 == space.theme, cached.1 == dark { return cached.2 }
        let p = Palette(theme: space.theme, systemDark: dark)
        renderings[space.id] = (space.theme, dark, p)
        return p
    }

    var currentPalette: Palette { palette(for: store.space(currentSpaceID) ?? store.selectedSpace) }

    /// Translucency setting (design §4.1): Off · Subtle · More.
    func applyTranslucency(_ t: AircTranslucency) {
        background.translucency = t
        schedulePrewarm()
    }

    /// Something is moving (a live resize, a Space slide or its colour, a drag in the sidebar or of a pane): idle work
    /// waits.
    var isBusyForIdleWork: Bool { window.inLiveResize || sidebar.pager.isTrackingOrSettling || colorAnimating || dragsInProgress > 0 }

    /// Renders every Space's background at the window's size while nothing else is happening, so switching never
    /// renders one.
    func schedulePrewarm() {
        guard !prewarmScheduled else { return }
        prewarmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.prewarmScheduled = false
            if self.isBusyForIdleWork { return self.schedulePrewarm() }
            self.background.prewarm(self.store.orderedSpaces.map { self.palette(for: $0).resolved })
            self.prepareSparePage()
            self.card.prewarmEmptyView()
            if self.spareCommandBar == nil && self.commandBar == nil {
                let bar = CommandBarView(mode: .newTab, palette: self.currentPalette, host: self)
                bar.preloadRows(AircMetrics.CommandBar.maxRows)
                self.root.addSubview(bar)
                bar.park()
                self.spareCommandBar = bar
                bar.prewarmEditing()
                bar.prepareForNextOpening(palette: self.currentPalette, in: self.root.bounds, sidebarFrame: self.sidebar.frame,
                                          contentFrame: self.card.frame)
            } else {
                self.scheduleSpareBarRefresh()
            }
        }
    }

    // MARK: Store changes

    private func storeDidChange(_ change: StoreChange) {
        if change.windowStateChanged { sidebarSideMayHaveChanged() }
        // A page's URL, title or icon: pageChanged already refreshed its row; no sidebar rebuild (M3).
        if change.contentOnly { return }
        scheduleSpareBarRefresh()
        queueArchiveReschedule()
        if change.touches(.space) || change.touches(.profile) {
            renderings = renderings.filter { store.space($0.key) != nil }
            if quiet == 0 { schedulePrewarm() }
        }
        if quiet > 0 { return }
        scheduleReload()
    }

    func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadAll(animated: true)
        }
    }

    func reloadAll(animated: Bool) {
        applyKeepLoadedPolicy()
        if store.space(currentSpaceID) == nil { currentSpaceID = store.selectedSpace.id }
        // WIN-7: another window closed, archived or moved what this one shows.
        reconcileWithOtherWindows()
        syncSplitPresentation()
        rebuildPages()
        for p in pageViews.values { p.reload(animated: animated && p.spaceID == currentSpaceID) }
        refreshChrome()
        if !sidebar.pager.isTrackingOrSettling, !colorAnimating {
            let index = store.orderedSpaces.firstIndex { $0.id == currentSpaceID } ?? 0
            if abs(sidebar.pager.position - Double(index)) > 0.001 { sidebar.pager.apply(Double(index)) }
            else { pagerDidMove(to: sidebar.pager.position) }
        }
    }

    /// Store writes inside this scope don't schedule a sidebar reload; the caller updates exactly what changed.
    func beginQuiet() { quiet += 1 }
    func endQuiet() { quiet -= 1 }

    /// A new Space's page, built and drawn now, without reloading the other pages.
    func addPage(for spaceID: String) {
        Perf.time("new.addPage.build") { rebuildPages() }
        // rebuildPages already renders new pages (or refreshes the pre-rendered spare's header).
        // Re-rendering here invalidates the rows we drew before Enter.
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_NEW_SPACE_BASELINE"] == "1" {
            Perf.time("new.addPage.reload") { pageView(for: spaceID)?.reload(animated: false) }
            refreshChrome()
        }
        #endif
        // The caller immediately switches to this Space; show()/showEmpty() refreshes chrome
        // with its palette. Refreshing here first redraws chrome with the outgoing Space's palette.
        schedulePrewarm()   // the next spare page
    }

    /// A page view built ahead (at idle) for the next new Space.
    private var sparePage: SpacePageView?

    /// Not in the window until the New Space card prerenders it (nothing walks or draws it before).
    private func prepareSparePage() {
        guard sparePage == nil else { return }
        let p = SpacePageView(spaceID: "spare", palette: currentPalette, controller: self)
        p.frame = NSRect(x: 0, y: 0, width: sidebar.pager.pageWidth, height: sidebar.pager.bounds.height)
        sparePage = p
    }

    private func takeSparePage(for s: Space) -> SpacePageView? {
        guard let p = sparePage else { return nil }
        sparePage = nil
        if let pre = p.prerendered, pre.profileID == s.profileID, pre.theme == s.theme { prerenderedClaims.insert(ObjectIdentifier(p)) }
        p.claim(spaceID: s.id, palette: palette(for: s))
        return p
    }

    /// Spare pages claimed by a new Space whose profile and theme `prerenderNewSpacePage` already drew.
    private var prerenderedClaims: Set<ObjectIdentifier> = []

    /// Draws the spare page ahead as the Space the New Space card would create (its profile and theme; the name is
    /// set at Create), just right of the last page, where nothing shows it. New Space then claims a drawn page.
    func prerenderNewSpacePage(profileID: String, theme: AircKit.SpaceTheme, name: String = "", icon: String? = nil) {
        prepareSparePage()
        guard let p = sparePage else { return }
        let space = Space(id: "spare", name: name, icon: icon.map(SpaceIcon.emoji), theme: theme, profileID: profileID, createdAt: Date())
        if let pre = p.prerendered, pre.profileID == profileID, pre.theme == theme, p.superview != nil {
            // Only the name or icon changed: the header is drawn with them, so Create has nothing left to draw there.
            p.prerenderHeader(space)
            return
        }
        let pager = sidebar.pager
        p.frame = NSRect(x: pager.pageWidth * CGFloat(pager.pages.count), y: 0, width: pager.pageWidth, height: pager.bounds.height)
        p.isHidden = false
        // Drawn in the window (only attached layers draw), past the last page where the pager's clip hides it.
        if p.superview !== pager.strip { pager.strip.addSubview(p) }
        p.prerender(space)
    }

    /// The New Space card closed without creating: the spare page leaves the window again.
    func hideSparePage() { sparePage?.removeFromSuperview() }

    private func rebuildPages() {
        let spaces = store.orderedSpaces
        var ordered: [SpacePageView] = []
        for s in spaces {
            let v = pageViews[s.id] ?? takeSparePage(for: s) ?? SpacePageView(spaceID: s.id, palette: palette(for: s), controller: self)
            pageViews[s.id] = v
            ordered.append(v)
        }
        for id in pageViews.keys where store.space(id) == nil { pageViews[id] = nil }
        if ordered.map(\.spaceID) != sidebar.pager.pages.map(\.spaceID) {
            let before = Set(sidebar.pager.pages.map(ObjectIdentifier.init))
            sidebar.pager.setPages(ordered)
            sidebar.pager.layoutSubtreeIfNeeded()
            // Pages that were already there keep their rows; only new ones are drawn (a new Space mustn't redraw
            // every Space's sidebar).
            for p in ordered where !before.contains(ObjectIdentifier(p)) {
                if prerenderedClaims.remove(ObjectIdentifier(p)) != nil { p.refreshHeader() } else { p.reload(animated: false) }
            }
        }
    }

    /// Header buttons, footer, card colour: everything outside the pages.
    func refreshChrome() {
        let pal = currentPalette
        let t = pages[shownTabID ?? ""]
        sidebar.header.configure(palette: pal, canGoBack: t?.canGoBack ?? false, canGoForward: t?.canGoForward ?? false,
                                 loading: t?.isLoading ?? false, hasPage: t != nil)
        let profilesInUse = Set(store.state.spaces.values.map(\.profileID))
        sidebar.footer.configure(spaces: store.orderedSpaces, profiles: store.state.profiles, palette: pal,
                                 multipleProfiles: profilesInUse.count > 1,
                                 provisional: newSpacePanel.map { $0.model.icon ?? "" })
        card.palette = pal
        sidebar.update.palette = pal
        // Only while it shows: hidden, it may hold the Space the New Space card will make (prepareEmptySpace), and
        // `showEmpty` sets it before showing it.
        if card.showsEmptyState { card.emptySpace = emptySpaceContent() }
        commandBar?.palette = pal
        library?.setTheme(pal.resolved)
        mediaLibraryChromeChanged()
    }

    /// What the card shows while the current Space has no tab: its icon and name, and its profile while several are
    /// in use.
    private func emptySpaceContent() -> PageCardView.EmptySpace {
        guard let space = store.state.spaces[currentSpaceID] else { return card.emptySpace }
        let emoji: String? = if case .emoji(let e)? = space.icon { e } else { nil }
        return emptySpaceContent(name: space.name, emoji: emoji, profileID: space.profileID, adding: false)
    }

    /// `adding`: for a Space about to be made (the New Space card), whose profile counts as in use.
    func emptySpaceContent(name: String, emoji: String?, profileID: String, adding: Bool) -> PageCardView.EmptySpace {
        var profilesInUse = Set(store.state.spaces.values.map(\.profileID))
        if adding { profilesInUse.insert(profileID) }
        let identity = profilesInUse.count > 1 ? store.state.profiles[profileID].map {
            AircProfileIdentity(name: $0.name, emoji: $0.emoji, color: $0.color.aircColor, account: $0.googleAccount)
        } : nil
        return PageCardView.EmptySpace(emoji: emoji, name: name, profile: identity)
    }

    func pageView(for spaceID: String) -> SpacePageView? { pageViews[spaceID] }

    // MARK: Tabs ↔ engine pages

    func engineTab(for tabID: String) -> EngineTab? { pages[tabID] }

    /// The tab a Space's page shows: the window's tab for the current Space, else its last one.
    func displayedTabID(forSpace spaceID: String) -> String? {
        spaceID == currentSpaceID ? shownTabID : preferredTab(forSpace: spaceID)
    }

    /// Creates the engine page for a tab if it has none (pinned tabs and Favorites load lazily).
    @discardableResult
    private func ensurePage(_ tabID: String) -> EngineTab? {
        if let p = pages[tabID] { return p }
        // WIN-7: another window has the page: it moves here, live.
        if let moved = takePageFromOtherWindow(tabID) { return moved }
        guard let tab = store.tab(tabID), let profile = profiles.engineProfile(for: tab.profileID) else { return nil }
        let url = URL(string: tab.url).flatMap { URLRules.isNewTab($0.absoluteString) ? nil : $0 }
        // MEM-3: a WebKit page unloaded after the timeout comes back with its history and scroll position.
        let page = reopenUnloadedPage(tabID, url: url, profile: profile)
            ?? engineWindow.openTab(url: url, profile: profile, foreground: false)
        adopt(page, as: tabID)
        return page
    }

    func adopt(_ page: EngineTab, as tabID: String) {
        page.delegate = self
        pages[tabID] = page
        tabIDByPage[ObjectIdentifier(page)] = tabID
        applyKeepLoadedPolicy()
    }

    /// Loads a tab's page without showing it (the perf workload's recent tabs, the leak cycle).
    @discardableResult func loadPageInBackground(_ tabID: String) -> EngineTab? { ensurePage(tabID) }

    /// Closes a scratch tab and its page without archiving it (the perf harness's open/close cycles).
    func discardScratchTab(_ tabID: String) {
        dropPage(tabID)
        try? store.forgetTab(tabID)
    }

    /// Frees a tab's page; the tab stays and loads again when shown (MEM-3 on the dev engine).
    func unloadPage(_ tabID: String) { dropPage(tabID) }

    func dropPage(_ tabID: String) {
        hiddenSince[tabID] = nil
        closingTabs.remove(tabID)
        guard let p = pages.removeValue(forKey: tabID) else { return }
        prompts.dropAll(for: p)
        tabIDByPage[ObjectIdentifier(p)] = nil
        p.delegate = nil
        p.close()
    }

    func tabID(for page: EngineTab) -> String? { tabIDByPage[ObjectIdentifier(page)] }

    /// Forgets a tab's page without closing it (the caller closed it, or the engine did).
    func removePageMapping(_ tabID: String) {
        closingTabs.remove(tabID)
        guard let p = pages.removeValue(forKey: tabID) else { return }
        tabIDByPage[ObjectIdentifier(p)] = nil
    }

    /// Puts a tab's page in the card (a view swap, no reload) and marks it viewed. `updatesRows: false` when the
    /// sidebar already shows this tab as selected (a Space switch to the tab its page shows).
    /// `takeOver` (WIN-7): a pick (a row, ⌘1–9, the Command Bar) moves a page another window shows here; a Space switch,
    /// a swipe or a closed tab's neighbour (false) shows "Open in another window" instead.
    func show(_ tabID: String, focus: Bool = true, updatesRows: Bool = true, defersNewPage: Bool = false, takeOver: Bool = true) {
        bringBackFromCallWindow(tabID)
        guard let tab = store.tab(tabID) else { return }
        if let other = app?.window(showing: tabID, except: self) {
            guard takeOver else { return showElsewhere(tabID, updatesRows: updatesRows) }
            other.pageLeaving(tabID)
        }
        let wasElsewhere = multiWindow.elsewhereTabID != nil
        // SV-1: a tab in a split shows its split, with its pane focused.
        if let x = store.split(containing: tabID), store.members(of: x).count >= 2, store.space(x.spaceID) != nil,
           showSplit(x, focus: tabID, focusPage: focus, updatesRows: updatesRows) { return }
        if wasElsewhere { hideElsewhere() }
        if shownSplitID != nil { leaveSplitPresentation() }
        if let profile = profiles.engineProfile(for: tab.profileID) { engineWindow.activeProfile = profile }
        if defersNewPage, pages[tabID] == nil {
            // A Space never shown since launch: its sidebar and colour arrive this frame, its page (a new web view,
            // tens of ms) right after it.
            engineWindow.deactivateAll()
            card.showsEmptyState = false
            shownTabID = tabID
            prompts.refresh()
            try? store.activate(tabID, inSpace: currentSpaceID)
            refreshChrome()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shownTabID == tabID else { return }
                self.show(tabID, focus: focus, updatesRows: false, takeOver: takeOver)
            }
            noteShown(tabID)
            return
        }
        if findBar != nil, tabID != shownTabID { closeFind(refocusPage: false) }
        if peek != nil, tabID != shownTabID { closePeek() }
        guard let page = Perf.time("show.ensurePage", { ensurePage(tabID) }) else { return }
        // SB-45: the page leaving is pictured while it's still drawn (Sidebar/TabPreview.swift).
        tabPreview.pageWillChange(hiding: shownTabID, showing: tabID)
        Perf.time("show.activateTab") { engineWindow.activateTab(page) }
        app?.engine.setPictureInPictureWindowActive(page, active: window.isKeyWindow)
        card.showsEmptyState = false
        // Back from "Open in another window": the page is new to this card.
        let previous = wasElsewhere ? nil : shownTabID
        shownTabID = tabID
        noteShown(tabID)
        if previous != tabID {
            pageVisibilityChanged(hidden: previous, shown: tabID)
            scheduleSpareBarRefresh()   // ⌘T lists the other tabs, most recent first
        }
        Perf.time("show.storeActivate") { try? store.activate(tabID, inSpace: currentSpaceID) }
        if focus { Perf.time("show.focus") { page.focus() } }
        if previous != tabID { prompts.refresh() }
        if previous != tabID, updatesRows {
            // Selection shows in the same frame as the press (Arc activates on press).
            pageView(for: currentSpaceID)?.reload(animated: false)
            scheduleReload()
        }
        Perf.time("show.refreshChrome") { refreshChrome() }
        queueArchiveReschedule()
        if previous != tabID { protectedMediaPageShown(tabID) }
    }

    func showEmpty(updatesRows: Bool = true) {
        if shownSplitID != nil { leaveSplitPresentation() }
        hideElsewhere()
        multiWindow.tabBySpace[currentSpaceID] = nil
        app?.scheduleSessionSave()
        protectedMediaToast?.dismiss()
        protectedMediaToast = nil
        pageVisibilityChanged(hidden: shownTabID, shown: nil)
        shownTabID = nil
        scheduleSpareBarRefresh()
        prompts.refresh()
        card.emptySpace = emptySpaceContent()
        card.showsEmptyState = true
        // The empty view (opaque, above the page) covers the page in this frame; the engine hides it right after
        // (on Chromium every tab is set invisible: ~2.5 ms of the New Space frame, §2.12).
        let hidePage = { [weak self] in
            guard let self, self.shownTabID == nil else { return }
            self.engineWindow.deactivateAll()
        }
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_NEW_SPACE_BASELINE"] == "1" {
            DispatchQueue.main.async(execute: hidePage)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: hidePage)
        }
        #else
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: hidePage)
        #endif
        refreshChrome()
        if updatesRows { scheduleReload() }
    }

    /// WIN-7: `tabID`'s page is in another window. This window keeps the tab selected and its card says so ("Open in
    /// another window", with Show Here and Go to Window), as Arc's placeholder for moved content. The page leaves
    /// this window when the other one takes it (takePageFromOtherWindow).
    func showElsewhere(_ tabID: String, updatesRows: Bool = true) {
        let before = visibleTabIDs
        if shownSplitID != nil { leaveSplitPresentation() }
        if findBar != nil { closeFind(refocusPage: false) }
        if peek != nil { closePeek() }
        protectedMediaToast?.dismiss()
        protectedMediaToast = nil
        let previous = shownTabID
        multiWindow.elsewhereTabID = tabID
        shownTabID = tabID
        noteShown(tabID)
        for id in before { pageVisibilityChanged(hidden: id, shown: nil) }
        card.showsEmptyState = false
        engineWindow.deactivateAll()
        presentElsewhere(tabID)
        prompts.refresh()
        if updatesRows, previous != tabID {
            pageView(for: currentSpaceID)?.reload(animated: false)
            scheduleReload()
        }
        refreshChrome()
        queueArchiveReschedule()
    }

    // MARK: Split View (SV-1)

    /// Every tab whose page is on screen: the split's panes, or the shown tab (none while its page is in another
    /// window, WIN-7).
    var visibleTabIDs: Set<String> {
        if multiWindow.elsewhereTabID != nil { return [] }
        if let x = store.split(shownSplitID) { return Set(x.tabIDs) }
        return shownTabID.map { [$0] } ?? []
    }

    /// Shows `x` in the page card's place with `tabID`'s pane focused: every pane's page is attached and live, each in
    /// its own profile. False when the engine can't (the caller shows the tab alone).
    @discardableResult
    func showSplit(_ x: Split, focus tabID: String, focusPage: Bool = true, updatesRows: Bool = true) -> Bool {
        if !store.showsSplit(x, inSpace: currentSpaceID) {
            // A pane picked from elsewhere (Command Bar, picture-in-picture's back to tab): its split's Space first.
            guard store.space(x.spaceID) != nil else { return false }
            switchToSpace(x.spaceID, animated: false)
        }
        let ids = store.members(of: x).map(\.id)
        guard ids.count >= 2, ids.contains(tabID) else { return false }
        // WIN-7: a window showing these panes gives them up ("Open in another window" there).
        for id in ids { app?.window(showing: id, except: self)?.pageLeaving(id) }
        let wasElsewhere = multiWindow.elsewhereTabID != nil
        var panePages: [EngineTab] = []
        for id in ids {
            bringBackFromCallWindow(id)
            guard let page = ensurePage(id) else { return false }
            panePages.append(page)
        }
        guard let focused = pages[tabID] else { return false }
        if findBar != nil, tabID != shownTabID { closeFind(refocusPage: false) }
        if peek != nil { closePeek() }
        let wasShowing = shownSplitID == x.id
        let before = visibleTabIDs
        let previous = wasElsewhere ? nil : shownTabID
        if wasElsewhere { hideElsewhere() }
        let container = splitContainer
        if container.frame != card.frame { container.frame = card.frame }
        container.configure(x, tabIDs: ids, palette: currentPalette, animated: wasShowing)
        container.isHidden = false
        container.layoutSubtreeIfNeeded()
        let hosts = ids.compactMap { container.pane(for: $0)?.host }
        do {
            try Perf.time("split.presentPanes") { try engineWindow.presentPanes(Array(zip(panePages, hosts)).map { ($0.0, $0.1) }, focused: focused) }
        } catch {
            if !wasShowing { container.isHidden = true }
            showToast("Split View needs the Chromium engine")
            return false
        }
        card.isHidden = true
        card.showsEmptyState = false
        shownSplitID = x.id
        shownTabID = tabID
        noteShown(tabID)
        container.setFocused(tabID)
        app?.engine.setPictureInPictureWindowActive(focused, active: window.isKeyWindow)
        let now = Set(ids)
        for id in before.subtracting(now) { pageVisibilityChanged(hidden: id, shown: nil) }
        for id in now.subtracting(before) { pageVisibilityChanged(hidden: nil, shown: id) }
        // Every pane counts as viewed (its archive timer starts again); the focused one is the Space's last.
        for id in ids where id != tabID { try? store.activate(id, inSpace: currentSpaceID) }
        try? store.activate(tabID, inSpace: currentSpaceID)
        store.setSplitFocus(x.id, tabID)
        if focusPage { engineWindow.focusPane(focused) }
        if previous != tabID || !wasShowing { prompts.refresh() }
        if updatesRows, previous != tabID || !wasShowing {
            pageView(for: currentSpaceID)?.reload(animated: false)
            scheduleReload()
        }
        refreshChrome()
        queueArchiveReschedule()
        if previous != tabID || !wasShowing { protectedMediaPageShown(tabID) }
        return true
    }

    /// Back to one page in the card (the engine's activateTab or deactivateAll hides the other panes).
    private func leaveSplitPresentation() {
        guard shownSplitID != nil else { return }
        let before = visibleTabIDs
        shownSplitID = nil
        animator.cancel("split")
        splitContainer.isHidden = true
        card.isHidden = false
        for id in before where id != shownTabID { pageVisibilityChanged(hidden: id, shown: nil) }
    }

    /// A click into a pane, ⌘[ / ⌘], ⌃⇧1–4: the keyboard (⌘L, ⌘W, find, zoom, DevTools) moves to that pane; the split
    /// stays as it is.
    func focusSplitPane(_ tabID: String, focusPage: Bool = true) {
        guard let x = store.split(shownSplitID), x.tabIDs.contains(tabID), let page = pages[tabID] else { return }
        if focusPage { engineWindow.focusPane(page) }
        guard tabID != shownTabID else { return }
        if findBar != nil { closeFind(refocusPage: false) }
        let previous = shownTabID
        shownTabID = tabID
        if !focusPage { engineWindow.focusPane(page) }
        store.setSplitFocus(x.id, tabID)
        try? store.activate(tabID, inSpace: currentSpaceID)
        splitContainer.setFocused(tabID)
        app?.engine.setPictureInPictureWindowActive(page, active: window.isKeyWindow)
        prompts.refresh()
        let sidebarPage = pageView(for: currentSpaceID)
        sidebarPage?.refreshTab(tabID)
        if let previous { sidebarPage?.refreshTab(previous) }
        refreshChrome()
    }

    /// ⌘[ / ⌘] in a split: the previous or next pane, wrapping. False when no split is shown.
    @discardableResult
    func focusAdjacentPane(_ offset: Int) -> Bool {
        guard let x = store.split(shownSplitID), let i = x.tabIDs.firstIndex(of: shownTabID ?? "") else { return false }
        let n = x.tabIDs.count
        focusSplitPane(x.tabIDs[((i + offset) % n + n) % n])
        return true
    }

    /// After a store change the split on screen follows it (a pane came, went or moved; it was separated), and a shown
    /// tab that has just joined a split shows it.
    private func syncSplitPresentation() {
        // WIN-7: nothing of this window's is on screen while its tab's page is in another window.
        guard let shown = shownTabID, multiWindow.elsewhereTabID == nil else { return }
        if let sid = shownSplitID {
            guard let x = store.split(sid), store.members(of: x).count >= 2 else {
                leaveSplitPresentation()
                if store.tab(shown) != nil { show(shown, focus: false, updatesRows: false, takeOver: false) }
                else if let t = preferredTab(forSpace: currentSpaceID) { show(t, focus: false, updatesRows: false, takeOver: false) }
                else { showEmpty(updatesRows: false) }
                return
            }
            let ids = store.members(of: x).map(\.id)
            if ids != splitContainer.tabIDs || x.axis != splitContainer.axis || !ids.contains(shown) {
                show(ids.contains(shown) ? shown : (x.focusedTabID ?? ids[0]), focus: false, updatesRows: false, takeOver: false)
            }
        } else if let x = store.split(containing: shown), store.showsSplit(x, inSpace: currentSpaceID), store.members(of: x).count >= 2 {
            show(x.focusedTabID ?? shown, focus: false, updatesRows: false, takeOver: false)
        }
    }

    /// A press on a pane's page moves the keyboard there first (the press itself goes on to the page).
    private func setUpSplitFocus() {
        paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            guard let self, e.window === self.window, self.shownSplitID != nil, !self.splitContainer.isHidden,
                  self.commandBar == nil, self.peek == nil,
                  let id = self.splitContainer.paneTabID(at: e.locationInWindow), id != self.shownTabID,
                  let pane = self.splitContainer.pane(for: id), let frame = self.window.contentView?.superview,
                  let hit = frame.hitTest(frame.convert(e.locationInWindow, from: nil)), hit.isDescendant(of: pane) else { return e }
            self.focusSplitPane(id, focusPage: false)
            return e
        }
    }

    /// Clicking a Favorite, pinned row or Today row.
    func activate(entry: SidebarEntry) {
        closeCommandBar()
        switch entry {
        case .favorite(let item, _):
            guard let t = try? store.openItem(item.id, inSpace: currentSpaceID) else { return }
            // SB-12 (QA issue 2): a Favorite you're already on that has wandered off goes back to its saved URL,
            // as Arc's does; otherwise it shows as you left it.
            // (A Favorite split: its focused pane's saved URL.)
            if t.id == shownTabID, let saved = store.item(t.itemID)?.savedURL, URLRules.isDrifted(saved: saved, current: t.url) {
                resetToSaved(t.id, keepCurrent: false)
                return
            }
            show(t.id)
        case .pinned(let item, _, _):
            guard let t = try? store.openItem(item.id, inSpace: currentSpaceID) else { return }
            show(t.id)
        case .today(let t):
            show(t.id)
        case .split:
            if let t = entry.liveTab { show(t.id) }
        case .folder:
            break
        }
    }

    /// ⌘W and the row's ✕ (SB-30, CB-2). The page closes first: a page without unload handlers closes now; one with them
    /// stays in the sidebar, shown, until the engine has run them and closes it (`tabRequestedClose`). If the page asks
    /// and the person stays, the tab and its page are unchanged.
    func closeTab(_ tabID: String) {
        guard store.tab(tabID) != nil else { return }
        // WIN-7: its page is in another window, which closes it (its unload handlers, its next tab); this window
        // follows the store change.
        if pages[tabID] == nil, let owner = app?.pageOwner(of: tabID, except: self) { return owner.closeTab(tabID) }
        if closePanesInTurn(tabID) { return }
        if let page = pages[tabID], !page.isClosed {
            closingTabs.insert(tabID)
            page.close()
            guard page.isClosed else { return }
        }
        finishClosing(tabID)
    }

    /// Takes a tab whose page has closed (or never loaded) out of the sidebar, undoably, and shows the next one.
    func finishClosing(_ tabID: String) {
        closingTabs.remove(tabID)
        guard let tab = store.tab(tabID) else { return }
        let wasShown = tabID == shownTabID
        let spaceForNext = tab.spaceID ?? currentSpaceID
        // SV-1: a closed pane hands the keyboard to its neighbour; the split stays (or its last tab shows alone).
        // SV-2: a pinned or Favorite split closes whole: every pane's page goes and its row stays.
        let alsoClosing = panesClosingWith(tabID)
        let pane = store.split(containing: tabID).flatMap { x -> String? in
            guard x.itemID == nil else { return nil }
            let rest = x.tabIDs.filter { $0 != tabID && store.tab($0) != nil }
            guard let i = x.tabIDs.firstIndex(of: tabID), !rest.isEmpty else { return nil }
            return rest[min(i, rest.count - 1)]
        }
        let next = wasShown ? (pane.flatMap { store.tab($0) } ?? nextFreeTab(afterClosing: tabID, inSpace: spaceForNext)) : nil
        do { try store.closeTab(tabID) } catch { return }
        dropPage(tabID)
        for id in alsoClosing where store.tab(id) == nil { dropPage(id) }
        if wasShown {
            if let next, store.tab(next.id) != nil { show(next.id, takeOver: false) } else { showEmpty() }
        }
    }

    func closeCurrentTab() {
        if peek != nil { return closePeek() }
        if let id = shownTabID { closeTab(id) }
    }

    /// LA-1 ⌘O: a live page from a Little Arc window (or one its page opened) becomes a new Today tab in `spaceID`
    /// without reloading: the engine moves it into this window (same profile only). False when it can't (another
    /// profile, an engine that can't move pages); nothing has changed then.
    @discardableResult
    func adoptMovedPage(_ page: EngineTab, inSpace spaceID: String) -> Bool {
        guard let space = store.space(spaceID), let profile = profiles.engineProfile(for: space.profileID),
              page.profile === profile, !page.isClosed else { return false }
        do { try engineWindow.moveTab(page, profile: profile, to: engineWindow.hostView) } catch { return false }
        let title = page.title
        guard let t = try? store.openTab(url: page.url?.absoluteString ?? "about:blank", inSpace: spaceID, title: title) else {
            page.close()
            return false
        }
        adopt(page, as: t.id)
        lastRecordedURL[t.id] = page.url?.absoluteString
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: false) }
        show(t.id)
        scheduleReload()
        return true
    }

    /// AT-1: a link from another app, as a new Today tab in `spaceID` (its profile: already signed in there).
    func openExternal(_ url: URL, inSpace spaceID: String) {
        guard store.space(spaceID) != nil, let t = try? store.openTab(url: url.absoluteString, inSpace: spaceID) else { return }
        if spaceID != currentSpaceID { switchToSpace(spaceID, animated: false) }
        show(t.id)
    }

    /// Clear Today and Archive Tabs Below: each page closes first, in order, like ⌘W. Pages that close at once are
    /// archived together as one undoable step. A page with unload handlers is waited for: if it asks "Leave site?" its
    /// tab is shown with the question; Leave archives it and the rest carry on, Stay keeps it and the rest (their pages
    /// never asked). One question at a time, so no tab is left with a hidden one.
    func closeThenArchive(_ ids: [String], reason: ArchiveReason, label: String, returnTo: String? = nil) {
        var ready: [String] = []
        let ids = ids.filter { store.tab($0) != nil }
        for (n, id) in ids.enumerated() {
            guard let page = pages[id], !page.isClosed else { ready.append(id); continue }
            closingTabs.insert(id)
            page.close()
            if page.isClosed { closingTabs.remove(id); ready.append(id); continue }
            archiveNow(ready, reason: reason, label: label)
            archiveQueue = ArchiveQueue(current: id, rest: Array(ids[(n + 1)...]), reason: reason, label: label, returnTo: returnTo ?? shownTabID)
            if app?.engine.reportsCloseOutcome != true { watchForStay(id) }
            // A page that only runs its handlers closes within a moment; one that asks shows the question with its tab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.archiveQueue?.current == id, self.pages[id]?.isClosed == false else { return }
                self.archiveQueue?.shownForDialog = true
                if self.shownTabID != id {
                    if let sid = self.store.tab(id)?.spaceID, sid != self.currentSpaceID { self.switchToSpace(sid, animated: false) }
                    self.show(id, focus: false)
                }
            }
            return
        }
        archiveNow(ready, reason: reason, label: label)
        if let back = returnTo, store.tab(back) != nil, shownTabID != back { show(back) }
    }

    private func archiveNow(_ ids: [String], reason: ArchiveReason, label: String) {
        guard !ids.isEmpty else { return }
        let shown = shownTabID
        let next = shown.flatMap { ids.contains($0) ? nextFreeTab(afterClosing: $0, inSpace: currentSpaceID) : nil }
        guard let archived = try? store.archiveTabs(ids, reason: reason, label: label) else { return }
        archived.forEach(dropPage)
        if let shown, archived.contains(shown) {
            if let next, store.tab(next.id) != nil { show(next.id, takeOver: false) } else { showEmpty() }
        }
    }

    /// The page's question closed (any window of the engine's): if the page is still open a moment later, the person
    /// stayed. The queue stops there; the tab and the ones after it stay as they were.
    private func watchForStay(_ id: String) {
        if let o = archiveDialogObserver { NotificationCenter.default.removeObserver(o) }
        archiveDialogObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
            [weak self] note in
            guard let self, (note.object as? NSWindow) !== self.window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let q = self.archiveQueue, q.current == id, let page = self.pages[id], !page.isClosed else { return }
                self.stopArchiveQueue(stayedOn: id)
            }
        }
    }

    private func stopArchiveQueue(stayedOn id: String?) {
        if let o = archiveDialogObserver { NotificationCenter.default.removeObserver(o) }
        archiveDialogObserver = nil
        guard let q = archiveQueue else { return }
        archiveQueue = nil
        // A tab the person stayed on keeps its close request: if they leave the page later after all, it's archived
        // like ⌘W's (finishClosing), never dropped.
        let kept = 1 + q.rest.count
        if id != nil { showToast(kept == 1 ? "Kept this tab: you stayed on the page" : "Kept \(kept) tabs: you stayed on the page") }
    }

    /// The engine closed the page the queue was waiting on (the person chose Leave, or the page didn't ask).
    private func archiveQueuePageClosed(_ id: String) {
        guard let q = archiveQueue, q.current == id else { return }
        stopArchiveQueue(stayedOn: nil)
        closingTabs.remove(id)
        if q.shownForDialog, shownTabID == id {
            // Off the tab we showed for the question, back to the one the person was on.
            if let back = q.returnTo, store.tab(back) != nil, back != id { show(back) }
        }
        archiveNow([id], reason: q.reason, label: q.label)
        closeThenArchive(q.rest, reason: q.reason, label: q.label, returnTo: q.returnTo)
    }

    /// ⌘Z: restores what the last close, Clear, delete or archive removed.
    func undo() {
        if reopenClosedPeek() { return }
        let before = Set(store.state.tabs.keys)
        guard let result = try? store.undo() else { NSSound.beep(); return }
        let label: String
        switch result {
        case .refused(_, let reason):
            // H3: the tab would have come back in another profile than the one it was closed in.
            showToast(reason)
            return
        case .restored(let l, let moved):
            label = l
            if let id = moved.first, let t = store.tab(id), let sp = store.space(t.spaceID) {
                showToast("Reopened in \(sp.name), which uses \(store.profile(ofSpace: sp.id).name)")
            }
        }
        let restored = Set(store.state.tabs.keys).subtracting(before)
        if store.space(currentSpaceID) == nil { currentSpaceID = store.selectedSpace.id }
        if label == "Close Tab", let id = restored.first {
            if let sid = store.tab(id)?.spaceID, sid != currentSpaceID { switchToSpace(sid, animated: true) }
            show(id)
        } else if label == "Delete Space", let sid = store.windowState.selectedSpaceID {
            reloadAll(animated: false)
            switchToSpace(sid, animated: true)
        }
    }

    private var archiveProtected: Set<String> {
        var protected = visibleTabIDs
        for (id, p) in pages where p.isAudible { protected.insert(id) }
        // WIN-7: each window archives its own pages; the oldest one also the tabs no window has a page for.
        protected.formUnion(tabsKeptByOtherWindows)
        // Waiting for its page to close, or skipped because its page would ask "Leave site?" (until its retry).
        protected.formUnion(autoArchiveClosing)
        let now = Date()
        for (id, at) in autoArchiveRetryAt where at > now { protected.insert(id) }
        return protected
    }

    /// SB-43, like Clear Today: each due tab's page closes before the tab goes to the Archive. Nobody is there to
    /// answer "Leave site?", so a page that would ask isn't closed at all: it stays as it is and is tried again
    /// `autoArchiveRetry` later. Pages without unload handlers close at once; a page whose handlers run (and don't ask)
    /// is archived when the engine reports it closed. Nothing is ever force-closed.
    func runAutoArchive() {
        let now = Date()
        autoArchiveRetryAt = autoArchiveRetryAt.filter { $0.value > now && store.tab($0.key) != nil }
        let due = store.dueForAutoArchive(protected: archiveProtected)
        var ready: [String] = []
        for id in due {
            guard let page = pages[id], !page.isClosed else { ready.append(id); continue }
            page.evaluate(Self.wouldAskBeforeUnload) { [weak self] answer in
                guard let self, self.pages[id] === page, !page.isClosed,
                      self.store.dueForAutoArchive(protected: self.archiveProtected).contains(id) else { return }
                // true: it would ask. A page that can't answer (no renderer: discarded, crashed) has no handlers to run.
                if (answer as? Bool) == true {
                    self.autoArchiveRetryAt[id] = Date().addingTimeInterval(Self.autoArchiveRetry)
                    self.queueArchiveReschedule()
                    return
                }
                self.autoArchiveClosing.insert(id)
                page.close()
                if page.isClosed { self.autoArchivePageClosed(id) }
            }
        }
        if let archived = try? store.autoArchive(ready, protected: archiveProtected) { archived.forEach(dropPage) }
        _ = try? store.backupIfNeeded(to: AppPaths.backups)
    }

    /// A page auto-archiving asked to close has closed: its tab goes to the Archive.
    private func autoArchivePageClosed(_ id: String) {
        guard autoArchiveClosing.remove(id) != nil else { return }
        let wasShown = id == shownTabID
        if let archived = try? store.autoArchive([id], pageClosed: true) { archived.forEach(dropPage) }
        if wasShown, store.tab(id) == nil {
            if let t = preferredTab(forSpace: currentSpaceID) { show(t, takeOver: false) } else { showEmpty() }
        }
        queueArchiveReschedule()
    }

    /// The page's own answer, without asking anyone: whether closing it now would show "Leave site?". Chromium only
    /// asks on a page the person has used (sticky activation) whose beforeunload handlers cancel the event or set a
    /// message; a synthetic BeforeUnloadEvent shows what the handlers would do.
    static let wouldAskBeforeUnload = """
    (function(){try{
      if (navigator.userActivation && !navigator.userActivation.hasBeenActive) return false;
      var e = document.createEvent('BeforeUnloadEvent'); e.initEvent('beforeunload', false, true);
      window.dispatchEvent(e);
      return e.defaultPrevented || e.returnValue === false || (typeof e.returnValue === 'string' && e.returnValue !== '');
    }catch(x){return true}})()
    """
    /// How long a page that would ask waits before auto-archiving tries it again.
    static var autoArchiveRetry: TimeInterval = 30 * 60

    /// A one-shot timer for the next tab that falls due (SB-43), or the next retry of a page that would have asked;
    /// none while nothing will.
    func scheduleArchive() {
        archiveTimer?.invalidate()
        archiveTimer = nil
        let now = Date()
        let retry = autoArchiveRetryAt.filter { $0.value > now && store.tab($0.key) != nil }.values.min()
        guard let due = [store.nextAutoArchiveDate(protected: archiveProtected), retry].compactMap({ $0 }).min() else { return }
        let t = Timer(fire: max(due, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            self?.runAutoArchive()
            self?.scheduleArchive()
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        archiveTimer = t
    }

    /// Tabs were shown, opened or closed, or audio changed: the next deadline may have moved (coalesced, off the hot path).
    func queueArchiveReschedule() {
        guard !archiveRescheduleQueued else { return }
        archiveRescheduleQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.archiveRescheduleQueued = false
            self?.scheduleArchive()
        }
    }

    private func armFlush() {
        guard !flushArmed, store.hasPendingWrites else { return }
        flushArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.flushArmed = false
            try? self?.store.flush()
        }
    }

    /// The archive timer, for the perf harness's idle check (MEM-6).
    var repeatingTimerCount: Int { archiveTimer.map { $0.timeInterval > 0 ? 1 : 0 } ?? 0 }
    var nextArchiveWakeup: Date? { archiveTimer?.fireDate }

    /// Changing a Space's profile (or moving a tab across profiles) recreates its pages (SP-13).
    func reloadPagesInNewProfile(_ tabIDs: [String]) {
        for id in tabIDs {
            let wasShown = id == shownTabID
            dropPage(id)
            if wasShown { show(id) }
        }
    }

    // MARK: Spaces

    /// The Space of `profileID` shown last in this window (where an opener-less tab of that profile goes, M2).
    func lastShownSpace(ofProfile profileID: String) -> String? { lastSpaceByProfile[profileID] }

    /// Click a footer icon, ⌃1–9, ⌥⌘←/→, Command Bar (SP-20). The page swap is instant: the target Space's page is
    /// already built and shows its last tab, its background is already rendered, and its store writes are quiet.
    func switchToSpace(_ spaceID: String, animated: Bool) {
        guard let space = store.space(spaceID) else { return }
        let spaces = store.orderedSpaces
        guard let target = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        let from = sidebar.pager.position
        let fromSpace = store.space(currentSpaceID)
        quiet += 1
        defer { quiet -= 1 }
        folderPreview.hide()
        Perf.time("applySpace") { applySpace(spaceID, refreshesChrome: false) }
        closeCommandBar()
        // Neighbour: the colour changes at once (τ ≈ 30 ms), ahead of the slide. Longer jumps follow it.
        if animated, fromSpace != nil, abs(from - Double(target)) <= 1.01 {
            colorAnimating = true
            Perf.time("background") { background.crossfade(to: palette(for: space).resolved) }
        }
        colorToken += 1
        let token = colorToken
        Perf.time("pager") {
            sidebar.pager.go(to: target, animated: animated) { [weak self] in
                if self?.colorToken == token { self?.colorAnimating = false }
            }
        }
        Perf.time("show") {
            // WIN-7: this window's own tab there (or the Space's last one no other window shows).
            if let t = preferredTab(forSpace: spaceID) {
                show(t, updatesRows: displayedTabIDBeforeSwitch(spaceID) != t, defersNewPage: true, takeOver: false)
            } else {
                showEmpty(updatesRows: false)
            }
        }
    }

    /// What the target Space's page was drawn with (its last tab); if that's what it shows next, no rows change.
    private func displayedTabIDBeforeSwitch(_ spaceID: String) -> String? {
        pageView(for: spaceID)?.drawnShownTabID
    }

    /// The footer's drag (Arc): Space `id` goes to `index`; the sidebar stays on the Space it shows.
    func reorderSpace(_ id: String, to index: Int) {
        do { try store.moveSpace(id, to: index) } catch { NSSound.beep(); return }
        reloadAll(animated: false)
        // The press's own slide may still be settling: the pager goes straight to the Space's new place.
        if let i = store.orderedSpaces.firstIndex(where: { $0.id == currentSpaceID }) { sidebar.pager.go(to: i, animated: false) }
    }

    func switchSpace(offset: Int) {
        guard let s = store.adjacentSpace(to: currentSpaceID, offset: offset) else { NSSound.beep(); return }
        switchToSpace(s.id, animated: true)
    }

    func switchToSpace(number n: Int) {
        let spaces = store.orderedSpaces
        guard n >= 1, n <= spaces.count else { return }
        switchToSpace(spaces[n - 1].id, animated: true)
    }

    private func applySpace(_ spaceID: String, refreshesChrome: Bool = true) {
        currentSpaceID = spaceID
        store.selectSpace(spaceID, deferred: true)
        if let s = store.space(spaceID) {
            lastSpaceByProfile[s.profileID] = spaceID
            if let p = profiles.engineProfile(for: s.profileID) { engineWindow.activeProfile = p }
        }
        if refreshesChrome { refreshChrome() }
    }

    /// The pager moved (swipe or settle): blend the window colour by how much of each page shows.
    func pagerDidMove(to position: Double) {
        let spaces = store.orderedSpaces
        guard !spaces.isEmpty else { return }
        sidebar.footer.setPosition(position)
        guard !colorAnimating else { return }
        let b = SwipePaging.colorBlend(position: position, pageCount: spaces.count)
        let from = palette(for: spaces[b.from]).resolved
        let to = palette(for: spaces[b.to]).resolved
        background.show(from, to, t: b.t)
    }

    /// A finger is on the trackpad: the colour follows the pages again.
    func pagerDidBeginTracking() {
        colorToken += 1
        colorAnimating = false
    }

    /// The swipe was released; the page swap happens now, while the spring settles.
    func pagerWillSettle(on page: Int) {
        let spaces = store.orderedSpaces
        guard spaces.indices.contains(page), spaces[page].id != currentSpaceID else { return }
        applySpace(spaces[page].id)
        if let t = preferredTab(forSpace: spaces[page].id) { show(t, focus: false, takeOver: false) } else { showEmpty() }
    }

    func pagerDidSettle(on page: Int) {
        pagerDidMove(to: Double(page))
    }

    // MARK: Sidebar hide/show (SB-60)

    func toggleSidebar() {
        if revealController?.isRevealed == true {
            revealController?.dock()
            return
        }
        sidebarHidden.toggle()
        store.updateWindowState { $0.sidebarHidden = sidebarHidden }
        app?.scheduleSessionSave()
        let from = sidebarFraction
        let to: CGFloat = sidebarHidden ? 0 : 1
        let duration = sidebarHidden ? AircCurve.sidebarHide.duration : AircCurve.sidebarShow.duration
        positionTrafficLights()
        animator.curve("sidebar", duration: duration, easing: Easing.sidebar, update: { [weak self] p in
            guard let self else { return }
            self.sidebarFraction = from + (to - from) * CGFloat(p)
            self.layoutRoot()
        }, completion: { [weak self] in
            self?.positionTrafficLights()
        })
    }

    func setSidebarWidth(_ w: CGFloat) {
        sidebarWidth = min(max(w, AircMetrics.Sidebar.minWidth), AircMetrics.Sidebar.maxWidth)
        store.updateWindowState { $0.sidebarWidth = Double(sidebarWidth) }
        app?.scheduleSessionSave()
        layoutRoot()
    }

    // MARK: Toasts

    func showToast(_ text: String) {
        toast.show(text, palette: currentPalette, in: card.frame)
    }
}

// MARK: - Engine callbacks

extension WindowController: EngineWindowDelegate {
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?,
                      disposition: TabDisposition) {
        // SP-3: popups and new tabs stay in the opener's Space and profile.
        let openerID = opener.flatMap { tabID(for: $0) }
        let openerTab = store.tab(openerID)
        var spaceID = openerTab?.spaceID ?? currentSpaceID
        // M2: a tab with no known opener (an extension's tab, a notification click) runs in the profile that asked for
        // it. It goes to a Space of that profile (the last one shown), never into another profile's Space.
        if let pid = profiles.profileID(for: tab.profile), store.profile(ofSpace: spaceID).id != pid {
            let mine = store.spaces(usingProfile: pid)
            guard let home = mine.first(where: { $0.id == lastShownSpace(ofProfile: pid) }) ?? mine.first else {
                tab.close()
                showToast("A page from \(store.profile(pid)?.name ?? "another profile") was closed: no Space uses that profile")
                return
            }
            spaceID = home.id
        }
        let background = disposition == .background
        guard let t = try? store.openTab(url: tab.url?.absoluteString ?? "about:blank", inSpace: spaceID,
                                         openerID: openerID, background: background, activate: !background)
        else { tab.close(); return }
        adopt(tab, as: t.id)
        if !background {
            if spaceID != currentSpaceID { switchToSpace(spaceID, animated: true) }
            show(t.id)
        } else {
            scheduleReload()
        }
    }

    func engineWindow(_ window: EngineWindow, tabCancelledClose tab: EngineTab) {
        guard let id = tabID(for: tab) else { return }
        closingTabs.remove(id)
        // Auto-archive's close asked after all (a frame the check didn't see) and the person stayed: tried again later.
        if autoArchiveClosing.remove(id) != nil {
            autoArchiveRetryAt[id] = Date().addingTimeInterval(Self.autoArchiveRetry)
            queueArchiveReschedule()
        }
        if archiveQueue?.current == id { stopArchiveQueue(stayedOn: id) }
        if paneCloseQueue?.current == id { stopPaneClose(stayedOn: id) }
    }

    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        if peek?.page === tab { return peekPageClosed(tab) }
        guard let id = tabID(for: tab) else { return }
        // Clear Today / Archive Tabs Below waiting on this page.
        if archiveQueue?.current == id { return archiveQueuePageClosed(id) }
        // A pinned or Favorite split closing pane by pane.
        if paneCloseQueue?.current == id { return panePageClosed(id) }
        // Auto-archive asked it to close.
        if autoArchiveClosing.contains(id) { return autoArchivePageClosed(id) }
        // A close we asked for (⌘W) that the page let through after its unload handlers.
        if closingTabs.contains(id) { return finishClosing(id) }
        let wasShown = id == shownTabID
        let opener = store.tab(id)?.openerID
        try? store.forgetTab(id)
        dropPage(id)
        if wasShown {
            if let opener, store.tab(opener) != nil { show(opener, takeOver: false) }
            else if let t = preferredTab(forSpace: currentSpaceID) { show(t, takeOver: false) } else { showEmpty() }
        }
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}

    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { true }

    /// A page opened again in another engine (a DRM service's link in a Chromium page, the URL bar on a WebKit page;
    /// docs/user/protected-media.md): the same tab shows the new page, in the same pane, with the same focus.
    func engineWindow(_ window: EngineWindow, replace old: EngineTab, with new: EngineTab) -> Bool {
        if let p = peek, p.page === old {
            new.delegate = self
            peek = Peek(page: new, view: p.view, openerTabID: p.openerTabID, closing: p.closing)
            return true
        }
        guard let id = tabID(for: old) else { return false }
        prompts.dropAll(for: old)
        old.delegate = nil
        tabIDByPage[ObjectIdentifier(old)] = nil
        adopt(new, as: id)
        if store.tab(id)?.isMuted == true { new.isMuted = true }
        if findBar != nil, id == shownTabID { closeFind(refocusPage: false) }
        if visibleTabIDs.contains(id) {
            if let x = store.split(shownSplitID), let focused = shownTabID {
                showSplit(x, focus: focused, focusPage: false, updatesRows: false)
            } else {
                engineWindow.activateTab(new)
                app?.engine.setPictureInPictureWindowActive(new, active: self.window.isKeyWindow)
            }
        }
        refreshRow(id)
        if id == shownTabID {
            prompts.refresh()
            refreshChrome()
            protectedMediaPageShown(id)
        }
        return true
    }
}

extension WindowController: EngineTabDelegate {
    private func pageChanged(_ page: EngineTab, persist: Bool) {
        guard let id = tabID(for: page) else { return }
        recordHistory(id, page)
        if persist {
            store.updateTab(id, url: page.url?.absoluteString, title: page.title.isEmpty ? nil : page.title,
                            faviconURL: page.faviconURL?.absoluteString)
        }
        refreshRow(id)
        if id == shownTabID { refreshChrome() }
        if persist { scheduleSpareBarRefresh() }   // a title, icon or address ⌘T's rows may show
    }

    /// History is per profile (SP-24). A visit is a new main-frame URL; the title follows when it arrives.
    private func recordHistory(_ id: String, _ page: EngineTab) {
        guard let h = app?.history, let tab = store.tab(id), let url = page.url?.absoluteString else { return }
        if lastRecordedURL[id] != url {
            lastRecordedURL[id] = url
            h.recordVisit(profileID: tab.profileID, url: url, title: page.title, typed: typedNavigations.remove(id) != nil)
        } else if !page.title.isEmpty {
            h.updateTitle(profileID: tab.profileID, url: url, title: page.title)
        }
    }

    /// The next URL this tab commits was typed or picked in the Command Bar.
    func markTyped(_ tabID: String) { typedNavigations.insert(tabID) }

    func refreshRow(_ tabID: String) {
        for p in pageViews.values { p.refreshTab(tabID) }
    }

    func tabDidChangeTitle(_ tab: EngineTab) {
        if let p = peek, p.page === tab { p.view.titleLabel.stringValue = tab.title.isEmpty ? URLRules.displayHost(tab.url?.absoluteString ?? "") : tab.title }
        pageChanged(tab, persist: true)
    }
    func tabDidChangeURL(_ tab: EngineTab) {
        pageChanged(tab, persist: true)
        applyKeepLoadedPolicy()
        prompts.pageNavigated(tab)
        if let id = tabID(for: tab), id == shownTabID { protectedMediaPageShown(id) }
    }
    func tabDidChangeLoading(_ tab: EngineTab) { pageChanged(tab, persist: false) }
    func tabDidChangeFavicon(_ tab: EngineTab) { pageChanged(tab, persist: true) }
    func tabDidChangeNavigationState(_ tab: EngineTab) { pageChanged(tab, persist: false) }
    func tabDidChangeAudio(_ tab: EngineTab) {
        pageChanged(tab, persist: false)
        queueArchiveReschedule()   // a tab playing audio is never archived (SB-43)
    }
    func tabDidChangeThemeColor(_ tab: EngineTab) {}
    func tab(_ tab: EngineTab, didReceiveShortcut combo: String, pageUsedIt: Bool) {
        guard tabID(for: tab) == shownTabID else { return }
        KeyMonitor.pageReported(combo, pageUsedIt: pageUsedIt, in: self)
    }

    /// The shown page, when it has keyboard focus.
    var focusedPage: EngineTab? {
        guard let id = shownTabID, let page = engineTab(for: id), let r = window.firstResponder as? NSView,
              r === page.view || r.isDescendant(of: page.view) else { return nil }
        return page
    }
}

extension WindowController: PromptHost {
    var promptRoot: NSView { root }
    var promptSibling: NSView? { toast }
    var promptEngineWindow: EngineWindow { engineWindow }
    var promptShownPage: EngineTab? { peek?.page ?? shownTabID.flatMap { pages[$0] } }
    var promptTheme: ResolvedTheme { currentPalette.resolved }
    func promptOwns(_ page: EngineTab) -> Bool { tabID(for: page) != nil || page === peek?.page }
    func promptToast(_ text: String) { showToast(text) }

    /// The profile's name while there are several (the card says which profile a site gets the permission in).
    func promptProfileName(for page: EngineTab) -> String? {
        guard store.state.profiles.count > 1, let id = tabID(for: page), let t = store.tab(id) else { return nil }
        return store.profile(t.profileID)?.name
    }

    /// The URL field of the Space on screen; with the sidebar hidden, the page's top-left corner.
    func promptAnchor() -> (view: NSView, rect: NSRect) {
        if sidebarFraction >= 1 || revealController?.isRevealed == true,
           let field = pageView(for: currentSpaceID)?.urlField, field.window != nil, !field.isHiddenOrHasHiddenAncestor {
            return (field, field.bounds)
        }
        return (root, NSRect(x: card.frame.minX + 10, y: card.frame.minY + 4, width: 1, height: 0))
    }
}

enum AppPaths {
    static var dataDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Airc", isDirectory: true)
    static var store: URL { dataDirectory.appendingPathComponent("spaces.sqlite") }
    static var backups: URL { dataDirectory.appendingPathComponent("Backups", isDirectory: true) }
    static var history: URL { dataDirectory.appendingPathComponent("history.sqlite") }
    /// Chromium's user data directory (its profiles), unless `--user-data-dir` says otherwise.
    static var chromium: URL { dataDirectory.appendingPathComponent("Chromium", isDirectory: true) }

    private static var prepared = false

    /// Picks the data folder for this run, before any engine starts (Chromium reads its user data directory at
    /// startup). `--ephemeral` starts from an empty folder and removes it at quit.
    static func prepare(_ options: LaunchOptions) {
        guard !prepared else { return }
        prepared = true
        if let dir = options.dataDir { dataDirectory = dir }
        if options.ephemeral, let dir = options.dataDir, mayDeleteEphemeral(dir) { try? FileManager.default.removeItem(at: dir) }
        if options.ephemeral && options.dataDir == nil {
            dataDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("airc-ephemeral-\(UUID().uuidString)", isDirectory: true)
        }
        let existed = FileManager.default.fileExists(atPath: dataDirectory.path)
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        // Only a folder Airc made for a throwaway run is ever deleted again (L1).
        if options.ephemeral && !existed {
            FileManager.default.createFile(atPath: dataDirectory.appendingPathComponent(ephemeralMarker).path, contents: Data())
        }
    }

    static let ephemeralMarker = ".airc-ephemeral"

    /// L1: `--ephemeral --data-dir X` deletes X at launch and quit only when Airc made X for a throwaway run (its marker
    /// file is there), and never the home folder, a folder above it, or the usual places for documents.
    static func mayDeleteEphemeral(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let p = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let forbidden = ["/", home] + ["Library", "Library/Application Support", "Documents", "Desktop", "Downloads"]
            .map { home + "/" + $0 }
        if forbidden.contains(p) || home.hasPrefix(p + "/") { return false }
        return fm.fileExists(atPath: dir.appendingPathComponent(ephemeralMarker).path)
    }

    /// The command line Chromium gets: the program, its own switches, and a user data directory. The app's options
    /// (and their values, which Chromium would open as URLs) stay out.
    static func chromiumArguments(_ options: LaunchOptions) -> [String] {
        var args = [CommandLine.arguments.first ?? "Airc"] + options.engineSwitches
        if !args.contains(where: { $0.hasPrefix("--user-data-dir") }) { args.append("--user-data-dir=" + chromium.path) }
        // Scripted runs happen in a background (often occluded) window, which Chromium would otherwise stop painting.
        // The mock keychain keeps them away from the owner's Keychain (and works while the screen is locked).
        if options.isAutomated { args += ["--disable-backgrounding-occluded-windows", "--use-mock-keychain"] }
        return args
    }
}
