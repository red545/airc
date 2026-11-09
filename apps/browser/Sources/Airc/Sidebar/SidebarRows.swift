// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// A rounded plate that shows hover, press and selection (Arc ref §2.8).
final class PlateLayer: CALayer {
    override init() {
        super.init()
        cornerRadius = AircMetrics.Row.plateRadius
        cornerCurve = .continuous
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// `inSelection`: a row of the multi-selection that isn't the shown tab (SB-36): Arc's secondary selection fill, no
    /// shadow. The shown tab keeps its own look when it's selected too.
    func style(palette: Palette, hovered: Bool, selected: Bool, pressed: Bool, inSelection: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inSelection, !selected {
            backgroundColor = (pressed ? palette.pressed : hovered ? palette.multiSelectedHover : palette.multiSelected).cgColor
            shadowOpacity = 0
        } else if selected {
            backgroundColor = (hovered ? palette.selectedHover : palette.selected).cgColor
            if let s = palette.selectedShadow {
                apply(s)
            } else {
                shadowOpacity = 0
            }
        } else {
            backgroundColor = pressed ? palette.pressed.cgColor : hovered ? palette.hover.cgColor : NSColor.clear.cgColor
            shadowOpacity = 0
        }
        CATransaction.commit()
    }
}

/// Base for every sidebar row: hover tracking, the plate, press feedback, context menu.
class SidebarRowView: NSView {
    weak var controller: WindowController?
    /// The Space page that owns this row (drag and drop starts there).
    weak var page: SpacePageView?
    var palette: Palette!
    let plate = PlateLayer()
    var isHovered = false { didSet { if oldValue != isHovered { updateStyle() } } }
    var isPressed = false { didSet { if oldValue != isPressed { updateStyle() } } }
    var isSelected = false { didSet { if oldValue != isSelected { updateStyle() } } }
    /// In the page's multi-selection (SB-36, ⌘/⇧-click): Arc's secondary selection fill (the shown row keeps its own).
    var isInSelection = false { didSet { if oldValue != isInSelection { updateStyle() } } }
    var showsPlate = true
    /// Where the plate sits inside the row.
    var plateInsets = NSEdgeInsets(top: 2, left: AircMetrics.Sidebar.inset, bottom: 2, right: AircMetrics.Sidebar.inset)

    // MARK: Keyboard focus and VoiceOver (P03, Sidebar/SidebarKeyboard.swift)

    /// The row's place in its page's keyboard order (SidebarNavItem.id); nil for what the keyboard skips (cards, the
    /// divider), which then keep AppKit's own accessibility.
    var navID: String?
    /// The keyboard is on this row (it's the window's first responder): its plate shows as on hover, with the system
    /// focus ring around it.
    private(set) var isKeyboardFocused = false {
        didSet {
            guard oldValue != isKeyboardFocused else { return }
            updateStyle()
            needsLayout = true
            noteFocusRingMaskChanged()
        }
    }
    /// The row's name for VoiceOver; nil: the page's model has it (SidebarNavItem.title).
    var spokenTitle: String? { nil }
    /// Where the focus ring goes: the plate (a Favorite: the tile).
    var focusRingRect: NSRect { plate.frame }
    var focusRingRadius: CGFloat { AircMetrics.Row.plateHeight / 4 }
    private lazy var disclosure = SidebarDisclosureElement(row: self)

    override var acceptsFirstResponder: Bool {
        navID != nil && (page?.isMovingKeyboardFocus == true || window?.firstResponder === self)
    }
    /// Tab doesn't walk the rows (it jumps between the sidebar's sections, SidebarNavigator).
    override var canBecomeKeyView: Bool { false }
    override func becomeFirstResponder() -> Bool {
        isKeyboardFocused = true
        page?.rowDidTakeKeyboardFocus(self)
        return true
    }
    override func resignFirstResponder() -> Bool {
        isKeyboardFocused = false
        page?.rowDidLoseKeyboardFocus(self)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if page?.sidebarKeyDown(event, row: self) != true { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { navID == nil ? .zero : focusRingRect }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingRect, xRadius: focusRingRadius, yRadius: focusRingRadius).fill()
    }

    private var navKind: SidebarNavItem.Kind? { page?.navItem(navID)?.kind }

    override func isAccessibilityElement() -> Bool { navID != nil || super.isAccessibilityElement() }
    override func accessibilityRole() -> NSAccessibility.Role? { navID != nil ? .row : super.accessibilityRole() }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { navID != nil ? .outlineRow : super.accessibilitySubrole() }
    override func accessibilityLabel() -> String? {
        guard navID != nil else { return super.accessibilityLabel() }
        return spokenTitle ?? page?.navItem(navID)?.title
    }
    override func accessibilityRoleDescription() -> String? {
        page?.accessibilityRoleDescription(of: navID) ?? super.accessibilityRoleDescription()
    }
    override func accessibilityValue() -> Any? { navID != nil ? page?.accessibilityValue(of: navID) : super.accessibilityValue() }
    /// The page on screen: its row (a Favorite's tile, a split's row) is the selected one.
    override func isAccessibilitySelected() -> Bool { navID != nil ? isSelected && navKind != .newTab : super.isAccessibilitySelected() }
    override func isAccessibilityExpanded() -> Bool { page?.navItem(navID)?.isExpanded ?? false }
    override func isAccessibilityDisclosed() -> Bool { page?.navItem(navID)?.isExpanded ?? false }
    override func accessibilityDisclosureLevel() -> Int { page?.accessibilityLevel(of: navID) ?? 0 }
    override func accessibilityParent() -> Any? { navID != nil ? (page?.outline ?? super.accessibilityParent()) : super.accessibilityParent() }
    override func isAccessibilityFocused() -> Bool { navID != nil ? window?.firstResponder === self : super.isAccessibilityFocused() }
    /// A row reads as one element; a folder and the header add their disclosure triangle.
    override func accessibilityChildren() -> [Any]? {
        guard navID != nil else { return super.accessibilityChildren() }
        return navKind == .folder || navKind == .header ? [disclosure] : []
    }
    override func accessibilityPerformPress() -> Bool {
        guard navID != nil, let page else { return super.accessibilityPerformPress() }
        return page.performPrimaryAction(self, keepKeyboard: window?.firstResponder === self)
    }
    /// VoiceOver's "show menu": the row's context menu, as a right-click opens it.
    override func accessibilityPerformShowMenu() -> Bool {
        guard navID != nil, let window, let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1), let menu = menu(for: event) else { return super.accessibilityPerformShowMenu() }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX + 24, y: bounds.maxY), in: self)
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(plate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    func updateStyle() {
        guard palette != nil else { return }
        plate.isHidden = !showsPlate
        plate.style(palette: palette, hovered: isHovered || isKeyboardFocused, selected: isSelected, pressed: isPressed,
                    inSelection: isInSelection)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = AircMetrics.Row.plateHeight
        plate.frame = NSRect(x: plateInsets.left, y: (bounds.height - h) / 2,
                             width: bounds.width - plateInsets.left - plateInsets.right, height: h)
        CATransaction.commit()
    }

    /// What the drag ghost shows for this row (AircDragGhostLayer is built from data, not a capture).
    var dragTitle: String { "" }
    var dragFavicon: CGImage? { nil }

    /// Back to a fresh row before it's reused for another entry (TabRowPool).
    func resetForPool() {
        isHovered = false
        isPressed = false
        isSelected = false
        isInSelection = false
        navID = nil
        alphaValue = 1
        page = nil
        layer?.removeAllAnimations()
        layer?.opacity = 1
        plate.removeAllAnimations()
    }

    /// Press feedback: the plate shrinks to 0.99 over 70 ms.
    func pressAnimation() {
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 1
        a.toValue = 0.99
        a.duration = AircCurve.press.duration
        a.autoreverses = true
        plate.add(a, forKey: "press")
    }
}

/// Small borderless glyph button with a hover plate (close, mute, •••, header buttons). The glyph is a sublayer
/// (`LayerImage`), not an NSImageView, which on macOS 26 is two views: every view costs on each layout pass.
final class GlyphButton: NSView {
    var symbol: String { didSet { if symbol != oldValue { updateImage() } } }
    var symbolSize: CGFloat
    var tint: NSColor = .secondaryLabelColor { didSet { if tint != oldValue { updateImage() } } }
    var hoverFill: NSColor = .clear
    var isEnabled = true { didSet { if isEnabled != oldValue { updateImage() } } }
    var action: (() -> Void)?
    /// ⌘-click, when it does something else (Back / Forward: open that page in a background tab, SB-1).
    var commandAction: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// The pointer came onto the button or left it (the Library button's recent files, LIB-1).
    var onHover: ((Bool) -> Void)?
    /// The menu comes on a long press (or right-click) and a plain click acts (Back, Forward); otherwise a press shows
    /// the menu at once.
    var longPressMenu = false
    var plateRadius: CGFloat = 6
    private let glyph = CALayer()
    private var hovered = false { didSet { updatePlate() } }

    init(symbol: String, size: CGFloat = 13, frame: NSRect = .zero) {
        self.symbol = symbol
        self.symbolSize = size
        super.init(frame: frame)
        wantsLayer = true
        glyph.contentsGravity = .center
        glyph.actions = LayerImage.noActions
        layer?.addSublayer(glyph)
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    /// The header's buttons sit in the titlebar band (centre 23.5 pt down), where the window server would drag the
    /// window on a press over a view that doesn't claim it (PageHostView).
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateImage() {
        let color = tint.withAlphaComponent(tint.alphaComponent * (isEnabled ? 1 : 0.45))
        LayerImage.set(LayerImage.symbol(symbol, size: symbolSize, weight: .medium, color: color), on: glyph, in: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if LayerImage.scaleChanged(glyph, in: self) { updateImage() }
    }

    private func updatePlate() {
        layer?.cornerRadius = plateRadius
        layer?.backgroundColor = (hovered && isEnabled) ? hoverFill.cgColor : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyph.frame = bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if !longPressMenu, let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            return
        }
        layer?.backgroundColor = hoverFill.withAlphaComponent(hoverFill.alphaComponent * 1.8).cgColor
        guard longPressMenu, let window else { return }
        // Held for Arc's long press (macOS's 0.5 s): the menu instead of the click.
        let release = window.nextEvent(matching: [.leftMouseUp], until: Date().addingTimeInterval(Self.longPress),
                                       inMode: .eventTracking, dequeue: true)
        if let release { return mouseUp(with: release) }
        updatePlate()
        if let menu = menuProvider?() { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self) }
    }

    static let longPress: TimeInterval = 0.5

    override func mouseUp(with event: NSEvent) {
        updatePlate()
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.command), let commandAction { return commandAction() }
        action?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuProvider?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

/// One-line labels show a few dozen characters; anything longer is cut before it reaches a label (CoreText would
/// shape all of it on every measure and draw: long URLs and data: URLs are thousands of characters).
enum TextLimits {
    static let label = 300

    static func clip(_ s: String) -> String { s.count > label ? String(s.prefix(label)) : s }
}

/// Images drawn straight into a layer: the glyph of a GlyphButton, a favicon. Cheaper than an NSImageView, which on
/// macOS 26 adds a second view (`_NSImageViewSimpleImageView`) that every layout pass walks.
enum LayerImage {
    static let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                 "contentsScale": NSNull(), "hidden": NSNull()]
    private static var tinted: [String: NSImage] = [:]

    /// A template symbol drawn in `color`, made once per symbol, size, weight and colour.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = String(format: "%@|%.1f|%.2f|%.4f,%.4f,%.4f,%.4f", name, size, weight.rawValue,
                         c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        if let hit = tinted[key] { return hit }
        guard let base = Symbols.image(name, size: size, weight: weight) else { return nil }
        let img = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            c.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted[key] = img
        return img
    }

    /// The window's scale differs from the one `layer` was drawn at (a move to another display, not a re-attach).
    static func scaleChanged(_ layer: CALayer, in view: NSView) -> Bool {
        guard layer.contents != nil, let scale = view.window?.backingScaleFactor else { return false }
        return abs(layer.contentsScale - scale) > 0.01
    }

    /// Puts `image` in `layer` at `view`'s backing scale (nil clears it).
    static func set(_ image: NSImage?, on layer: CALayer, in view: NSView) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image {
            layer.contentsScale = image.recommendedLayerContentsScale(scale)
            layer.contents = image.layerContents(forContentsScale: layer.contentsScale)
        } else {
            layer.contents = nil
        }
        CATransaction.commit()
    }
}

/// Favicon, or a calm placeholder square while there's none (the owner's screenshot shows one). The icon is a
/// sublayer (`LayerImage`), not an NSImageView.
///
/// An icon FaviconCache couldn't get yet is never given up on: the view asks again when it comes on screen (moved into
/// a window, unhidden, its window uncovered), when the network comes back, and when its page loads (the engine hands
/// over the page's icon), within the cache's backoff. No timer of its own.
final class FaviconView: NSView, FaviconWatcher {
    private let icon = CALayer()
    private let placeholder = CALayer()
    /// The icon asked for and not shown yet; `waiting` while FaviconCache hasn't answered.
    private var requested: String?
    private var waiting = false
    /// The icon whose round failed, watched for the cache's triggers.
    private var watching: String?
    private var image: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        placeholder.cornerRadius = 4
        placeholder.cornerCurve = .continuous
        placeholder.actions = LayerImage.noActions
        layer?.addSublayer(placeholder)
        icon.actions = LayerImage.noActions
        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    #if AIRC_TESTING
    /// The image shown now (the checks compare it with what they handed in).
    var shownImage: NSImage? { placeholder.isHidden ? image : nil }
    /// Whether the icon layer has contents (an icon shown without the window drawing: the screen locked).
    var iconLayerHasContents: Bool { placeholder.isHidden && icon.contents != nil }
    /// The icon this view waits for after a failed round (nil: none).
    var watchedIcon: String? { watching }
    #endif

    /// The icon shown now, or nil while the placeholder square shows.
    var cgImage: CGImage? {
        guard placeholder.isHidden, let image else { return nil }
        var r = NSRect(origin: .zero, size: NSSize(width: 64, height: 64))
        return image.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    private func show(_ img: NSImage?, gravity: CALayerContentsGravity = .resizeAspect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.isHidden = img != nil
        if icon.contentsGravity != gravity { icon.contentsGravity = gravity }
        CATransaction.commit()
        guard img !== image else { return }
        image = img
        LayerImage.set(img, on: icon, in: self)
    }

    func set(image: NSImage?, url: String?, fallbackPage: String?, palette: Palette, symbol: String? = nil) {
        // Every path that shows something else forgets the icon asked for before, so a slow fetch for a reused row's
        // previous content can't land on it (cbsites: Spiegel's icon on Spotify's row).
        if let symbol {
            forgetRequest()
            show(LayerImage.symbol(symbol, size: 14, weight: .semibold, color: palette.textSecondary), gravity: .center)
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.backgroundColor = palette.placeholderIcon.cgColor
        CATransaction.commit()
        if let image {
            // The engine shows the page's icon: the page loaded. If the cache failed to get it, now is a good time
            // (the row shows the cache's copy once the page is unloaded).
            if let url, FaviconCache.shared.cached(url) == nil { FaviconCache.shared.pageLoaded(url, profile: profileID) }
            forgetRequest()
            return show(image)
        }
        // A file on disk with no icon of its own (P04's file tabs): its type's icon, a folder's for a directory.
        if let file = FaviconCache.fileIcon(forPage: fallbackPage) { forgetRequest(); return show(file) }
        let key = url ?? fallbackPage.flatMap(FaviconCache.guess(for:))
        if let cached = FaviconCache.shared.cached(key) { forgetRequest(); return show(cached) }
        show(nil)
        guard let key else { forgetRequest(); return }
        // Asked for and still coming (FaviconCache retries a failed fetch); otherwise ask again: each configure is the
        // next page load or a refresh, and the cache decides whether that may reach the network yet.
        if requested == key, waiting { return }
        request(key, .shown)
    }

    private func forgetRequest() {
        requested = nil
        stopWatching()
    }

    private func stopWatching() {
        guard let w = watching else { return }
        watching = nil
        FaviconCache.shared.unwatch(self, w)
    }

    private func request(_ key: String, _ trigger: FaviconBackoff.Trigger) {
        if watching != key { stopWatching() }
        requested = key
        waiting = true
        // A new row is configured before its page adds it: it asks a moment later, once placed, so its failures back
        // off under its profile from the first one.
        if profileID == nil { DispatchQueue.main.async { [weak self] in self?.ask(key, trigger) } } else { ask(key, trigger) }
    }

    private func ask(_ key: String, _ trigger: FaviconBackoff.Trigger) {
        FaviconCache.shared.load(key, retrying: true, profile: profileID, trigger: trigger) { [weak self] img in
            guard let self, self.requested == key else { return }
            self.waiting = false
            if let img {
                self.stopWatching()
                self.show(img)
            } else if self.watching == nil {
                // Not yet: the cache's next trigger (or this view's) asks again.
                self.watching = key
                FaviconCache.shared.watch(self, key)
            }
        }
    }

    /// The profile whose Space shows this view, for the cache's per-profile backoff (nil outside a Space's page).
    private var profileID: String? {
        var v = superview
        while let s = v {
            if let page = s as? SpacePageView { return page.controller?.store.profile(ofSpace: page.spaceID).id }
            v = s.superview
        }
        return nil
    }

    /// Back on screen with no icon (a reused row, a Space page shown again), or another trigger: asks again.
    private func retryIfBlank(_ trigger: FaviconBackoff.Trigger) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, image == nil, let key = requested, !waiting else { return }
        request(key, trigger)
    }

    func faviconArrived(_ img: NSImage, for url: String) {
        guard requested == url, image == nil else { return }
        watching = nil
        waiting = false
        show(img)
    }

    func faviconRetry(_ trigger: FaviconBackoff.Trigger, in window: NSWindow?) {
        if let window, window !== self.window { return }
        retryIfBlank(trigger)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        retryIfBlank(.shown)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        retryIfBlank(.shown)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let image, LayerImage.scaleChanged(icon, in: self) { LayerImage.set(image, on: icon, in: self) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = bounds
        placeholder.frame = bounds.insetBy(dx: 1, dy: 1)
        CATransaction.commit()
    }
}

/// Rows that left a page, kept for the next row any page needs (opening a tab, a move, a new Space): building one is
/// a dozen allocations and its labels' setup; reusing it is a configure. At most `limit` wait.
final class TabRowPool {
    private var rows: [TabRowView] = []
    static let limit = 24

    func take() -> TabRowView {
        guard let r = rows.popLast() else { return TabRowView() }
        return r
    }

    func give(_ r: TabRowView) {
        guard rows.count < Self.limit, r.superview == nil else { return }
        r.resetForPool()
        rows.append(r)
    }

    var count: Int { rows.count }
}

/// A pinned tab, Favorite-as-row or Today tab (SB-30, SB-31, SB-44).
final class TabRowView: SidebarRowView {
    enum Kind: Equatable { case pinned(itemID: String), today }
    private(set) var kind: Kind = .today
    private(set) var tabID: String?
    private(set) var entry: SidebarEntry?
    var depth = 0

    private let favicon = FaviconView()
    private let title = AircFadingLabel(style: AircFont.row)
    /// The host line, the audio button and ✕ are made when first needed (most rows never show them; every view costs
    /// on each layout pass, §2.12).
    private var host: AircFadingLabel?
    private var audio: GlyphButton?
    private var close: GlyphButton?
    private var closeSymbol = "xmark"
    private var muted = false
    /// SB-44: AircDesign's ring takes the favicon's slot once a load has run for 150 ms (fast loads never flicker).
    private let loading = AircLoadingIndicator()
    /// The item's emoji (Change Icon…), drawn instead of the favicon.
    private var emoji: NSTextField?
    private var showsSpinner: Bool { loading.isShowing }
    private var isUnloaded = false
    private var drifted = false
    private var faviconHovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = AircFont.row.appFont
        title.lineBreakMode = .byClipping
        for v in [favicon, title] as [NSView] { addSubview(v) }
        layer?.addSublayer(loading.layer)
        loading.onVisibilityChange = { [weak self] on in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup {
                $0.duration = AircMetrics.Loading.fade
                self.favicon.animator().alphaValue = on ? 0 : self.faviconAlpha
                self.emoji?.animator().alphaValue = on ? 0 : self.faviconAlpha
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeClose() -> GlyphButton {
        if let close { return close }
        let b = GlyphButton(symbol: closeSymbol, size: 11)
        b.action = { [weak self] in self?.closeTapped() }
        b.isHidden = true
        addSubview(b)
        close = b
        styleButtons()
        return b
    }

    private func makeAudio() -> GlyphButton {
        if let audio { return audio }
        let b = GlyphButton(symbol: "speaker.wave.2.fill", size: 11)
        b.action = { [weak self] in
            guard let self, let id = self.tabID else { return }
            self.controller?.toggleMute(id)
        }
        addSubview(b)
        audio = b
        styleButtons()
        return b
    }

    private func styleButtons() {
        guard let palette else { return }
        for b in [audio, close].compactMap({ $0 }) {
            b.tint = palette.textSecondary
            b.hoverFill = palette.hover
        }
        close?.symbol = closeSymbol
        audio?.symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    func configure(_ entry: SidebarEntry, palette: Palette, selected: Bool) {
        self.entry = entry
        self.palette = palette
        let item = entry.item
        let tab = entry.liveTab
        tabID = tab?.id
        kind = item.map { .pinned(itemID: $0.id) } ?? .today
        if case .pinned(_, let d, _) = entry { depth = d } else { depth = 0 }
        let engineTab = tab.flatMap { controller?.engineTab(for: $0.id) }
        // SB-15 / MEM-3: no page yet, or one the engine has freed (Chromium keeps a discarded page's object).
        // A note never loads a page (Notes/NoteCenter.swift): its row isn't dimmed.
        isUnloaded = (tab == nil || controller?.isPageUnloaded(tab?.id) != false) && !NoteURL.isNote(tab?.url ?? item?.savedURL)

        // Title: the custom name, or the page's; a pinned tab away from its URL shows "/" (SB-31). Tidy Titles
        // (AI/AIFeatures.swift) may give a long page title a short name; the page's own then shows on hover.
        var text: String
        let titleColor = palette.textPrimary
        let tidied = tidyName(for: entry, engineTab: engineTab)
        if let item {
            text = tidied ?? item.displayTitle
            drifted = tab.map { t in item.savedURL.map { URLRules.isDrifted(saved: $0, current: t.url) } ?? false } ?? false
            if drifted, let t = tab {
                let current = engineTab?.title.isEmpty == false ? engineTab!.title : t.displayTitle
                let s = NSMutableAttributedString(string: text, attributes: [.foregroundColor: titleColor, .font: AircFont.row.appFont])
                s.append(NSAttributedString(string: " / " + current,
                                            attributes: [.foregroundColor: palette.textMuted, .font: AircFont.row.appFont]))
                setTitle(s)
            } else {
                setTitle(NSAttributedString(string: text, attributes: [.foregroundColor: titleColor, .font: AircFont.row.appFont]))
            }
        } else if let tab {
            drifted = false
            text = tidied ?? (engineTab?.title.isEmpty == false ? engineTab!.title : tab.displayTitle)
            setTitle(NSAttributedString(string: text, attributes: [.foregroundColor: titleColor, .font: AircFont.row.appFont]))
        }
        showTidyOriginal(tidied != nil, entry: entry, engineTab: engineTab)

        // A grey host line under localhost pins (Arc's dev host line), or a pinned mail or calendar's line from its
        // preview ("1 Recent", "Event in 9m", Previews/ServicePreviewCenter.swift).
        let url = tab?.url ?? item?.savedURL ?? ""
        let status = item == nil ? nil : ServicePreviewCenter.shared.statusLine(for: entry, in: controller)
        let showHost = (URLRules.isLocalDev(url) && item != nil) || status != nil
        if showHost, host == nil {
            let h = AircFadingLabel(style: AircFont.caption)
            h.font = AircFont.caption.appFont
            h.lineBreakMode = .byClipping
            addSubview(h)
            host = h
        }
        if let host {
            host.isHidden = !showHost
            let text = showHost ? status ?? URLRules.displayHost(url) : ""
            if host.stringValue != text { host.stringValue = text }
            if host.textColor != palette.textMuted { host.textColor = palette.textMuted }
        }

        favicon.set(image: engineTab?.favicon, url: tab?.faviconURL ?? item?.faviconURL,
                    fallbackPage: url, palette: palette,
                    symbol: NoteURL.isNote(url) ? "note.text" : (drifted && faviconHovered) ? "arrow.uturn.backward" : nil)
        developerSite = DeveloperMode.shared.applies(url)
        if !showsSpinner { favicon.alphaValue = (item != nil && isUnloaded) ? 0.5 : 1 }
        // A custom icon wins, except while the favicon is the "Back to pinned URL" arrow. A Today tab has its own (S03).
        showCustomIcon(drifted && faviconHovered ? nil : item?.icon ?? tab?.icon)

        if CastCenter.shared.isCasting(engineTab) {
            showCustomIcon(nil)
            favicon.set(image: nil, url: nil, fallbackPage: url, palette: palette, symbol: "airplayvideo")
            favicon.toolTip = "Casting — open Site Controls to stop"
        } else { favicon.toolTip = nil }
        let audible = engineTab?.isAudible ?? false
        muted = tab?.isMuted ?? false
        if audible || muted { makeAudio() }
        audio?.isHidden = !(audible || muted)
        // Arc: ✕ on hover; "−" on the selected pinned row (close keeps the row).
        closeSymbol = (item != nil && selected) ? "minus" : "xmark"
        styleButtons()
        loading.apply(palette.resolved)
        loading.setLoading(engineTab?.isLoading ?? false)

        isSelected = selected
        updateStyle()
        needsLayout = true
    }

    /// The emoji drawn instead of the favicon (Change Icon…), nil while the favicon shows.
    var customIcon: String? { emoji?.isHidden == false ? emoji?.stringValue : nil }

    private func showCustomIcon(_ icon: String?) {
        guard let icon, !icon.isEmpty else {
            emoji?.isHidden = true
            favicon.isHidden = false
            return
        }
        let field = emoji ?? {
            let f = NSTextField(labelWithString: "")
            f.font = NSFont.systemFont(ofSize: AircMetrics.Footer.spaceEmoji)
            f.alignment = .center
            addSubview(f)
            emoji = f
            return f
        }()
        if field.stringValue != icon { field.stringValue = icon }
        field.isHidden = false
        if !showsSpinner { field.alphaValue = faviconAlpha }
        favicon.isHidden = true
    }

    override var spokenTitle: String? { title.stringValue.isEmpty ? nil : title.stringValue }

    /// DEV-1: the row's page is in Developer Mode (Arc's outline while selected).
    private(set) var developerSite = false

    override func updateStyle() {
        super.updateStyle()
        DeveloperMode.outline(plate, on: isSelected && developerSite, palette: palette)
        let showsClose = isHovered && tabID != nil
        if showsClose { makeClose() }
        close?.isHidden = !showsClose
    }

    private var faviconAlpha: CGFloat { (entry?.item != nil && isUnloaded) ? 0.5 : 1 }

    override func resetForPool() {
        super.resetForPool()
        faviconHovered = false
        favicon.alphaValue = 1
        emoji?.isHidden = true
        favicon.isHidden = false
        close?.isHidden = true
    }

    /// The title as last set: setting the same one again would measure and redraw it (§2.12, a reload configures every
    /// row). Long titles are cut first: a label shows one line, and a 5,000-character title would be shaped in full.
    private var shownTitle: NSAttributedString?
    private func setTitle(_ t: NSAttributedString) {
        let t = t.length > TextLimits.label ? t.attributedSubstring(from: NSRange(location: 0, length: TextLimits.label)) : t
        guard shownTitle.map({ !$0.isEqual(to: t) }) ?? true else { return }
        shownTitle = t
        title.attributedStringValue = t
    }

    override func layout() {
        super.layout()
        let indent = CGFloat(depth) * AircMetrics.Row.folderIndent
        let h = bounds.height
        let fs = AircMetrics.Row.favicon
        favicon.frame = NSRect(x: AircMetrics.Row.faviconX + indent, y: (h - fs) / 2, width: fs, height: fs)
        emoji?.frame = NSRect(x: AircMetrics.Row.faviconX + indent - 2, y: (h - 20) / 2, width: 22, height: 20)
        var x = AircMetrics.Row.titleX + indent - DesignGaps.labelInset
        if let audio, !audio.isHidden {
            audio.frame = NSRect(x: x - 4, y: (h - 22) / 2, width: 22, height: 22)
            x += 22
        }
        let right = bounds.width - AircMetrics.Row.titleTrailing - (isHovered ? AircMetrics.Row.closeButton : 0)
        let titleH: CGFloat = 18
        // Titles end in a soft fade before the trailing controls (✕ on hover) and never run under them.
        if let host, !host.isHidden {
            title.frame = NSRect(x: x, y: h / 2 - titleH + 1, width: max(0, right - x), height: titleH)
            host.frame = NSRect(x: x, y: h / 2 + 1, width: max(0, right - x), height: 14)
        } else {
            title.frame = NSRect(x: x, y: (h - titleH) / 2, width: max(0, right - x), height: titleH)
        }
        let cb = AircMetrics.Row.closeButton
        close?.frame = NSRect(x: bounds.width - AircMetrics.Sidebar.inset - 5 - cb, y: (h - cb) / 2, width: cb, height: cb)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loading.layer.position = CGPoint(x: favicon.frame.midX, y: favicon.frame.midY)
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        needsLayout = true
        controller?.tabPreview.hoverBegan(self, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if faviconHovered { faviconHovered = false; refresh() }
        needsLayout = true
        controller?.tabPreview.hoverEnded(self, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let over = favicon.frame.insetBy(dx: -4, dy: -4).contains(p)
        if over != faviconHovered, drifted { faviconHovered = over; refresh() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func refresh() {
        if let entry { configure(entry, palette: palette, selected: isSelected) }
    }

    private func closeTapped() {
        guard let id = tabID else { return }
        controller?.closeTab(id)
    }

    // Press activates on mouse-down (Arc). Dragging is handled by the page.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if drifted, favicon.frame.insetBy(dx: -4, dy: -4).contains(p), let id = tabID {
            // "Back to pinned URL"; ⌘-click also keeps the current page in a new Today tab.
            controller?.resetToSaved(id, keepCurrent: event.modifierFlags.contains(.command))
            return
        }
        if event.clickCount == 2, let item = entry?.item {
            controller?.beginRename(itemID: item.id, in: self, titleFrame: title.frame)
            return
        }
        // SB-36: ⌘-click adds or removes the row, ⇧-click extends to it; the page shown stays.
        let flags = event.modifierFlags.intersection([.command, .shift])
        if !flags.isEmpty, let entry, let page {
            page.select(entry.id, extending: flags.contains(.shift))
            return
        }
        // A press on a row of the multi-selection may start dragging all of it; a plain click clears it on release.
        if let entry, page?.selection.contains(entry.id) != true { page?.clearSelection() }
        isPressed = true
        pressAnimation()
        // Arc: ⌥-click opens the tab in a split with the page on screen (an ⌥-drag still copies it, SB-35).
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .option, let entry, let c = controller,
           c.optionClickSplits(entry) {
            if page?.beginPossibleDrag(entry: entry, row: self, event: event) == false { c.optionClickSplit(entry) }
            isPressed = false
            return
        }
        // The page on screen before the press shows the tab: a drag onto the page splits with it (SV-1).
        let before = controller?.shownTabID
        if let entry { controller?.activate(entry: entry) }
        if let entry { page?.beginPossibleDrag(entry: entry, row: self, event: event, shownBefore: before) }
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click closes, like a tab strip.
        if event.buttonNumber == 2 { closeTapped() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entry else { return nil }
        if let page, page.selection.count > 1, page.selection.contains(entry.id) {
            return controller?.selectionMenu(ids: page.selection, spaceID: page.spaceID)
        }
        return controller?.menu(for: entry)
    }

    var titleField: NSTextField { title }

    override var dragTitle: String { title.stringValue }
    override var dragFavicon: CGImage? { favicon.cgImage }
    #if AIRC_TESTING
    var faviconViewForTesting: FaviconView { favicon }
    #endif
}

/// A folder row (SB-33): opens and closes on press, bold title.
final class FolderRowView: SidebarRowView {
    private(set) var item: Item?
    var depth = 0
    /// The folder glyph is a sublayer; the emoji label is made only for folders that have one.
    private let icon = CALayer()
    private var iconImage: NSImage?
    private var emoji: NSTextField?
    private let title = AircFadingLabel(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = AircFont.row.weight(.semibold).appFont
        title.lineBreakMode = .byClipping
        icon.contentsGravity = .center
        icon.actions = LayerImage.noActions
        layer?.addSublayer(icon)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Item, depth: Int, palette: Palette) {
        self.item = item
        self.depth = depth
        self.palette = palette
        let text = TextLimits.clip(item.displayTitle)
        if title.stringValue != text { title.stringValue = text }
        if title.textColor != palette.textPrimary { title.textColor = palette.textPrimary }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let e = item.icon, !e.isEmpty {
            let field = emoji ?? {
                let f = NSTextField(labelWithString: "")
                f.font = NSFont.systemFont(ofSize: AircMetrics.Footer.spaceEmoji)
                f.alignment = .center
                addSubview(f)
                emoji = f
                return f
            }()
            if field.stringValue != e { field.stringValue = e }
            field.isHidden = false
            icon.isHidden = true
        } else {
            emoji?.isHidden = true
            icon.isHidden = false
            // The outline folder in the accent, filled at 0.9 when open (visual review #6).
            let img = AircFolderGlyph.image(isOpen: !item.isCollapsed, theme: palette.resolved)
            if img !== iconImage {
                iconImage = img
                LayerImage.set(img, on: icon, in: self)
            }
        }
        CATransaction.commit()
        updateStyle()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let iconImage, LayerImage.scaleChanged(icon, in: self) { LayerImage.set(iconImage, on: icon, in: self) }
    }

    override func layout() {
        super.layout()
        let indent = CGFloat(depth) * AircMetrics.Row.folderIndent
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.frame = NSRect(x: AircMetrics.Row.faviconX + indent - 2, y: (h - 22) / 2, width: 22, height: 22)
        CATransaction.commit()
        emoji?.frame = NSRect(x: AircMetrics.Row.faviconX + indent - 2, y: (h - 20) / 2, width: 22, height: 20)
        let x = AircMetrics.Row.titleX + indent - DesignGaps.labelInset
        title.frame = NSRect(x: x, y: (h - 18) / 2, width: max(0, bounds.width - x - AircMetrics.Row.titleTrailing), height: 18)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let item { controller?.folderPreview.hoverBegan(folder: item, row: self) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.folderPreview.hoverEnded()
    }

    override func mouseDown(with event: NSEvent) {
        guard let item else { return }
        controller?.folderPreview.hide()
        if event.clickCount == 2 {
            controller?.beginRename(itemID: item.id, in: self, titleFrame: title.frame)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .shift])
        if !flags.isEmpty, let page {
            page.select(item.id, extending: flags.contains(.shift))
            return
        }
        if page?.selection.contains(item.id) != true { page?.clearSelection() }
        isPressed = true
        pressAnimation()
        controller?.toggleFolder(item.id)
        page?.beginPossibleDrag(entry: .folder(item, depth: depth), row: self, event: event)
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item else { return nil }
        if let page, page.selection.count > 1, page.selection.contains(item.id) {
            return controller?.selectionMenu(ids: page.selection, spaceID: page.spaceID)
        }
        return controller?.menu(for: .folder(item, depth: depth))
    }

    var titleField: NSTextField { title }

    override var spokenTitle: String? { item?.displayTitle }

    override var dragTitle: String { item?.displayTitle ?? "" }
    override var dragFavicon: CGImage? {
        var r = NSRect(x: 0, y: 0, width: 32, height: 32)
        if let e = item?.icon, !e.isEmpty {
            let img = NSImage(size: r.size, flipped: false) { rect in
                let font = NSFont.systemFont(ofSize: 26)
                let s = NSAttributedString(string: e, attributes: [.font: font])
                let size = s.size()
                s.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
                return true
            }
            return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        }
        return iconImage?.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

/// The line between pinned and Today, with "Clear" on sidebar hover (SB-40).
final class DividerRowView: SidebarRowView {
    var spaceID = ""
    private let line = CALayer()
    private let clear = NSTextField(labelWithString: "Clear")
    private var clearHovered = false
    var sidebarHovered = false { didSet { clear.isHidden = !sidebarHovered } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        showsPlate = false
        layer?.addSublayer(line)
        clear.font = AircFont.micro.appFont
        clear.isHidden = true
        clear.toolTip = "Clear this Space’s unpinned tabs"
        addSubview(clear)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spaceID: String, palette: Palette) {
        self.spaceID = spaceID
        self.palette = palette
        line.backgroundColor = palette.separator.cgColor
        let ink = clearHovered ? palette.clearHover : palette.clearIdle
        if clear.textColor != ink { clear.textColor = ink }
        updateStyle()
    }

    override func layout() {
        super.layout()
        clear.sizeToFit()
        let cw = clear.frame.width
        let showClear = !clear.isHidden
        let lineRight = bounds.width - AircMetrics.Divider.inset - (showClear ? cw + 8 : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        line.frame = NSRect(x: AircMetrics.Divider.inset, y: 7, width: max(0, lineRight - AircMetrics.Divider.inset), height: 1 / scale)
        CATransaction.commit()
        clear.frame = NSRect(x: bounds.width - AircMetrics.Divider.inset - cw, y: 7 - clear.frame.height / 2,
                             width: cw, height: clear.frame.height)
    }

    override func mouseMoved(with event: NSEvent) {
        let over = clear.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil))
        if over != clearHovered {
            clearHovered = over
            clear.textColor = over ? palette.clearHover : palette.clearIdle
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        if !clear.isHidden, clear.frame.insetBy(dx: -4, dy: -4).contains(convert(event.locationInWindow, from: nil)) {
            controller?.clearToday()
        }
    }
}

/// "+ New Tab" (SB-41): opens the Command Bar; new tabs appear just below it.
final class NewTabRowView: SidebarRowView {
    private let plus = CALayer()
    private var plusColor: NSColor?
    private let label = NSTextField(labelWithString: "New Tab")
    var active = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.contentsGravity = .center
        plus.actions = LayerImage.noActions
        layer?.addSublayer(plus)
        label.font = AircFont.row.appFont
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: Palette, active: Bool) {
        self.palette = palette
        if plusColor != palette.textFaint {
            plusColor = palette.textFaint
            LayerImage.set(LayerImage.symbol("plus", size: 15, weight: .regular, color: palette.textFaint), on: plus, in: self)
        }
        if label.textColor != palette.textMuted { label.textColor = palette.textMuted }
        isSelected = active
        updateStyle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard LayerImage.scaleChanged(plus, in: self) else { return }
        plusColor = nil
        if let palette { configure(palette: palette, active: isSelected) }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plus.frame = NSRect(x: AircMetrics.Row.faviconX - 1, y: (h - 20) / 2, width: 20, height: 20)
        CATransaction.commit()
        let x = AircMetrics.Row.titleX - DesignGaps.labelInset
        label.frame = NSRect(x: x, y: (h - 18) / 2, width: bounds.width - x - 17, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        pressAnimation()
        controller?.openCommandBar(mode: .newTab)
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }
}

/// SP-12: right after a Space gets a fresh profile, offer Google sign-in at the top of Today. The card is AircDesign's
/// (design.md §7 "Sign in to Google", visual review #3): the G, the copy, Sign in in the accent, Not now and ✕.
final class SignInCardView: SidebarRowView {
    private let card = AircSignInCardView(theme: DesignTheme.default.resolved(systemIsDark: false))
    var spaceID = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        showsPlate = false
        card.onSignIn = { [weak self] in
            guard let self else { return }
            if self.controller?.store.profile(ofSpace: self.spaceID).signInState == .offered {
                self.controller?.addGoogleFavorites(spaceID: self.spaceID)
            } else {
                self.controller?.signInToGoogle(spaceID: self.spaceID)
            }
        }
        card.onNotNow = { [weak self] in
            guard let self else { return }
            self.controller?.dismissSignInCard(spaceID: self.spaceID)
        }
        card.onDismiss = { [weak self] in
            guard let self else { return }
            self.controller?.dismissSignInCard(spaceID: self.spaceID)
        }
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spaceID: String, palette: Palette) {
        self.spaceID = spaceID
        self.palette = palette
        let profile = controller?.store.profile(ofSpace: spaceID)
        card.account = profile?.signInState == .offered ? profile?.googleAccount : nil
        card.theme = palette.resolved
    }

    override func layout() {
        super.layout()
        let inset = AircMetrics.Sidebar.inset
        card.frame = NSRect(x: inset, y: 0, width: bounds.width - 2 * inset, height: bounds.height)
    }
}
