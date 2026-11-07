// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine

/// Rows that show a tab preview: Today and pinned tab rows, Favorites tiles.
protocol TabPreviewRow: SidebarRowView {
    var previewEntry: SidebarEntry? { get }
}

extension TabRowView: TabPreviewRow {
    var previewEntry: SidebarEntry? { entry }
}

extension FavoriteTileView: TabPreviewRow {
    /// SV-2: a Favorite split's tile already shows its panes.
    var previewEntry: SidebarEntry? {
        guard let item, item.kind != .split else { return nil }
        return .favorite(item, controller?.store.liveTab(forItem: item.id))
    }
}

extension WindowController {
    private static var tabPreviewKey = 0

    /// SB-45: the card beside a sidebar tab under the pointer.
    var tabPreview: TabPreviewController {
        if let p = objc_getAssociatedObject(self, &Self.tabPreviewKey) as? TabPreviewController { return p }
        let p = TabPreviewController(controller: self)
        objc_setAssociatedObject(self, &Self.tabPreviewKey, p, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return p
    }
}

/// SB-45 tab previews (Dia's rich tab previews): the pointer resting on a pinned tab, a Today tab or a Favorite for
/// `dwell` brings a card beside the sidebar, level with the row: the page's picture, its favicon and title, the host,
/// and quick actions (pin or unpin, add to or remove from Favorites, open in a split with the page on screen, Peek).
/// With a card up, moving to another row moves it there at once.
///
/// Cost: the rows' own enter and exit events drive it (TabRowView, FavoriteTileView); nothing runs on a mouse move.
/// The event monitor and the sidebar observer exist only while a row is under the pointer or the card is up.
///
/// Pictures come from the engine only for pages on screen (`EnginePreviewSnapshotting`): live for the page shown,
/// otherwise the last one kept in memory (TabPreviewCache), taken when a page is shown, when it leaves the screen and
/// when the pointer comes to the sidebar. A hidden, unloaded or discarded page is never asked: Chromium can't copy a
/// surface it no longer draws, and WebKit would repaint the page just for it.
///
/// It hides on a click, a scroll, any key (Esc only closes it), a menu, the sidebar collapsing or resizing, a Space
/// change and a tab change; it never shows while rows are dragged, while the Space pager moves, or over the Command
/// Bar, Site Controls, the Library or the other panels. Keyboard users get no card. Settings → Appearance → "Show tab
/// previews" turns it off (and forgets the pictures).
final class TabPreviewController {
    static let dwell: TimeInterval = 0.4
    /// Off a row or the card: this long to reach the card or another row before it hides.
    static let grace: TimeInterval = 0.22
    /// A card that hid this recently because the pointer left the sidebar comes back without the dwell.
    static let warm: TimeInterval = 0.35
    /// Rows moving under a still pointer (a scroll) don't count as hovering for this long after the last scroll event.
    static let scrollQuiet: TimeInterval = 0.35
    /// The sidebar edge to the card.
    static let gap: CGFloat = 6
    /// The page on screen is pictured again when the pointer comes to the sidebar if its picture is older than this.
    static let staleAfter: CFTimeInterval = 2

    enum Thumbnail: String { case none, live, cached, placeholder }

    private weak var c: WindowController?
    private(set) var card: TabPreviewCardView?
    private(set) var isShowing = false
    /// The row under the pointer, and the pointer's last known place (window coordinates, from the rows' events).
    private weak var row: SidebarRowView?
    private var pointer: NSPoint = .zero
    private(set) weak var shownRow: SidebarRowView?
    private(set) var shownEntry: SidebarEntry?
    private(set) var thumbnail: Thumbnail = .none
    private var dwellWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var switchWork: DispatchWorkItem?
    private var shownWork: DispatchWorkItem?
    private var insideCard = false
    /// No card for this row until the pointer leaves it (a click, a key or a menu on it).
    private weak var suppressedRow: SidebarRowView?
    private var lastScroll: CFTimeInterval = 0
    private var hiddenAt: CFTimeInterval = 0
    private var hiddenByLeaving = false
    private var menuOpen = false
    private var monitor: Any?
    private var sidebarObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var settingsObserver: AnyCancellable?
    /// Pictures asked for and not back yet, with whoever waits for them.
    private var pending: [String: [(CGImage?) -> Void]] = [:]

    init(controller: WindowController) {
        c = controller
        let nc = NotificationCenter.default
        menuObservers = [
            nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = true
                self?.dismiss(suppressing: self?.row)
            },
            nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = false
            },
        ]
        settingsObserver = controller.app?.settings?.$values.map(\.tabPreviews).removeDuplicates().dropFirst().sink { [weak self] on in
            guard !on else { return }
            self?.hide()
            TabPreviewCache.shared.removeAll()
        }
    }

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        disarm()
    }

    var isEnabled: Bool { c?.app?.settings?.values.tabPreviews ?? true }

    // MARK: Hover

    /// The pointer entered a row (its tracking area's event).
    func hoverBegan(_ r: SidebarRowView, event: NSEvent) {
        guard isEnabled else { return }
        #if AIRC_TESTING
        let t0 = CACurrentMediaTime()
        defer { stats.hoverCost.append(CACurrentMediaTime() - t0); stats.enters += 1; stats.lastEnterAt = t0 }
        #endif
        let previous = pointer
        pointer = event.locationInWindow
        row = r
        hideWork?.cancel()
        arm()
        refreshVisibleIfStale()
        guard suppressedRow !== r, CACurrentMediaTime() - lastScroll >= Self.scrollQuiet else { return }
        if isShowing {
            guard shownRow !== r else { return }
            // On the way to the card across other rows: a moment to arrive before the card moves.
            if heading(from: previous, to: pointer) {
                switchWork?.cancel()
                let w = DispatchWorkItem { [weak self, weak r] in
                    guard let self, let r, self.row === r, !self.insideCard else { return }
                    self.show(r)
                }
                switchWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
                return
            }
            return show(r)
        }
        if hiddenByLeaving, CACurrentMediaTime() - hiddenAt < Self.warm { return show(r) }
        scheduleDwell(r)
    }

    /// The pointer left a row.
    func hoverEnded(_ r: SidebarRowView, event: NSEvent?) {
        if suppressedRow === r { suppressedRow = nil }
        guard row === r else { return }
        if let event { pointer = event.locationInWindow }
        row = nil
        dwellWork?.cancel()
        dwellWork = nil
        if isShowing { scheduleHide() } else { disarm() }
    }

    private func scheduleDwell(_ r: SidebarRowView) {
        dwellWork?.cancel()
        let w = DispatchWorkItem { [weak self, weak r] in
            guard let self, let r, self.row === r else { return }
            self.show(r)
        }
        dwellWork = w
        #if AIRC_TESTING
        stats.dwellTimers += 1
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: w)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.insideCard, self.row == nil else { return }
            self.hide(leaving: true)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: w)
    }

    /// Whether the pointer moving from `a` to `b` heads for the card: `b` lies in the triangle from `a` to the card's
    /// near edge (the menu-aim rule).
    private func heading(from a: NSPoint, to b: NSPoint) -> Bool {
        let onRight = c?.sidebarOnRight == true
        guard let card, card.superview != nil, onRight ? b.x < a.x : b.x > a.x else { return false }
        let r = card.convert(card.cardRect, to: nil)
        let nearX = onRight ? r.maxX : r.minX
        let top = NSPoint(x: nearX, y: r.maxY), bottom = NSPoint(x: nearX, y: r.minY)
        func side(_ p: NSPoint, _ q: NSPoint, _ s: NSPoint) -> CGFloat { (q.x - p.x) * (s.y - p.y) - (q.y - p.y) * (s.x - p.x) }
        let d1 = side(a, top, b), d2 = side(top, bottom, b), d3 = side(bottom, a, b)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    // MARK: Events while armed

    private func arm() {
        guard monitor == nil, let c else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
            self?.handle(e) ?? e
        }
        sidebarObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: c.sidebar,
                                                                 queue: .main) { [weak self] _ in
            self?.dismiss(suppressing: self?.row)
        }
    }

    private func disarm() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if let o = sidebarObserver { NotificationCenter.default.removeObserver(o) }
        sidebarObserver = nil
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // The card's own buttons.
            if isShowing, let card, e.window === c?.window, card.cardRect.contains(card.convert(e.locationInWindow, from: nil)) {
                return e
            }
            dismiss(suppressing: row)
        case .scrollWheel:
            lastScroll = CACurrentMediaTime()
            dismiss(suppressing: nil)
        case .keyDown:
            let wasShowing = isShowing
            dismiss(suppressing: row)
            if wasShowing, e.keyCode == 53 { return nil }   // Esc closes the card and nothing else
        default:
            break
        }
        return e
    }

    /// Hides at once and cancels a pending dwell; `suppressing` stays without a card until the pointer leaves it.
    func dismiss(suppressing r: SidebarRowView?) {
        if let r { suppressedRow = r }
        dwellWork?.cancel()
        dwellWork = nil
        hide()
    }

    // MARK: Showing

    private func canShow(_ r: SidebarRowView, _ c: WindowController) -> Bool {
        guard isEnabled, !menuOpen, r.window === c.window, c.window.isVisible, !r.isHiddenOrHasHiddenAncestor,
              r.page.map({ $0.spaceID == c.currentSpaceID }) ?? true,
              c.dragsInProgress == 0, NSEvent.pressedMouseButtons == 0, !c.sidebar.pager.isTrackingOrSettling,
              !c.sidebarHidden || c.revealController?.isRevealed == true,
              CACurrentMediaTime() - lastScroll >= Self.scrollQuiet,
              c.commandBar == nil, c.siteControls == nil, c.library == nil, c.newSpacePanel == nil, c.createProfilePanel == nil,
              c.themePopover == nil, c.folderPreview.panel == nil, c.boostEditor == nil, c.extensionsPopover?.isShown != true,
              c.manageSpacesPanel == nil else { return false }
        // Scrolled out of the list, or the pointer isn't on it any more (rows moved under it).
        let visible = r.visibleRect
        return visible.height >= r.bounds.height / 2 && r.bounds.contains(r.convert(pointer, from: nil))
    }

    private func show(_ r: SidebarRowView) {
        dwellWork = nil
        switchWork?.cancel()
        guard let c, let entry = (r as? TabPreviewRow)?.previewEntry, entry.liveTab != nil || entry.item?.savedURL != nil,
              canShow(r, c) else { return }
        #if AIRC_TESTING
        let t0 = CACurrentMediaTime()
        defer { stats.showCost.append(CACurrentMediaTime() - t0); stats.shows += 1; stats.lastShownAt = CACurrentMediaTime() }
        #endif
        let card = self.card ?? makeCard()
        let url = Self.url(of: entry, in: c)
        card.apply(content(of: entry, url: url, in: c), palette: c.currentPalette)
        let tabID = entry.liveTab?.id
        if let shot = TabPreviewCache.shared.shot(tab: tabID, item: entry.item?.id, url: url) {
            card.setThumbnail(shot.image)
            thumbnail = .cached
        } else {
            card.setThumbnail(nil)
            thumbnail = .placeholder
        }
        let wasShowing = isShowing && card.superview != nil
        let oldFrame = card.frame
        let frame = Self.frame(beside: r, in: c)
        card.frame = frame
        if !wasShowing {
            c.folderPreview.hide()
            c.root.addSubview(card, positioned: .below, relativeTo: c.toast)
        }
        card.layoutSubtreeIfNeeded()
        isShowing = true
        shownRow = r
        shownEntry = entry
        insideCard = false
        let rowMid = r.convert(NSPoint(x: 0, y: r.bounds.midY), to: c.root).y
        if wasShowing { move(card, from: oldFrame, to: frame) } else { present(card, anchorY: rowMid - frame.minY) }
        // The page on screen: a picture of it as it is now.
        if let tabID, c.visibleTabIDs.contains(tabID) {
            capture(tabID, reason: .live) { [weak self] image in
                guard let self, let image, self.isShowing, self.shownEntry?.id == entry.id else { return }
                self.card?.setThumbnail(image)
                self.thumbnail = .live
            }
        }
    }

    /// Hides at once (one frame, like the folder preview).
    func hide(leaving: Bool = false) {
        dwellWork?.cancel()
        switchWork?.cancel()
        hideWork?.cancel()
        if isShowing {
            isShowing = false
            hiddenAt = CACurrentMediaTime()
            hiddenByLeaving = leaving
            shownRow = nil
            shownEntry = nil
            insideCard = false
            thumbnail = .none
            card?.layer?.removeAllAnimations()
            card?.removeFromSuperview()
        }
        if row == nil { disarm() }
    }

    /// The card is built a moment after the window's first page, at idle, so the first one shown costs what every later
    /// one does (building its labels, buttons and symbols took 4–10 ms in a hover's frame).
    private var prewarmed = false
    private func prewarm() {
        guard !prewarmed else { return }
        prewarmed = true
        func build(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, let c = self.c, self.card == nil else { return }
                if c.isBusyForIdleWork, tries < 5 { return build(tries + 1) }
                let card = self.makeCard()
                card.frame = NSRect(x: 0, y: 0, width: TabPreviewCardView.width + 2 * TabPreviewCardView.margin,
                                    height: TabPreviewCardView.height + 2 * TabPreviewCardView.margin)
                card.apply(.init(title: "", host: "", favicon: nil, faviconURL: nil, pageURL: "", isPinned: false, isFavorite: false,
                                 canSplit: true, canPeek: true), palette: c.currentPalette)
                card.setThumbnail(nil)
                card.layoutSubtreeIfNeeded()
            }
        }
        build(0)
    }

    private func makeCard() -> TabPreviewCardView {
        let v = TabPreviewCardView(frame: .zero)
        v.onButton = { [weak self] b in self?.perform(b) }
        v.onHover = { [weak self] inside in
            guard let self else { return }
            self.insideCard = inside
            if inside { self.hideWork?.cancel() } else if self.row == nil { self.scheduleHide() }
        }
        card = v
        return v
    }

    /// Beside the sidebar (to its left when it's on the right, WIN-5), the card's top level with the row's, kept inside
    /// the window.
    static func frame(beside r: SidebarRowView, in c: WindowController) -> NSRect {
        let m = TabPreviewCardView.margin, w = TabPreviewCardView.width, h = TabPreviewCardView.height
        let rowRect = r.convert(r.bounds, to: c.root)
        let sidebar = c.sidebar.convert(c.sidebar.bounds, to: c.root)
        let x = c.sidebarOnRight ? max(sidebar.minX - gap - w, 8) : min(sidebar.maxX + gap, c.root.bounds.width - w - 8)
        let top = min(max(8, rowRect.minY - 4), c.root.bounds.height - h - 8)
        return NSRect(x: x - m, y: top - m, width: w + 2 * m, height: h + 2 * m).integral
    }

    /// Reduce Motion, or the checks' stand-in for it.
    private var reduceMotion: Bool {
        #if AIRC_TESTING
        if let o = Self.reduceMotionOverride { return o }
        #endif
        return onMain { AircMotion.prefersReducedMotion }
    }

    /// Grows from the row's edge on the popover spring and fades in (Reduce Motion: a 150 ms fade).
    private func present(_ card: TabPreviewCardView, anchorY: CGFloat) {
        guard let layer = card.layer else { return }
        #if AIRC_TESTING
        stats.lastPresentSprang = !reduceMotion
        #endif
        if reduceMotion { return layer.fade(from: 0, to: 1, duration: AircMotion.reducedDuration) }
        // A flipped view's layer has its origin at the top left: scale about the card's edge nearest the sidebar, level
        // with the row.
        let nearX = c?.sidebarOnRight == true ? card.bounds.width - TabPreviewCardView.margin : TabPreviewCardView.margin
        let p = CGPoint(x: nearX, y: min(max(anchorY, TabPreviewCardView.margin), card.bounds.height - TabPreviewCardView.margin))
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, 0.94, 0.94, 1)
        t = CATransform3DTranslate(t, -p.x, -p.y, 0)
        layer.add(AircSpring.grow.caAnimation(keyPath: "transform", from: NSValue(caTransform3D: t),
                                              to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "grow")
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
    }

    /// Row to row with the card up: it glides to the new row on the row spring (Reduce Motion: a cross-fade in place).
    private func move(_ card: TabPreviewCardView, from old: NSRect, to new: NSRect) {
        guard let layer = card.layer, old != new else { return }
        layer.removeAnimation(forKey: "grow")
        if reduceMotion {
            layer.add(AircMotion.crossfadeTransition(), forKey: kCATransition)
            return
        }
        let t = CATransform3DMakeTranslation(old.minX - new.minX, old.minY - new.minY, 0)
        layer.add(AircSpring.row.caAnimation(keyPath: "transform", from: NSValue(caTransform3D: t),
                                             to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "move")
    }

    // MARK: Content

    static func url(of entry: SidebarEntry, in c: WindowController) -> String {
        let tab = entry.liveTab.flatMap { c.store.tab($0.id) }
        let page = tab.flatMap { c.engineTab(for: $0.id) }
        return page?.url?.absoluteString ?? tab?.url ?? entry.item.flatMap { c.store.item($0.id)?.savedURL } ?? ""
    }

    private func content(of entry: SidebarEntry, url: String, in c: WindowController) -> TabPreviewCardView.Content {
        let tab = entry.liveTab.flatMap { c.store.tab($0.id) }
        let item = entry.item.flatMap { c.store.item($0.id) }
        let page = tab.flatMap { c.engineTab(for: $0.id) }
        let pageTitle = page?.title.isEmpty == false ? page?.title : nil
        let title: String
        switch entry {
        case .pinned: title = item?.displayTitle ?? pageTitle ?? ""
        case .favorite: title = pageTitle ?? item?.displayTitle ?? ""
        default: title = pageTitle ?? tab?.displayTitle ?? ""
        }
        let onScreen = tab.map { c.visibleTabIDs.contains($0.id) } ?? false
        let shownSplit = c.shownSplitID.flatMap { c.store.split($0) }
        let web = url.hasPrefix("http://") || url.hasPrefix("https://")
        return .init(title: title, host: URLRules.displayHost(url), favicon: page?.favicon,
                     faviconURL: tab?.faviconURL ?? item?.faviconURL, pageURL: url,
                     isPinned: item.map { !$0.isFavorite } ?? false, isFavorite: item?.isFavorite ?? false,
                     canSplit: c.shownTabID != nil && !onScreen && (shownSplit?.tabIDs.count ?? 1) < Split.maxPanes && !url.isEmpty,
                     canPeek: c.shownTabID != nil && !onScreen && web)
    }

    // MARK: Actions

    private func perform(_ b: TabPreviewCardView.Button) {
        guard let c, let entry = shownEntry else { return }
        let tab = entry.liveTab.flatMap { c.store.tab($0.id) }
        let item = entry.item.flatMap { c.store.item($0.id) }
        let url = Self.url(of: entry, in: c)
        dismiss(suppressing: shownRow)
        let action: TelemetryFeature.TabPreviewAction
        switch b {
        case .pin:
            if let item, item.isFavorite {
                action = .pin
                c.performDrop(.item(item.id), to: .pinned(spaceID: c.currentSpaceID, parentID: nil, index: 0))
            } else if let item {
                action = .unpin
                c.performDrop(.item(item.id), to: .today(spaceID: c.currentSpaceID, index: 0))
            } else if let tab {
                action = .pin
                try? c.store.togglePin(tab.id, inSpace: c.currentSpaceID)
            } else { return }
        case .favorite:
            if let item, item.isFavorite {
                action = .unfavorite
                c.performDrop(.item(item.id), to: .today(spaceID: c.currentSpaceID, index: 0))
            } else if let item {
                action = .favorite
                c.performDrop(.item(item.id), to: .favorites(profileID: c.store.profile(ofSpace: c.currentSpaceID).id, index: 99))
            } else if let tab {
                action = .favorite
                c.performDrop(.tab(tab.id), to: .favorites(profileID: tab.profileID, index: 99))
            } else { return }
        case .split:
            guard let anchor = c.shownTabID else { return }
            if let x = c.store.split(containing: anchor), x.tabIDs.count >= Split.maxPanes {
                return c.showToast(WindowController.splitFullMessage)
            }
            guard let id = tab?.id ?? item.flatMap({ try? c.store.openItem($0.id, inSpace: c.currentSpaceID, activate: false) })?.id,
                  !c.visibleTabIDs.contains(id) else { return }
            action = .split
            c.addPane(id, nextTo: anchor, axis: .horizontal)
        case .peek:
            guard let shown = c.shownTabID, let opener = c.engineTab(for: shown), let u = URL(string: url) else { return }
            action = .peek
            c.openPeek(u, from: opener)
        }
        Telemetry.shared.record(.featureUsed(.tabPreviewAction(action)))
        #if AIRC_TESTING
        stats.actions.append(action.rawValue)
        #endif
    }

    // MARK: Pictures

    enum Reason: String { case live, shown, leaving, hover }

    /// The page shown changes (WindowController.show, before the engine swaps them): a last picture of the one leaving
    /// while it's still drawn (WebKit pages), and one of the new page once it has settled.
    func pageWillChange(hiding: String?, showing: String) {
        if isShowing { hide() }
        guard isEnabled else { return }
        prewarm()
        guard hiding != showing else { return }
        if let hiding { capture(hiding, reason: .leaving) }
        scheduleShownCapture(showing, attempt: 0)
    }

    private func scheduleShownCapture(_ id: String, attempt: Int) {
        shownWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, let c = self.c, c.visibleTabIDs.contains(id) else { return }
            // Still loading: once more a little later, then whatever it shows.
            if c.engineTab(for: id)?.isLoading == true, attempt < 2 { return self.scheduleShownCapture(id, attempt: attempt + 1) }
            self.capture(id, reason: .shown)
        }
        shownWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 1.2 : 2), execute: w)
    }

    /// The pointer came to the sidebar: the page on screen again if its picture is older than `staleAfter` (so the
    /// next switch leaves a fresh one behind). At most once per page per `staleAfter`.
    private func refreshVisibleIfStale() {
        guard let c else { return }
        for id in c.visibleTabIDs where pending[id] == nil && (TabPreviewCache.shared.age(tab: id) ?? .infinity) > Self.staleAfter {
            capture(id, reason: .hover)
        }
    }

    /// Asks the engine for a picture of `tabID`'s page, which must be on screen (or just leaving it), and keeps it.
    func capture(_ tabID: String, reason: Reason, completion: ((CGImage?) -> Void)? = nil) {
        guard isEnabled, let c, c.visibleTabIDs.contains(tabID) || reason == .leaving, !c.isPageUnloaded(tabID),
              let page = c.engineTab(for: tabID), let source = page as? EnginePreviewSnapshotting,
              reason != .leaving || source.picturesLeavingPage else { completion?(nil); return }
        // The selected tab can belong to a hidden or minimized window. It has no new
        // frame to copy; keep its last picture until the window is shown again.
        var requiresVisibleWindow = true
        #if AIRC_TESTING
        if ProcessInfo.processInfo.environment["AIRC_PREVIEW_BASELINE"] == "1" { requiresVisibleWindow = false }
        #endif
        guard !requiresVisibleWindow || (c.window.isVisible && !c.window.isMiniaturized) else {
            completion?(nil)
            return
        }
        let url = page.url?.absoluteString ?? c.store.tab(tabID)?.url ?? ""
        guard !url.isEmpty, !URLRules.isNewTab(url) else { completion?(nil); return }
        if pending[tabID] != nil {
            if let completion { pending[tabID]?.append(completion) }
            return
        }
        pending[tabID] = completion.map { [$0] } ?? []
        let itemID = c.store.tab(tabID)?.itemID
        #if AIRC_TESTING
        let t0 = CACurrentMediaTime()
        stats.requests[reason.rawValue, default: 0] += 1
        #endif
        source.previewSnapshot(maxPixels: TabPreviewCache.maxPixels) { [weak self] image in
            guard let self else { return }
            #if AIRC_TESTING
            self.stats.results.append((reason.rawValue, image != nil, CACurrentMediaTime() - t0))
            #endif
            if let image, self.isEnabled { TabPreviewCache.shared.store(image, url: url, tab: tabID, item: itemID) }
            let waiting = self.pending.removeValue(forKey: tabID) ?? []
            waiting.forEach { $0(image) }
        }
    }

    // MARK: Checks

    #if AIRC_TESTING
    struct Stats {
        var enters = 0
        var shows = 0
        var dwellTimers = 0
        var requests: [String: Int] = [:]
        var results: [(reason: String, ok: Bool, seconds: Double)] = []
        var hoverCost: [Double] = []
        var showCost: [Double] = []
        var actions: [String] = []
        var lastEnterAt: CFTimeInterval = 0
        var lastShownAt: CFTimeInterval = 0
        var lastPresentSprang = false
    }
    var stats = Stats()
    static var reduceMotionOverride: Bool?
    #endif
}
