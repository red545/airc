// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// The URL field (SB-2): host only, 36 pt, radius 12. Click opens the Command Bar over it.
final class URLFieldView: NSView {
    weak var controller: WindowController?
    /// The host, or "Search or enter URL…" with no page; fades instead of "…" (visual review #17).
    private let label = AircAddressFieldLabel(theme: DesignTheme.default.resolved(systemIsDark: false))
    private let copyButton = GlyphButton(symbol: "link", size: 12)
    private let siteButton = GlyphButton(symbol: "slider.horizontal.3", size: 12)
    /// ⌘E's list (engine/PASS7.md: the puzzle menu), shown on hover (with no extensions yet it leads to the Web Store).
    private let puzzleButton = GlyphButton(symbol: "puzzlepiece.extension", size: 12)
    /// Pinned extension actions with their badges, shown on hover.
    private var extensionButtons: [ExtensionButton] = []
    /// Camera, microphone, screen, location, blocked pop-up and site-settings icons (SiteControls/SiteIndicators.swift).
    let siteIndicators = SiteIndicatorsView()
    private let progress = CALayer()
    private var palette: Palette?
    var sidebarHovered = false {
        didSet {
            guard sidebarHovered != oldValue else { return }
            // Requeried each time the buttons are about to show; nothing polls.
            if sidebarHovered { controller?.refreshExtensionButtons() }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = AircRadius.row
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(label)
        addSubview(copyButton)
        addSubview(siteButton)
        addSubview(puzzleButton)
        addSubview(siteIndicators)
        puzzleButton.toolTip = "Extensions ⌘E"
        puzzleButton.action = { [weak self] in self?.controller?.showExtensions() }
        layer?.addSublayer(progress)
        copyButton.toolTip = "Copy URL"
        siteButton.toolTip = "Site Controls"
        copyButton.action = { [weak self] in self?.controller?.copyURL() }
        siteButton.action = { [weak self] in self?.controller?.toggleSiteControls() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(host: String, loading: Double?, palette: Palette) {
        self.palette = palette
        layer?.backgroundColor = palette.urlFieldFill.cgColor
        label.theme = palette.resolved
        label.host = host.isEmpty ? nil : host
        copyButton.tint = palette.glyph
        siteButton.tint = palette.glyph
        puzzleButton.tint = palette.glyph
        puzzleButton.hoverFill = palette.hover
        extensionButtons.forEach { $0.hoverFill = palette.hover }
        copyButton.hoverFill = palette.hover
        siteButton.hoverFill = palette.hover
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
        siteIndicators.refresh(palette: palette)
    }

    override func layout() {
        super.layout()
        let b = AircMetrics.Sidebar.urlFieldButton
        let showButtons = sidebarHovered && !label.showsPlaceholder
        copyButton.isHidden = !showButtons
        siteButton.isHidden = !showButtons
        siteButton.frame = NSRect(x: bounds.width - 3 - b, y: (bounds.height - b) / 2, width: b, height: b)
        copyButton.frame = siteButton.frame.offsetBy(dx: -b, dy: 0)
        // Site Controls' icons: left of the buttons, or at the field's end while they're hidden.
        let indicatorsMinX = siteIndicators.place(endingAt: showButtons ? copyButton.frame.minX : bounds.width - 3, hovered: showButtons)
        // Extensions to the left of copy: the puzzle, then the pinned actions (Chrome's order, right to left).
        // The puzzle shows on hover even with no extensions yet: its list is the way to the Web Store.
        var minX = showButtons ? indicatorsMinX : copyButton.frame.minX
        puzzleButton.isHidden = !showButtons
        if !puzzleButton.isHidden {
            puzzleButton.frame = NSRect(x: minX - b, y: (bounds.height - b) / 2, width: b, height: b)
            minX = puzzleButton.frame.minX
        }
        for e in extensionButtons.reversed() {
            // At least 72 pt of the host stays readable; pins beyond that are in ⌘E's list.
            e.isHidden = !showButtons || minX - b < 72
            guard !e.isHidden else { continue }
            e.frame = NSRect(x: minX - b, y: (bounds.height - b) / 2, width: b, height: b)
            minX = e.frame.minX
        }
        label.frame = AircAddressFieldLabel.frame(inField: bounds, trailingControlMinX: showButtons ? minX
                                                  : siteIndicators.isEmpty ? nil : indicatorsMinX)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.openCommandBar(mode: .editURL)
    }

    /// The pinned actions to draw (already filtered to enabled ones).
    func setExtensions(_ actions: [ExtensionAction]) {
        if extensionButtons.map(\.id) != actions.map(\.id) {
            extensionButtons.forEach { $0.removeFromSuperview() }
            extensionButtons = actions.map { a in
                let v = ExtensionButton(id: a.id)
                v.action = { [weak self] button in
                    self?.controller?.runExtension(button.id, anchor: button, rect: button.bounds)
                }
                addSubview(v)
                return v
            }
        }
        if let palette { zip(extensionButtons, actions).forEach { $0.configure($1, palette: palette) } }
        // Greyed out where the extension can't run (Chrome does the same), still there to click.
        zip(extensionButtons, actions).forEach { $0.alphaValue = $1.isActive ? 1 : 0.4 }
        needsLayout = true
    }

    /// Where an action's popup anchors: its pinned button, else the field's trailing end.
    func extensionAnchor(for id: String) -> NSRect {
        if let b = extensionButtons.first(where: { $0.id == id && !$0.isHidden }) { return b.frame }
        return NSRect(x: bounds.width - 40, y: 0, width: 36, height: bounds.height)
    }
}

/// One Favorites tile (SB-11/12/13): 47 pt tall, radius 10, unread dot.
final class FavoriteTileView: SidebarRowView {
    private(set) var item: Item?
    private let favicon = FaviconView()
    private let dot = CALayer()
    private let tile = CALayer()
    /// SV-2: a Favorite split's face (FavoriteSplitTile.swift), over the tile it cuts along its axis.
    private(set) var splitFace: FavoriteSplitFace?
    /// Live Calendar's countdown on a Calendar Favorite (Calendar/CalendarViews.swift).
    private(set) var calendarFace: CalendarTileFace?
    /// The favicon's alpha as drawn (SB-15: half strength while the page is unloaded).
    var iconAlpha: CGFloat { favicon.alphaValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        showsPlate = false
        tile.cornerRadius = AircMetrics.Favorites.radius
        tile.cornerCurve = .continuous
        layer?.insertSublayer(tile, at: 0)
        dot.backgroundColor = AircColor.unreadDot.nsColor.cgColor
        dot.cornerRadius = AircMetrics.Favorites.unreadDot / 2
        layer?.addSublayer(dot)
        addSubview(favicon)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Item, tab: LiveTab?, palette: Palette, selected: Bool) {
        self.item = item
        self.palette = palette
        favicon.isHidden = item.kind == .split
        calendarFace = CalendarTileFace.isCalendar(item) ? calendarFace ?? CalendarTileFace(tile: self) : nil
        if item.kind == .split {
            if splitFace == nil { splitFace = FavoriteSplitFace(tile: tile, in: self) }
            splitFace?.configure(item, controller: controller, palette: palette)
            dot.isHidden = true
            toolTip = splitFace?.title
            isSelected = selected
            updateStyle()
            return
        }
        splitFace?.remove()
        splitFace = nil
        let engineTab = tab.flatMap { controller?.engineTab(for: $0.id) }
        let saved = item.savedURL ?? ""
        var iconURL = tab?.faviconURL ?? item.faviconURL
        if URLRules.isCalendar(saved) {
            iconURL = URLRules.calendarIconURL(day: Calendar.current.component(.day, from: Date()))
        }
        favicon.set(image: URLRules.isCalendar(saved) ? nil : engineTab?.favicon, url: iconURL, fallbackPage: saved,
                    palette: palette)
        // SB-15: a Favorite whose page is freed (or not loaded yet) draws as an unloaded row does (design §Sidebar row).
        favicon.alphaValue = controller?.isPageUnloaded(tab?.id) != false ? 0.5 : 1
        let title = engineTab?.title ?? tab?.title ?? item.pageTitle ?? ""
        dot.isHidden = !(URLRules.showsUnreadBadge(saved) && (URLRules.unreadCount(fromTitle: title) ?? 0) > 0)
        toolTip = item.displayTitle
        isSelected = selected
        calendarFace?.configure(palette: palette)
        updateStyle()
    }

    override func updateStyle() {
        guard let palette else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            tile.backgroundColor = (isHovered ? palette.selectedHover : palette.selected).cgColor
            tile.apply(palette.selectedShadow ?? .none)
        } else {
            tile.backgroundColor = (isHovered ? palette.tileHover : palette.tileFill).cgColor
            tile.shadowOpacity = 0
        }
        splitFace?.applyStyle(of: tile)
        CATransaction.commit()
    }

    override func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = bounds
        // Visual review #18: 6 pt, centred 11 pt from the right and 10 pt from the bottom.
        let d = AircMetrics.Favorites.unreadDot, o = AircMetrics.Favorites.unreadDotOffset
        dot.frame = NSRect(x: bounds.width - o.x - d / 2, y: bounds.height - o.y - d / 2, width: d, height: d)
        CATransaction.commit()
        let s = AircMetrics.Favorites.favicon
        favicon.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
        calendarFace?.layout(in: bounds, favicon: favicon)
        splitFace?.layout(in: bounds)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        calendarFace?.hover(true)
        controller?.tabPreview.hoverBegan(self, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        calendarFace?.hover(false)
        controller?.tabPreview.hoverEnded(self, event: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        if calendarFace != nil { CalendarCard.shared.hide() }
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = 0.97
        a.duration = AircCurve.press.duration
        a.autoreverses = true
        tile.add(a, forKey: "press")
        let entry = SidebarEntry.favorite(item, controller?.store.liveTab(forItem: item.id))
        controller?.activate(entry: entry)
        page?.beginPossibleDrag(entry: entry, row: self, event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        return controller?.menu(for: .favorite(item, controller?.store.liveTab(forItem: item.id)))
    }

    override var dragTitle: String { splitFace?.title ?? item?.displayTitle ?? "" }
    override var dragFavicon: CGImage? { splitFace?.firstIcon ?? favicon.cgImage }
}

/// SP-15 (Arc's ProfileIndicatorView; design mockup profiles.html §7): which profile this Space uses, shown while
/// two or more profiles have Spaces. At rest the avatar and name in caption ink; with the pointer on the header a
/// pill of the avatar and a chevron that opens Set Profile ›. A long Space name condenses it to the avatar first.
final class ProfileIndicatorView: NSView {
    private let avatar = CALayer()
    private let name = AircFadingLabel(frame: .zero)
    private let chevron = CALayer()
    private let pill = CALayer()
    private var avatarImage: NSImage?
    var onClick: (() -> Void)?
    /// Avatar (and chevron) only.
    var condensed = false { didSet { if condensed != oldValue { needsLayout = true } } }
    var hovered = false { didSet { if hovered != oldValue { update() } } }
    private var palette: Palette?

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.fadeWidth = 12
        wantsLayer = true
        pill.cornerRadius = 11
        pill.actions = LayerImage.noActions
        layer?.addSublayer(pill)
        name.font = AircFont.caption.appFont
        name.lineBreakMode = .byClipping
        for l in [avatar, chevron] {
            l.contentsGravity = .center
            l.actions = LayerImage.noActions
            layer?.addSublayer(l)
        }
        addSubview(name)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(profile: Profile, palette: Palette) {
        self.palette = palette
        let img = ProfileAvatarImage.image(profile, size: 16)
        if img !== avatarImage {
            avatarImage = img
            LayerImage.set(img, on: avatar, in: self)
        }
        if name.stringValue != profile.name { name.stringValue = profile.name }
        let tip = "This Space uses the “\(profile.name)” Profile" + (profile.googleAccount.map { " (\($0))" } ?? "")
        if toolTip != tip { toolTip = tip }
        update()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard LayerImage.scaleChanged(avatar, in: self) || LayerImage.scaleChanged(chevron, in: self) else { return }
        if let avatarImage { LayerImage.set(avatarImage, on: avatar, in: self) }
        update()
    }

    private func update() {
        guard let palette else { return }
        if name.textColor != palette.textMuted { name.textColor = palette.textMuted }
        LayerImage.set(LayerImage.symbol("chevron.down", size: 8, weight: .bold, color: palette.textSecondary), on: chevron, in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.backgroundColor = hovered ? palette.tileFill.cgColor : nil
        CATransaction.commit()
        needsLayout = true
    }

    /// The width it wants: avatar + name at rest, avatar + chevron in the hover pill (or when condensed).
    var fullWidth: CGFloat { 16 + 5 + ceil(name.attributedStringValue.size().width) + 2 }
    var compactWidth: CGFloat { hovered ? 16 + 4 + 8 + 12 : 16 }
    var preferredWidth: CGFloat { hovered || condensed ? compactWidth : fullWidth }

    override func layout() {
        super.layout()
        let h = bounds.height
        let showsName = !(hovered || condensed)
        name.isHidden = !showsName
        let x0: CGFloat = hovered ? 4 : 0
        if showsName {
            name.sizeToFit()
            name.frame = NSRect(x: 21, y: (h - name.frame.height) / 2, width: max(0, bounds.width - 21), height: name.frame.height)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.isHidden = !hovered
        avatar.frame = NSRect(x: x0, y: (h - 16) / 2, width: 16, height: 16)
        chevron.frame = NSRect(x: 24, y: (h - 10) / 2, width: 10, height: 10)
        pill.frame = NSRect(x: 0, y: (h - 22) / 2, width: bounds.width, height: 22)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The Space name row (SB-20, SB-22): icon + name and, with several profiles in use, the profile indicator (SP-15);
/// hover shows •••, a chevron and the indicator's pill.
final class SpaceHeaderView: SidebarRowView {
    var spaceID = ""
    private let icon = NSTextField(labelWithString: "")
    private let chevron = CALayer()
    private let name = AircFadingLabel(frame: .zero)
    /// Made once two or more profiles have Spaces (most people have one).
    private var indicator: ProfileIndicatorView?
    private let more = GlyphButton(symbol: "ellipsis", size: 13)
    private var chevronKey = ""
    private var hasIcon = true
    private var collapsed = false
    private var showsProfile = false
    private var profileID = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.font = NSFont.systemFont(ofSize: AircMetrics.Footer.spaceEmoji)
        icon.alignment = .center
        name.font = AircFont.spaceName.appFont
        name.lineBreakMode = .byClipping
        chevron.contentsGravity = .center
        chevron.actions = LayerImage.noActions
        layer?.addSublayer(chevron)
        for v in [icon, name, more] as [NSView] { addSubview(v) }
        more.toolTip = "Space options"
        more.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.controller?.spaceMenu(spaceID: self.spaceID)
        }
    }

    private func makeIndicator() -> ProfileIndicatorView {
        if let indicator { return indicator }
        let v = ProfileIndicatorView()
        v.onClick = { [weak self] in self?.showSetProfileMenu() }
        addSubview(v)
        indicator = v
        return v
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `showsProfile`: two or more profiles have Spaces (Arc: hasMultipleProfilesInUse).
    func configure(space: Space, profile: Profile, showsProfile: Bool, palette: Palette) {
        spaceID = space.id
        profileID = profile.id
        self.palette = palette
        self.showsProfile = showsProfile
        collapsed = space.pinnedCollapsed
        switch space.icon {
        case .emoji(let e)?:
            if icon.stringValue != e { icon.stringValue = e }
            hasIcon = true
        case .symbol(let s)?:
            icon.stringValue = ""
            hasIcon = true
            let attachment = NSTextAttachment()
            attachment.image = Symbols.image(s, size: 14)
            icon.attributedStringValue = NSAttributedString(attachment: attachment)
        case nil:
            hasIcon = false
        }
        let title = TextLimits.clip(space.name)
        if name.stringValue != title { name.stringValue = title }
        if name.textColor != palette.spaceName { name.textColor = palette.spaceName }
        if showsProfile { makeIndicator() }
        indicator?.configure(profile: profile, palette: palette)
        more.tint = palette.glyph
        more.hoverFill = palette.hover
        updateStyle()
        needsLayout = true
    }

    override func updateStyle() {
        super.updateStyle()
        more.isHidden = !isHovered
        indicator?.isHidden = !showsProfile
        indicator?.hovered = isHovered
        icon.isHidden = isHovered || !hasIcon
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.isHidden = !isHovered
        CATransaction.commit()
        guard let palette else { return }
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        let key = symbol + palette.textSecondary.description
        if key != chevronKey {
            chevronKey = key
            LayerImage.set(LayerImage.symbol(symbol, size: 11, weight: .semibold, color: palette.textSecondary), on: chevron, in: self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard LayerImage.scaleChanged(chevron, in: self) else { return }
        chevronKey = ""
        updateStyle()
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: AircMetrics.SpaceHeader.iconCenterX - 13, y: (h - 20) / 2, width: 26, height: 20)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.frame = NSRect(x: AircMetrics.SpaceHeader.iconCenterX - 10, y: (h - 20) / 2, width: 20, height: 20)
        CATransaction.commit()
        let x = ((hasIcon || isHovered) ? AircMetrics.SpaceHeader.nameX : AircMetrics.SpaceHeader.nameXWithoutIcon) - DesignGaps.labelInset
        let m = AircMetrics.SpaceHeader.moreButton
        more.frame = NSRect(x: bounds.width - AircMetrics.Sidebar.inset - 6 - m, y: (h - m) / 2, width: m, height: m)
        var right = isHovered ? more.frame.minX - 4 : bounds.width - 17
        if showsProfile, let indicator {
            // The indicator condenses before the name loses room; then the name fades out 20 pt before it.
            name.sizeToFit()
            let nameWidth = ceil(name.frame.width)
            indicator.condensed = x + nameWidth + 24 + indicator.fullWidth > right
            let w = min(indicator.preferredWidth, max(16, (right - x) * 0.5))
            indicator.frame = NSRect(x: right - w, y: (h - 22) / 2, width: w, height: 22)
            right = indicator.frame.minX - 4
        }
        name.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, right - x), height: 18)
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); needsLayout = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); needsLayout = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.beginRenameSpace(spaceID, in: self, titleFrame: name.frame)
            return
        }
        controller?.togglePinnedCollapsed(spaceID)
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.spaceMenu(spaceID: spaceID) }

    /// The indicator opens the Space menu's Set Profile › (never a manager: rename and delete live in Settings).
    private func showSetProfileMenu() {
        guard let indicator, let menu = controller?.setProfileMenu(spaceID: spaceID, current: profileID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: indicator.frame.minX, y: indicator.frame.maxY + 4), in: self)
    }
}

/// The tab list scrolls vertically; a mostly horizontal gesture belongs to the Space pager.
final class SidebarScrollView: NSScrollView {
    weak var pager: SpacePagerView?
    private var routeToPager = false

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || (event.phase == [] && event.momentumPhase == []) {
            routeToPager = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && event.hasPreciseScrollingDeltas
        }
        if routeToPager, let pager {
            pager.scrollWheel(with: event)
        } else if event.momentumPhase != [] && routeToPager {
            return
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// One Space's sidebar page: URL field, Favorites, Space name, then the scrolling list of pinned
/// rows, the divider, "+ New Tab" and Today. Pages slide horizontally when switching Spaces.
final class SpacePageView: NSView {
    private(set) var spaceID: String
    weak var controller: WindowController?
    /// The tab the last reload drew as this page's shown tab (selection, URL field).
    private(set) var drawnShownTabID: String?
    private(set) var palette: Palette
    let urlField = URLFieldView()
    let favorites = FlippedView()
    let header = SpaceHeaderView()
    let scrollView = SidebarScrollView()
    let list = FlippedView()
    private(set) var rows: [String: SidebarRowView] = [:]
    private var order: [(id: String, entry: RowModel)] = []
    /// SB-36: rows picked with ⌘/⇧-click, in display order (entry IDs), apart from the page being shown.
    private(set) var selection: [String] = []
    private var selectionAnchor: String?
    private var tiles: [String: FavoriteTileView] = [:]
    private var favoritesHeight: CGFloat = 0
    private let dropLine = CALayer()
    private let dropRing = CALayer()
    private var highlightedFolder: SidebarRowView?
    var sidebarHovered = false {
        didSet {
            urlField.sidebarHovered = sidebarHovered
            (rows["divider"] as? DividerRowView)?.sidebarHovered = sidebarHovered
            rows["divider"]?.needsLayout = true
        }
    }

    enum RowModel {
        case entry(SidebarEntry), divider, newTab, signIn, defaultBrowser
    }

    /// A spare page made at idle becomes a new Space's page (§2.12: New Space within one frame).
    func claim(spaceID: String, palette: Palette) {
        self.spaceID = spaceID
        self.palette = palette
    }

    init(spaceID: String, palette: Palette, controller: WindowController) {
        self.spaceID = spaceID
        self.palette = palette
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        urlField.controller = controller
        header.controller = controller
        header.page = self
        addSubview(urlField)
        addSubview(favorites)
        addSubview(header)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = list
        addSubview(scrollView)
        for l in [dropLine, dropRing] {
            l.isHidden = true
            l.zPosition = 100
            layer?.addSublayer(l)
        }
        dropLine.cornerRadius = 1
        dropRing.cornerRadius = AircSpacing.s / 2
        dropRing.borderWidth = 2
        dropRing.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Reload

    func reload(animated: Bool) {
        guard let c = controller, let space = c.store.space(spaceID) else { return }
        render(space, animated: animated)
    }

    /// The profile and theme `prerender` drew this (spare) page for.
    private(set) var prerendered: (profileID: String, theme: AircKit.SpaceTheme)?

    /// Speed pass (New Space ≤ 1 frame): the spare page drawn ahead as the Space the New Space card would create, so
    /// Create only has to set the header's name and icon (`refreshHeader`).
    func prerender(_ space: Space) {
        render(space, animated: false)
        prerendered = (space.profileID, space.theme)
    }

    /// The New Space card's name or icon changed: the prerendered header follows (the rest stays as drawn).
    func prerenderHeader(_ space: Space) {
        guard let c = controller else { return }
        var profilesInUse = Set(c.store.state.spaces.values.map(\.profileID))
        profilesInUse.insert(space.profileID)
        header.configure(space: space, profile: c.store.profile(space.profileID) ?? c.store.defaultProfile,
                         showsProfile: profilesInUse.count > 1, palette: palette)
    }

    /// After `claim`: the header is the only part that differs from what `prerender` drew.
    func refreshHeader() {
        guard let c = controller, let space = c.store.space(spaceID) else { return }
        prerendered = nil
        header.configure(space: space, profile: c.store.profile(ofSpace: spaceID),
                         showsProfile: Set(c.store.state.spaces.values.map(\.profileID)).count > 1, palette: palette)
    }

    private func render(_ space: Space, animated: Bool) {
        guard let c = controller else { return }
        let store = c.store
        palette = c.palette(for: space)
        let profile = store.profile(space.profileID) ?? store.defaultProfile
        let shownTab = c.displayedTabID(forSpace: spaceID)
        drawnShownTabID = shownTab
        // SV-1: while a split is on screen its row is the selected one (its tabs' own rows, a pinned tab's or a
        // Favorite's, aren't).
        let shownSplit = store.split(containing: shownTab)

        // URL field shows the page this Space shows.
        let shown = store.tab(shownTab)
        let engineTab = shown.flatMap { c.engineTab(for: $0.id) }
        let urlString = engineTab?.url?.absoluteString ?? shown?.url ?? ""
        urlField.configure(host: URLRules.displayHost(urlString),
                           loading: engineTab.map { $0.isLoading ? $0.progress : 1 }, palette: palette)
        header.configure(space: space, profile: profile, showsProfile: Set(store.state.spaces.values.map(\.profileID)).count > 1,
                         palette: palette)

        // Favorites grid.
        let favs = store.favorites(ofProfile: profile.id)
        let width = bounds.width - 2 * AircMetrics.Sidebar.inset
        let layout = FavoritesGrid.layout(count: favs.count, width: Double(max(width, 60)))
        favoritesHeight = CGFloat(layout.height)
        var seenTiles = Set<String>()
        for (i, f) in favs.enumerated() {
            seenTiles.insert(f.id)
            let tile = tiles[f.id] ?? {
                let t = FavoriteTileView()
                t.controller = c
                t.page = self
                favorites.addSubview(t)
                tiles[f.id] = t
                return t
            }()
            let live = f.kind == .split ? store.liveTab(forSplitItem: f.id) : store.liveTab(forItem: f.id)
            tile.configure(f, tab: live, palette: palette,
                           selected: f.kind == .split ? shownSplit?.id == f.id : live != nil && live?.id == shownTab && shownSplit == nil)
            let r = FavoritesGrid.frame(index: i, layout: layout)
            let frame = NSRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.w), height: CGFloat(r.h))
            tile.setFrameAnimated(frame, animated: animated && tile.frame != .zero, spring: Spring(AircSpring.fold))
        }
        for (id, t) in tiles where !seenTiles.contains(id) {
            t.removeFromSuperview()
            tiles[id] = nil
        }
        favoritesHeight += CalendarPromptView.place(in: favorites, below: favoritesHeight, width: width, favorites: favs,
                                                    spaceID: spaceID, palette: palette, controller: c)

        // The list.
        var models: [(String, RowModel)] = []
        if !space.pinnedCollapsed {
            models += store.pinnedRows(ofSpace: spaceID).map { ($0.id, .entry($0)) }
        }
        let today = store.todayRows(ofSpace: spaceID)
        models.append(("divider", .divider))
        models.append(("newtab", .newTab))
        if c.showsSignInCard(space: space) { models.append(("signin", .signIn)) }
        if c.showsDefaultBrowserCard { models.append(("defaultbrowser", .defaultBrowser)) }
        models += today.map { ($0.id, .entry($0)) }
        order = models.map { (id: $0.0, entry: $0.1) }

        var y: CGFloat = 0
        var seen = Set<String>()
        let w = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : bounds.width
        for (id, model) in models {
            seen.insert(id)
            let isNew = rows[id] == nil
            let view: SidebarRowView
            let height: CGFloat
            switch model {
            case .entry(let e):
                switch e {
                case .folder(let item, let depth):
                    let v = (rows[id] as? FolderRowView) ?? FolderRowView()
                    v.controller = c
                    v.configure(item, depth: depth, palette: palette)
                    view = v
                case .split(let x, _):
                    let v = (rows[id] as? SplitRowView) ?? SplitRowView()
                    v.controller = c
                    v.configure(e, palette: palette, selected: shownSplit?.id == x.id, focusedTabID: shownTab)
                    view = v
                case .pinned(let item, let depth, _) where item.kind == .split:
                    // SV-2: a pinned split is one row, like a Today split's.
                    let v = (rows[id] as? SplitRowView) ?? SplitRowView()
                    v.controller = c
                    v.configure(splitItem: item, depth: depth, palette: palette, selected: shownSplit?.id == item.id, focusedTabID: shownTab)
                    view = v
                default:
                    let v = (rows[id] as? TabRowView) ?? c.tabRowPool.take()
                    v.controller = c
                    v.configure(e, palette: palette, selected: e.liveTab != nil && e.liveTab?.id == shownTab && shownSplit == nil)
                    view = v
                }
                height = AircMetrics.Row.pitch
            case .divider:
                let v = (rows[id] as? DividerRowView) ?? DividerRowView()
                v.controller = c
                v.configure(spaceID: spaceID, palette: palette)
                v.sidebarHovered = sidebarHovered
                view = v
                height = DesignGaps.dividerBlock
                if y > 0 { y += 6 }
            case .newTab:
                let v = (rows[id] as? NewTabRowView) ?? NewTabRowView()
                v.controller = c
                v.configure(palette: palette, active: c.isCommandBarOpen(mode: .newTab) && spaceID == c.currentSpaceID)
                view = v
                height = AircMetrics.Row.pitch
                y -= (DesignGaps.dividerBlock - 7) - (AircMetrics.Divider.aboveFirstRow - AircMetrics.Row.height / 2)
            case .signIn:
                let v = (rows[id] as? SignInCardView) ?? SignInCardView()
                v.controller = c
                v.configure(spaceID: spaceID, palette: palette)
                view = v
                height = AircMetrics.Profile.signInCardHeight
            case .defaultBrowser:
                let v = (rows[id] as? DefaultBrowserCardView) ?? DefaultBrowserCardView()
                v.controller = c
                v.configure(palette: palette)
                view = v
                height = DefaultBrowserCardView.height(width: w, theme: palette.resolved)
            }
            view.page = self
            view.isInSelection = selection.contains(id)
            if view.superview !== list { list.addSubview(view) }
            rows[id] = view
            let frame = NSRect(x: 0, y: y, width: w, height: model.isEntry ? AircMetrics.Row.height : height)
            if isNew {
                view.frame = frame
                if animated { view.layer?.fade(from: 0, to: 1, duration: 0.12) }
            } else {
                view.setFrameAnimated(frame, animated: animated)
            }
            y += height
        }
        for (id, v) in rows where !seen.contains(id) {
            rows[id] = nil
            if animated {
                v.layer?.fade(from: 1, to: 0, duration: 0.1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak c] in
                    // Unless a reload took it back meanwhile.
                    guard v.page?.rows[id] !== v else { return }
                    v.removeFromSuperview()
                    if let r = v as? TabRowView { c?.tabRowPool.give(r) }
                }
            } else {
                v.removeFromSuperview()
                if let r = v as? TabRowView { c.tabRowPool.give(r) }
            }
        }
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(y + 12, scrollView.contentSize.height))
        needsLayout = true
    }

    /// Engine state of one tab changed (title, favicon, loading): refresh just its row or tile.
    /// The "+ New Tab" row lights up while ⌘T's Command Bar is open (no rebuild of the page).
    func refreshNewTabRow() {
        guard let c = controller else { return }
        let active = c.isCommandBarOpen(mode: .newTab) && spaceID == c.currentSpaceID
        for case let v as NewTabRowView in rows.values { v.configure(palette: palette, active: active) }
    }

    func refreshTab(_ tabID: String) {
        guard let c = controller else { return }
        let shown = c.displayedTabID(forSpace: spaceID)
        let shownSplit = c.store.split(containing: shown)
        for (_, v) in rows {
            if let r = v as? TabRowView, r.tabID == tabID, let tab = c.store.tab(tabID) {
                let entry: SidebarEntry
                if let item = c.store.item(tab.itemID) {
                    entry = .pinned(item, depth: r.depth, tab)
                } else {
                    entry = .today(tab)
                }
                r.configure(entry, palette: palette, selected: tabID == shown && shownSplit == nil)
            }
            if let r = v as? SplitRowView, r.splitItem != nil {
                r.refreshPane(tabID, palette: palette, selected: shownSplit.map { $0.id == r.splitItem?.id } ?? false, focusedTabID: shown)
            }
            if let r = v as? SplitRowView, let x = r.split.flatMap({ c.store.split($0.id) }), x.tabIDs.contains(tabID) {
                r.configure(.split(x, c.store.members(of: x)), palette: palette, selected: shownSplit?.id == x.id, focusedTabID: shown)
            }
        }
        for (_, t) in tiles {
            if let item = t.item, item.kind == .split, c.store.tab(tabID).flatMap({ c.store.splitItem(ofPane: $0.itemID) })?.id == item.id {
                t.configure(item, tab: nil, palette: palette, selected: shownSplit?.id == item.id)
            }
            if let item = t.item, let live = c.store.liveTab(forItem: item.id), live.id == tabID {
                t.configure(item, tab: live, palette: palette, selected: tabID == shown && shownSplit == nil)
            }
        }
        if tabID == c.displayedTabID(forSpace: spaceID) {
            let engineTab = c.engineTab(for: tabID)
            let url = engineTab?.url?.absoluteString ?? c.store.tab(tabID)?.url ?? ""
            urlField.configure(host: URLRules.displayHost(url),
                               loading: engineTab.map { $0.isLoading ? $0.progress : 1 }, palette: palette)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        urlField.frame = NSRect(x: AircMetrics.Sidebar.inset, y: 0, width: w - 2 * AircMetrics.Sidebar.inset, height: AircMetrics.Sidebar.urlFieldHeight)
        var y = DesignGaps.favoritesTop
        if favoritesHeight > 0 {
            favorites.frame = NSRect(x: AircMetrics.Sidebar.inset, y: y, width: w - 2 * AircMetrics.Sidebar.inset, height: favoritesHeight)
            y += favoritesHeight + 6
        } else {
            favorites.frame = NSRect(x: AircMetrics.Sidebar.inset, y: y, width: w - 2 * AircMetrics.Sidebar.inset, height: 0)
        }
        header.frame = NSRect(x: 0, y: y, width: w, height: AircMetrics.Row.height)
        y += AircMetrics.Row.height + 1
        scrollView.frame = NSRect(x: 0, y: y, width: w, height: max(0, bounds.height - y))
        if list.frame.width != scrollView.contentSize.width {
            list.frame.size.width = scrollView.contentSize.width
            for v in list.subviews { v.frame.size.width = scrollView.contentSize.width }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { reload(animated: false) }
    }

    // MARK: Hover over the empty list: double-click opens a new tab; right-click the Space menu.

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { controller?.openCommandBar(mode: .newTab) } else { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { controller?.spaceMenu(spaceID: spaceID) }

    // MARK: Multi-selection (SB-36)

    private var selectableIDs: [String] {
        order.compactMap { m in if case .entry = m.entry { return m.id } else { return nil } }
    }

    /// ⌘-click toggles `id`; ⇧-click (`extending`) selects from the anchor to `id`. The first pick also takes the row
    /// of the page you're on, as Arc does.
    func select(_ id: String, extending: Bool) {
        let ids = selectableIDs
        var set = Set(selection)
        if set.isEmpty, let shown = controller?.displayedTabID(forSpace: spaceID),
           let shownID = order.first(where: { m in if case .entry(let e) = m.entry { return e.shows(shown) } else { return false } })?.id {
            set.insert(shownID)
            selectionAnchor = shownID
        }
        if extending, let anchor = selectionAnchor ?? set.first, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            set.formUnion(ids[min(a, b)...max(a, b)])
        } else if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
            selectionAnchor = id
        }
        applySelection(ids.filter { set.contains($0) })
    }

    func clearSelection() {
        guard !selection.isEmpty else { return }
        selectionAnchor = nil
        applySelection([])
    }

    private func applySelection(_ ids: [String]) {
        selection = ids
        for (id, v) in rows { v.isInSelection = ids.contains(id) }
    }

    // MARK: Drag and drop inside the sidebar (SB-35)

    /// Arc (SB-35): holding a drag 0.5 s at the sidebar's left or right edge pages into the neighbouring Space, where
    /// the drop then lands; ⌥ held at the drop puts a copy there instead of moving.
    static let edgeDwell: CFTimeInterval = 0.5
    static let edgeWidth: CGFloat = 14

    /// The Space a drag at `x` (root coordinates) pages to after the dwell: -1 the previous, 1 the next, 0 none.
    static func edgeSide(at x: CGFloat, sidebar visible: NSRect, onRight: Bool) -> Int {
        let x = x - visible.minX, width = visible.width, ew = edgeWidth
        if onRight { return x > width - ew ? 1 : (x < ew && x > -2 * ew) ? -1 : 0 }
        return x < ew ? -1 : (x > width - ew && x < width + 2 * ew) ? 1 : 0
    }

    /// `shownBefore`: the tab on screen before the press showed this one; a drag over the page brings it back, and the
    /// drop splits it with the dragged tab (SV-1).
    func beginPossibleDrag(entry: SidebarEntry, row: SidebarRowView, event: NSEvent, shownBefore: String? = nil) {
        guard let window, let c = controller else { return }
        let start = convert(event.locationInWindow, from: nil)
        var dragging = false
        var ghost: CALayer?
        // The ghost floats over the whole window in its own top-most view, so it is above every row on screen and in
        // captures (a sublayer of the paged sidebar was drawn under the rows and offset by `render(in:)`).
        var overlay: NSView?
        var grabOffset = CGPoint.zero
        var destination: DropDestination?
        /// SV-1: over the page instead (Arc 101: drag a tab into the middle of the screen for a Split View).
        var pageZone: SplitDropZone?
        var showedUnder = false
        // The page the pointer is over: this one, or a neighbour after edge paging.
        var target: SpacePageView = self
        var edge: (side: Int, since: CFTimeInterval)?
        var copying = NSEvent.modifierFlags.contains(.option)
        let source: DragSource
        switch entry {
        case .today(let t): source = .tab(t.id)
        case .split(let x, _): source = .split(x.id)
        default: source = .item(entry.item!.id)
        }
        // SB-36: a row of a multi-selection carries the whole selection, in display order.
        let group: [String] = selection.count > 1 && selection.contains(entry.id) ? selection : [entry.id]
        let sources: [DragSource] = group.count > 1 ? group.compactMap { id in
            if c.store.item(id) != nil { return .item(id) }
            if c.store.split(id) != nil { return .split(id) }
            return c.store.tab(id) != nil ? .tab(id) : nil
        } : [source]
        let groupHasFolder = sources.contains { s in
            if case .item(let id) = s { return c.store.item(id)?.kind == .folder }
            return false
        }
        let groupRows = group.compactMap { rows[$0] }
        // SB-35: past the window's edge, the drag can leave it (Sidebar/TabDragOut.swift).
        let out = TabDragOut(controller: c, source: source, entry: entry, group: sources.count, pressInWindow: event.locationInWindow,
                             shownBefore: shownBefore)
        var lastPoint = event.locationInWindow
        var cancelled = false
        func setCursor() { (copying ? NSCursor.dragCopy : NSCursor.arrow).set() }
        c.dragsInProgress += 1
        defer { c.dragsInProgress -= 1 }
        tracking: while true {
            // Polls every 50 ms, so a pointer resting at the edge still pages.
            let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged],
                                     until: Date().addingTimeInterval(0.05), inMode: .eventTracking, dequeue: true)
            switch e?.type {
            case .flagsChanged?:
                copying = e!.modifierFlags.contains(.option)
                if dragging { setCursor() }
            case .keyDown? where e!.keyCode == 53:  // Esc cancels
                destination = nil
                pageZone = nil
                cancelled = true
                break tracking
            case .leftMouseUp?:
                copying = e!.modifierFlags.contains(.option)
                lastPoint = e!.locationInWindow
                break tracking
            case .leftMouseDragged?:
                let e = e!
                let p = target.convert(e.locationInWindow, from: nil)
                if !dragging {
                    let q = convert(e.locationInWindow, from: nil)
                    guard hypot(q.x - start.x, q.y - start.y) > AircSpacing.xs else { continue }
                    dragging = true
                    row.isPressed = false
                    if case .folder(let item, _) = entry {
                        // The press already toggled the folder; put it back as it was.
                        c.toggleFolder(item.id)
                    }
                    let g = makeGhost(of: row, count: sources.count)
                    ghost = g
                    let rowOrigin = row.convert(NSPoint.zero, to: self)
                    // The ghost is centred on the row it lifts (its height is the row pitch, the row's may differ).
                    grabOffset = CGPoint(x: start.x - rowOrigin.x,
                                         y: start.y - rowOrigin.y + (g.bounds.height - row.bounds.height) / 2)
                    let o = FlippedView(frame: c.root.bounds)
                    o.wantsLayer = true
                    c.root.addSubview(o)
                    o.layer?.addSublayer(g)
                    overlay = o
                    out?.lift(ghost: g, overlay: o, grab: grabOffset)
                    row.alphaValue = 0.35
                    groupRows.forEach { $0.alphaValue = 0.35 }
                    setCursor()
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if let overlay {
                    let w = overlay.convert(e.locationInWindow, from: nil)
                    ghost?.frame.origin = CGPoint(x: w.x - grabOffset.x, y: w.y - grabOffset.y)
                }
                CATransaction.commit()
                lastPoint = e.locationInWindow
                if out?.update(windowPoint: e.locationInWindow) == true {
                    // Outside the window: nothing in it is a drop target until the pointer comes back.
                    target.hideDropIndicator()
                    c.hideSplitDropPreview()
                    destination = nil
                    pageZone = nil
                    edge = nil
                    continue
                }
                let rootPoint = c.root.convert(e.locationInWindow, from: nil)
                if sources.count == 1, case .tab(let dragged) = source, let under = shownBefore, under != dragged,
                   c.shownTabID == dragged, c.store.tab(under) != nil, c.card.frame.contains(rootPoint), !c.sidebar.frame.contains(rootPoint) {
                    // Over the page: the page that was there comes back under the pointer, ready to split.
                    c.show(under, focus: false)
                    showedUnder = true
                }
                pageZone = sources.count == 1 ? c.splitDropZone(for: source, at: rootPoint) : nil
                if pageZone != nil {
                    target.hideDropIndicator()
                    destination = nil
                } else {
                    destination = target.dropDestination(at: p, source: source, entry: entry, carriesFolder: groupHasFolder)
                }
                // The edge of the sidebar as it shows in the window (not a page's, which may still be sliding in). The
                // left edge pages to the previous Space and the right one to the next on either side (WIN-5); the
                // inner edge's zone reaches a little over the page.
                let visible = c.sidebar.convert(c.sidebar.bounds, to: c.root).intersection(c.root.bounds)
                let side = Self.edgeSide(at: c.root.convert(e.locationInWindow, from: nil).x, sidebar: visible, onRight: c.sidebarOnRight)
                if side == 0 { edge = nil } else if edge?.side != side { edge = (side, CACurrentMediaTime()) }
            default:
                break
            }
            // Edge paging: after the dwell, the neighbouring Space comes in and the drag carries on there.
            if dragging, let ed = edge, CACurrentMediaTime() - ed.since >= Self.edgeDwell {
                let spaces = c.windowSpaces
                if let i = spaces.firstIndex(where: { $0.id == target.spaceID }), spaces.indices.contains(i + ed.side) {
                    let next = spaces[i + ed.side].id
                    target.hideDropIndicator()
                    destination = nil
                    c.switchToSpace(next, animated: true)
                    if let page = c.pageView(for: next) { target = page }
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                // Another dwell pages again.
                edge = (ed.side, CACurrentMediaTime() + Self.edgeDwell)
            }
        }
        NSCursor.arrow.set()
        c.hideSplitDropPreview()
        row.isPressed = false
        row.alphaValue = 1
        groupRows.forEach { $0.alphaValue = 1 }
        ghost?.removeFromSuperlayer()
        overlay?.removeFromSuperview()
        hideDropIndicator()
        if target !== self { target.hideDropIndicator() }
        // Released (or Esc) outside the window: a new window, or another one (TabDragOut).
        if dragging, out?.finish(drop: !cancelled, windowPoint: lastPoint) == true { return }
        // A plain click (no drag) on a row of the multi-selection leaves just that row, as everywhere else.
        if !dragging, sources.count > 1 { clearSelection() }
        if dragging, let pageZone, case .tab(let id) = source {
            c.dropOnPage(id, zone: pageZone)
        } else if showedUnder, case .tab(let id) = source, c.store.tab(id) != nil {
            // Not dropped on the page after all: the dragged tab shows again, as its press showed it.
            c.show(id, focus: false)
        }
        if dragging, pageZone == nil, let destination {
            if sources.count > 1 {
                if copying { c.performCopy(sources, to: destination) } else { c.performDrop(sources, to: destination) }
                clearSelection()
            } else if copying {
                c.performCopy(source, to: destination)
            } else {
                c.performDrop(source, to: destination)
            }
        }
    }

    /// The dragged row, lifted (design.md §7 "Drag ghost"): AircDragGhostLayer, built from the row's data on an opaque
    /// plate, so no text shows through and nothing is drawn from a capture.
    /// `count` > 1: a multi-selection; the ghost carries how many rows it holds in a badge at its top right.
    private func makeGhost(of row: SidebarRowView, count: Int = 1) -> CALayer {
        let isTile = row is FavoriteTileView
        let scale = window?.backingScaleFactor ?? 2
        let g = AircDragGhostLayer(kind: isTile ? .tile : .row, width: row.bounds.width, theme: palette.resolved, scale: scale)
        g.configure(title: row.dragTitle, favicon: row.dragFavicon)
        if count > 1 {
            let theme = palette.resolved
            let text = CATextLayer()
            text.string = NSAttributedString(string: "\(count)", attributes: [
                .font: AircFont.caption.weight(.semibold).appFont, .foregroundColor: theme.background.nsColor])
            text.alignmentMode = .center
            text.contentsScale = scale
            let w = max(18, CGFloat("\(count)".count) * 7 + 10)
            let badge = CALayer()
            badge.frame = CGRect(x: g.bounds.width - w + 4, y: -6, width: w, height: 18)
            badge.cornerRadius = 9
            badge.backgroundColor = theme.text.nsColor.cgColor
            text.frame = CGRect(x: 0, y: 2, width: w, height: 15)
            badge.addSublayer(text)
            g.addSublayer(badge)
        }
        return g
    }

    /// SV-1: a split's pane dragged by its handle (WindowController.dragPaneOut), at a window point: where it would land
    /// in this sidebar, with the drop line or column; nil, and nothing shown, when the pointer isn't over the sidebar.
    func paneDropDestination(_ tabID: String, at windowPoint: NSPoint) -> DropDestination? {
        guard let c = controller, let t = c.store.tab(tabID),
              c.sidebar.frame.contains(c.root.convert(windowPoint, from: nil)) else { hideDropIndicator(); return nil }
        return dropDestination(at: convert(windowPoint, from: nil), source: .tab(tabID), entry: .today(t))
    }

    func endPaneDrag() { hideDropIndicator() }

    func hideDropIndicator() {
        dropLine.isHidden = true
        dropRing.isHidden = true
        highlightedFolder?.isHovered = false
        highlightedFolder = nil
    }

    /// Shows the 2 pt drop line (with its 8 pt ring) at `y` in page coordinates.
    private func showDropLine(y: CGFloat, x: CGFloat, width: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLine.backgroundColor = palette.dropLine.cgColor
        dropRing.borderColor = palette.dropLine.cgColor
        dropLine.frame = NSRect(x: x + AircSpacing.s, y: y - 1, width: max(0, width - AircSpacing.s), height: 2)
        dropRing.frame = NSRect(x: x, y: y - AircSpacing.s / 2, width: AircSpacing.s, height: AircSpacing.s)
        dropLine.isHidden = false
        dropRing.isHidden = false
        CATransaction.commit()
    }

    private func showDropColumn(x: CGFloat, y: CGFloat, height: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dropLine.backgroundColor = palette.dropLine.cgColor
        dropLine.frame = NSRect(x: x - 1, y: y, width: 2, height: height)
        dropLine.isHidden = false
        dropRing.isHidden = true
        CATransaction.commit()
    }

    /// The Favorite split whose tile is under `p` (page coordinates), with the tile's frame there.
    private func favoriteSplitTile(at p: NSPoint) -> (item: Item, frame: NSRect)? {
        for t in tiles.values where !t.isHidden {
            guard let i = t.item, i.kind == .split else { continue }
            let f = favorites.convert(t.frame, to: self)
            if f.contains(p) { return (i, f) }
        }
        return nil
    }

    /// Where a drop at `p` (page coordinates) lands, and draws the indicator for it.
    /// `carriesFolder`: a dragged multi-selection holds a folder (it can't go into Favorites or Today either).
    func dropDestination(at p: NSPoint, source: DragSource, entry: SidebarEntry, carriesFolder: Bool = false) -> DropDestination? {
        guard let c = controller else { return nil }
        let store = c.store
        let profileID = store.profile(ofSpace: spaceID).id
        highlightedFolder?.isHovered = false
        highlightedFolder = nil
        let isFolder: Bool = carriesFolder || { if case .folder = entry { return true }; return false }()

        // Above the Space name: Favorites.
        if p.y < header.frame.midY {
            if isFolder { hideDropIndicator(); return nil }
            // SV-2: a tab onto the middle of a Favorite split's tile joins it as one more pane, as on a pinned split's
            // row: the tile's left or right half puts it first or last. The tile's outer quarters still place the tab
            // between Favorites; a full split takes no more.
            if case .tab(let dragged) = source, let hit = favoriteSplitTile(at: p), abs(p.x - hit.frame.midX) < hit.frame.width / 4,
               store.splitItem(ofPane: store.tab(dragged)?.itemID)?.id != hit.item.id,
               store.panes(ofSplitItem: hit.item.id).count < Split.maxPanes,
               store.tab(dragged)?.profileID == profileID {
                let f = hit.frame, leading = p.x < f.midX
                if let tile = tiles[hit.item.id] { tile.isHovered = true; highlightedFolder = tile }
                showDropColumn(x: leading ? f.minX + 6 : f.maxX - 6, y: f.minY + 6, height: f.height - 12)
                return .split(spaceID: spaceID, target: hit.item.id, leading: leading)
            }
            let favs = store.favorites(ofProfile: profileID)
            let alreadyFavorite = entry.item?.isFavorite == true
            if !alreadyFavorite && favs.count >= SpacesStore.maxFavorites { hideDropIndicator(); return nil }
            let gridOrigin = favorites.frame.origin
            if favs.isEmpty {
                showDropLine(y: header.frame.minY - 2, x: AircMetrics.Sidebar.inset, width: bounds.width - 2 * AircMetrics.Sidebar.inset)
                return .favorites(profileID: profileID, index: 0)
            }
            let layout = FavoritesGrid.layout(count: favs.count, width: Double(favorites.frame.width))
            let local = CGPoint(x: p.x - gridOrigin.x, y: p.y - gridOrigin.y)
            let rowIndex = max(0, min(layout.rows - 1, Int(local.y / CGFloat(FavoritesGrid.tileHeight + FavoritesGrid.gap))))
            let colF = local.x / CGFloat(layout.tileWidth + FavoritesGrid.gap)
            let col = max(0, min(layout.columns, Int(colF.rounded())))
            let index = min(favs.count, rowIndex * layout.columns + col)
            let slot = FavoritesGrid.frame(index: min(index, favs.count - 1), layout: layout)
            let x = index >= favs.count && index % layout.columns != 0
                ? gridOrigin.x + CGFloat(slot.x + slot.w) + 4 : gridOrigin.x + CGFloat(FavoritesGrid.frame(index: index, layout: layout).x) - 4
            showDropColumn(x: x, y: gridOrigin.y + CGFloat(slot.y), height: CGFloat(FavoritesGrid.tileHeight))
            return .favorites(profileID: profileID, index: index)
        }

        // In the list.
        let lp = list.convert(p, from: self)
        let listToPage = { (y: CGFloat) -> CGFloat in self.convert(NSPoint(x: 0, y: y), from: self.list).y }
        let pinnedRoots = store.pinnedRoots(ofSpace: spaceID)
        var pinnedEntries: [(SidebarEntry, NSRect)] = []
        var todayIndex = 0
        var todayFrames: [NSRect] = []
        var todayEntries: [(SidebarEntry, NSRect)] = []
        var dividerFrame = NSRect.zero
        for (id, model) in order {
            guard let v = rows[id] else { continue }
            switch model {
            case .entry(let e):
                switch e {
                case .today, .split: todayFrames.append(v.frame); todayEntries.append((e, v.frame))
                default: pinnedEntries.append((e, v.frame))
                }
            case .divider: dividerFrame = v.frame
            default: break
            }
        }
        _ = todayIndex

        // Today section: below the divider.
        if lp.y > dividerFrame.midY {
            if isFolder { hideDropIndicator(); return nil }
            // SV-1: a Today tab onto the middle of a Today row (a tab or a split): a split. The row's left or right half
            // puts the dragged tab first or last (Arc ref §2.11).
            if case .tab(let dragged) = source, !carriesFolder, store.tab(dragged)?.isToday == true,
               let (e, f) = todayEntries.first(where: { lp.y >= $0.1.minY && lp.y < $0.1.maxY }), abs(lp.y - f.midY) < f.height / 4,
               e.id != dragged, e.split?.tabIDs.contains(dragged) != true, (e.split?.tabIDs.count ?? 1) < Split.maxPanes {
                let leading = lp.x < f.midX
                if let row = rows[e.id] { row.isHovered = true; highlightedFolder = row }
                let inset = AircMetrics.Sidebar.inset + 6
                showDropColumn(x: leading ? inset : bounds.width - inset, y: listToPage(f.minY) + 6, height: f.height - 12)
                return .split(spaceID: spaceID, target: e.id, leading: leading)
            }
            var index = todayFrames.count
            for (i, f) in todayFrames.enumerated() where lp.y < f.midY { index = i; break }
            let lineY = index < todayFrames.count ? todayFrames[index].minY
                : (todayFrames.last?.maxY ?? (rows["newtab"]?.frame.maxY ?? dividerFrame.maxY))
            showDropLine(y: listToPage(lineY), x: AircMetrics.Sidebar.inset, width: bounds.width - 2 * AircMetrics.Sidebar.inset)
            todayIndex = index
            return .today(spaceID: spaceID, index: index)
        }

        // Pinned section.
        func siblingIndex(_ item: Item) -> Int {
            store.children(of: item.container, parent: item.parentID).firstIndex(where: { $0.id == item.id }) ?? 0
        }
        func depthOf(_ e: SidebarEntry) -> Int {
            switch e {
            case .pinned(_, let d, _), .folder(_, let d): d
            default: 0
            }
        }
        for (e, f) in pinnedEntries where lp.y >= f.minY && lp.y < f.maxY {
            guard let item = e.item else { continue }
            let d = CGFloat(depthOf(e)) * AircMetrics.Row.folderIndent
            // SV-2: a tab onto the middle of a pinned split's row joins it as one more pane, up to the pane limit; the
            // row's left or right half puts it first or last, as on a Today split. (Arc's own behaviour here isn't
            // recorded; a full split takes no more and the drop goes between rows.)
            if item.kind == .split, case .tab(let dragged) = source, !carriesFolder, abs(lp.y - f.midY) < f.height / 4,
               store.splitItem(ofPane: store.tab(dragged)?.itemID)?.id != item.id,
               store.panes(ofSplitItem: item.id).count < Split.maxPanes,
               store.tab(dragged)?.profileID == store.profile(ofSpace: spaceID).id {
                let leading = lp.x < f.midX
                if let row = rows[item.id] { row.isHovered = true; highlightedFolder = row }
                let inset = AircMetrics.Sidebar.inset + 6
                showDropColumn(x: leading ? inset : bounds.width - inset, y: listToPage(f.minY) + 6, height: f.height - 12)
                return .split(spaceID: spaceID, target: item.id, leading: leading)
            }
            // Onto a folder (middle half): into it.
            if case .folder = e, abs(lp.y - f.midY) < f.height / 4, item.id != entry.item?.id {
                if let row = rows[item.id] { row.isHovered = true; highlightedFolder = row }
                hideDropLineOnly()
                let count = store.children(of: item.container, parent: item.id).count
                return .pinned(spaceID: spaceID, parentID: item.id, index: count)
            }
            if lp.y < f.midY {
                showDropLine(y: listToPage(f.minY), x: AircMetrics.Sidebar.inset + d, width: bounds.width - 2 * AircMetrics.Sidebar.inset - d)
                return .pinned(spaceID: spaceID, parentID: item.parentID, index: siblingIndex(item))
            }
            if case .folder = e, !item.isCollapsed {
                showDropLine(y: listToPage(f.maxY), x: AircMetrics.Sidebar.inset + d + AircMetrics.Row.folderIndent,
                             width: bounds.width - 2 * AircMetrics.Sidebar.inset - d - AircMetrics.Row.folderIndent)
                return .pinned(spaceID: spaceID, parentID: item.id, index: 0)
            }
            showDropLine(y: listToPage(f.maxY), x: AircMetrics.Sidebar.inset + d, width: bounds.width - 2 * AircMetrics.Sidebar.inset - d)
            return .pinned(spaceID: spaceID, parentID: item.parentID, index: siblingIndex(item) + 1)
        }
        // Between the last pinned row and the divider (or an empty pinned section).
        let y = pinnedEntries.last?.1.maxY ?? 0
        showDropLine(y: listToPage(max(y, 0)), x: AircMetrics.Sidebar.inset, width: bounds.width - 2 * AircMetrics.Sidebar.inset)
        return .pinned(spaceID: spaceID, parentID: nil, index: pinnedRoots.count)
    }

    private func hideDropLineOnly() {
        dropLine.isHidden = true
        dropRing.isHidden = true
    }
}

extension SpacePageView.RowModel {
    var isEntry: Bool { if case .entry = self { return true }; return false }
}
