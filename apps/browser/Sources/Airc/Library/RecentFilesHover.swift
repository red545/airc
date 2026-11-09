// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

extension WindowController {
    private static var recentFilesKey = 0

    /// LIB-1: the recent files over the footer's Library button.
    var recentFiles: RecentFilesHover {
        if let h = objc_getAssociatedObject(self, &Self.recentFilesKey) as? RecentFilesHover { return h }
        let h = RecentFilesHover(controller: self)
        objc_setAssociatedObject(self, &Self.recentFilesKey, h, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return h
    }
}

/// Arc's Library button hover (Arc ref §2.9): the pointer resting on the footer's Library button for `dwell` brings a
/// small card just above it with the last five downloads and Captures (icon, name, time). A click opens a file in its
/// app; a row drags out as the file. The card stays while the pointer goes from the button to it.
///
/// Like the tab preview card (TabPreview.swift): the button's own enter and exit events drive it, nothing runs on a mouse
/// move, and the event monitor exists only while the pointer is on the button or the card is up. It grows from the
/// button on the `grow` spring (Reduce Motion: a fade) and hides at once on a click elsewhere, a scroll, a key (Esc only
/// closes it) or a menu. Never while a mouse button is down (a drag), with the Library or a sheet open, or with nothing
/// to show. Private windows have no Library button, and their downloads and Captures are never listed (LibraryFiles).
final class RecentFilesHover {
    static let dwell: TimeInterval = 0.5
    /// Off the button or the card: this long to reach the other before the card hides.
    static let grace: TimeInterval = 0.22
    /// The button's top to the card.
    static let gap: CGFloat = 4

    private weak var c: WindowController?
    private(set) var card: RecentFilesCardView?
    private(set) var isShowing = false
    private var overButton = false
    private var overCard = false
    /// No card until the pointer leaves the button (it was clicked).
    private var suppressed = false
    private var menuOpen = false
    private var dwellWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var monitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var filesWatch: AnyCancellable?
    #if AIRC_TESTING
    /// Why the last dwell showed nothing (the scripted check reads it).
    private(set) var lastRefusal: String?
    #endif

    init(controller: WindowController) {
        c = controller
        let nc = NotificationCenter.default
        menuObservers = [
            nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = true
                self?.hide()
            },
            nc.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuOpen = false
            },
        ]
    }

    deinit {
        menuObservers.forEach(NotificationCenter.default.removeObserver)
        disarm()
    }

    // MARK: Hover

    /// The pointer entered or left the Library button (its tracking area's events).
    func buttonHover(_ inside: Bool) {
        overButton = inside
        if inside {
            hideWork?.cancel()
            guard !isShowing, !suppressed else { return }
            arm()
            // The list is worked out during the dwell (off the main thread), so it's ready when the card comes.
            LibraryFiles.shared.refresh()
            dwellWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.dwellEnded() }
            dwellWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
        } else {
            suppressed = false
            dwellWork?.cancel()
            dwellWork = nil
            if isShowing { scheduleHide() } else { disarm() }
        }
    }

    private func cardHover(_ inside: Bool) {
        overCard = inside
        if inside { hideWork?.cancel() } else if !overButton { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.overButton, !self.overCard else { return }
            // A row being dragged out: the card stays under the drag until the button comes up.
            if NSEvent.pressedMouseButtons != 0 { return self.scheduleHide() }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: work)
    }

    /// Why no card may show now, or nil.
    private func refusal(_ c: WindowController) -> String? {
        if NSEvent.pressedMouseButtons != 0 || c.dragsInProgress > 0 { return "a mouse button is down (a drag)" }
        if menuOpen { return "a menu is open" }
        if c.library != nil { return "the Library is open" }
        if c.window.attachedSheet != nil { return "a sheet is open" }
        if !c.window.isVisible { return "the window isn't on screen" }
        if c.sidebar.footer.libraryButton.isHiddenOrHasHiddenAncestor { return "the Library button is hidden" }
        if c.sidebarHidden, c.revealController?.isRevealed != true { return "the sidebar is hidden" }
        return nil
    }

    private func dwellEnded() {
        dwellWork = nil
        guard let c, overButton, !isShowing else { return }
        if let why = refusal(c) {
            #if AIRC_TESTING
            lastRefusal = why
            #endif
            return
        }
        let files = LibraryFiles.shared.recent
        guard !files.isEmpty else {
            #if AIRC_TESTING
            lastRefusal = "no recent files"
            #endif
            return
        }
        #if AIRC_TESTING
        lastRefusal = nil
        #endif
        show(files, in: c)
    }

    private func show(_ files: [LibraryFile], in c: WindowController) {
        let card = self.card ?? makeCard()
        card.apply(files: files, palette: c.currentPalette)
        card.frame = Self.frame(rows: files.count, in: c)
        c.root.addSubview(card, positioned: .below, relativeTo: c.toast)
        card.layoutSubtreeIfNeeded()
        isShowing = true
        overCard = false
        // The tooltip would land on the card.
        c.sidebar.footer.libraryButton.toolTip = nil
        present(card)
        // A download finishing or a file deleted while it's up.
        filesWatch = LibraryFiles.shared.$recent.dropFirst().removeDuplicates().sink { [weak self] files in
            guard let self, let c = self.c, self.isShowing, let card = self.card else { return }
            guard !files.isEmpty else { return self.hide() }
            card.apply(files: files, palette: c.currentPalette)
            card.frame = Self.frame(rows: files.count, in: c)
        }
    }

    /// Hides at once (one frame, like the tab preview).
    func hide() {
        dwellWork?.cancel()
        dwellWork = nil
        hideWork?.cancel()
        filesWatch = nil
        if isShowing {
            isShowing = false
            overCard = false
            card?.layer?.removeAllAnimations()
            card?.removeFromSuperview()
            c?.sidebar.footer.libraryButton.toolTip = SpaceBarView.libraryToolTip
        }
        if !overButton { disarm() }
    }

    private func makeCard() -> RecentFilesCardView {
        let v = RecentFilesCardView(frame: .zero)
        v.onHover = { [weak self] inside in self?.cardHover(inside) }
        v.onOpen = { [weak self] f in
            self?.hide()
            LibraryFiles.shared.open(f)
        }
        card = v
        return v
    }

    /// Just above the Library button, its left edge on the button's (its right edge on the sidebar's right edge's
    /// side when the sidebar is on the right, WIN-5), kept inside the window.
    static func frame(rows: Int, in c: WindowController) -> NSRect {
        let m = RecentFilesCardView.margin, w = RecentFilesCardView.width, h = RecentFilesCardView.height(rows: rows)
        let b = c.sidebar.footer.libraryButton
        let button = b.convert(b.bounds, to: c.root)
        let x = c.sidebarOnRight ? max(8, button.maxX - w) : min(button.minX, c.root.bounds.width - w - 8)
        let bottom = button.minY - gap
        let top = max(8, bottom - h)
        return NSRect(x: x - m, y: top - m, width: w + 2 * m, height: h + 2 * m).integral
    }

    private var reduceMotion: Bool {
        #if AIRC_TESTING
        if let o = TabPreviewController.reduceMotionOverride { return o }
        #endif
        return onMain { AircMotion.prefersReducedMotion }
    }

    /// Grows up out of the button on the popover spring and fades in (Reduce Motion: a 150 ms fade).
    private func present(_ card: RecentFilesCardView) {
        guard let layer = card.layer else { return }
        if reduceMotion { return layer.fade(from: 0, to: 1, duration: AircMotion.reducedDuration) }
        // A flipped view's layer has its origin at the top left: scale about the card's bottom corner over the button.
        let r = card.cardRect
        let p = CGPoint(x: c?.sidebarOnRight == true ? r.maxX : r.minX, y: r.maxY)
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, 0.94, 0.94, 1)
        t = CATransform3DTranslate(t, -p.x, -p.y, 0)
        layer.add(AircSpring.grow.caAnimation(keyPath: "transform", from: NSValue(caTransform3D: t),
                                              to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "grow")
        layer.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration)
    }

    // MARK: Events

    private func arm() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
            self?.handle(e) ?? e
        }
    }

    private func disarm() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // The card's own rows (a click opens, a press may start a drag).
            if isShowing, let card, e.window === c?.window, card.cardRect.contains(card.convert(e.locationInWindow, from: nil)) {
                return e
            }
            if overButton { suppressed = true }
            hide()
        case .scrollWheel:
            hide()
        case .keyDown:
            let wasShowing = isShowing
            if overButton { suppressed = true }
            hide()
            if wasShowing, e.keyCode == 53 { return nil }   // Esc closes the card and nothing else
        default:
            break
        }
        return e
    }

    #if AIRC_TESTING
    /// The files the card lists now.
    var shownFiles: [LibraryFile] { isShowing ? card?.files ?? [] : [] }
    /// The card's hover, as its tracking area would report it.
    func testCardHover(_ inside: Bool) { cardHover(inside) }
    #endif
}

extension SpaceBarView {
    static let libraryToolTip = "View Library ⇧⌘L"
}

/// The recent-files card: the Space's `surface` at `popover` elevation, like the tab preview card, with its rows in a
/// SwiftUI host. The view is larger than the card by the shadow's reach and hit-tests only the card.
final class RecentFilesCardView: NSView {
    static let width: CGFloat = 264
    static let margin: CGFloat = 24
    static let header: CGFloat = 30
    static let rowHeight: CGFloat = 40
    static let inset: CGFloat = 6
    static func height(rows: Int) -> CGFloat { header + CGFloat(rows) * rowHeight + inset }

    var onHover: ((Bool) -> Void)?
    var onOpen: ((LibraryFile) -> Void)?
    private(set) var files: [LibraryFile] = []
    private let ambient = CALayer()
    private let plate = CALayer()
    private var host: AircFirstClickHostingView<RecentFilesList>?
    private var palette: Palette?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [ambient, plate] {
            l.actions = LayerImage.noActions.merging(["backgroundColor": NSNull(), "borderColor": NSNull(), "shadowPath": NSNull()]) { a, _ in a }
            l.cornerCurve = .continuous
            l.cornerRadius = AircRadius.popover
        }
        layer?.addSublayer(ambient)
        layer?.addSublayer(plate)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cardRect: NSRect {
        NSRect(x: Self.margin, y: Self.margin, width: bounds.width - 2 * Self.margin, height: bounds.height - 2 * Self.margin)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, cardRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    func apply(files: [LibraryFile], palette p: Palette) {
        self.files = files
        let t = p.resolved
        if palette != p {
            palette = p
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.backgroundColor = t.surface.nsColor.cgColor
            plate.borderColor = t.surfaceBorder.nsColor.cgColor
            plate.borderWidth = 0.5
            plate.applyAircShadow(.popover)
            if let a = AircShadow.popover.layers.dropFirst().first {
                ambient.backgroundColor = t.surface.nsColor.cgColor
                ambient.shadowColor = a.color.alpha(1).cgColor
                ambient.shadowOpacity = Float(a.color.alpha)
                ambient.shadowRadius = a.radius
                ambient.shadowOffset = CGSize(width: a.x, height: -a.y)
            }
            CATransaction.commit()
        }
        let list = RecentFilesList(files: files, theme: t) { [weak self] in self?.onOpen?($0) }
        if let host {
            host.rootView = list
        } else {
            let h = AircFirstClickHostingView(rootView: list)
            h.wantsLayer = true
            h.layer?.cornerRadius = AircRadius.popover
            h.layer?.cornerCurve = .continuous
            h.layer?.masksToBounds = true
            addSubview(h)
            host = h
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let r = cardRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = r
        ambient.frame = r
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: AircRadius.popover,
                          cornerHeight: AircRadius.popover, transform: nil)
        plate.shadowPath = path
        ambient.shadowPath = path
        CATransaction.commit()
        host?.frame = r
    }
}

/// The card's contents: "Recent", then one row per file.
struct RecentFilesList: View {
    let files: [LibraryFile]
    let theme: ResolvedTheme
    let onOpen: (LibraryFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent").aircFont(AircFont.caption.weight(.medium)).foregroundStyle(theme.surfaceTextTertiary.color)
                .padding(.horizontal, 14)
                .frame(height: RecentFilesCardView.header, alignment: .center)
            ForEach(files) { f in RecentFileRow(file: f, theme: theme) { onOpen(f) } }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RecentFilesCardView.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .testAnchorRoot()
    }
}

private struct RecentFileRow: View {
    let file: LibraryFile
    let theme: ResolvedTheme
    let onOpen: () -> Void
    @State private var hovered = false
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale
    private static let icon: CGFloat = 28

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .frame(width: Self.icon, height: Self.icon)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().interpolation(.high)
                        .frame(width: Self.icon, height: Self.icon)
                }
            }
            .frame(width: Self.icon, height: Self.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).aircFont(AircFont.row).foregroundStyle(theme.surfaceText.color).lineLimit(1).truncationMode(.middle)
                Text(Self.when(file.date)).aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: RecentFilesCardView.rowHeight)
        .background(RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous).fill(hovered ? theme.surfaceHover.color : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .help(file.name)
        .testAnchor("library.recent.\(file.name)")
        .task(id: "\(file.id)|\(file.date.timeIntervalSince1970)") {
            // Pictures for images and videos; other files keep their icon.
            guard file.kind != .other else { return }
            if let hit = LibraryThumbnails.shared.cached(file, side: Self.icon, scale: scale) { image = hit; return }
            LibraryThumbnails.shared.thumbnail(file, side: Self.icon, scale: scale) { got in if let got { image = got } }
        }
    }

    /// "Just now", "12 min ago", "Yesterday, 18:04", "3 Nov".
    static func when(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday, " + d.formatted(date: .omitted, time: .shortened) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}
