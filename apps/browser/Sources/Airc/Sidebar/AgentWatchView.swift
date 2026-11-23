// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI

/// Watch (docs/user/agents.md): an agent tab's page, live and read-only, over this window's page card. The agent window
/// stays where it is (off screen, never key): Watch shows copies of its page as the engine draws it
/// (AgentPageDriver.watchFrame: a copy of the compositor's surface on Chromium, WebKit's snapshot of its last frame)
/// at up to `fps`, one at a time, only while the window is on screen. Over it: the agent's pointer (a dot that moves
/// on the row spring and rings at each click), the field it types into, and a caption of the current call ("Clicking
/// ‘Archive’", "Typing…"). Clicks, scrolls and keys stop here (Esc closes), so nothing reaches the page underneath or
/// the agent's. Take over and Stop are in its bar.
final class AgentWatchView: NSView {
    /// Frames per second while watching.
    static var fps: Double = 15
    /// The picture's pixels per point, as a share of the screen's (1: the window's backing scale). Less costs less:
    /// the copy, its upload and the scaling all shrink with the pixel count (artifacts/agentview/REPORT.md, "Cost").
    static var pixelScale: CGFloat = 0.5
    /// Recordings (the demo runs, marketing shots) draw frames even when other windows cover this one. They also
    /// copy frames: a recording renders layers in the app, which can't draw a hosted context.
    static var ignoresOcclusion = false
    /// Show the engine's own output where it can (AgentPageDriver.liveLayer: no copies); else copy frames.
    static var allowsLive = true

    let rowID: String
    private(set) weak var controller: WindowController?
    /// The person's tab when Watch opened: showing another one closes Watch.
    let shownTabAtOpen: String?
    private let image = CALayer()
    /// The live page (a hosted context), in page points, scaled into the picture's place.
    private let liveBox = CALayer()
    private var live: (layer: CALayer, id: UInt32, flipped: Bool)?
    /// "live" (the engine's own output, no copies) or "copies" (frames copied at `fps`); checks and the report read it.
    private(set) var mode = "copies"
    private(set) var liveChecks = 0
    private let pointer = CALayer()
    private let ripple = CAShapeLayer()
    private let field = CALayer()
    private let overlay = AgentWatchModel()
    private var host: AircFirstClickHostingView<AgentWatchOverlay>?
    private var token: UUID?
    /// The Airc Agent's approval card, mirrored from the panel while this row is its run's (AgentRunCenter.approval).
    private var approvalSub: AnyCancellable?
    private var promptSub: NSObjectProtocol?
    private var running = false
    private var inFlight = false
    private var pageSize = CGSize(width: 1280, height: 800)
    private var lastPointer: CGPoint?
    private var lastField: CGRect?
    private var fieldHide: DispatchWorkItem?
    private weak var previousResponder: NSResponder?

    // What checks and the cost measurement read.
    private(set) var framesShown = 0
    private(set) var captureMs: [Double] = []
    private(set) var lastFrame: CGImage?
    private(set) var startedAt = Date()
    var caption: String? { overlay.caption }
    var pointerShown: Bool { !pointer.isHidden }
    var fieldShown: Bool { !field.isHidden }

    init(rowID: String, controller: WindowController) {
        self.rowID = rowID
        self.controller = controller
        shownTabAtOpen = controller.shownTabID
        super.init(frame: controller.card.bounds)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        layer?.masksToBounds = true
        layer?.cornerRadius = controller.card.cornerRadius
        layer?.cornerCurve = .continuous
        image.contentsGravity = .resizeAspect
        image.cornerRadius = 8
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.minificationFilter = .trilinear
        layer?.addSublayer(image)
        liveBox.anchorPoint = .zero
        liveBox.masksToBounds = true
        liveBox.cornerRadius = 8
        liveBox.isHidden = true
        layer?.addSublayer(liveBox)
        field.cornerRadius = 6
        field.borderWidth = 2
        field.isHidden = true
        layer?.addSublayer(field)
        ripple.fillColor = nil
        ripple.lineWidth = 2
        ripple.opacity = 0
        layer?.addSublayer(ripple)
        pointer.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
        pointer.cornerRadius = 7
        pointer.borderWidth = 2
        pointer.borderColor = NSColor.white.cgColor
        pointer.shadowOpacity = 0.35
        pointer.shadowRadius = 3
        pointer.shadowOffset = .zero
        pointer.isHidden = true
        layer?.addSublayer(pointer)
        overlay.view = self
        let h = AircFirstClickHostingView(rootView: AgentWatchOverlay(model: overlay))
        h.safeAreaRegions = []
        h.frame = bounds
        h.autoresizingMask = [.width, .height]
        addSubview(h)
        host = h
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTheme()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Open, close

    /// `takeKeys`: the person opened it (a click), so keys stop here. Opened by itself ("show agent pages in front"), it
    /// leaves the keyboard where it is until it's clicked.
    func start(takeKeys: Bool = true) {
        guard let c = controller, let row = AgentActivity.shared.model.row(rowID) else { return }
        if let w = AgentCenter.shared.windows[row.window] { pageSize = w.size }
        frame = c.card.bounds
        c.card.addSubview(self, positioned: .above, relativeTo: nil)
        update(row: row, state: AgentActivity.shared.model.state(row, now: Date()))
        token = AgentActivity.shared.watch(rowID) { [weak self] e in self?.handle(e) }
        approvalSub = AgentRunCenter.shared.$approval.sink { [weak self] a in self?.syncApproval(a) }
        previousResponder = c.window.firstResponder
        if takeKeys { c.window.makeFirstResponder(self) }
        running = true
        startedAt = Date()
        followActivity()
        promptSub = NotificationCenter.default.addObserver(forName: AgentPrompts.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPrompt() }
        }
        syncPrompt()
        AgentPrompts.shared.watchChanged()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer?.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration) }
        requestFrame()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func stop() {
        running = false
        approvalSub = nil
        removeLive()
        hold(nil, nil)
        endCommitWatch()
        if let o = activityObserver { NotificationCenter.default.removeObserver(o) }
        activityObserver = nil
        if let o = promptSub { NotificationCenter.default.removeObserver(o) }
        promptSub = nil
        AgentPrompts.shared.watchChanged()
        if let token { AgentActivity.shared.unwatch(rowID, token) }
        token = nil
        if let w = window, w.firstResponder === self {
            if let back = previousResponder as? NSView, back.window === w { w.makeFirstResponder(back) } else { w.makeFirstResponder(nil) }
        }
        removeFromSuperview()
    }

    func update(row: AgentTabRow, state: AgentRowState) {
        overlay.label = row.label
        overlay.client = row.client
        overlay.icon = AgentCenter.shared.windows[row.window]?.tab(row.tab)?.favicon
        overlay.live = row.isLive
        switch state {
        case .acting(let c): overlay.acting = true; overlay.caption = overlay.approval != nil ? "Waiting for your OK" : (c ?? "Working…")
        case .needsYou(let why) where why == AgentPrompts.reason:
            overlay.acting = false
            overlay.caption = overlay.prompt != nil ? "Waiting for your answer" : "Needs you · \(row.client) asked for your passkey"
        case .needsYou(let why): overlay.acting = false; overlay.caption = "Needs you · \(why). Take over to do it here; \(row.client) can go on after"
        case .idle:
            overlay.acting = false
            // "Waiting for …" only while there's nothing to show yet; with the page in view it's between two steps.
            overlay.caption = overlay.approval != nil ? "Waiting for your OK" : hasFrame || Self.legacy && framesShown > 0 ? "\(row.client) is between steps" : "Waiting for \(row.client)"
        case .justEnded(let end), .faded(let end, _):
            overlay.acting = false
            switch end {
            case .done: overlay.caption = "\(row.client) is done"
            case .stopped: overlay.caption = "You stopped \(row.client)"
            case .takenOver: overlay.caption = "This page is yours now"
            }
            pointer.isHidden = true
            field.isHidden = true
        }
        setAccessibilityLabel("Watching \(row.label), read-only")
    }

    // MARK: Frames

    /// The page the live layer comes from, opted in to keep a hidden view's last frame while watched (engine patch 042,
    /// as the agent card does): a navigation to a new view never empties the context Watch shows before the new one
    /// exists. Weak: Watch never keeps a closed page alive.
    private var heldTab: (tab: () -> EngineTab?, id: ObjectIdentifier, driver: AgentPageDriver)?
    /// The tab Watch last asked the driver to keep drawing (watchfix).
    private var keptLive: ObjectIdentifier?
    private var liveMissSince: CFTimeInterval?
    /// A context the window server showed as empty: copies until the engine gives the page another one.
    private var blankContext: UInt32?
    private var blankSeen = 0
    private var nextProbe: CFTimeInterval = 0
    private var probesSinceInstall = 0
    private var snapshotMisses = 0
    private var commitObserver: CFRunLoopObserver?
    private var activityObserver: NSObjectProtocol?
    private var fastUntil: CFTimeInterval = 0
    /// What checks and the report read: live installs, swaps found before Core Animation's commit, empty contexts left
    /// for copies, copies that came from the agent's screenshot path.
    private(set) var liveInstalls = 0
    private(set) var swapsByCommit = 0
    private(set) var blankFallbacks = 0
    private(set) var screenshotCopies = 0
    /// A picture of the page is on screen (a copy, or a live context the window server drew).
    private(set) var hasFrame = false
    #if AIRC_TESTING
    /// agentwatch2's before arm: Watch as 0.1.54 had it (no keeping, no hold, no probe, no screenshot copies).
    static var legacy = ProcessInfo.processInfo.environment["AIRC_WATCH_LEGACY"] == "1"
    #else
    static let legacy = false
    #endif

    private func again(_ after: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in self?.requestFrame() }
    }

    private func requestFrame() {
        guard running else { return }
        let interval = 1 / max(1, Self.fps)
        guard let row = AgentActivity.shared.model.row(rowID), row.isLive,
              let w = AgentCenter.shared.windows[row.window], let tab = w.tab(row.tab) else { return again(0.5) }
        if !Self.legacy, w.keepsVisible, keptLive != ObjectIdentifier(tab) {
            keptLive = ObjectIdentifier(tab)
            w.driver.keepLive(tab)
        }
        // Live where the engine can host its own output and the tab is the one its window shows: nothing to copy, only a
        // look 10 times a second that the context is still the one shown (and a few looks at what the window server drew).
        if Self.allowsLive, !Self.ignoresOcclusion, w.activeTabID == row.tab {
            // agentux3: checked as the host is made (the tab's own first), and swapped in one commit.
            let current = w.driver.liveContextID(tab, in: w.window)
            let check = CACurrentMediaTime() < fastUntil ? 1.0 / 120 : AgentPaneLiveView.liveCheckInterval
            if let current, current == blankContext, !Self.legacy {
                if live != nil { removeLive() }
            } else if let live, live.id == current {
                liveChecks += 1
                liveMissSince = nil
                if !Self.legacy { probeLive() }
                return again(check)
            } else if current != nil, let made = w.driver.liveLayer(tab, in: w.window) {
                liveMissSince = nil
                installLive(made)
                if !Self.legacy { hold(tab, w.driver) }
                return again(check)
            } else if live != nil, !Self.legacy {
                // Between two contexts: the last picture stays for a moment (cardflicker's rule), then copies.
                let now = CACurrentMediaTime()
                if liveMissSince == nil { liveMissSince = now }
                if now - (liveMissSince ?? now) < 1.5 { return again(AgentPaneLiveView.liveCheckInterval) }
                removeLive()
            } else {
                removeLive()
            }
        } else if live != nil {
            removeLive()
        }
        // Nothing to draw for: a hidden, minimized or covered window.
        guard let win = window, Self.ignoresOcclusion || win.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else { return again(0.5) }
        guard !inFlight else { return }
        inFlight = true
        let started = CACurrentMediaTime()
        let scale = win.backingScaleFactor * Self.pixelScale
        let rect = imageRect()
        let maxPixels = CGSize(width: max(64, rect.width * scale), height: max(64, rect.height * scale))
        let shown: (CGImage?) -> Void = { [weak self] picture in
            guard let self else { return }
            self.inFlight = false
            let ms = (CACurrentMediaTime() - started) * 1000
            if self.captureMs.count < 4000 { self.captureMs.append(ms) }
            if let picture, self.running {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.image.contents = picture
                CATransaction.commit()
                self.lastFrame = picture
                self.framesShown += 1
                self.gotFrame()
            }
            // The agent's screenshot path is slower and goes through the page's DevTools session: a few a second.
            let wait = max(0, (self.snapshotMisses >= 2 ? max(interval, 0.25) : interval) - (CACurrentMediaTime() - started))
            self.again(wait)
        }
        w.driver.watchFrame(tab, maxPixels: maxPixels) { [weak self] picture in
            guard let self else { return }
            if picture != nil || Self.legacy { self.snapshotMisses = 0; return shown(picture) }
            // No surface to copy (a page the engine hides or hasn't drawn since its window went off screen): the picture
            // the agent's own screenshot gets, which the engine draws on request (watchfix).
            self.snapshotMisses += 1
            guard self.snapshotMisses >= 2 else { return shown(nil) }
            w.driver.capture(tab) { result in
                if case .success = result { self.screenshotCopies += 1 }
                if case .success(let image) = result { shown(image) } else { shown(nil) }
            }
        }
    }

    /// A picture is on screen: "Waiting for …" goes (it's only for when there is nothing to show yet).
    private func gotFrame() {
        guard !hasFrame else { return }
        hasFrame = true
        if let row = AgentActivity.shared.model.row(rowID) { update(row: row, state: AgentActivity.shared.model.state(row, now: Date())) }
        AgentCenter.shared.onEvent?("watch-frame \(rowID) \(mode)")
    }

    private func installLive(_ made: (layer: CALayer, id: UInt32, flipped: Bool)) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let old = liveBox.sublayers ?? []
        live = made
        mode = "live"
        liveBox.bounds = CGRect(origin: .zero, size: pageSize)
        made.layer.anchorPoint = .zero
        made.layer.frame = liveBox.bounds
        // The new host first, then the old one goes (one commit, never an empty frame).
        liveBox.addSublayer(made.layer)
        old.forEach { $0.removeFromSuperlayer() }
        if liveBox.contentsAreFlipped() != made.flipped { liveBox.isGeometryFlipped.toggle() }
        liveBox.isHidden = false
        // The copy goes: the window server's picture must show what the context itself draws (probeLive).
        image.isHidden = true
        CATransaction.commit()
        needsLayout = true
        liveInstalls += 1
        // A new context can mean a new DevTools target for the page: keep it drawing (idempotent).
        if !Self.legacy, liveInstalls > 1, let row = AgentActivity.shared.model.row(rowID), let w = AgentCenter.shared.windows[row.window],
           w.keepsVisible, let tab = w.tab(row.tab) { w.driver.keepLive(tab) }
        probesSinceInstall = 0
        blankSeen = 0
        nextProbe = CACurrentMediaTime() + 0.25
        AgentCenter.shared.onEvent?("watch-live \(rowID) ctx \(made.id)")
    }

    private func removeLive() {
        guard live != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live?.layer.removeFromSuperlayer()
        live = nil
        mode = "copies"
        liveBox.isHidden = true
        image.isHidden = false
        CATransaction.commit()
        hold(nil, nil)
    }

    /// Only the page Watch shows live keeps hidden frames; any other (or none) is back to the engine's default.
    private func hold(_ tab: EngineTab?, _ driver: AgentPageDriver?) {
        let id = tab.map { ObjectIdentifier($0 as AnyObject) }
        if let held = heldTab, held.id != id {
            if let old = held.tab() { held.driver.holdFramesOnHide(old, false) }
            heldTab = nil
        }
        if let tab, let id, let driver, heldTab == nil {
            driver.holdFramesOnHide(tab, true)
            weak var page = tab as AnyObject
            heldTab = ({ page as? EngineTab }, id, driver)
        }
    }

    /// The hosted context can't be read in the app (render(in:) draws nothing for it): the window server's picture of our
    /// own window can (no Screen Recording needed). A few looks after each install, then every 5 s: a context that shows
    /// nothing at all (exactly Watch's own background across the page's place, twice) is left for copies until the
    /// engine makes another (the owner's blank Watch, 0.1.54).
    private func probeLive() {
        let now = CACurrentMediaTime()
        guard now >= nextProbe, let live, let win = window, win.occlusionState.contains(.visible) else { return }
        probesSinceInstall += 1
        nextProbe = now + (probesSinceInstall < 4 ? 0.3 : 5)
        guard let verdict = Self.liveVerdict(self) else { return }
        if verdict {
            blankSeen = 0
            gotFrame()
            return
        }
        blankSeen += 1
        guard blankSeen >= 2 else { return }
        blankContext = live.id
        blankFallbacks += 1
        if let row = AgentActivity.shared.model.row(rowID), let w = AgentCenter.shared.windows[row.window], w.keepsVisible, let tab = w.tab(row.tab) {
            w.driver.keepLive(tab)
        }
        AgentCenter.shared.onEvent?("watch-live-blank \(rowID) ctx \(live.id)")
        removeLive()
    }

    /// True: the window server shows something of the page in the live box; false: only Watch's background; nil: no
    /// picture (no window number, capture off).
    static func liveVerdict(_ v: AgentWatchView) -> Bool? {
        let r = v.imageRect()
        guard r.width > 20, r.height > 20, let px = v.windowPixels([CGPoint(x: r.minX - AgentWatchView.inset / 2, y: r.midY)]
              + [0.2, 0.5, 0.8].flatMap { fx in [0.2, 0.5, 0.8].map { fy in CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) } }),
              px.count == 10 else { return nil }
        let bg = px[0]
        return px.dropFirst().contains { abs($0.r - bg.r) > 3 || abs($0.g - bg.g) > 3 || abs($0.b - bg.b) > 3 }
    }

    /// Pixels of our own window at points of this view, from the window server (what the person sees here).
    func windowPixels(_ points: [CGPoint]) -> [(r: Int, g: Int, b: Int)]? {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1", let w = window, w.windowNumber > 0,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
              let main = NSScreen.screens.first else { return nil }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // Only the part of the window Watch covers (in global display points, top-left origin).
        let inWindow = convert(bounds, to: nil)
        let onScreen = w.convertToScreen(inWindow)
        let area = CGRect(x: onScreen.minX, y: main.frame.maxY - onScreen.maxY, width: onScreen.width, height: onScreen.height)
        guard let img = unsafeBitCast(sym, to: Fn.self)(area, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue(),
              img.width > 8 else { return nil }
        let s = CGFloat(img.width) / max(1, bounds.width)
        return points.compactMap { p in AgentImages.pixel(img, x: Int(p.x * s), y: Int(p.y * s)) }
    }

    /// After an agent action Chromium may replace its host (a new context) and drop the old one in the same turn: for
    /// 2.5 s a run-loop observer looks just before Core Animation commits, so the swap goes out in Chromium's commit.
    private func followActivity() {
        activityObserver = NotificationCenter.default.addObserver(forName: AgentActivity.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.live != nil, !Self.legacy else { return }
                self.fastUntil = CACurrentMediaTime() + 2.5
                self.armCommitWatch()
            }
        }
    }

    private func armCommitWatch() {
        guard commitObserver == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if CACurrentMediaTime() > self.fastUntil || !self.running {
                    self.endCommitWatch()
                    return
                }
                guard let live = self.live, let row = AgentActivity.shared.model.row(self.rowID), let w = AgentCenter.shared.windows[row.window],
                      w.activeTabID == row.tab, let tab = w.tab(row.tab), let current = w.driver.liveContextID(tab, in: w.window),
                      current != live.id, current != self.blankContext, let made = w.driver.liveLayer(tab, in: w.window) else { return }
                self.swapsByCommit += 1
                self.installLive(made)
                self.hold(tab, w.driver)
            }
        }
        commitObserver = o
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }

    private func endCommitWatch() {
        if let o = commitObserver { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
        commitObserver = nil
    }

    // MARK: Layout

    static let barHeight: CGFloat = 46
    static let inset: CGFloat = 14

    /// The page's picture: the agent window's shape, fit below the bar.
    func imageRect() -> CGRect {
        let area = bounds.insetBy(dx: Self.inset, dy: 0)
        let top = Self.barHeight
        let avail = CGRect(x: area.minX, y: top, width: area.width, height: max(1, bounds.height - top - Self.inset))
        let f = min(avail.width / pageSize.width, avail.height / pageSize.height)
        let size = CGSize(width: (pageSize.width * f).rounded(), height: (pageSize.height * f).rounded())
        return CGRect(x: avail.midX - size.width / 2, y: avail.minY + (avail.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// A page point (the agent window's points) in this view.
    func viewPoint(_ p: CGPoint) -> CGPoint {
        let r = imageRect()
        return CGPoint(x: r.minX + p.x * r.width / pageSize.width, y: r.minY + p.y * r.height / pageSize.height)
    }

    private func viewRect(_ rect: CGRect) -> CGRect {
        let a = viewPoint(rect.origin), b = viewPoint(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).insetBy(dx: -3, dy: -3)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = imageRect()
        image.frame = r
        liveBox.position = r.origin
        liveBox.setAffineTransform(CGAffineTransform(scaleX: r.width / pageSize.width, y: r.height / pageSize.height))
        if let p = lastPointer { pointer.position = viewPoint(p) }
        if let r = lastField { field.frame = viewRect(r) }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        guard let c = controller else { return }
        let theme = c.currentPalette.resolved
        overlay.theme = theme
        layer?.backgroundColor = theme.surface.cgColor
        image.backgroundColor = NSColor.white.cgColor
        image.borderColor = theme.surfaceBorder.cgColor
        image.borderWidth = 0.5
        pointer.backgroundColor = theme.accent.cgColor
        ripple.strokeColor = theme.accent.cgColor
        field.borderColor = theme.accent.cgColor
        field.backgroundColor = theme.accent.alpha(0.12).cgColor
    }

    // MARK: The agent's actions

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func handle(_ e: AgentActivity.WatchEvent) {
        switch e {
        case .caption(let text):
            overlay.caption = text
            overlay.acting = true
        case .pointer(let p, let click):
            movePointer(to: p, click: click)
        case .field(let rect, _):
            showField(rect)
        }
    }

    private func movePointer(to p: CGPoint, click: Bool) {
        let target = viewPoint(p)
        let from = pointer.presentation()?.position ?? pointer.position
        let wasHidden = pointer.isHidden
        lastPointer = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.isHidden = false
        pointer.position = target
        CATransaction.commit()
        if !wasHidden, !reduceMotion {
            pointer.add(AircSpring.row.caAnimation(keyPath: "position", from: NSValue(point: from), to: NSValue(point: target)), forKey: "move")
        }
        guard click else { return }
        ripple.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ripple.position = target
        CATransaction.commit()
        if reduceMotion {
            ripple.opacity = 0
            return
        }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ripple.add(group, forKey: "ring")
    }

    private func showField(_ rect: CGRect?) {
        fieldHide?.cancel()
        guard let rect else { field.isHidden = true; lastField = nil; return }
        lastField = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = viewRect(rect)
        field.isHidden = false
        CATransaction.commit()
        let work = DispatchWorkItem { [weak self] in self?.field.isHidden = true; self?.lastField = nil }
        fieldHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Read-only: nothing gets through

    override func mouseDown(with event: NSEvent) { if window?.firstResponder !== self { window?.makeFirstResponder(self) } }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { escape() }   // Esc
        // agentux3: landed here from "needs you": Return takes over (the page waits for the person to sign in).
        if event.keyCode == 36 || event.keyCode == 76, overlay.landed, overlay.live { takeOver() }
    }

    /// A "needs you" click landed here (AgentAttention): Take over is the default button and has the keys.
    func land() {
        overlay.landed = true
        controller?.window.makeFirstResponder(self)
    }

    var isLanded: Bool { overlay.landed }
    #if AIRC_TESTING
    var landedForTesting: Bool { overlay.landed }
    #endif
    override func keyUp(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) { escape() }

    /// Esc declines a waiting approval (as in the panel), else closes Watch.
    private func escape() {
        if overlay.approval != nil { return answerApproval(allow: false) }
        if let p = overlay.prompt { return AgentPrompts.shared.dismiss(p.id) }
        controller?.sidebar.agents.closeWatch()
    }

    // MARK: The approval card (the panel's, mirrored)

    /// The run's approval, shown here while this row is the Airc Agent run's own window; answering here or in the panel
    /// resolves both (one request, AgentRunCenter.answerApproval).
    private func syncApproval(_ a: AgentApprovalRequest?) {
        let run = AgentRunCenter.shared
        let row = AgentActivity.shared.model.row(rowID)
        let mine = row?.clientKey == AgentBridge.clientKey && row?.window != nil && row?.window == run.runWindowID
        let shown = mine ? a : nil
        guard overlay.approval != shown else { return }
        overlay.approval = shown
        if let row { update(row: row, state: AgentActivity.shared.model.state(row, now: Date())) }
        if shown != nil { NSAccessibility.post(element: self, notification: .layoutChanged) }
    }

    func answerApproval(allow: Bool) { AgentRunCenter.shared.answerApproval(allow: allow) }

    // MARK: The agent's page asks for the person (watchfix: a passkey request, attributed)

    /// The request of the page Watch shows, unless the person put it off ("Not now": it waits in Needs you).
    func syncPrompt() {
        guard let row = AgentActivity.shared.model.row(rowID) else { return }
        let p = AgentPrompts.shared.prompts.first { $0.rowID == rowID && !$0.dismissed }
        guard overlay.prompt != p else { return }
        overlay.prompt = p
        update(row: row, state: AgentActivity.shared.model.state(row, now: Date()))
        if p != nil {
            NSAccessibility.post(element: self, notification: .layoutChanged)
            AgentCenter.shared.onEvent?("watch-prompt \(rowID) \(p!.id)")
        }
    }

    var promptShown: AgentPrompts.Prompt? { overlay.prompt }
    func answerPrompt(allow: Bool) {
        guard let p = overlay.prompt else { return }
        if allow { AgentPrompts.shared.allow(p.id) } else { AgentPrompts.shared.dismiss(p.id) }
    }
    var approvalShown: Bool { overlay.approval != nil }

    // MARK: The bar's actions

    func takeOver() {
        // The pane task's page with its pane open: the pane's Take over, which keeps Hand back.
        if let c = controller, let row = AgentActivity.shared.model.row(rowID), row.window == AgentRunCenter.shared.runWindowID, AgentUI.usesPane,
           let p = AgentPaneController.pane(of: c), p.isShown {
            c.sidebar.agents.closeWatch()
            return p.model.takeOver()
        }
        controller?.sidebar.agents.takeOver(rowID)
    }
    func stopAgent() { controller?.sidebar.agents.stop(rowID) }
    func close() { controller?.sidebar.agents.closeWatch() }
}

final class AgentWatchModel: ObservableObject {
    /// Opened by a "needs you" click: Take over is the default button (Return).
    @Published var landed = false
    @Published var label = ""
    @Published var client = ""
    @Published var caption: String?
    @Published var acting = false
    @Published var live = true
    @Published var icon: NSImage?
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
    @Published var approval: AgentApprovalRequest?
    @Published var prompt: AgentPrompts.Prompt?
    weak var view: AgentWatchView?
}

struct AgentWatchOverlay: View {
    @ObservedObject var model: AgentWatchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: ResolvedTheme { model.theme }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Spacer(minLength: 0)
            if let p = model.prompt {
                AgentPromptCard(prompt: p, theme: theme, answer: { model.view?.answerPrompt(allow: $0) }, takeOver: { model.view?.takeOver() })
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let a = model.approval {
                AgentWatchApprovalCard(request: a, theme: theme, answer: { model.view?.answerApproval(allow: $0) })
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let caption = model.caption {
                HStack(spacing: 8) {
                    if model.live {
                        AgentPulseDot(acting: model.acting, color: theme.accent.nsColor, reduceMotion: reduceMotion)
                            .frame(width: 8, height: 8)
                    }
                    Text(caption)
                        .aircFont(AircFont.body.weight(.medium))
                        .foregroundStyle(theme.surfaceText.color)
                        .lineLimit(1)
                        .testAnchor("agentwatch-caption")
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(theme.surface.color).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
                .overlay(Capsule().strokeBorder(theme.surfaceBorder.color, lineWidth: 0.5))
                .padding(.bottom, AgentWatchView.inset + 12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(caption)
                .accessibilityAddTraits(.updatesFrequently)
                .animation(reduceMotion ? nil : AircSpring.row.animation, value: caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .testAnchorRoot()
        .aircTheme(theme)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = model.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "globe").foregroundStyle(theme.surfaceTextSecondary.color) }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.label).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                Text("Watching · read-only").aircFont(AircFont.caption).foregroundStyle(theme.surfaceTextSecondary.color)
            }
            Spacer(minLength: 8)
            if model.live {
                Button("Take Over") { model.view?.takeOver() }
                    .buttonStyle(.airc(model.landed ? .primary : .secondary, size: .small))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.focusRing.color.opacity(model.landed ? 0.8 : 0), lineWidth: 2).padding(-3))
                    .accessibilityLabel("Take over this page")
                    .help("Make this page one of your tabs. \(model.client) stops working in it.")
                    .testAnchor("agentwatch-takeover")
                Button("Stop") { model.view?.stopAgent() }
                    .buttonStyle(.airc(.secondary, size: .small))
                    .accessibilityLabel("Stop \(model.client)")
                    .help("End what \(model.client) is doing in Airc. It can't continue until you allow it again.")
                    .testAnchor("agentwatch-stop")
            }
            Button { model.view?.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.surfaceTextSecondary.color)
            .accessibilityLabel("Close Watch")
            .help("Close (Esc)")
            .testAnchor("agentwatch-close")
        }
        .padding(.horizontal, AgentWatchView.inset)
        .frame(height: AgentWatchView.barHeight)
    }
}

/// The Airc Agent's approval card on Watch: the panel's card (same request, same answer), so the person can say yes or no
/// while watching. Nothing is pre-selected; Esc declines.
private struct AgentWatchApprovalCard: View {
    let request: AgentApprovalRequest
    let theme: ResolvedTheme
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).aircFont(AircFont.title3).foregroundStyle(theme.surfaceText.color)
            }
            Text(request.risk.reason).aircFont(AircFont.callout).foregroundStyle(theme.surfaceTextSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Deny") { answer(false) }.buttonStyle(.airc(.secondary)).testAnchor("agentwatch-deny")
                Button("Allow Once") { answer(true) }.buttonStyle(.airc(.secondary)).testAnchor("agentwatch-allow")
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.surface.color).shadow(color: .black.opacity(0.2), radius: 10, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.45)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.title) \(request.risk.reason)")
        .testAnchor("agentwatch-approval")
    }
}
