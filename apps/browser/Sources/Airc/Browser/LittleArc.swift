// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// LA-1 Little Arc (spec §2.16b): a small window with one page and no sidebar, for links from other apps (AT-1's
/// default) and ⌥⌘N. A compact row holds the page's favicon, host and title, and Arc's Open in button at the right: a
/// press on it moves the page into its Space without reloading (the engine moves the live page between windows,
/// engine/FEATURES-V1.md), as ⌘O does; its chevron (⇧⌘O) opens Arc's Open In menu (LittleArcOpenInMenu): the short list
/// of Spaces, each in its colours, the chip's with ⌘O, then Search Spaces (⌥⌘O goes straight there), Profile and Copy
/// Link. A Little Arc window left alone for 6 hours goes to the Archive.
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
    let bar = LittleArcBarView()
    let addressField = LittleArcAddressField()
    /// The page's favicon and title, before and after the host.
    let favicon = CALayer()
    let titleLabel = NSTextField(labelWithString: "")
    /// The loading line under the row.
    let progress = CALayer()
    let chip = LittleArcOpenChip()
    let card = PageCardView()
    private var lights: TrafficLights?
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
    static let barHeight = AircMetrics.LittleArc.barHeight
    /// LA-1: Little Arc comes to the Space you're on, over a full-screen app too (a link from Slack or Mail in full
    /// screen), instead of opening on another Space, out of sight. Each time it's shown it moves to the active Space.
    /// Scripted runs leave it off unless a check asks: it would put test windows over the owner's full-screen apps.
    static var joinsActiveSpace = !LaunchOptions.current.isAutomated || actsAsOwner
    /// Test builds, AIRC_LA_AS_OWNER=1: a scratch copy treats a link as the owner's build does (joins the active Space,
    /// made key, the app activated, LittleArcFullScreen on), for the by-hand proof over another app's full screen
    /// (`--script littlearc` with AIRC_LA_FS=1). Never in the suite.
    static var actsAsOwner: Bool {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_LA_AS_OWNER"] == "1"
        #else
        return false
        #endif
    }
    /// Checks only: the window opens invisible and takes no clicks (a floating panel over the owner's screen otherwise).
    static var startsHidden = false
    /// It opened over another app's full screen (LittleArcFullScreen): a non-activating panel, floating on that Space,
    /// until that Space is left (`settleOverFullScreen`).
    let openedOverFullScreen: Bool
    private(set) var overFullScreen: Bool
    /// The menus made for the chip and ⌥⌘O (the checks see whether a click opened one).
    private(set) var menusMade = 0
    private(set) weak var shownMenu: NSMenu?

    private var store: SpacesStore? { app?.store }
    private var main: WindowController? { app?.controller }

    init(app: AppDelegate, url: URL?, spaceID: String, frame: NSRect, overFullScreen: Bool = false) {
        self.app = app
        self.spaceID = spaceID
        openedOverFullScreen = overFullScreen
        self.overFullScreen = overFullScreen
        // Its own window class: the engine's dialog anchor must not send it behind the browser window (LittleArcWindow).
        // Over another app's full screen, a panel that doesn't activate the app (LittleArcPanel).
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let hosted: NSWindow = overFullScreen
            ? LittleArcPanel(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            : LittleArcWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        hosted.isReleasedWhenClosed = false
        if Self.startsHidden {
            hosted.alphaValue = 0
            hosted.ignoresMouseEvents = true
        }
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

    /// The Spaces behaviour of an ordinary Little Arc window: it moves to the active Space when shown, and may sit over
    /// the active app's full screen.
    static let spacesBehaviour: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    /// The full-screen app's Space is no longer on screen (it was left, or the app left full screen): an ordinary window
    /// again, where it is now, at the normal level, activating the app as a window does.
    func settleOverFullScreen() {
        guard overFullScreen else { return }
        overFullScreen = false
        let w = window
        w.level = .normal
        (w as? NSPanel)?.isFloatingPanel = false
        w.styleMask.remove(.nonactivatingPanel)
        w.collectionBehavior.remove([.canJoinAllSpaces, .moveToActiveSpace])
        w.collectionBehavior.formUnion(Self.spacesBehaviour)
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
        if overFullScreen {
            w.collectionBehavior = LittleArcFullScreen.panelBehaviour
        } else if Self.joinsActiveSpace {
            w.collectionBehavior.formUnion(Self.spacesBehaviour)
        }
        w.minSize = NSSize(width: 420, height: 300)
        w.title = "Little Airc"
        w.delegate = self
        root.controller = self
        root.frame = NSRect(origin: .zero, size: frame.size)
        root.wantsLayer = true
        w.contentView = root
        root.addSubview(background)
        root.addSubview(card)
        root.addSubview(bar)
        root.addSubview(toast)
        bar.wantsLayer = true
        for l in [favicon, progress] {
            l.actions = LayerImage.noActions
            bar.layer?.addSublayer(l)
        }
        // The loading line's growth animates (its frame); everything else changes at once.
        progress.actions = ["hidden": NSNull(), "contents": NSNull(), "backgroundColor": NSNull()]
        favicon.contentsGravity = .resizeAspect
        progress.cornerRadius = AircMetrics.LittleArc.progressHeight / 2
        progress.isHidden = true
        titleLabel.font = AircFont.urlField.nsFont
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        bar.addSubview(addressField)
        bar.addSubview(titleLabel)
        bar.addSubview(chip)
        card.cornerRadius = AircMetrics.LittleArc.cardRadius
        card.embed(engineWindow.hostView)
        addressField.controller = self
        addressField.onEditing = { [weak self] _ in self?.root.needsLayout = true }
        // Arc's Open in button: one press moves the page (the owner's one click, 2026-11-06); only the chevron opens the
        // menu (owner, 2026-11-07). The separate ↗ button is gone.
        chip.onOpen = { [weak self] in self?.openInSpace() }
        chip.onMenu = { [weak self] in self?.showChipMenu() }
        lights = TrafficLights(window: w, centers: AircMetrics.LittleArc.trafficLightCenters)
        refreshChrome()
    }

    /// The row (AircMetrics.LittleArc): lights, favicon at 80, the host and then the title, the chip 8 pt from the right
    /// edge, all centred on the row's middle; the page card under it, inset 6 pt, its corner concentric with the window's.
    func layout() {
        typealias M = AircMetrics.LittleArc
        let b = root.bounds
        background.frame = b
        let h = Self.barHeight, mid = h / 2
        bar.frame = NSRect(x: 0, y: 0, width: b.width, height: h)
        // Narrow windows drop the chip's "Open in" (the tooltip and the menu still say it).
        chip.compact = b.width < 560
        let chipSize = chip.fittingSize
        chip.frame = NSRect(x: b.width - M.chipTrailing - chipSize.width, y: mid - chipSize.height / 2,
                            width: chipSize.width, height: chipSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        favicon.frame = NSRect(x: M.faviconX, y: mid - M.favicon / 2, width: M.favicon, height: M.favicon)
        CATransaction.commit()
        let end = chip.frame.minX - AircSpacing.m
        let fieldH: CGFloat = 20
        if addressField.isEditing {
            // Editing: the whole URL, up to the chip.
            titleLabel.isHidden = true
            addressField.frame = NSRect(x: M.textX, y: mid - fieldH / 2 + 1, width: max(60, end - M.textX), height: fieldH)
        } else {
            let hostW = min(addressField.naturalWidth, max(60, (end - M.textX) * 0.6))
            // The field's cell draws its text a point higher than a label's: one down, so host and title share a baseline.
            addressField.frame = NSRect(x: M.textX, y: mid - fieldH / 2 + 1, width: hostW, height: fieldH)
            let tx = addressField.frame.maxX + M.titleGap
            titleLabel.frame = NSRect(x: tx, y: mid - 8, width: max(0, end - tx), height: 16)
            titleLabel.isHidden = titleLabel.stringValue.isEmpty || titleLabel.frame.width < 120
        }
        let i = M.cardInset
        card.frame = NSRect(x: i, y: h, width: max(0, b.width - 2 * i), height: max(0, b.height - h - i))
        layoutProgress()
        prompts.layout()
        lights?.place()
    }

    /// How far the loading line has got for this load (Chromium reports 1, then 0, while a late image still loads).
    private var progressShown = 0.0

    /// The loading line: under the row, over the card's straight top edge (between its corners). It grows with the page
    /// (never back), waits at 95 % for the last requests, and goes when the page has loaded.
    private func layoutProgress() {
        typealias M = AircMetrics.LittleArc
        CATransaction.begin()
        if let page, page.isLoading {
            let grew = page.progress > progressShown && !progress.isHidden
            progressShown = max(progressShown, page.progress)
            CATransaction.setDisableActions(!grew)
            CATransaction.setAnimationDuration(AircCurve.press.duration)
            let span = max(0, card.frame.width - 2 * M.cardRadius)
            progress.isHidden = false
            progress.frame = NSRect(x: card.frame.minX + M.cardRadius, y: Self.barHeight - M.progressHeight - 2,
                                    width: span * min(0.95, max(0.08, progressShown)), height: M.progressHeight)
        } else {
            CATransaction.setDisableActions(true)
            progressShown = 0
            progress.isHidden = true
        }
        CATransaction.commit()
    }

    /// Favicon, host, title, chip and colours from the page and the Space.
    func refreshChrome() {
        let p = palette
        background.show(p.resolved)
        card.palette = p
        addressField.setPage(url: page?.url?.absoluteString ?? "", palette: p)
        refreshPageDetails(p)
        let space = store?.space(spaceID)
        if let pid = space?.profileID, let profile = store?.profile(pid) {
            chip.configure(profile: profile, spaceName: space?.name ?? "Space", palette: p)
        }
        root.needsLayout = true
    }

    /// The favicon (a globe until the page has one), the title (not when it only repeats the host) and the loading line.
    private func refreshPageDetails(_ p: Palette) {
        let img = page?.favicon ?? LayerImage.symbol("globe", size: 13, weight: .regular, color: p.glyph)
        LayerImage.set(img, on: favicon, in: bar)
        let host = URLRules.displayHost(page?.url?.absoluteString ?? "")
        let title = TextLimits.clip(page?.title ?? "")
        titleLabel.stringValue = title == host || title == page?.url?.absoluteString || URLRules.isNewTab(page?.url?.absoluteString ?? "") ? "" : title
        titleLabel.textColor = p.textSecondary
        progress.backgroundColor = p.textPrimary.withAlphaComponent(0.35).cgColor
        root.needsLayout = true
    }

    // MARK: The page

    private func open(_ url: URL?) {
        guard let pid = profileID, let profile = app?.profiles?.engineProfile(for: pid) else { return }
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
              let url = URLRules.resolve(text, search: profile.defaultSearch) else { return }
        noteActivity()
        if let page { page.load(url); page.focus() } else { open(url) }
    }

    func focusAddress() {
        window.makeFirstResponder(addressField)
    }

    // MARK: Open in Space (⌘O, ⌥⌘O)

    /// ⌘O: into the chip's Space, the same live page (no reload), as a new Today tab; this window closes.
    func openInSpace(_ target: String? = nil) {
        #if AIRC_TESTING
        LittleArcOpenInMenu.note("openInSpace: page \(page != nil), store \(store != nil), browser window \(app?.browserWindow() != nil)")
        #endif
        // WIN-7: the window used last (with every browser window closed, they come back first).
        guard let page, let store, let main = app?.browserWindow() else { return }
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

    /// A row's second line (macOS 14.4's menu subtitle; before it, after the title).
    static func secondary(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) { item.subtitle = text } else { item.title += " — " + text }
    }

    // MARK: Open In (the chevron, ⇧⌘O, ⌥⌘O)

    /// Arc's Open In menu while it's up (LittleArcOpenInMenu).
    private(set) var openInMenu: LittleArcOpenInMenu?

    /// The Spaces as Open In lists them: sidebar order, each with its own colours; "Reloads in <profile>" on a Space of
    /// another profile (a page can't change profile: it opens again there), the others move the page.
    func openInEntries() -> [LittleArcOpenInMenu.Entry] {
        guard let store else { return [] }
        let pid = profileID
        return store.orderedSpaces.map { s in
            LittleArcOpenInMenu.Entry(space: s, note: s.profileID == pid ? nil : "Reloads in \(store.profile(ofSpace: s.id).name)",
                                      palette: Palette(theme: s.theme, systemDark: Self.systemDark))
        }
    }

    /// The chevron and ⇧⌘O: Arc's Open In menu under the chip, the short list of Spaces; ⌥⌘O: straight into Search
    /// Spaces. The chevron or ⇧⌘O again closes it; ⌥⌘O on the short list turns it into the search.
    func showOpenInMenu(searching: Bool = false) {
        if let m = openInMenu, m.isShown {
            if searching, !m.isExpanded { return m.expand(query: "") }
            return m.close()
        }
        guard let store else { return }
        let m = LittleArcOpenInMenu(entries: openInEntries(), primaryID: spaceID, palette: palette,
                                    profile: profileID.flatMap { store.profile($0) },
                                    canCopy: page?.url.map { !URLRules.isNewTab($0.absoluteString) } ?? false, enabled: page != nil)
        m.onOpen = { [weak self] id in self?.openInSpace(id) }
        m.onCopyLink = { [weak self] in self?.copyLink() }
        m.onProfile = { [weak self] row in self?.showProfileMenu(from: row) }
        m.onForward = { [weak self] e in _ = self?.handleKey(e) }
        m.isToggle = { [weak self] e in
            guard let self, e.window === self.window else { return false }
            return self.chip.part(at: self.chip.convert(e.locationInWindow, from: nil)) == .chevron
        }
        m.onClose = { [weak self, weak m] in
            guard let self, let m, self.openInMenu === m else { return }
            self.openInMenu = nil
            self.chip.menuShown = false
        }
        menusMade += 1
        openInMenu = m
        chip.menuShown = true
        m.show(under: chip, searching: searching)
    }

    func showChipMenu() { showOpenInMenu() }

    /// Profile ▸ in Open In: the profiles (`profileMenu`) beside its row. Picking one opens the page again in that
    /// profile, in this window, and closes Open In.
    private func showProfileMenu(from row: NSView) {
        let menu = profileMenu(counted: false)
        let before = spaceID
        menu.popUp(positioning: nil, at: NSPoint(x: row.bounds.maxX + 2, y: 0), in: row)
        if spaceID != before { openInMenu?.close() }
    }

    /// ⇧⌘C and the menu's Copy Link: the page's address, as Copy URL in the browser window.
    func copyLink() {
        guard let url = page?.url?.absoluteString, !URLRules.isNewTab(url) else { return NSSound.beep() }
        WindowController.linkPasteboard.clearContents()
        WindowController.linkPasteboard.setString(url, forType: .string)
        promptToast("Copied Current URL")
    }

    // MARK: Profile

    /// Profile ▸ in the chip's menu (Arc's profile button, LA-1): every profile that has a Space, by its avatar and
    /// name, the page's checked. Another one opens the page again in that profile's most recent Space: it says so.
    func profileMenu(counted: Bool = true) -> NSMenu {
        let menu = NSMenu()
        if counted { menusMade += 1; shownMenu = menu }
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

    /// The chip picked another profile: its most recent Space becomes the target. A page can't change profile, so it
    /// opens again in the new one (signed in as that profile is).
    func switchSpace(_ sid: String) {
        guard sid != spaceID, let store, store.space(sid) != nil else { return }
        if let pid = store.space(sid)?.profileID {
            app?.settings.values.littleArcProfiles.remember(pid, for: page?.url)
        }
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
        archiveTimer = nil
        // Settings → Links → "Archive Little Arcs after: Never".
        guard Self.archiveAfter.isFinite else { return }
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
        archiveAndClose()
    }

    /// Close Little Arc Windows (P06b) and the timer: the page to its Space's Archive, then the window closes.
    func archiveAndClose() {
        if let page, let store, let url = page.url, !URLRules.isNewTab(url.absoluteString),
           let t = try? store.openTab(url: url.absoluteString, inSpace: spaceID, background: true, activate: false, title: page.title) {
            // The Library's "Little Arc" filter (P10a) finds it by this origin, as Arc's Archive filters for Little Arc.
            _ = try? store.archiveTabs([t.id], reason: .auto, label: "Archive Little Airc", origin: ArchiveEntry.littleArcOrigin)
        }
        closeWindow()
    }

    /// Settings → Links → "Archive Little Arcs after:" changed: the timer follows.
    func archiveIntervalChanged() { scheduleArchive() }
    /// When the window goes to the Archive (nil: never), for the checks.
    var archiveDue: Date? { archiveTimer?.fireDate }

    // MARK: Window

    func closeWindow() {
        openInMenu?.close()
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
        openInMenu?.close()
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
        if app?.options.isAutomated == true, !Self.actsAsOwner { w.orderFront(nil) } else { w.makeKeyAndOrderFront(nil); NSApp.activate() }
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
        // Over another app's full screen the panel becomes key without activating the app: that app stays in front,
        // in full screen, and the browser window's desktop isn't switched to.
        if overFullScreen { return window.makeKeyAndOrderFront(nil) }
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

    /// Little Arc's own shortcuts while it's the key window (the main window's commands don't apply to it). The table
    /// spells the commands' default keys; the user's map (Settings → Shortcuts) says which command a typed key is.
    func handleKey(_ event: NSEvent) -> Bool {
        let command = event.charactersIgnoringModifiers.flatMap {
            ShortcutCenter.shared.defaultKey(forTyped: $0.lowercased(), event.modifierFlags.intersection([.command, .option, .control, .shift]))
        }
        // Open In has the keys while it's up (arrows, Return, Esc, typing to search); a ⌘ key closes it and goes on.
        if let m = openInMenu, m.isShown {
            switch command {
            case ("o", [.command, .shift])?, ("o", [.command, .option])?: break
            default: if m.handleKey(event) { return true }
            }
        }
        guard let (key, mods) = command else { return false }
        switch (key, mods) {
        case ("o", .command): openInSpace(); return true
        case ("o", [.command, .option]): showOpenInMenu(searching: true); return true
        case ("o", [.command, .shift]): showOpenInMenu(); return true
        case ("c", [.command, .shift]): copyLink(); return true
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
            guard let self, let main = self.app?.browserWindow() else { tab.close(); return }
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
    func tabDidChangeLoading(_ tab: EngineTab) {
        guard tab === page else { return }
        layoutProgress()
    }
    func tabDidChangeFavicon(_ tab: EngineTab) { refreshAddress(tab) }
    func tabDidChangeNavigationState(_ tab: EngineTab) {}
    func tabDidChangeAudio(_ tab: EngineTab) {}
    func tabDidChangeThemeColor(_ tab: EngineTab) {}

    private func refreshAddress(_ tab: EngineTab) {
        guard tab === page else { return }
        let p = palette
        addressField.setPage(url: tab.url?.absoluteString ?? "", palette: p)
        refreshPageDetails(p)
        // Now, not on the next layout pass (a window off screen has none).
        layoutProgress()
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
/// the key since) puts it back in front, and its children with it (LittleArcFront).
final class LittleArcWindow: NSWindow {
    private lazy var front = LittleArcFront(self)
    var keepsFront: Bool { front.keepsFront }

    override func orderFront(_ sender: Any?) {
        front.ordered()
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        front.ordered()
        super.makeKeyAndOrderFront(sender)
    }

    override func orderOut(_ sender: Any?) {
        front.keepsFront = false
        super.orderOut(sender)
    }

    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(child, ordered: place)
        front.childAttached()
    }
}

/// LA-1 over another app's full screen (LittleArcFullScreen): Little Arc as a panel, as Arc's was. Only a
/// non-activating panel of a regular app is shown on another app's full-screen Space while that app is active (the proof,
/// artifacts/littlearc3). A click makes it key without activating Airc, so typing goes to it and the full-screen app
/// stays in front. Otherwise it behaves as the window does: it stays when the app deactivates, can be main (the engine
/// and AppKit look for a main window), is in the Window menu, and Esc goes to the page, never closing it.
final class LittleArcPanel: NSPanel {
    private lazy var front = LittleArcFront(self)
    var keepsFront: Bool { front.keepsFront }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // Set at creation: the window server learns it then (adding it later isn't reliable).
        super.init(contentRect: contentRect, styleMask: style.union(.nonactivatingPanel), backing: backing, defer: flag)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        worksWhenModal = false
        isExcludedFromWindowsMenu = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {}

    override func orderFront(_ sender: Any?) {
        front.ordered()
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        front.ordered()
        super.makeKeyAndOrderFront(sender)
    }

    override func orderOut(_ sender: Any?) {
        front.keepsFront = false
        super.orderOut(sender)
    }

    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        super.addChildWindow(child, ordered: place)
        front.childAttached()
    }
}

/// Little Arc's "in front again" for both window classes: meant to be in front from an order-front until another window
/// of ours takes the key, and back in front when the engine attaches its dialog anchor meanwhile.
final class LittleArcFront {
    private weak var window: NSWindow?
    var keepsFront = false
    private var keyObserver: NSObjectProtocol?

    init(_ window: NSWindow) {
        self.window = window
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
            [weak self] note in
            // The person moved on to another window of ours: it stays where they leave it.
            if let self, let other = note.object as? NSWindow, other !== self.window, other.parent !== self.window { self.keepsFront = false }
        }
    }

    deinit { keyObserver.map(NotificationCenter.default.removeObserver) }

    func ordered() { keepsFront = true }

    func childAttached() {
        guard let w = window, w.isVisible, keepsFront || w.isKeyWindow else { return }
        w.orderFront(nil)
        // AppKit may settle the group's order after this turn: once more then.
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, w.isVisible, self.keepsFront || w.isKeyWindow else { return }
            w.orderFront(nil)
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

/// The row above the page (flipped, like the root): a press nothing in it takes drags the window.
final class LittleArcBarView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The compact address: the host while it shows, in the text colour and medium; a click edits the whole URL
/// (selected) up to the chip, Return goes there, Esc puts it back.
final class LittleArcAddressField: NSTextField, NSTextFieldDelegate {
    weak var controller: LittleArcController?
    private var url = ""
    private var editing = false { didSet { if editing != oldValue { onEditing?(editing) } } }
    /// Editing began or ended (the row gives the field the title's room while it edits).
    var onEditing: ((Bool) -> Void)?
    var isEditing: Bool { editing }
    /// The host's width as drawn (with the cell's margins).
    var naturalWidth: CGFloat { ceil(attributedStringValue.size().width) + 6 }

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        font = AircFont.urlField.weight(.medium).nsFont
        cell?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        placeholderString = "Search or enter URL…"
        setAccessibilityLabel("Address")
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

/// Arc's Open in button, the one control at the row's right end: the page's profile (its avatar), "Open in" and the
/// Space, then a chevron. A press on the button moves the page into that Space (⌘O); only the chevron opens the menu
/// (⇧⌘O), as Arc's caret did. Each part has its own hover and pressed plate over the chip's resting fill.
final class LittleArcOpenChip: NSView {
    enum Part { case open, chevron }
    typealias M = AircMetrics.LittleArc
    private let plate = CALayer()
    private let partPlate = CALayer()
    private let divider = CALayer()
    private let avatar = CALayer()
    private let chevron = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var avatarImage: NSImage?
    private var palette: Palette?
    private var spaceName = ""
    var onOpen: (() -> Void)?
    var onMenu: (() -> Void)?
    /// Under the pointer, and pressed (the press's part, while the button is down or the menu is up).
    private(set) var hovered: Part? { didSet { if hovered != oldValue { restyle() } } }
    private(set) var pressed: Part? { didSet { if pressed != oldValue { restyle() } } }
    /// The chevron's menu is up.
    var menuShown = false { didSet { pressed = menuShown ? .chevron : nil } }
    /// Without "Open in" (narrow windows).
    var compact = false { didSet { if compact != oldValue { updateLabel(); needsLayout = true } } }
    /// For the checks: what it shows.
    var shownName: String { spaceName }
    var shownText: String { label.stringValue }
    var showsChevron: Bool { chevron.contents != nil && chevronRect.width > 0 && chevronRect.maxX <= bounds.maxX + 0.5 }
    /// The two parts, in the chip's (flipped) coordinates.
    var chevronRect: NSRect { NSRect(x: bounds.width - M.chevronWidth, y: 0, width: M.chevronWidth, height: bounds.height) }
    var openRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width - M.chevronWidth, height: bounds.height) }
    /// The fills the parts show now (the checks read the states).
    var plateFill: CGColor? { plate.backgroundColor }
    var partFill: CGColor? { partPlate.isHidden ? nil : partPlate.backgroundColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [plate, partPlate, divider, avatar, chevron] {
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        plate.cornerRadius = M.chipRadius
        plate.cornerCurve = .continuous
        partPlate.cornerCurve = .continuous
        partPlate.isHidden = true
        avatar.contentsGravity = .resizeAspect
        chevron.contentsGravity = .center
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The whole chip takes the press: its label would keep a first click for itself.
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || !frame.contains(point) ? nil : self }

    func part(at p: NSPoint) -> Part? {
        chevronRect.contains(p) ? .chevron : openRect.contains(p) ? .open : nil
    }

    /// A press that began on the Open in part (it acts on release there, as AppKit's buttons).
    private var tracking = false

    override func mouseDown(with event: NSEvent) {
        switch part(at: convert(event.locationInWindow, from: nil)) {
        case .chevron?:
            // As a pop-up button: the menu on the press.
            onMenu?()
        case .open?:
            tracking = true
            pressed = .open
        case nil:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        // Pressed only while the pointer stays on the button.
        pressed = part(at: convert(event.locationInWindow, from: nil)) == .open ? .open : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        tracking = false
        pressed = nil
        if part(at: convert(event.locationInWindow, from: nil)) == .open { onOpen?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    /// The pointer is at `p` (chip coordinates; nil: it left). The checks call this: posted moves never reach tracking areas.
    func hover(at p: NSPoint?) { hovered = p.flatMap(part(at:)) }

    func configure(profile: Profile, spaceName: String, palette: Palette) {
        self.palette = palette
        self.spaceName = spaceName
        let img = ProfileAvatarImage.image(profile, size: 16)
        if img !== avatarImage {
            avatarImage = img
            LayerImage.set(img, on: avatar, in: self)
        }
        LayerImage.set(LayerImage.symbol("chevron.down", size: 9, weight: .semibold, color: palette.textSecondary), on: chevron, in: self)
        updateLabel()
        restyle()
        setAccessibilityLabel("Open in \(spaceName)")
        toolTip = "Open in \(spaceName) (⌘O). The chevron (⇧⌘O): the Spaces, Search Spaces (⌥⌘O), the Profile (“\(profile.name)”), Copy Link."
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func updateLabel() {
        guard let palette else { return }
        let text = NSMutableAttributedString()
        if !compact {
            text.append(NSAttributedString(string: "Open in ", attributes: [
                .font: AircFont.callout.nsFont, .foregroundColor: palette.textSecondary]))
        }
        text.append(NSAttributedString(string: spaceName, attributes: [
            .font: AircFont.callout.weight(.semibold).nsFont, .foregroundColor: palette.textPrimary]))
        label.attributedStringValue = text
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if LayerImage.scaleChanged(avatar, in: self), let avatarImage { LayerImage.set(avatarImage, on: avatar, in: self) }
        if LayerImage.scaleChanged(chevron, in: self), let palette {
            LayerImage.set(LayerImage.symbol("chevron.down", size: 9, weight: .semibold, color: palette.textSecondary), on: chevron, in: self)
        }
    }

    /// Resting: the field fill (the browser window's URL field). Hover: the part gets the hover fill on top; pressed (or
    /// its menu up): the tile hover fill, a step darker (the theme's pressed fill is lighter than hover: rows shrink). The divider between the parts goes while either is lit, so the plate reads as one.
    private func restyle() {
        guard let palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = palette.urlFieldFill.cgColor
        let lit = pressed ?? hovered
        partPlate.isHidden = lit == nil
        partPlate.backgroundColor = (pressed != nil ? palette.tileHover : palette.hover).cgColor
        divider.backgroundColor = palette.separator.cgColor
        divider.isHidden = lit != nil
        CATransaction.commit()
        needsLayout = true
    }

    /// Padding 5, avatar 16, gap 6, the label (at most 180 pt), padding 8, then the chevron's 22.
    override var fittingSize: NSSize {
        let text = min(180, ceil(label.attributedStringValue.size().width) + 4)
        return NSSize(width: 5 + 16 + 6 + text + 8 + M.chevronWidth, height: M.chipHeight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        let lit = pressed ?? hovered
        let r = lit == .chevron ? chevronRect : openRect
        partPlate.frame = r
        // Rounded on the chip's outer corners only, so the lit part fills its end of the plate exactly.
        partPlate.cornerRadius = M.chipRadius
        partPlate.maskedCorners = lit == .chevron ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        divider.frame = NSRect(x: chevronRect.minX - 0.5, y: 6, width: 1, height: bounds.height - 12)
        avatar.frame = NSRect(x: 5, y: (bounds.height - 16) / 2, width: 16, height: 16)
        chevron.frame = chevronRect
        CATransaction.commit()
        label.frame = NSRect(x: 27, y: (bounds.height - 16) / 2, width: max(0, openRect.width - 27 - 8 + 4), height: 16)
    }
}

/// LA-1 over another app's full screen (owner report 2026-11-07: a link clicked in Slack or Mail in full screen didn't
/// show Little Arc over it). Launch Services activates Airc about 90 ms before it hands the link over. Little Arc as an
/// ordinary window then opened on the browser window's desktop, and macOS switched away from the full-screen Space
/// (artifacts/littlearc3). So:
/// - **The link** that comes while the app it came from is in native full screen opens Little Arc as a non-activating
///   floating panel (LittleArcPanel), made key at once. It shows on that Space, in front of the full-screen app, which
///   stays in full screen, and macOS doesn't switch (the proof, artifacts/lafullscreen: no Space change at all). A
///   click into it later makes it key without activating Airc. Elsewhere Little Arc is the ordinary window it always was.
/// - **No link** (⌘-Tab, the Dock): nothing changes; macOS switches to the browser window's desktop as before.
/// - **Fallback.** Should macOS switch anyway, Airc hands the activation back to the full-screen app 0.8 s after the
///   link (Launch Services activates Airc once more as it delivers it), and macOS returns to that Space with Little Arc
///   over it: a round trip to the desktop and back (littlearc3's way).
/// - **Settling.** The panel stays on that Space. Once the full-screen app leaves full screen (or quits), it becomes an
///   ordinary window again (`settleOverFullScreen`).
/// Links.log has each step with the Space changes, timed from the activation. Event-driven only: it looks at the window
/// list when Airc is about to become active, as a link is routed, and once per Space change while such a panel is open.
final class LittleArcFullScreen {
    static let shared = LittleArcFullScreen()
    weak var app: AppDelegate?

    /// Owner builds; test builds only for the by-hand proof (AIRC_LA_AS_OWNER=1), never in the suite (a suite run must
    /// not put a panel over the owner's full-screen app or hand the activation anywhere).
    static var enabled: Bool { !LaunchOptions.current.isAutomated || LittleArcController.actsAsOwner }
    /// The panel's Spaces: that full-screen Space only. The by-hand proof also tries every Space (AIRC_LA_FS_SPACES=all).
    static var panelBehaviour: NSWindow.CollectionBehavior {
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_LA_FS_SPACES"] == "all" { return [.canJoinAllSpaces, .fullScreenAuxiliary] }
        #endif
        return [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    /// How long after the link the fallback hands the activation back (Launch Services is done with Airc by then).
    static var settle: TimeInterval = 0.8

    /// The last other app that came to the front.
    private var lastOther: pid_t = 0
    /// The full-screen app Airc was just activated from, and when (the link comes about 0.1 s later).
    private var source: (pid: pid_t, at: Date)?
    /// The last activation from a full-screen app, for Links.log's timings, and the Space changes since.
    private(set) var episodeStart: Date?
    private(set) var spaceChanges: [TimeInterval] = []
    private var observers: [NSObjectProtocol] = []
    /// Little Arcs over a full-screen app, with that app.
    private struct Floating { weak var controller: LittleArcController?; var app: pid_t }
    private var floating: [Floating] = []
    /// What it did last (the checks and Links.log).
    private(set) var lastAction = "none"

    func install(app: AppDelegate) {
        self.app = app
        // P06b: the shortcut from anywhere and the archive interval (LittleArcGlobalActions; off: nothing installed).
        LittleArcGlobalActions.shared.install(app: app)
        guard observers.isEmpty, Self.enabled else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastOther = front.processIdentifier }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let pid = a?.processIdentifier, pid != getpid() { self?.lastOther = pid }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activeSpaceChanged()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.appWillBecomeActive()
        })
    }

    // MARK: Activation and the link

    private func stamp() -> String { episodeStart.map { String(format: "+%.3f s", Date().timeIntervalSince($0)) } ?? "-" }

    private func appWillBecomeActive() {
        source = nil
        let candidates = [NSWorkspace.shared.frontmostApplication?.processIdentifier, lastOther].compactMap { $0 }.filter { $0 != getpid() && $0 != 0 }
        guard let pid = candidates.first(where: LinkLog.isFullScreen) else { return }
        source = (pid, Date())
        episodeStart = Date()
        spaceChanges = []
        lastAction = "activated from a full-screen app"
        LinkLog.write("Little Arc full screen: +0.000 s activated from \(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)") "
                      + "in full screen")
    }

    /// A link is being routed: the full-screen app it came from, if Airc was just activated from one (or Airc wasn't
    /// activated and that app is still in front in full screen). Taken once.
    func takeLinkSource() -> pid_t? {
        guard Self.enabled else { return nil }
        if let s = source, Date().timeIntervalSince(s.at) < 3 {
            source = nil
            return s.pid
        }
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           LinkLog.isFullScreen(front.processIdentifier) {
            episodeStart = Date()
            spaceChanges = []
            return front.processIdentifier
        }
        return nil
    }

    /// A Little Arc opened over `pid`'s full screen and was ordered front. If macOS switched to the desktop anyway, the
    /// activation goes back to that app once Launch Services is done (the fallback).
    func shown(_ l: LittleArcController, over pid: pid_t) {
        floating.append(Floating(controller: l, app: pid))
        let w = l.window
        // Already ordered front by `openLittleArc`; on the full-screen Space whether Airc is active or not.
        w.orderFrontRegardless()
        lastAction = "shown over the full-screen app"
        // The suite's panels (checks) never hand activation anywhere.
        guard Self.enabled, pid != getpid() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak l] in
            guard let self, let l else { return }
            let there = LinkLog.isFullScreen(pid)
            LinkLog.write("Little Arc full screen: \(self.stamp()) Little Arc shown, the full-screen app's Space on screen \(LinkLog.yesNo(there)), "
                          + "Space changes \(self.spaceChanges.count), app active \(LinkLog.yesNo(NSApp.isActive))")
            guard !there, let prev = NSRunningApplication(processIdentifier: pid) else {
                self.lastAction = "shown over the full-screen app, no switch"
                return
            }
            let wait = max(0, Self.settle - 0.15)
            self.lastAction = "switched; handing back"
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak l] in
                guard let self, let w = l?.window, w.isVisible else { return }
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: prev)
                    prev.activate(from: .current, options: [])
                } else {
                    prev.activate(options: [])
                }
                w.orderFrontRegardless()
                self.lastAction = "handed back to the full-screen app"
                LinkLog.write("Little Arc full screen: \(self.stamp()) handed the activation back")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    LinkLog.write("Little Arc full screen: \(self.stamp()) after the hand-back: \(LinkLog.frontApp()), Little Arc on the active Space "
                                  + "\(LinkLog.yesNo(w.isOnActiveSpace)), app active \(LinkLog.yesNo(NSApp.isActive))")
                }
            }
        }
    }

    // MARK: Spaces

    private func activeSpaceChanged() {
        if let start = episodeStart, Date().timeIntervalSince(start) < 15 {
            spaceChanges.append(Date().timeIntervalSince(start))
            LinkLog.write("Little Arc full screen: \(stamp()) the active Space changed (\(LinkLog.frontApp()))")
        }
        guard !floating.isEmpty else { return }
        // Once the Space has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.settleFloating() }
    }

    /// Each Little Arc over a full-screen app that left full screen (or quit) becomes an ordinary window. On that Space
    /// only (the default), it waits there while the person is elsewhere; on every Space (the proof's other way), it
    /// settles on the Space it moved to.
    func settleFloating() {
        floating = floating.filter { f in
            guard let l = f.controller, l.overFullScreen, l.window.isVisible else { return false }
            let onlyThere = !l.window.collectionBehavior.contains(.canJoinAllSpaces)
            if LinkLog.isFullScreen(f.app) || (onlyThere && !l.window.isOnActiveSpace && NSRunningApplication(processIdentifier: f.app) != nil) {
                return true
            }
            l.settleOverFullScreen()
            LinkLog.write("Little Arc full screen: an ordinary window again (its full-screen app left full screen or its Space was left)")
            return false
        }
    }
}
