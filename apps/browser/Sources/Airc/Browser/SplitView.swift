// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import QuartzCore

/// SV-1 Split View (spec §2.16b): 2–4 pages side by side or stacked in the page card's place, each in its own card,
/// with the window's margin between them. The engine attaches each tab's page to its pane's host view
/// (`EngineWindow.presentPanes`); every pane stays live and keeps its own profile. Dividers in the gaps resize the
/// panes; a release near an even split, a double-click, or a pane coming or going settles on a spring.
///
/// Speed: a divider tick only sets the panes' frames (the engine's page views autoresize; no reattach, no store write,
/// no sidebar work); the sizes are saved when the drag ends.
final class SplitContainerView: NSView {
    weak var controller: WindowController?
    private(set) var panes: [SplitPaneView] = []
    private(set) var dividers: [SplitDividerView] = []
    private(set) var splitID: String?
    private(set) var axis: SplitAxis = .horizontal
    /// The shares shown now (they move during a drag or a spring).
    private(set) var fractions: [Double] = []
    private var palette: Palette?
    var tabIDs: [String] { panes.map(\.tabID) }
    /// Arc's Expand Current Split (P06c, Browser/SplitExtras.swift): this pane fills the split's place and the others
    /// wait behind it, live and at their sizes; the shares aren't touched, so restoring brings the split back as it was.
    var expandedTabID: String?

    /// The window's margin (the card's inset) between panes.
    static let gap: CGFloat = AircMetrics.Window.cardInset
    /// A release this close to an even split of the two panes settles on it.
    static let snapDistance: CGFloat = 16

    /// Main-thread cost of each divider tick (fractions → frames → the page views' autoresize), for the checks.
    static var dividerTickMs: [Double] = []
    /// Checks only: each tick also commits its Core Animation transaction inside the measurement, so a tick's time is
    /// its whole main-thread frame cost (the commit otherwise runs at the end of the run-loop turn).
    static var measureCommit = false
    /// Checks only: the pane whose controls a click on its handle opened last (scripted runs don't open the menu).
    static var paneMenuShown: String?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(controller: WindowController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Panes for `split`'s tabs, in order (existing pane views are reused by tab, so a page never moves to another
    /// host just because a pane came or went). `animated`: the panes spring from where they are to the split's sizes.
    func configure(_ split: Split, tabIDs ids: [String], palette: Palette, animated: Bool) {
        let keepsExpanded = expansionSurvives(split, ids)
        let previous = Dictionary(uniqueKeysWithValues: panes.map { ($0.tabID, $0) })
        let oldFrames = Dictionary(uniqueKeysWithValues: panes.map { ($0.tabID, $0.frame) })
        let changed = ids != tabIDs || split.axis != axis
        var next: [SplitPaneView] = []
        for id in ids {
            let p = previous[id] ?? SplitPaneView(theme: palette.resolved)
            p.onHandlePress = { [weak self, weak p] e in
                guard let self, let p else { return }
                self.controller?.dragPaneOut(p.tabID, event: e)
            }
            p.onHandleMenu = { [weak self, weak p] in
                guard let self, let p else { return nil }
                return self.controller?.paneMenu(p.tabID)
            }
            p.tabID = id
            if p.superview !== self { addSubview(p) }
            next.append(p)
        }
        for p in panes where !ids.contains(p.tabID) { p.removeFromSuperview() }
        panes = next
        while dividers.count < max(0, ids.count - 1) {
            let d = SplitDividerView()
            d.container = self
            addSubview(d)
            dividers.append(d)
        }
        while dividers.count > max(0, ids.count - 1) { dividers.removeLast().removeFromSuperview() }
        for (i, d) in dividers.enumerated() { d.index = i; d.axis = split.axis }
        let target = Split.normalized(split.fractions, count: ids.count)
        splitID = split.id
        axis = split.axis
        setPalette(palette)
        controller?.animator.cancel("split")
        if keepsExpanded {
            fractions = target
            return layoutExpanded()
        }
        if animated, changed, bounds.width > 0, !oldFrames.isEmpty {
            // New panes grow from nothing where they land; the others glide from their old place.
            let start = panes.map { p -> NSRect in
                oldFrames[p.tabID] ?? Self.collapsed(at: p, among: panes, frames: oldFrames, axis: split.axis, in: bounds)
            }
            animateFrames(from: start, to: target)
        } else if animated, !changed, target != fractions, bounds.width > 0 {
            spring(to: target, spring: Spring(AircSpring.settle))
        } else {
            fractions = target
            needsLayout = true
        }
    }

    func setPalette(_ p: Palette) {
        palette = p
        for pane in panes { pane.setTheme(p) }
        for d in dividers { d.palette = p }
    }

    func setFocused(_ tabID: String?) {
        // Another pane takes the keyboard: the split comes back first.
        if let e = expandedTabID, let tabID, tabID != e, tabIDs.contains(tabID) { setExpanded(nil, animated: true) }
        for p in panes { p.focused = panes.count > 1 && expandedTabID == nil && p.tabID == tabID }
    }

    func pane(for tabID: String) -> SplitPaneView? { panes.first { $0.tabID == tabID } }

    /// The pane under a window point.
    func paneTabID(at windowPoint: NSPoint) -> String? {
        let p = convert(windowPoint, from: nil)
        if let e = expandedTabID { return bounds.contains(p) ? e : nil }
        return panes.first { $0.frame.contains(p) }?.tabID
    }

    // MARK: Geometry

    private var length: CGFloat { axis == .horizontal ? bounds.width : bounds.height }
    private var usable: CGFloat { max(0, length - CGFloat(max(panes.count - 1, 0)) * Self.gap) }
    /// The smallest a pane gets along the axis.
    var minPane: CGFloat { min(200, usable / CGFloat(max(panes.count, 1)) * 0.6) }

    func frames(for f: [Double]) -> [NSRect] {
        var out: [NSRect] = []
        var pos: CGFloat = 0
        let u = usable
        for (i, share) in f.enumerated() {
            // Whole points (the last pane takes the rest), so pages don't blur at the seams.
            let size = i == f.count - 1 ? max(0, length - pos) : (CGFloat(share) * u).rounded()
            out.append(axis == .horizontal ? NSRect(x: pos, y: 0, width: size, height: bounds.height)
                                           : NSRect(x: 0, y: pos, width: bounds.width, height: size))
            pos += size + Self.gap
        }
        return out
    }

    override func layout() {
        super.layout()
        if expandedTabID != nil { return layoutExpanded() }
        apply(frames(for: fractions))
    }

    override var isHidden: Bool {
        // The split leaves the screen: an expanded pane ends there.
        didSet { if isHidden, expandedTabID != nil { dropExpansion() } }
    }

    func apply(_ rects: [NSRect]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (p, r) in zip(panes, rects) where p.frame != r { p.frame = r }
        for (i, d) in dividers.enumerated() where i + 1 < rects.count {
            if d.isHidden != (expandedTabID != nil) { d.isHidden = expandedTabID != nil }
            let a = rects[i], g = Self.gap
            let r = axis == .horizontal ? NSRect(x: a.maxX - 2, y: 0, width: g + 4, height: bounds.height)
                                        : NSRect(x: 0, y: a.maxY - 2, width: bounds.width, height: g + 4)
            if d.frame != r { d.frame = r }
        }
        CATransaction.commit()
    }

    /// Where a new pane starts: a zero-size strip at its slot.
    private static func collapsed(at pane: SplitPaneView, among panes: [SplitPaneView], frames: [String: NSRect],
                                  axis: SplitAxis, in bounds: NSRect) -> NSRect {
        let i = panes.firstIndex { $0 === pane } ?? 0
        let before = panes[..<i].compactMap { frames[$0.tabID] }.last
        let edge = before.map { axis == .horizontal ? $0.maxX : $0.maxY } ?? 0
        return axis == .horizontal ? NSRect(x: edge, y: 0, width: 0, height: bounds.height)
                                   : NSRect(x: 0, y: edge, width: bounds.width, height: 0)
    }

    // MARK: Motion

    /// A window nobody can see (behind others, or the screen locked) gets no display frames: it takes the end state
    /// at once instead of waiting for a spring that would never run.
    var canAnimate: Bool { window?.occlusionState.contains(.visible) == true && controller != nil }

    /// The shares spring to `target` (layout changes, a snap after a drag, a double-click).
    func spring(to target: [Double], spring: Spring, velocity: Double = 0, completion: (() -> Void)? = nil) {
        let from = fractions
        guard from.count == target.count, canAnimate else {
            fractions = target
            apply(frames(for: target))
            completion?()
            return
        }
        controller?.animator.spring("split", from: 0, to: 1, velocity: velocity, spring: spring, update: { [weak self] p in
            guard let self else { return }
            self.fractions = zip(from, target).map { $0 + ($1 - $0) * p }
            self.apply(self.frames(for: self.fractions))
        }, completion: completion)
    }

    /// Pane frames spring from `start` to the frames of `target` shares (panes coming or going).
    private func animateFrames(from start: [NSRect], to target: [Double]) {
        fractions = target
        let end = frames(for: target)
        guard canAnimate else { return apply(end) }
        apply(start)
        controller?.animator.spring("split", from: 0, to: 1, spring: Spring(AircSpring.settle), update: { [weak self] p in
            guard let self else { return }
            let t = CGFloat(p)
            let rects = zip(start, end).map { a, b in
                NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                       width: max(0, a.width + (b.width - a.width) * t), height: max(0, a.height + (b.height - a.height) * t))
            }
            self.apply(rects)
        }, completion: { [weak self] in self?.needsLayout = true })
    }

    // MARK: Dividers

    private var dragStart: (sizes: [CGFloat], point: CGFloat)?

    func beginDividerDrag(_ index: Int, at windowPoint: NSPoint) {
        controller?.animator.cancel("split")
        let p = convert(windowPoint, from: nil)
        dragStart = (fractions.map { CGFloat($0) * usable }, axis == .horizontal ? p.x : p.y)
    }

    /// One tick: the two panes beside divider `index` share the travel; the others hold still.
    func dragDivider(_ index: Int, to windowPoint: NSPoint) {
        guard let start = dragStart, index + 1 < start.sizes.count else { return }
        let t0 = CACurrentMediaTime()
        let p = convert(windowPoint, from: nil)
        let delta = (axis == .horizontal ? p.x : p.y) - start.point
        var sizes = start.sizes
        let pair = sizes[index] + sizes[index + 1], m = minPane
        sizes[index] = min(max(sizes[index] + delta, m), pair - m)
        sizes[index + 1] = pair - sizes[index]
        let u = max(usable, 1)
        fractions = sizes.map { Double($0 / u) }
        apply(frames(for: fractions))
        if Self.measureCommit { CATransaction.flush() }
        Self.dividerTickMs.append((CACurrentMediaTime() - t0) * 1000)
        if Self.dividerTickMs.count > 2000 { Self.dividerTickMs.removeFirst(1000) }
    }

    /// The drag ended: near an even split of the two panes it settles there; the sizes are saved.
    func endDividerDrag(_ index: Int) {
        dragStart = nil
        guard index + 1 < fractions.count else { return }
        let u = usable
        let a = CGFloat(fractions[index]) * u, b = CGFloat(fractions[index + 1]) * u
        if abs(a - b) < Self.snapDistance * 2, a != b {
            var target = fractions
            let even = (fractions[index] + fractions[index + 1]) / 2
            target[index] = even
            target[index + 1] = even
            spring(to: target, spring: Spring(AircSpring.row)) { [weak self] in self?.commit() }
        } else {
            commit()
        }
    }

    /// Double-click on a divider: every pane the same size.
    func equalize() {
        let even = Array(repeating: 1 / Double(max(panes.count, 1)), count: panes.count)
        spring(to: even, spring: Spring(AircSpring.settle)) { [weak self] in self?.commit() }
    }

    private func commit() {
        guard let id = splitID else { return }
        controller?.store.setSplitFractions(id, fractions)
    }
}

/// One pane: a page card with the single card's look (AircPageCardView: the theme's card shadow, `surface` clipped to
/// 6 pt circular corners, a 0.5 pt inside hairline) holding the engine's page, and a quiet ring while it has the
/// keyboard. Built from layers only (a layer border for the hairline, as AircPageCardView now has too): a hairline
/// drawn in `draw(_:)` re-rasterised a pane-sized bitmap on every divider tick (~1 ms a pane).
final class SplitPaneView: NSView {
    let host = PageHostView()
    /// The grab handle at the pane's top centre: shows while the pointer is near the top; drag it to take the pane out.
    let handle = PaneHandleView()
    private(set) var dragStrip: PageTopDragStrip!
    /// The handle was pressed (WindowController.dragPaneOut).
    var onHandlePress: ((NSEvent) -> Void)?
    /// Arc's Split View Controls for this pane (the handle's right-click).
    var onHandleMenu: (() -> NSMenu?)?
    private let clip = NSView()
    private let shadowPlate = CALayer()
    private let hairline = CALayer()
    private let ring = CALayer()
    var tabID = ""
    var focused = false { didSet { if focused != oldValue { ring.isHidden = !focused } } }

    init(theme: ResolvedTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "shadowPath": NSNull()]
        shadowPlate.actions = still
        shadowPlate.zPosition = -1
        layer?.addSublayer(shadowPlate)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .circular
        clip.layer?.cornerRadius = AircMetrics.Window.cardRadius
        clip.autoresizingMask = [.width, .height]
        addSubview(clip)
        host.wantsLayer = true
        host.autoresizesSubviews = true
        host.autoresizingMask = [.width, .height]
        clip.addSubview(host)
        // W07: the top of the pane's page drags the window too (Browser/PageDrag.swift), beside the handle.
        dragStrip = PageTopDragStrip.install(in: clip)
        dragStrip.page = host
        hairline.actions = still
        hairline.borderWidth = 0.5
        hairline.cornerCurve = .circular
        hairline.cornerRadius = AircMetrics.Window.cardRadius
        hairline.zPosition = 5
        layer?.addSublayer(hairline)
        ring.isHidden = true
        ring.borderWidth = 1.5
        ring.cornerCurve = .circular
        ring.cornerRadius = AircMetrics.Window.cardRadius + 2
        ring.actions = still
        layer?.addSublayer(ring)
        handle.onPress = { [weak self] e in self?.onHandlePress?(e) }
        handle.onMenu = { [weak self] in self?.onHandleMenu?() }
        addSubview(handle)
        apply(theme)
    }

    /// The band along the top where the handle shows.
    static let handleBand: CGFloat = 36

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func apply(_ theme: ResolvedTheme) {
        handle.apply(theme)
        let s = theme.pageCardShadow
        let key = s.layers.first
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowPlate.shadowColor = (key?.color.alpha(1) ?? .black()).cgColor
        shadowPlate.shadowOpacity = Float(key?.color.alpha ?? 0)
        shadowPlate.shadowRadius = key?.radius ?? 0
        shadowPlate.shadowOffset = CGSize(width: key?.x ?? 0, height: -(key?.y ?? 0))
        clip.layer?.backgroundColor = theme.surface.cgColor
        hairline.borderColor = (s.hairline ?? .clear).cgColor
        CATransaction.commit()
    }

    func setTheme(_ p: Palette) {
        apply(p.resolved)
        ring.borderColor = p.textPrimary.withAlphaComponent(p.isDark ? 0.42 : 0.30).cgColor
    }

    /// The page resizes in the same call (autoresizing), not in a later layout pass: a divider tick is one frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayers()
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    private func updateLayers() {
        if clip.frame != bounds { clip.frame = bounds }
        if host.frame != clip.bounds { host.frame = clip.bounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowPlate.frame = bounds
        let r = AircMetrics.Window.cardRadius
        shadowPlate.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        hairline.frame = bounds
        ring.frame = bounds.insetBy(dx: -2.5, dy: -2.5)
        CATransaction.commit()
        let hf = NSRect(x: 0, y: 0, width: bounds.width, height: Self.handleBand)
        if handle.frame != hf { handle.frame = hf }
    }
}

/// A pane's grab handle (SV-1): a small capsule on a plate at the top centre of the page, in the theme's surface so it
/// reads on light and dark pages. A click opens Arc's Split View Controls for the pane (so does a right-click). The view is the pane's top band: it shows the handle while the pointer is in the band
/// (a tracking area added once, `inVisibleRect`, so dividers' live resizes don't churn it: a pane-level tracking area
/// rebuilt on every resize threw the divider drag off). Only the capsule takes clicks, and only while it shows, so the
/// page keeps its top edge; the open-hand cursor over it; a drag lifts the pane out of the split.
final class PaneHandleView: NSView {
    static let size = NSSize(width: 56, height: 16)
    var onPress: ((NSEvent) -> Void)?
    var onMenu: (() -> NSMenu?)?
    private(set) var isShown = false
    var isDragging = false
    private let plate = CALayer()
    private let grip = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull()]
        plate.actions = still
        grip.actions = still
        plate.cornerRadius = 7
        plate.cornerCurve = .continuous
        plate.borderWidth = 0.5
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowOpacity = 0.16
        plate.shadowRadius = 3
        plate.shadowOffset = CGSize(width: 0, height: -1)
        grip.cornerRadius = 1.5
        layer?.addSublayer(plate)
        plate.addSublayer(grip)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Move pane")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The capsule's rectangle (what takes the press), centred at the band's top.
    var grabRect: NSRect {
        NSRect(x: ((bounds.width - Self.size.width) / 2).rounded(), y: 4, width: Self.size.width, height: Self.size.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }
    }

    override func mouseEntered(with event: NSEvent) { setShown(true) }
    override func mouseExited(with event: NSEvent) { if !isDragging { setShown(false) } }

    func apply(_ theme: ResolvedTheme) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = theme.surface.cgColor
        plate.borderColor = theme.surfaceBorder.cgColor
        grip.backgroundColor = theme.surfaceTextTertiary.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let g = grabRect
        plate.frame = NSRect(x: g.minX + 8, y: g.minY + 2, width: g.width - 16, height: 12)
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        grip.frame = NSRect(x: (plate.bounds.width - 20) / 2, y: (plate.bounds.height - 3) / 2, width: 20, height: 3)
        CATransaction.commit()
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown, let layer else { return }
        isShown = shown
        layer.fade(from: layer.presentation()?.opacity ?? layer.opacity, to: shown ? 1 : 0, duration: shown ? 0.12 : 0.2)
        window?.invalidateCursorRects(for: self)
    }

    // Click-through except the capsule while it shows: the page under the band keeps its clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, let sv = superview else { return nil }
        return grabRect.contains(convert(point, from: sv)) ? self : nil
    }
    override func resetCursorRects() { if isShown { addCursorRect(grabRect, cursor: .openHand) } }
    override func mouseDown(with event: NSEvent) { onPress?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
}

/// The gap between two panes. Drag to resize (the cursor shows which way); double-click evens the panes out. A short
/// grabber shows while the pointer is over it.
final class SplitDividerView: NSView {
    weak var container: SplitContainerView?
    var index = 0
    var axis: SplitAxis = .horizontal { didSet { if axis != oldValue { window?.invalidateCursorRects(for: self); needsLayout = true } } }
    var palette: Palette? { didSet { grip.backgroundColor = palette?.textPrimary.withAlphaComponent(0.32).cgColor } }
    private let grip = CALayer()
    private var hovered = false { didSet { if hovered != oldValue { updateGrip() } } }
    private var dragging = false { didSet { if dragging != oldValue { updateGrip() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grip.cornerRadius = 1.5
        grip.opacity = 0
        layer?.addSublayer(grip)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// AppKit's (private) question for a view in the titlebar band: the window server mustn't drag the window here.
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let long: CGFloat = 32, thick: CGFloat = 3
        grip.frame = axis == .horizontal
            ? NSRect(x: (bounds.width - thick) / 2, y: (bounds.height - long) / 2, width: thick, height: long)
            : NSRect(x: (bounds.width - long) / 2, y: (bounds.height - thick) / 2, width: long, height: thick)
        CATransaction.commit()
    }

    private func updateGrip() {
        let to: Float = hovered || dragging ? 1 : 0
        guard grip.opacity != to else { return }
        grip.fade(from: grip.opacity, to: to, duration: to > 0 ? 0.12 : 0.2)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { container?.equalize(); return }
        dragging = true
        container?.beginDividerDrag(index, at: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) { container?.dragDivider(index, to: event.locationInWindow) }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        container?.endDividerDrag(index)
    }
}

/// Where a tab dragged from the sidebar onto the page would go (Arc 101: "Drag a tab from your sidebar into the middle
/// of the screen to create a Split View"): the half of the page it's nearest to.
struct SplitDropZone: Equatable {
    var axis: SplitAxis
    /// Left or top.
    var leading: Bool

    /// The zone for a point in `rect` (both in one coordinate space, y down): the nearest edge's half.
    static func at(_ p: NSPoint, in rect: NSRect) -> SplitDropZone {
        let dl = p.x - rect.minX, dr = rect.maxX - p.x, dt = p.y - rect.minY, db = rect.maxY - p.y
        let m = min(dl, dr, dt, db)
        if m == dl { return SplitDropZone(axis: .horizontal, leading: true) }
        if m == dr { return SplitDropZone(axis: .horizontal, leading: false) }
        return SplitDropZone(axis: .vertical, leading: m == dt)
    }

    /// The part of `rect` (y down) the new pane would take.
    func preview(in rect: NSRect, gap: CGFloat) -> NSRect {
        let g = gap / 2
        switch (axis, leading) {
        case (.horizontal, true): return NSRect(x: rect.minX, y: rect.minY, width: rect.width / 2 - g, height: rect.height)
        case (.horizontal, false): return NSRect(x: rect.midX + g, y: rect.minY, width: rect.width / 2 - g, height: rect.height)
        case (.vertical, true): return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2 - g)
        case (.vertical, false): return NSRect(x: rect.minX, y: rect.midY + g, width: rect.width, height: rect.height / 2 - g)
        }
    }
}

/// The drop preview over the page while a tab is dragged there.
final class SplitDropPreviewView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AircMetrics.Window.cardRadius
        layer?.cornerCurve = .circular
        layer?.borderWidth = 2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ rect: NSRect, palette: Palette) {
        layer?.backgroundColor = palette.textPrimary.withAlphaComponent(0.10).cgColor
        layer?.borderColor = palette.textPrimary.withAlphaComponent(0.55).cgColor
        let wasHidden = isHidden
        if wasHidden {
            frame = rect
            isHidden = false
            layer?.fade(from: 0, to: 1, duration: 0.1)
        } else if frame != rect {
            setFrameAnimated(rect, animated: true, spring: Spring(AircSpring.row))
        }
    }

    func hide() { isHidden = true }
}
