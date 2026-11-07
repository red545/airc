// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import CoreImage

/// Header row (SB-1): sidebar toggle next to the traffic lights; back, forward, reload right-aligned. With the sidebar
/// on the right (WIN-5) the traffic lights stay over the page, so the toggle starts the row where it does in full screen.
final class SidebarHeaderView: NSView {
    weak var controller: WindowController?
    let toggle = GlyphButton(symbol: "sidebar.left", size: 14)
    let back = GlyphButton(symbol: "arrow.left", size: 14)
    let forward = GlyphButton(symbol: "arrow.right", size: 14)
    let reload = GlyphButton(symbol: "arrow.clockwise", size: 14)
    var fullscreen = false { didSet { needsLayout = true } }
    var onRight = false {
        didSet {
            guard onRight != oldValue else { return }
            toggle.symbol = onRight ? "sidebar.right" : "sidebar.left"
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in [toggle, back, forward, reload] { addSubview(b) }
        toggle.toolTip = "Hide sidebar (⌘S)"
        back.toolTip = "Back"
        forward.toolTip = "Forward"
        reload.toolTip = "Reload"
        toggle.action = { [weak self] in self?.controller?.toggleSidebar() }
        back.action = { [weak self] in self?.controller?.goBack() }
        forward.action = { [weak self] in self?.controller?.goForward() }
        reload.action = { [weak self] in self?.controller?.reloadOrStop() }
        // SB-1: right-click or a long press shows where Back and Forward go.
        back.menuProvider = { [weak self] in self?.controller?.historyMenu(forward: false) }
        forward.menuProvider = { [weak self] in self?.controller?.historyMenu(forward: true) }
        back.longPressMenu = true
        forward.longPressMenu = true
        back.commandAction = { [weak self] in self?.controller?.openHistoryInBackground(offset: -1) }
        forward.commandAction = { [weak self] in self?.controller?.openHistoryInBackground(offset: 1) }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func configure(palette: Palette, canGoBack: Bool, canGoForward: Bool, loading: Bool, hasPage: Bool) {
        for b in [toggle, back, forward, reload] {
            b.tint = palette.glyph
            b.hoverFill = palette.hover
        }
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        reload.isEnabled = hasPage
        reload.symbol = loading ? "xmark" : "arrow.clockwise"
    }

    override func layout() {
        super.layout()
        let s = AircMetrics.Sidebar.headerButton
        let y = AircMetrics.Sidebar.headerCenterY - s / 2
        let tx = fullscreen || onRight ? DesignGaps.toggleXFullscreen : AircMetrics.Sidebar.toggleX
        toggle.frame = NSRect(x: tx, y: y, width: s, height: s)
        let w = bounds.width
        reload.frame = NSRect(x: w - DesignGaps.headerButtonEndInset - s, y: y, width: s, height: s)
        forward.frame = reload.frame.offsetBy(dx: -AircMetrics.Sidebar.headerButtonPitch, dy: 0)
        back.frame = forward.frame.offsetBy(dx: -AircMetrics.Sidebar.headerButtonPitch, dy: 0)
        // A narrow sidebar drops buttons that would collide with the toggle (Arc ref §2.1).
        let minX = toggle.frame.maxX + 2
        back.isHidden = back.frame.minX < minX
        forward.isHidden = forward.frame.minX < minX
        reload.isHidden = reload.frame.minX < minX
    }
}

/// Pages one SpacePageView per Space horizontally (SP-21): finger tracking, rubber band at the ends,
/// a critically damped settle (0.19 s), at most one Space per swipe.
final class SpacePagerView: NSView {
    weak var controller: WindowController?
    let strip = FlippedView()
    private(set) var pages: [SpacePageView] = []
    /// Fractional page index under the sidebar.
    private(set) var position: Double = 0
    private var tracking = false
    private var startPage = 0
    private var rawPosition: Double = 0
    private var samples: [(t: CFTimeInterval, p: Double)] = []
    private var ignoringGesture = false
    lazy var animator = FrameAnimator(view: self)
    /// Pull-to-create (Arc, SP-21): a swipe past the last Space reveals a "+"; held past the detent it fills, pops
    /// 1.13× over 120 ms with a haptic, and letting go opens Create a Space.
    private let createIndicator = CALayer()
    private let createPlus = CAShapeLayer()
    private var createReady = false
    /// Raw overscroll (in pages) that arms the create state.
    static let createDetent = 0.32

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(strip)
        createIndicator.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        createIndicator.cornerRadius = 16
        createIndicator.opacity = 0
        createIndicator.actions = ["position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
        let plus = CGMutablePath()
        plus.move(to: CGPoint(x: 10, y: 16)); plus.addLine(to: CGPoint(x: 22, y: 16))
        plus.move(to: CGPoint(x: 16, y: 10)); plus.addLine(to: CGPoint(x: 16, y: 22))
        createPlus.path = plus
        createPlus.lineWidth = 2
        createPlus.lineCap = .round
        createPlus.frame = createIndicator.bounds
        createPlus.actions = ["strokeColor": NSNull()]
        createIndicator.addSublayer(createPlus)
        layer?.addSublayer(createIndicator)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    var pageWidth: CGFloat { max(bounds.width, 1) }
    var currentPage: Int { Int(position.rounded()) }
    var isTrackingOrSettling: Bool { tracking || animator.isRunning("settle") || CACurrentMediaTime() < coreSettleEnd }
    /// When a Core Animation settle (a click or key to a neighbouring Space) ends.
    private var coreSettleEnd: CFTimeInterval = 0

    /// Speed pass (§2.12): only the current page and its two neighbours are in the window. AppKit walks the whole
    /// view tree on every layout pass (`_findAnySubviewNeedingAutoLayoutEngine`), hidden views included, so the other
    /// Spaces' pages are detached: built and kept up to date, just not attached. Neighbours stay attached because
    /// attaching a page costs about 3 ms (each NSTextField re-resolves its appearance when it enters a window), which
    /// a switch to a neighbour can't afford in its first frame. Pages are attached or detached at idle (`settleTree`),
    /// never inside a switch, except a page that has to show right now. `held` keeps a page attached while it slides
    /// out (a Core Animation settle) or while a finger may bring it in (tracking).
    private var held: Set<ObjectIdentifier> = []
    private var treeSettleQueued = false

    func setPages(_ newPages: [SpacePageView]) {
        for p in pages where !newPages.contains(where: { $0 === p }) { p.removeFromSuperview() }
        pages = newPages
        for (i, p) in pages.enumerated() {
            p.scrollView.pager = self
            // A new page is sized now, so it renders at the sidebar's width while detached.
            if p.frame.size != pageSize { p.frame = pageFrame(i) }
        }
        needsLayout = true
    }

    private var pageSize: NSSize { NSSize(width: pageWidth, height: bounds.height) }
    private func pageFrame(_ i: Int) -> NSRect { NSRect(origin: NSPoint(x: CGFloat(i) * pageWidth, y: 0), size: pageSize) }

    override func layout() {
        super.layout()
        // Attached pages follow the sidebar's size every pass; detached ones when they come back (`attach`).
        for (i, p) in pages.enumerated() where p.superview === strip { p.frame = pageFrame(i) }
        strip.frame = NSRect(x: 0, y: 0, width: pageWidth * CGFloat(max(pages.count, 1)), height: bounds.height)
        apply(position)
    }

    /// Shows fractional page `p`.
    func apply(_ p: Double) {
        position = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.setFrameOrigin(NSPoint(x: -CGFloat(p) * pageWidth, y: 0))
        updateAttachedPages()
        CATransaction.commit()
        controller?.pagerDidMove(to: p)
    }

    /// Attaches the pages under the sidebar at the current position (one at rest, two mid-slide) and the held ones.
    /// Everything else waits for `settleTree`.
    private func updateAttachedPages() {
        var settled = true
        let current = Int(position.rounded())
        for (i, page) in pages.enumerated() {
            let onScreen = abs(Double(i) - position) < 0.999
            if onScreen || held.contains(ObjectIdentifier(page)) { attach(i); continue }
            let wanted = abs(i - current) <= 1
            if wanted != (page.superview === strip) { settled = false }
        }
        if !settled { queueTreeSettle() }
    }

    private func queueTreeSettle() {
        guard !treeSettleQueued else { return }
        treeSettleQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.treeSettleQueued = false
            self?.settleTree()
        }
    }

    /// At idle: attaches the current page's neighbours and detaches pages further away, one page per run-loop turn so
    /// no single turn holds the main thread for long.
    private func settleTree() {
        // Nor during the window's own animations (⌘S hide/show, the Library): a 3 ms attach would drop their frame.
        let windowAnimating = controller.map { $0.animator.isRunning("sidebar") || $0.animator.isRunning("library") } ?? false
        if isTrackingOrSettling || !held.isEmpty || windowAnimating { return queueTreeSettle() }
        // Not while the person is doing something: a change to the view tree makes AppKit redo the window's tracking
        // areas, which can end a press in progress (a click whose mouse-up hasn't arrived yet) or a hover.
        let sinceInput = ProcessInfo.processInfo.systemUptime - (NSApp.currentEvent?.timestamp ?? 0)
        if sinceInput < 0.5 || NSEvent.pressedMouseButtons != 0 { return queueTreeSettle() }
        let current = Int(position.rounded())
        for (i, page) in pages.enumerated() {
            let wanted = abs(i - current) <= 1
            if wanted, page.superview !== strip {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                attach(i)
                CATransaction.commit()
            } else if !wanted, page.superview != nil {
                page.removeFromSuperview()
            } else {
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.settleTree() }
            return
        }
    }

    private func attach(_ i: Int) {
        let page = pages[i]
        let f = pageFrame(i)
        if page.frame != f { page.frame = f }
        if page.superview !== strip { strip.addSubview(page) }
        if page.isHidden { page.isHidden = false }
    }

    /// Keeps pages `indices` attached until `release()`.
    private func hold(_ indices: [Int]) {
        for i in indices where pages.indices.contains(i) { held.insert(ObjectIdentifier(pages[i])) }
    }

    private func release() {
        guard !held.isEmpty else { return }
        held = []
        queueTreeSettle()
    }

    /// The page views attached now (`--script frames` census and tests).
    var attachedPages: [SpacePageView] { pages.filter { $0.superview === strip } }

    /// Clicks and shortcuts slide the new page in on the same spring.
    func go(to page: Int, animated: Bool, velocity: Double = 0, completion: (() -> Void)? = nil) {
        let target = Double(max(0, min(page, pages.count - 1)))
        guard animated else {
            animator.cancel("settle")
            stopCoreSettle()
            held = []
            apply(target)
            completion?()
            return
        }
        // A click or key to a neighbour: the colour cross-fades on its own, so nothing needs the position each frame.
        // The slide runs as a Core Animation spring in the render server, with no main-thread work per frame.
        let reduceMotion = onMain { AircMotion.prefersReducedMotion }
        if velocity == 0, abs(target - position) <= 1.001, let layer = strip.layer {
            animator.cancel("settle")
            let from = layer.presentation()?.position ?? layer.position
            layer.removeAnimation(forKey: "springPosition")
            // The page sliding out stays attached until the slide ends.
            if !reduceMotion { hold(Array(Int(position.rounded(.down))...Int(position.rounded(.up)))) }
            apply(target)
            if !reduceMotion { layer.springPosition(from: from, spring: Spring(AircSpring.settle)) }
            let duration = reduceMotion ? 0 : AircSpring.settle.settlingDuration
            coreSettleEnd = CACurrentMediaTime() + duration
            let end = coreSettleEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                if let self, self.coreSettleEnd == end, !self.tracking, !self.animator.isRunning("settle") { self.release() }
                completion?()
            }
            return
        }
        stopCoreSettle()
        // A longer jump or a released swipe: every page it passes is attached once, up front, not mid-flight.
        let lo = Int(min(position, target).rounded(.down)), hi = Int(max(position, target).rounded(.up))
        hold(Array(lo...hi))
        animator.spring("settle", from: position, to: target, velocity: velocity, spring: Spring(AircSpring.settle),
                        epsilon: 0.0005, update: { [weak self] in self?.apply($0) }, completion: { [weak self] in
            if let self, !self.tracking { self.release() }
            completion?()
        })
    }

    /// A finger landed mid-settle: continue from where the page is on screen.
    private func stopCoreSettle() {
        guard let l = strip.layer, l.animation(forKey: "springPosition") != nil else { return }
        let dx = (l.presentation()?.position.x ?? l.position.x) - l.position.x
        l.removeAnimation(forKey: "springPosition")
        coreSettleEnd = 0
        apply(position - Double(dx / pageWidth))
    }

    // MARK: Swipe

    override func scrollWheel(with event: NSEvent) {
        track(phase: event.phase, momentum: event.momentumPhase, dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
              precise: event.hasPreciseScrollingDeltas)
    }

    /// One scroll event of a swipe (also fed directly by `--script frames`, which can't post trackpad phases).
    func track(phase: NSEvent.Phase, momentum: NSEvent.Phase, dx: CGFloat, dy: CGFloat, precise: Bool) {
        if momentum != [] {
            return  // our spring replaces momentum
        }
        if ignoringGesture {
            if phase == .ended || phase == .cancelled { ignoringGesture = false }
            return
        }
        if phase == .began && !tracking {
            // Only a mostly horizontal swipe pages Spaces; a vertical one scrolls the list.
            guard abs(dx) > abs(dy) else {
                ignoringGesture = true
                return
            }
            animator.cancel("settle")
            stopCoreSettle()
            controller?.pagerDidBeginTracking()
            tracking = true
            startPage = Int(position.rounded())
            // Both neighbours come in now, so the finger never waits for a page to be attached.
            hold([startPage - 1, startPage, startPage + 1])
            apply(position)
            rawPosition = position
            samples = []
        }
        guard tracking else {
            // A wheel mouse with no phases: one page per notch.
            if phase == [], !precise, abs(dx) > abs(dy) {
                controller?.switchSpace(offset: dx > 0 ? -1 : 1)
            }
            return
        }
        if phase == .changed || phase == .began {
            rawPosition -= Double(dx) / Double(pageWidth) * SwipePaging.trackingRatio
            // Never more than one page away from where the swipe started.
            rawPosition = min(max(rawPosition, Double(startPage) - 1), Double(startPage) + 1)
            apply(displayed(rawPosition))
            updateCreateIndicator()
            samples.append((CACurrentMediaTime(), rawPosition))
            if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        }
        if phase == .ended || phase == .cancelled {
            tracking = false
            let create = createReady && phase == .ended
            createReady = false
            hideCreateIndicator()
            if create {
                let last = max(pages.count - 1, 0)
                go(to: last, animated: true) { [weak self] in self?.release(); self?.controller?.pagerDidSettle(on: last) }
                controller?.openNewSpacePanel()
                return
            }
            let now = CACurrentMediaTime()
            let recent = samples.filter { now - $0.t < 0.08 }
            var velocity = 0.0
            if let first = recent.first, let last = recent.last, last.t > first.t {
                velocity = (last.p - first.p) / (last.t - first.t)
            }
            let target = SwipePaging.targetPage(startPage: startPage, position: rawPosition, velocity: velocity,
                                                pageWidth: Double(pageWidth), pageCount: pages.count)
            controller?.pagerWillSettle(on: target)
            go(to: target, animated: true, velocity: velocity) { [weak self] in
                self?.controller?.pagerDidSettle(on: target)
            }
        }
    }

    private func updateCreateIndicator() {
        let last = Double(max(pages.count - 1, 0))
        let over = rawPosition - last
        guard over > 0, let theme = controller?.currentPalette.resolved else { return hideCreateIndicator() }
        let revealed = (displayed(rawPosition) - last) * Double(pageWidth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        createIndicator.position = CGPoint(x: pageWidth - CGFloat(revealed) / 2, y: bounds.height * 0.42)
        createIndicator.opacity = Float(min(1, revealed / 24))
        let ready = over >= Self.createDetent
        createIndicator.backgroundColor = (ready ? theme.text : theme.hoverFill).cgColor
        createPlus.strokeColor = (ready ? theme.background : theme.textSecondary).cgColor
        CATransaction.commit()
        if ready != createReady {
            createReady = ready
            if ready {
                // The ready fill lands in 60 ms (the colour above), then the detent pops: 1.13× over 120 ms.
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1, 1.13, 1]
                pop.keyTimes = [0, 0.5, 1]
                pop.duration = 0.12
                pop.beginTime = CACurrentMediaTime() + 0.06
                createIndicator.add(pop, forKey: "pop")
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    private func hideCreateIndicator() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        createIndicator.opacity = 0
        CATransaction.commit()
    }

    /// Rubber band past the first and last Space.
    private func displayed(_ raw: Double) -> Double {
        let last = Double(max(pages.count - 1, 0))
        let w = Double(pageWidth)
        if raw < 0 { return -SwipePaging.rubberBand(-raw * w, limit: w * 0.5) / w }
        if raw > last { return last + SwipePaging.rubberBand((raw - last) * w, limit: w * 0.5) / w }
        return raw
    }

    // Mouse buttons 4/5 over the sidebar switch Spaces (SP-20).
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 3 { controller?.switchSpace(offset: -1) }
        else if event.buttonNumber == 4 { controller?.switchSpace(offset: 1) }
        else { super.otherMouseDown(with: event) }
    }
}

/// The footer (SB-50/51): Library, one icon per Space, "+".
final class SpaceBarView: NSView {
    weak var controller: WindowController?
    private let library = GlyphButton(symbol: "archivebox", size: 15)
    private let plus = GlyphButton(symbol: "plus", size: 15)
    private var cells: [SpaceCell] = []
    private var spaceIDs: [String] = []
    /// While a cell is dragged, layout leaves the cells where the drag puts them.
    private var reordering = false
    private var position: Double = 0
    /// The Space icons, in order (the real-event checks drag them).
    var cellViews: [NSView] { cells.filter { !$0.isHidden } }
    /// The Library button (the checks compare the Library's back button with it).
    var libraryButton: NSView { library }

    /// The Library button's place in a column `height` tall, from its top-left: the footer's left button. The Library's
    /// back button takes the same place, so a second click without moving the pointer goes back (Arc).
    static func libraryButtonFrame(columnHeight height: CGFloat) -> NSRect {
        let b = AircMetrics.Footer.button
        return NSRect(x: AircMetrics.Footer.buttonInset, y: height - AircMetrics.Footer.height + (AircMetrics.Footer.height - b) / 2,
                      width: b, height: b)
    }
    /// The current Space's position as the window last set it (a provisional cell overrides it while shown).
    private var spacePosition: Double = 0
    private var hasProvisional = false

    final class SpaceCell: NSView {
        let label = NSTextField(labelWithString: "")
        let dot = CALayer()
        let ring = CALayer()
        let hover = CALayer()
        /// The `tileFill` plate of the Space being created (Create a Space, visual review #12).
        let plate = CALayer()
        var spaceID = ""
        weak var controller: WindowController?
        weak var bar: SpaceBarView?
        var hasEmoji = true
        var showsProfileDot = false { didSet { if showsProfileDot != oldValue { needsLayout = true } } }
        /// Other Spaces' icons at half saturation (design.md §7 "Space bar", visual review #11), in tenths.
        private var saturationStep = 10
        func setSaturation(_ s: Double) {
            let step = Int((s * 10).rounded())
            guard step != saturationStep else { return }
            saturationStep = step
            label.contentFilters = step >= 10 ? [] : [CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: Double(step) / 10])!]
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            hover.cornerRadius = 6
            layer?.addSublayer(hover)
            plate.cornerRadius = 6
            plate.cornerCurve = .continuous
            plate.isHidden = true
            layer?.addSublayer(plate)
            label.font = NSFont.systemFont(ofSize: AircMetrics.Footer.spaceEmoji)
            label.alignment = .center
            label.wantsLayer = true
            label.layerUsesCoreImageFilters = true
            addSubview(label)
            dot.cornerRadius = 3.5
            layer?.addSublayer(dot)
            // SP-15: a 6 pt dot in the profile's colour at the icon's bottom right, cut out of the icon by a 1.5 pt
            // ring of the sidebar's own colour.
            ring.borderWidth = 1.5
            ring.cornerRadius = 4.5
            ring.isHidden = true
            layer?.addSublayer(ring)
        }

        required init?(coder: NSCoder) { fatalError() }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let s = min(bounds.width, 28)
            hover.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - 28) / 2, width: s, height: 28)
            plate.frame = hover.frame
            let small = bounds.width < 18
            label.isHidden = !hasEmoji || small
            label.frame = NSRect(x: 0, y: (bounds.height - 20) / 2, width: bounds.width, height: 20)
            // A Space without an icon shows its dot; with a profile dot, that dot alone (no stray "••").
            let d: CGFloat = (hasEmoji && !small) || showsProfileDot ? 0 : (small ? 5 : 7)
            dot.isHidden = d == 0
            dot.cornerRadius = d / 2
            dot.frame = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            let mid = NSPoint(x: bounds.midX, y: bounds.midY)
            ring.frame = small || !hasEmoji
                ? NSRect(x: mid.x - 4.5, y: mid.y - 4.5, width: 9, height: 9)
                : NSRect(x: mid.x + 3.5, y: mid.y - 11.5, width: 9, height: 9)
            ring.opacity = showsProfileDot ? 1 : 0
            CATransaction.commit()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        var hoverColor: CGColor = NSColor.clear.cgColor
        override func mouseEntered(with event: NSEvent) { hover.backgroundColor = hoverColor }
        override func mouseExited(with event: NSEvent) { hover.backgroundColor = nil }
        override func mouseDown(with event: NSEvent) {
            controller?.switchToSpace(spaceID, animated: true)
            bar?.beginReorder(self, event: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? { controller?.spaceMenu(spaceID: spaceID) }
    }

    // MARK: Reordering (Arc: drag a Space's icon along the bar)

    /// The press switched to the Space; if the pointer then moves along the bar, the icon lifts and follows it, the
    /// others make room on the row spring, and the release puts the Space there (SpacesStore.moveSpace).
    func beginReorder(_ cell: SpaceCell, event: NSEvent) {
        guard let window, !hasProvisional, cells.count > 1, let from = cells.firstIndex(where: { $0 === cell }) else { return }
        let origin = convert(event.locationInWindow, from: nil)
        let grab = origin.x - cell.frame.minX
        var order = cells
        var dragging = false
        reordering = true
        defer { reordering = false }
        tracking: while true {
            guard let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                           inMode: .eventTracking, dequeue: true) else { break }
            if e.type == .leftMouseUp { break }
            let p = convert(e.locationInWindow, from: nil)
            if !dragging {
                guard abs(p.x - origin.x) > AircSpacing.xs else { continue }
                dragging = true
                lift(cell, true)
            }
            let slots = slotFrames(count: order.count, current: order.firstIndex { $0 === cell } ?? from)
            let lo = slots.first?.minX ?? 0, hi = slots.last?.maxX ?? bounds.width
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cell.setFrameOrigin(NSPoint(x: min(max(p.x - grab, lo), hi - cell.frame.width), y: cell.frame.minY))
            CATransaction.commit()
            // The slot under the icon's centre; the others glide to theirs.
            let mid = cell.frame.midX
            let target = slots.firstIndex { mid < $0.maxX } ?? (slots.count - 1)
            if let now = order.firstIndex(where: { $0 === cell }), now != target {
                order.remove(at: now)
                order.insert(cell, at: target)
                let moved = slotFrames(count: order.count, current: target)
                for (c, f) in zip(order, moved) where c !== cell { c.setFrameAnimated(f, animated: true) }
            }
        }
        guard dragging else { return }
        let to = order.firstIndex { $0 === cell } ?? from
        let final = slotFrames(count: order.count, current: to)
        cell.setFrameAnimated(final[to], animated: true)
        lift(cell, false)
        guard to != from else { return }
        // The cell views keep their Spaces: the bar's own order follows before the store's does.
        cells = order
        spaceIDs = order.map(\.spaceID)
        controller?.reorderSpace(cell.spaceID, to: to)
    }

    /// Where each cell goes for `count` cells with `current` the wide one (the layout's own arithmetic).
    private func slotFrames(count: Int, current: Int) -> [NSRect] {
        let span = SpaceBarLayout.span(sidebarWidth: Double(bounds.width))
        let widths = SpaceBarLayout.cellWidths(count: count, current: current, span: span)
        var x = (bounds.width - CGFloat(widths.reduce(0, +))) / 2
        return widths.map { w in
            defer { x += CGFloat(w) }
            return NSRect(x: x, y: (bounds.height - 34) / 2, width: CGFloat(w), height: 34)
        }
    }

    /// Lifted: above the others, a touch larger (the drag ghost's lift).
    private func lift(_ cell: SpaceCell, _ up: Bool) {
        guard let layer = cell.layer else { return }
        layer.zPosition = up ? 10 : 0
        let scale: CGFloat = up ? 1.12 : 1
        // Scale about the cell's centre (its layer's anchor is the corner AppKit gives it).
        let t = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-cell.bounds.midX, -cell.bounds.midY, 0),
                                                         CATransform3DMakeScale(scale, scale, 1)),
                                    CATransform3DMakeTranslation(cell.bounds.midX, cell.bounds.midY, 0))
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = t
        a.duration = AircCurve.press.duration * 2
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = t
        layer.add(a, forKey: "lift")
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(library)
        addSubview(plus)
        library.toolTip = "View Library ⇧⌘L"
        plus.toolTip = "New…"
        library.action = { [weak self] in self?.controller?.showLibrary() }
        plus.menuProvider = { [weak self] in self?.controller?.plusMenu() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// `provisional`: while Create a Space is open, its cell (icon, or "" for the dot) after the others, as current.
    func configure(spaces: [Space], profiles: [String: Profile], palette: Palette, multipleProfiles: Bool,
                   provisional: String? = nil) {
        // Create replaces the provisional dot with one real Space. Keep each existing cell
        // bound to its Space and move the provisional cell into the insertion slot. Zipping
        // by index instead changes every following emoji and its saturation filter, forcing
        // those labels to redraw in Create's first frame.
        var adoptsProvisional = hasProvisional && provisional == nil
        #if AIRC_TESTING
        if adoptsProvisional, ProcessInfo.processInfo.environment["AIRC_NEW_SPACE_BASELINE"] == "1" { adoptsProvisional = false }
        #endif
        if adoptsProvisional, spaces.count == cells.count,
           let spare = cells.first(where: { $0.spaceID.isEmpty }) {
            let existing = Dictionary(uniqueKeysWithValues: cells.filter { !$0.spaceID.isEmpty }.map { ($0.spaceID, $0) })
            let newIDs = Set(spaces.map(\.id)).subtracting(existing.keys)
            if newIDs.count == 1, Set(existing.keys).isSubset(of: Set(spaces.map(\.id))) {
                cells = spaces.map { existing[$0.id] ?? spare }
            }
        }
        var spaces = spaces
        hasProvisional = provisional != nil
        if let provisional {
            spaces.append(Space(id: "", name: "New Space", icon: provisional.isEmpty ? nil : .emoji(provisional), profileID: ""))
        }
        library.tint = palette.glyph
        plus.tint = palette.glyph
        library.hoverFill = palette.hover
        plus.hoverFill = palette.hover
        spaceIDs = spaces.map(\.id)
        while cells.count < spaces.count {
            let c = SpaceCell()
            c.controller = controller
            c.bar = self
            addSubview(c)
            cells.append(c)
        }
        while cells.count > spaces.count { cells.removeLast().removeFromSuperview() }
        for (c, s) in zip(cells, spaces) {
            c.spaceID = s.id
            c.controller = controller
            // Only what changed: a Space switch re-runs this with the same Spaces and a new palette.
            let label: String, emoji: Bool
            switch s.icon {
            case .emoji(let e)?: (label, emoji) = (e, true)
            case .symbol?: (label, emoji) = ("◆", true)
            case nil: (label, emoji) = ("", false)
            }
            if c.label.stringValue != label { c.label.stringValue = label }
            if c.hasEmoji != emoji { c.hasEmoji = emoji; c.needsLayout = true }
            c.dot.backgroundColor = palette.textSecondary.cgColor
            c.hoverColor = palette.hover.cgColor
            if c.toolTip != s.name { c.toolTip = s.name }
            let isProvisional = hasProvisional && c === cells[spaces.count - 1]
            c.plate.isHidden = !isProvisional
            c.plate.backgroundColor = palette.tileFill.cgColor
            // SP-15: the profile's dot once two or more profiles have Spaces (it dims with its cell).
            if multipleProfiles, let p = profiles[s.profileID] {
                c.ring.isHidden = false
                c.ring.backgroundColor = p.color.nsColor.cgColor
                c.ring.borderColor = palette.resolved.profileDotRing.nsColor.cgColor
                c.showsProfileDot = true
            } else {
                c.ring.isHidden = true
                c.showsProfileDot = false
            }
        }
        // Hidden when there is only one Space (Arc ref §2.9).
        cells.forEach { $0.isHidden = spaces.count < 2 }
        needsLayout = true
        applyPosition(hasProvisional ? Double(spaces.count - 1) : spacePosition)
    }

    /// Current Space full strength, others dimmed; follows the swipe.
    func setPosition(_ p: Double) {
        spacePosition = p
        if !hasProvisional { applyPosition(p) }
    }

    private func applyPosition(_ p: Double) {
        position = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, c) in cells.enumerated() {
            let d = min(1, abs(Double(i) - p))
            c.alphaValue = CGFloat(1 - 0.55 * d)
            c.setSaturation(1 - 0.5 * d)
        }
        CATransaction.commit()
        if !cells.isEmpty { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let b = AircMetrics.Footer.button
        let y = (bounds.height - b) / 2
        library.frame = Self.libraryButtonFrame(columnHeight: bounds.height)
        plus.frame = NSRect(x: bounds.width - AircMetrics.Footer.buttonInset - b, y: y, width: b, height: b)
        guard !reordering else { return }
        let span = CGFloat(SpaceBarLayout.span(sidebarWidth: Double(bounds.width)))
        let widths = SpaceBarLayout.cellWidths(count: cells.count, current: Int(position.rounded()), span: Double(span))
        let total = widths.reduce(0, +)
        var x = (bounds.width - CGFloat(total)) / 2
        for (c, w) in zip(cells, widths) {
            c.frame = NSRect(x: x, y: (bounds.height - 34) / 2, width: CGFloat(w), height: 34)
            x += CGFloat(w)
        }
    }
}

/// The whole sidebar column: fixed header, paging Space pages, fixed footer.
final class SidebarView: NSView {
    weak var controller: WindowController?
    let header = SidebarHeaderView()
    let pager = SpacePagerView()
    let footer = SpaceBarView()
    /// SB-54: downloads and the media tray, above the footer (Media/SidebarTray.swift).
    let tray = SidebarTrayView()
    /// "New Airc Version Available", just above the footer (Browser/UpdateButton.swift).
    let update = UpdateButtonView()
    private(set) var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(pager)
        addSubview(header)
        addSubview(footer)
        addSubview(tray)
        addSubview(update)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func connect(_ c: WindowController) {
        controller = c
        header.controller = c
        pager.controller = c
        footer.controller = c
        update.controller = c
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        header.frame = NSRect(x: 0, y: 0, width: w, height: AircMetrics.Sidebar.urlFieldTop)
        footer.frame = NSRect(x: 0, y: h - AircMetrics.Footer.height, width: w, height: AircMetrics.Footer.height)
        let u = update.height
        update.frame = NSRect(x: 0, y: h - AircMetrics.Footer.height - u, width: w, height: u)
        let t = tray.height
        tray.frame = NSRect(x: 0, y: h - AircMetrics.Footer.height - u - t, width: w, height: t)
        pager.frame = NSRect(x: 0, y: AircMetrics.Sidebar.urlFieldTop, width: w, height: max(0, h - AircMetrics.Sidebar.urlFieldTop - AircMetrics.Footer.height - u - t))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ h: Bool) {
        hovered = h
        pager.pages.forEach { $0.sidebarHovered = h }
    }

    // Swipes anywhere over the sidebar page Spaces, not only over the list.
    override func scrollWheel(with event: NSEvent) { pager.scrollWheel(with: event) }

    override func otherMouseDown(with event: NSEvent) { pager.otherMouseDown(with: event) }
}
