// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
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
        previousResponder = c.window.firstResponder
        if takeKeys { c.window.makeFirstResponder(self) }
        running = true
        startedAt = Date()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { layer?.fade(from: 0, to: 1, duration: AircCurve.previewIn.duration) }
        requestFrame()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func stop() {
        running = false
        removeLive()
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
        case .acting(let c): overlay.acting = true; overlay.caption = c ?? "Working…"
        case .idle: overlay.acting = false; overlay.caption = "Waiting for \(row.client)"
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

    private func requestFrame() {
        guard running else { return }
        let interval = 1 / max(1, Self.fps)
        guard let row = AgentActivity.shared.model.row(rowID), row.isLive,
              let w = AgentCenter.shared.windows[row.window], let tab = w.tab(row.tab) else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.requestFrame() }
        }
        // Live where the engine can host its own output and the tab is the one its window shows: nothing to copy, only a
        // look once a second that the context is still the one shown.
        if Self.allowsLive, !Self.ignoresOcclusion, w.activeTabID == row.tab {
            let current = w.driver.liveContextID(in: w.window)
            if let live, live.id == current {
                liveChecks += 1
                return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestFrame() }
            }
            removeLive()
            if let made = w.driver.liveLayer(tab, in: w.window) {
                installLive(made)
                return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.requestFrame() }
            }
        } else if live != nil {
            removeLive()
        }
        // Nothing to draw for: a hidden, minimized or covered window.
        guard let win = window, Self.ignoresOcclusion || win.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.requestFrame() }
        }
        guard !inFlight else { return }
        inFlight = true
        let started = CACurrentMediaTime()
        let scale = win.backingScaleFactor * Self.pixelScale
        let rect = imageRect()
        let maxPixels = CGSize(width: max(64, rect.width * scale), height: max(64, rect.height * scale))
        w.driver.watchFrame(tab, maxPixels: maxPixels) { [weak self] picture in
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
            }
            let wait = max(0, interval - (CACurrentMediaTime() - started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.requestFrame() }
        }
    }

    private func installLive(_ made: (layer: CALayer, id: UInt32, flipped: Bool)) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live = made
        mode = "live"
        liveBox.sublayers?.forEach { $0.removeFromSuperlayer() }
        liveBox.bounds = CGRect(origin: .zero, size: pageSize)
        made.layer.anchorPoint = .zero
        made.layer.frame = liveBox.bounds
        liveBox.addSublayer(made.layer)
        if liveBox.contentsAreFlipped() != made.flipped { liveBox.isGeometryFlipped.toggle() }
        liveBox.isHidden = false
        image.isHidden = true
        CATransaction.commit()
        needsLayout = true
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
        if event.keyCode == 53 { controller?.sidebar.agents.closeWatch() }   // Esc
    }
    override func keyUp(with event: NSEvent) {}
    override func cancelOperation(_ sender: Any?) { controller?.sidebar.agents.closeWatch() }

    // MARK: The bar's actions

    func takeOver() { controller?.sidebar.agents.takeOver(rowID) }
    func stopAgent() { controller?.sidebar.agents.stop(rowID) }
    func close() { controller?.sidebar.agents.closeWatch() }
}

final class AgentWatchModel: ObservableObject {
    @Published var label = ""
    @Published var client = ""
    @Published var caption: String?
    @Published var acting = false
    @Published var live = true
    @Published var icon: NSImage?
    @Published var theme = DesignTheme.default.resolved(systemIsDark: false)
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
                    .buttonStyle(.airc(.secondary, size: .small))
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
