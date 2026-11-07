// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// LA-1 Little Arc (spec §2.16b): a small window with one page and no sidebar, for links from other apps (AT-1's
/// default) and ⌥⌘N. A compact row holds the address, the profile chip (the Space the page belongs to; switchable) and
/// Open in Space. ⌘O moves the page into that Space without reloading (the engine moves the live page between windows,
/// engine/FEATURES-V1.md); ⌥⌘O lets you choose the Space. A Little Arc window left alone for 6 hours goes to the
/// Archive.
final class LittleArcController: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    let engineWindow: EngineWindow
    var window: NSWindow { engineWindow.window }
    /// The one page (nil once it moved to a Space).
    private(set) var page: EngineTab?
    /// The Space ⌘O moves the page into; its profile is the page's.
    private(set) var spaceID: String
    let root = LittleArcRootView()
    let background: ThemeBackgroundView
    let bar = NSView()
    let addressField = LittleArcAddressField()
    let chip = LittleArcProfileChip()
    let openButton = GlyphButton(symbol: "arrow.up.forward.square", size: 13)
    let card = PageCardView()
    let toast = ToastView()
    lazy var prompts = PromptPresenter(host: self)
    /// LA-1: left alone this long, the window goes to the Archive (scripted runs shorten it).
    static var archiveAfter: TimeInterval = 6 * 3600
    private(set) var lastActive = Date()
    private var archiveTimer: Timer?
    /// Closing was asked for once (the engine closes the window after the page's unload handlers).
    private var closing = false
    /// LA-1 mini player: the window was closed with media playing, and the page plays on in picture in picture with
    /// the window hidden (`isMiniPlayer`); `miniPlayerPending` while the engine opens it.
    private(set) var isMiniPlayer = false
    private var miniPlayerPending = false
    static let barHeight: CGFloat = 32
    /// LA-1: Little Arc comes to the Space you're on, over a full-screen app too (a link from Slack or Mail in full
    /// screen), instead of opening on another Space, out of sight. Each time it's shown it moves to the active Space.
    /// Scripted runs leave it off unless a check asks: it would put test windows over the owner's full-screen apps.
    static var joinsActiveSpace = !LaunchOptions.current.isAutomated
    /// The menus made for the chip and the ↗ button (the checks see whether a click opened one).
    private(set) var menusMade = 0
    private(set) weak var shownMenu: NSMenu?

    private var store: SpacesStore? { app?.store }
    private var main: WindowController? { app?.controller }

    init(app: AppDelegate, url: URL?, spaceID: String, frame: NSRect) {
        self.app = app
        self.spaceID = spaceID
        // Its own window class: the engine's dialog anchor must not send it behind the browser window (LittleArcWindow).
        let hosted = LittleArcWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        hosted.isReleasedWhenClosed = false
        engineWindow = (app.engine as? EngineCallHosting)?.makeWindow(hosting: hosted) ?? app.engine.makeWindow(contentRect: frame)
        let space = app.store.space(spaceID) ?? app.store.selectedSpace
        background = ThemeBackgroundView(theme: Palette(theme: space.theme, systemDark: Self.systemDark).resolved)
        super.init()
        engineWindow.delegate = self
        setUpWindow(frame: frame)
        app.promptCenter?.register(prompts)
        open(url)
        scheduleArchive()
    }

    static var systemDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    var palette: Palette {
        Palette(theme: (store?.space(spaceID) ?? store?.selectedSpace)?.theme ?? .neutral, systemDark: Self.systemDark)
    }
    var profileID: String? { store?.space(spaceID)?.profileID }

    private func setUpWindow(frame: NSRect) {
        let w = window
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        // As the main window: not movable by its background (a page click must reach the page); the row drags it.
        w.isMovableByWindowBackground = false
        w.tabbingMode = .disallowed
        w.isRestorable = false
        if Self.joinsActiveSpace { w.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary]) }
        w.minSize = NSSize(width: 420, height: 300)
        w.title = "Little Arc"
        w.delegate = self
        root.controller = self
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.wantsLayer = true
        w.contentView = root
        root.addSubview(background)
        root.addSubview(card)
        root.addSubview(bar)
        root.addSubview(toast)
        bar.addSubview(addressField)
        bar.addSubview(chip)
        bar.addSubview(openButton)
        card.embed(engineWindow.hostView)
        addressField.controller = self
        chip.action = { [weak self] in self?.showProfileMenu() }
        // A click opens the page in the chip's Space; the Spaces come on a long press, a right-click or ⌥⌘O (the owner
        // needed two clicks while a press opened the menu, 2026-11-06).
        openButton.action = { [weak self] in self?.openInSpace() }
        openButton.longPressMenu = true
        openButton.menuProvider = { [weak self] in self?.spacesMenu() }
        refreshChrome()
    }

    func layout() {
        let b = root.bounds
        background.frame = b
        let h = Self.barHeight
        bar.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        let s: CGFloat = 22
        openButton.frame = NSRect(x: b.width - 8 - s, y: (h - s) / 2, width: s, height: s)
        let chipSize = chip.fittingSize
        chip.frame = NSRect(x: openButton.frame.minX - 6 - chipSize.width, y: (h - chipSize.height) / 2,
                            width: chipSize.width, height: chipSize.height)
        // After the traffic lights.
        let x: CGFloat = 78
        addressField.frame = NSRect(x: x, y: (h - 20) / 2, width: max(60, chip.frame.minX - 10 - x), height: 20)
        let i: CGFloat = 6
        card.frame = NSRect(x: i, y: h, width: max(0, b.width - 2 * i), height: max(0, b.height - h - i))
        prompts.layout()
    }

    /// Address, chip, button and colours from the page and the Space.
    func refreshChrome() {
        let p = palette
        background.show(p.resolved)
        card.palette = p
        addressField.setPage(url: page?.url?.absoluteString ?? "", palette: p)
        openButton.tint = p.glyph
        openButton.hoverFill = p.hover
        let space = store?.space(spaceID)
        openButton.toolTip = "Open in \(space?.name ?? "Space") (⌘O). ⌥⌘O or a long press: choose a Space."
        if let pid = space?.profileID, let profile = store?.profile(pid) { chip.configure(profile: profile, palette: p) }
        root.needsLayout = true
    }

    // MARK: The page

    private func open(_ url: URL?) {
        guard let pid = profileID, let profile = main?.profiles.engineProfile(for: pid) else { return }
        engineWindow.activeProfile = profile
        let p = engineWindow.openTab(url: url, profile: profile, foreground: true)
        p.delegate = self
        page = p
        engineWindow.activateTab(p)
        app?.engine.setPictureInPictureWindowActive(p, active: window.isKeyWindow)
        prompts.refresh()
        refreshChrome()
        // The page is what's in focus (else AppKit hands the window's first key to the address field, selected);
        // ⌥⌘N's empty window starts in the address field.
        window.initialFirstResponder = p.view
        if url == nil { DispatchQueue.main.async { [weak self] in self?.focusAddress() } }
    }

    func navigate(_ text: String) {
        guard let pid = profileID, let profile = store?.profile(pid),
              let url = URLRules.resolve(text, engine: profile.searchEngine) else { return }
        noteActivity()
        if let page { page.load(url); page.focus() } else { open(url) }
    }

    func focusAddress() {
        window.makeFirstResponder(addressField)
    }

    // MARK: Open in Space (⌘O, ⌥⌘O)

    /// ⌘O: into the chip's Space, the same live page (no reload), as a new Today tab; this window closes.
    func openInSpace(_ target: String? = nil) {
        guard let main, let page, let store else { return }
        let sid = target ?? spaceID
        guard let space = store.space(sid) else { return }
        if main.adoptMovedPage(page, inSpace: sid) {
            self.page = nil
        } else {
            // Another profile (⌥⌘O to a Space signed in elsewhere), or an engine that can't move pages: the page opens
            // again there.
            let url = page.url ?? URL(string: "about:blank")!
            page.delegate = nil
            page.close()
            self.page = nil
            main.openExternal(url, inSpace: sid)
            main.showToast("Opened in \(space.name), with its own profile")
        }
        bringForward(main.window)
        closeWindow()
    }

    /// ⌥⌘O, and a long press or right-click on ↗: every Space, by its icon and name, the chip's checked. A Space of
    /// another profile says so, and that it reloads the page there (a page can't change profile); the others move it.
    func spacesMenu() -> NSMenu {
        let menu = NSMenu()
        menusMade += 1
        shownMenu = menu
        guard let store else { return menu }
        let pid = profileID
        for s in store.orderedSpaces {
            let item = menu.add(s.name) { [weak self] in self?.openInSpace(s.id) }
            item.image = Self.icon(of: s)
            if s.id == spaceID { item.state = .on }
            if s.profileID != pid { Self.secondary(item, "Reloads in \(store.profile(ofSpace: s.id).name)") }
        }
        return menu
    }

    /// A Space's icon for a menu row: its emoji or symbol (none: no image).
    static func icon(of space: Space) -> NSImage? {
        switch space.icon {
        case .symbol(let name)?: return Symbols.image(name, size: 14)
        case .emoji(let e)?:
            return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                let text = NSAttributedString(string: e, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                let b = text.size()
                text.draw(at: NSPoint(x: (r.width - b.width) / 2, y: (r.height - b.height) / 2))
                return true
            }
        case nil: return nil
        }
    }

    /// A row's second line (macOS 14.4's menu subtitle; before it, after the title).
    static func secondary(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) { item.subtitle = text } else { item.title += " — " + text }
    }

    func showSpacesMenu() {
        // The row isn't flipped: the menu's top-left just under the button.
        spacesMenu().popUp(positioning: nil, at: NSPoint(x: openButton.frame.minX, y: openButton.frame.minY - 4), in: bar)
    }

    // MARK: Profile chip

    /// The chip's menu (Arc's profile button, LA-1): every profile that has a Space, by its avatar and name, the page's
    /// checked. Another one opens the page again in that profile's most recent Space: it says so.
    func profileMenu() -> NSMenu {
        let menu = NSMenu()
        menusMade += 1
        shownMenu = menu
        guard let store, let main else { return menu }
        for p in store.orderedProfiles {
            let spaces = store.spaces(usingProfile: p.id)
            guard let target = spaces.first(where: { $0.id == main.lastShownSpace(ofProfile: p.id) }) ?? spaces.first else { continue }
            let item = menu.add(p.name) { [weak self] in self?.switchSpace(target.id) }
            item.image = ProfileAvatarImage.image(p, size: 18)
            if p.id == profileID { item.state = .on } else { Self.secondary(item, "Reloads the page") }
        }
        return menu
    }

    private func showProfileMenu() {
        // The row isn't flipped: the menu's top-left just under the chip.
        profileMenu().popUp(positioning: nil, at: NSPoint(x: chip.frame.minX, y: chip.frame.minY - 4), in: bar)
    }

    /// The chip picked another profile: its most recent Space becomes the target. A page can't change profile, so it
    /// opens again in the new one (signed in as that profile is).
    func switchSpace(_ sid: String) {
        guard sid != spaceID, let store, store.space(sid) != nil else { return }
        let sameProfile = store.space(sid)?.profileID == profileID
        spaceID = sid
        if !sameProfile, let old = page {
            let url = old.url
            old.delegate = nil
            prompts.dropAll(for: old)
            old.close()
            page = nil
            open(url.flatMap { URLRules.isNewTab($0.absoluteString) ? nil : $0 })
        }
        refreshChrome()
    }

    // MARK: Archive after 6 h (LA-1)

    func noteActivity() {
        lastActive = Date()
        scheduleArchive()
    }

    private func scheduleArchive() {
        archiveTimer?.invalidate()
        let t = Timer(fire: lastActive.addingTimeInterval(Self.archiveAfter), interval: 0, repeats: false) { [weak self] _ in
            self?.archiveNow()
        }
        t.tolerance = min(60, Self.archiveAfter / 10)
        RunLoop.main.add(t, forMode: .common)
        archiveTimer = t
    }

    /// The page goes to the Archive of its Space (the Library's Archived Tabs restores it), and the window closes.
    func archiveNow() {
        guard !window.isKeyWindow else { return noteActivity() }
        if let page, let store, let url = page.url, !URLRules.isNewTab(url.absoluteString),
           let t = try? store.openTab(url: url.absoluteString, inSpace: spaceID, background: true, activate: false, title: page.title) {
            _ = try? store.archiveTabs([t.id], reason: .auto, label: "Archive Little Arc")
        }
        closeWindow()
    }

    // MARK: Window

    func closeWindow() {
        archiveTimer?.invalidate()
        archiveTimer = nil
        guard !closing else { return }
        closing = true
        if windowShouldClose(window) { window.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closing = true
        if !isMiniPlayer, !miniPlayerPending, let page, offerMiniPlayer(page) { return false }
        return closeForReal()
    }

    /// The engine closes the window once the page's unload handlers have run (it may ask "Leave site?").
    private func closeForReal() -> Bool {
        #if canImport(AircCore)
        return ChromiumRuntime.closeWindow(engineWindow)
        #else
        page?.close()
        return true
        #endif
    }

    // MARK: Mini player (LA-1, SB-55)

    /// Closing a window whose page plays a video or sound: the media goes on in picture in picture (the engine's
    /// trusted host entry, engine/PASS12.md), the window hidden with its page kept. Not when picture in picture is off
    /// or the site is set to never. True: the close waits for the answer.
    private func offerMiniPlayer(_ page: EngineTab) -> Bool {
        #if canImport(AircCore)
        guard let chromium = app?.engine as? ChromiumEngine, let settings = app?.settings.values, settings.pipAutomatic else { return false }
        if let origin = page.url.flatMap({ WindowController.pictureInPictureOrigin($0.absoluteString) }), settings.pipSites[origin] == false {
            return false
        }
        miniPlayerPending = true
        var decided = false
        let decide: (Bool) -> Void = { [weak self, weak page] playing in
            guard !decided else { return }
            decided = true
            guard let self, let page, self.miniPlayerPending else { return }
            guard playing else { return self.miniPlayerUnavailable() }
            chromium.enterPictureInPictureForHost(page) { [weak self] route, opened in
                guard let self, self.miniPlayerPending else { return }
                if opened { return self.becomeMiniPlayer() }
                guard route == "session" else { return self.miniPlayerUnavailable() }
                // The site opens it itself (its MediaSession handler): the engine's picture-in-picture state says when.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    if self?.miniPlayerPending == true { self?.miniPlayerUnavailable() }
                }
            }
        }
        if page.isAudible { decide(true); return true }
        // A video playing without sound (muted, or a silent part) counts too; a page that can't answer doesn't.
        page.evaluate("[].some.call(document.querySelectorAll('video'),function(v){return !v.paused&&!v.ended&&!v.muted&&v.readyState>2})") { v in
            decide((v as? Bool) == true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { decide(false) }
        return true
        #else
        return false
        #endif
    }

    private func becomeMiniPlayer() {
        miniPlayerPending = false
        isMiniPlayer = true
        archiveTimer?.invalidate()
        archiveTimer = nil
        prompts.dropAll()
        window.orderOut(nil)
    }

    private func miniPlayerUnavailable() {
        miniPlayerPending = false
        if closeForReal() { window.close() }
    }

    /// The engine's picture-in-picture state for this window's page (`active`).
    func pictureInPictureChanged(active: Bool) {
        if active, miniPlayerPending { return becomeMiniPlayer() }
        guard !active, isMiniPlayer else { return }
        // The picture in picture was closed: so is the window, as it was asked to be.
        isMiniPlayer = false
        if closeForReal() { return window.close() }
        // A page that asks before it goes ("Leave site?") shows its question in the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.page?.isClosed == false, !self.window.isVisible else { return }
            self.closing = false
            self.bringForward(self.window)
        }
    }

    /// "Back to tab" in the picture in picture: the window comes back with its page, and the picture in picture closes.
    func restoreFromMiniPlayer() {
        guard isMiniPlayer || miniPlayerPending, let page else { return }
        isMiniPlayer = false
        miniPlayerPending = false
        closing = false
        bringForward(window)
        noteActivity()
        #if canImport(AircCore)
        (app?.engine as? ChromiumEngine)?.closePictureInPicture(page)
        #endif
    }

    func windowWillClose(_ notification: Notification) {
        archiveTimer?.invalidate()
        prompts.dropAll()
        app?.littleArcClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Back in use: a close the page kept open ("Stay") is over.
        if page != nil { closing = false }
        noteActivity()
        if let page { app?.engine.setPictureInPictureWindowActive(page, active: true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        noteActivity()
        if let page { app?.engine.setPictureInPictureWindowActive(page, active: false) }
    }

    private func bringForward(_ w: NSWindow) {
        if app?.options.isAutomated == true { w.orderFront(nil) } else { w.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    /// `w` is below `other` as the window server orders this app's windows on screen (AppKit's own list can lag behind
    /// while a window animates in).
    static func isBehind(_ w: NSWindow, _ other: NSWindow) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let order = list.compactMap { d -> Int? in
            (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() ? (d[kCGWindowNumber as String] as? NSNumber)?.intValue : nil
        }
        guard let mine = order.firstIndex(of: w.windowNumber), let theirs = order.firstIndex(of: other.windowNumber) else { return false }
        return mine > theirs
    }

    // MARK: Presses on the page

    /// What a press hits (AppKit's hit test and the content view's, as Chromium checks), and whether that is the page.
    private func pageHit(_ e: NSEvent) -> (hit: NSView?, contentHit: NSView?, onPage: Bool) {
        guard let content = window.contentView, let frame = content.superview else { return (nil, nil, false) }
        let p = frame.convert(e.locationInWindow, from: nil)
        let hit = frame.hitTest(p), contentHit = content.hitTest(p)
        guard let pageView = page?.view, let hit else { return (hit, contentHit, false) }
        return (hit, contentHit, hit === pageView || hit.isDescendant(of: pageView))
    }

    /// LA-1: Little Arc holds the link you just clicked in another app, so a press on its page works the first time. On
    /// a window that isn't key the press would only make it key (Chromium takes no first click, as in Chrome), so the
    /// window becomes key before AppKit hands the press on, and the press goes to the page. The browser window keeps
    /// Chrome's behaviour. Called from the app's mouse-down monitor; never activates a scripted run.
    func takeFirstPress(_ e: NSEvent) {
        guard !window.isKeyWindow, window.isVisible, !isMiniPlayer, pageHit(e).onPage else { return }
        if !NSApp.isActive {
            guard app?.options.isAutomated != true else { return }
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Links.log (LinkLog.swift)

    private var pressesLogged = 0
    private var pressReachedPage = false

    /// A press in this window, before AppKit hands it on, until one reaches the page and at most three: what it hits in
    /// AppKit's hit test and in Chromium's own check (the content view's hit test must land in the page), the window's
    /// key state before the press and once `takeFirstPress` ran, and whether the page took it (a press on a window that
    /// isn't key only activates it); a moment later, the page's own answer (a user activation).
    func notePress(_ e: NSEvent, wasKey: Bool) {
        guard LinkLog.enabled, !pressReachedPage, pressesLogged < 3 else { return }
        pressesLogged += 1
        let (hit, contentHit, onPage) = pageHit(e)
        let pageView = page?.view
        let contentOnPage = contentHit.map { v in pageView.map { v === $0 || v.isDescendant(of: $0) } ?? false } ?? false
        func name(_ v: NSView?) -> String { v.map { String(describing: type(of: $0)) } ?? "nothing" }
        let key = window.isKeyWindow
        let firstMouse = hit?.acceptsFirstMouse(for: e) ?? false
        let outcome = !onPage ? "not the page" : !contentOnPage ? "dropped by the page (Chromium's check misses it)"
            : !key && !firstMouse ? "activates the window only (the page takes no first click)" : "reaches the page"
        if outcome == "reaches the page" { pressReachedPage = true }
        let line = "Little Arc press \(pressesLogged): hit \(name(hit)) (\(onPage ? "in the page" : "not in the page")), "
            + "content view's hit \(name(contentHit)), window key \(LinkLog.yesNo(wasKey))\(key != wasKey ? " → \(LinkLog.yesNo(key))" : ""), "
            + "app active \(LinkLog.yesNo(NSApp.isActive)), accepts first mouse \(LinkLog.yesNo(firstMouse)) → \(outcome)"
        guard let p = page, onPage else { return LinkLog.write(line) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak p] in
            guard let p else { return LinkLog.write(line) }
            p.evaluate("navigator.userActivation ? navigator.userActivation.isActive : null") { v in
                LinkLog.write(line + "; then: page user activation \((v as? Bool).map(LinkLog.yesNo) ?? "?"), "
                              + "window key \(LinkLog.yesNo(self?.window.isKeyWindow == true))")
            }
        }
    }

    /// Little Arc's own shortcuts while it's the key window (the main window's commands don't apply to it).
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch (key, mods) {
        case ("o", .command): openInSpace(); return true
        case ("o", [.command, .option]): showSpacesMenu(); return true
        case ("w", .command): closeWindow(); return true
        case ("l", .command): focusAddress(); return true
        case ("r", .command): page?.reload(); return true
        case ("[", .command): page?.goBack(); return true
        case ("]", .command): page?.goForward(); return true
        case ("n", [.command, .option]): app?.openLittleArc(url: nil); return true
        default: return false
        }
    }
}

extension LittleArcController: EngineWindowDelegate {
    /// A link the page opens in a new tab (or a popup) goes to the main window, in this Space: same profile, same page.
    func engineWindow(_ window: EngineWindow, didInsertTab tab: EngineTab, opener: EngineTab?, disposition: TabDisposition) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let main = self.main else { tab.close(); return }
            if !main.adoptMovedPage(tab, inSpace: self.spaceID) {
                let url = tab.url
                tab.close()
                if let url { main.openExternal(url, inSpace: self.spaceID) }
            }
        }
    }

    /// The page closed itself (window.close()).
    func engineWindow(_ window: EngineWindow, tabRequestedClose tab: EngineTab) {
        guard tab === page else { return }
        page = nil
        // The page closed itself (window.close()); one closing with the window needs nothing more.
        if !closing { closeWindow() }
    }

    func engineWindow(_ window: EngineWindow, tab: EngineTab, didChangeFullscreen fullscreen: Bool) {}

    /// A link in the page to a DRM service (docs/user/protected-media.md) opens again in Safari's engine, here, as in
    /// the main window; not while the window closes or plays on as the mini player.
    func engineWindowCanReplaceTabs(_ window: EngineWindow) -> Bool { !closing && !isMiniPlayer && !miniPlayerPending }

    func engineWindow(_ window: EngineWindow, replace old: EngineTab, with new: EngineTab) -> Bool {
        guard old === page, !closing, !isMiniPlayer else { return false }
        let focused = (self.window.firstResponder as? NSView)?.isDescendant(of: old.view) == true
        prompts.dropAll(for: old)
        old.delegate = nil
        new.delegate = self
        page = new
        engineWindow.activateTab(new)
        app?.engine.setPictureInPictureWindowActive(new, active: self.window.isKeyWindow)
        self.window.initialFirstResponder = new.view
        if focused { new.focus() }
        prompts.refresh()
        refreshChrome()
        noteActivity()
        return true
    }
}

extension LittleArcController: EngineTabDelegate {
    func tabDidChangeTitle(_ tab: EngineTab) { refreshAddress(tab) }
    func tabDidChangeURL(_ tab: EngineTab) {
        refreshAddress(tab)
        prompts.pageNavigated(tab)
        noteActivity()
    }
    func tabDidChangeLoading(_ tab: EngineTab) {}
    func tabDidChangeFavicon(_ tab: EngineTab) {}
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    private func refreshAddress(_ tab: EngineTab) {
        guard tab === page else { return }
        addressField.setPage(url: tab.url?.absoluteString ?? "", palette: palette)
    }
}

extension LittleArcController: PromptHost {
    var promptRoot: NSView { root }
    var promptSibling: NSView? { toast }
    var promptEngineWindow: EngineWindow { engineWindow }
    var promptShownPage: EngineTab? { page }
    var promptTheme: ResolvedTheme { palette.resolved }
    func promptAnchor() -> (view: NSView, rect: NSRect) { (addressField, addressField.bounds) }
    func promptProfileName(for page: EngineTab) -> String? {
        guard let store, store.state.profiles.count > 1, let pid = profileID else { return nil }
        return store.profile(pid)?.name
    }
    func promptOwns(_ page: EngineTab) -> Bool { page === self.page }
    func promptToast(_ text: String) { toast.show(text, palette: palette, in: card.frame) }
}

/// LA-1: Little Arc's window. The engine hangs an invisible dialog anchor on every window that hosts its pages
/// (WindowHost::UpdateModalParent). Chromium orders the anchor in just below the app's main window
/// (NativeWidgetNSWindowBridge, a show without activation), and that is the browser window until Little Arc is key in an
/// active app; attaching the anchor as a child then moves this window down to it, behind the browser window. A link
/// opened Little Arc out of sight that way, and a click on its link landed on the browser window (ship runs
/// 2026-11-06). So an attach while it's meant to be in front (ordered front, and no other window of ours has taken
/// the key since) puts it back in front, and its children with it.
final class LittleArcWindow: NSWindow {
    private(set) var keepsFront = false
    private var keyObserver: NSObjectProtocol?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            // The person moved on to another window of ours: it stays where they leave it.
            if let self, let other = note.object as? NSWindow, other !== self, other.parent !== self { self.keepsFront = false }
        }
    }

    deinit { keyObserver.map(NotificationCenter.default.removeObserver) }

    override func orderFront(_ sender: Any?) {
        keepsFront = true
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        keepsFront = true
        super.makeKeyAndOrderFront(sender)
    }

    override func orderOut(_ sender: Any?) {
        keepsFront = false
        super.orderOut(sender)
    }

    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(child, ordered: place)
        guard isVisible, keepsFront || isKeyWindow else { return }
        orderFront(nil)
        // AppKit may settle the group's order after this turn: once more then.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.keepsFront || self.isKeyWindow else { return }
            self.orderFront(nil)
        }
        LinkLog.write("Little Arc: in front again as the engine attached its dialog anchor")
    }
}

/// The window's root: lays out the row and the page; a press nothing takes drags the window (like RootView).
final class LittleArcRootView: NSView {
    weak var controller: LittleArcController?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func layout() {
        super.layout()
        controller?.layout()
    }
}

/// The compact address: the host while it shows; a click edits the whole URL (selected), Return goes there, Esc puts
/// it back.
final class LittleArcAddressField: NSTextField, NSTextFieldDelegate {
    weak var controller: LittleArcController?
    private var url = ""
    private var editing = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = AircFont.urlField.nsFont
        cell?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        placeholderString = "Search or enter URL…"
        delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The row lies in the titlebar band, where the window server drags the window on a press no view claims.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPage(url: String, palette: Palette) {
        self.url = URLRules.isNewTab(url) ? "" : url
        textColor = palette.textPrimary
        if !editing { stringValue = URLRules.displayHost(self.url) }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            editing = true
            stringValue = url
            currentEditor()?.selectAll(nil)
        }
        return ok
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        editing = false
        stringValue = URLRules.displayHost(url)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            window?.makeFirstResponder(nil)
            if !text.isEmpty { controller?.navigate(text) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            window?.makeFirstResponder(nil)
            controller?.page?.focus()
            return true
        default:
            return false
        }
    }
}

/// The profile chip (Arc's profile button in Little Arc: avatar, name, chevron): the target Space's profile. A click
/// opens the profile menu.
final class LittleArcProfileChip: NSView {
    private let avatar = CALayer()
    private let label = NSTextField(labelWithString: "")
    private let chevron = CALayer()
    private let plate = CALayer()
    private var avatarImage: NSImage?
    private var palette: Palette?
    private var hovered = false { didSet { if hovered != oldValue { updatePlate() } } }
    var action: (() -> Void)?
    /// For the checks: what it shows.
    var shownName: String { label.stringValue }
    var showsChevron: Bool { chevron.contents != nil && chevron.frame.maxX <= bounds.maxX && chevron.frame.minX > label.frame.minX }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.cornerRadius = 11
        plate.cornerCurve = .continuous
        plate.actions = LayerImage.noActions
        layer?.addSublayer(plate)
        for l in [avatar, chevron] {
            l.contentsGravity = .center
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        label.font = AircFont.callout.weight(.medium).nsFont
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole chip takes the press: its name label would keep a first click for itself.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }
    override func mouseDown(with event: NSEvent) { action?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    func configure(profile: Profile, palette: Palette) {
        self.palette = palette
        let img = ProfileAvatarImage.image(profile, size: 16)
        if img !== avatarImage {
            avatarImage = img
            LayerImage.set(img, on: avatar, in: self)
        }
        label.stringValue = profile.name
        label.textColor = palette.textSecondary
        LayerImage.set(LayerImage.symbol("chevron.down", size: 8, weight: .bold, color: palette.textSecondary), on: chevron, in: self)
        updatePlate()
        setAccessibilityLabel("Profile: \(profile.name)")
        toolTip = "This page uses the “\(profile.name)” Profile. Click to choose another."
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if LayerImage.scaleChanged(avatar, in: self), let avatarImage { LayerImage.set(avatarImage, on: avatar, in: self) }
        if LayerImage.scaleChanged(chevron, in: self), let palette {
            LayerImage.set(LayerImage.symbol("chevron.down", size: 8, weight: .bold, color: palette.textSecondary), on: chevron, in: self)
        }
    }

    private func updatePlate() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = palette.map { (hovered ? $0.tileFill : $0.hover).cgColor }
        CATransaction.commit()
    }

    /// Avatar 16, gap 5, the name (as drawn, with the label's own margins; at most 140 pt), gap 4, chevron 8, padding 4
    /// and 7.
    override var fittingSize: NSSize {
        let name: CGFloat = min(140, ceil(label.attributedStringValue.size().width) + 6)
        let chrome: CGFloat = 4 + 16 + 5 + 4 + 8 + 7
        return NSSize(width: chrome + name, height: 22)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        avatar.frame = NSRect(x: 4, y: 3, width: 16, height: 16)
        chevron.frame = NSRect(x: bounds.width - 7 - 8, y: 7, width: 8, height: 8)
        CATransaction.commit()
        label.frame = NSRect(x: 25, y: 3, width: max(0, chevron.frame.minX - 4 - 25), height: 16)
    }
}
