// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import SwiftUI

/// What the main view shows over a page the Airc Agent works in (agentmainview, docs/design/agent-ux.md §5): a soft glow
/// in the Space's accent colour around the page, a slim bar at the top ("Airc Agent is using this tab · Take over ·
/// Stop"), a pulse where the agent clicks, and, while it drives, a shield that keeps the person's clicks and typing off
/// the page ("Take over to use this page"). It lies over the page inside the card, so nothing moves when it appears.
final class AgentMainChromeView: NSView {
    enum Mode: Equatable {
        case off
        /// The agent drives the page. `waiting`: it waits for the person's OK in the pane.
        case working(waiting: Bool)
        /// The person took the tab over; Hand back gives it to the agent again.
        case takenOver
    }

    final class BarModel: ObservableObject {
        @Published var mode: Mode = .off
        @Published var hint: String?
        @Published var name = "Airc Agent"
        /// The buttons' frames in the bar's own space (top left), for the clicks AgentMainChromeView dispatches itself.
        var hitRects: [String: CGRect] = [:]
        @Published var pressed: String?
        var onTakeOver: () -> Void = {}
        var onStop: () -> Void = {}
        var onHandBack: () -> Void = {}
    }

    let bar = BarModel()
    /// The person scrolled the page while the agent drives it (allowed: the agent looks again before its next click).
    var onPersonScroll: (() -> Void)?
    /// The page's view, for scrolls the shield passes on.
    weak var page: NSView?
    private(set) var mode: Mode = .off
    private(set) var acting = false
    /// Checks: how many of the person's clicks and keys the shield kept off the page, and pulses drawn.
    private(set) var blockedClicks = 0
    private(set) var blockedKeys = 0
    private(set) var pulses = 0
    private(set) var lastPulse: CGPoint?

    private let glow = CALayer()
    private let glowRing = CAShapeLayer()
    private let edgeLine = CAShapeLayer()
    private let pulseLayer = CALayer()
    private var barHost: AircFirstClickHostingView<AnyView>!
    private var hintWork: DispatchWorkItem?
    private var accent: NSColor = .controlAccentColor
    var cornerRadius: CGFloat = 6 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // The glow: a ring just outside the page whose shadow falls inward (an inner glow that never covers the middle).
        glowRing.fillRule = .evenOdd
        glowRing.shadowOffset = .zero
        glowRing.shadowOpacity = 1
        glowRing.shadowRadius = 16
        glow.addSublayer(glowRing)
        edgeLine.fillColor = nil
        edgeLine.lineWidth = 1.5
        glow.addSublayer(edgeLine)
        glow.opacity = 0
        layer?.addSublayer(glow)
        layer?.addSublayer(pulseLayer)
        let root = AnyView(AgentMainBar(model: bar))
        barHost = AircFirstClickHostingView(rootView: root)
        // Near the window's title bar: no safe-area inset (it moved the buttons away from where they're drawn), as Watch.
        barHost.safeAreaRegions = []
        barHost.isHidden = true
        addSubview(barHost)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var palette: Palette?

    func setTheme(_ palette: Palette) {
        guard palette != self.palette else { return }
        self.palette = palette
        accent = palette.resolved.accent.nsColor
        barHost.rootView = AnyView(AgentMainBar(model: bar).aircTheme(palette.resolved).testAnchorRoot())
        barHost.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowRing.fillColor = accent.cgColor
        glowRing.shadowColor = accent.cgColor
        edgeLine.strokeColor = accent.withAlphaComponent(palette.isDark ? 0.75 : 0.6).cgColor
        CATransaction.commit()
    }

    func set(_ m: Mode, animated: Bool = true) {
        guard m != mode else { return }
        let was = mode
        mode = m
        bar.mode = m
        isHidden = m == .off
        barHost.isHidden = m == .off
        if m == .off { bar.hint = nil; setActing(false) }
        let target: Float
        switch m {
        case .off: target = 0
        case .working: target = acting ? 1 : 0.7
        case .takenOver: target = 0
        }
        fade(glow, to: target, animated: animated && was != .off)
        if case .working = m {} else { glow.removeAnimation(forKey: "breathe") }
        needsLayout = true
        reclaimKeys()
    }

    /// The person's keys stop at the shield while the agent drives (a WebKit click by the agent can hand the page the
    /// keys: they come back here after each call).
    func reclaimKeys() {
        guard shields, let w = window else { return }
        if let r = w.firstResponder as? NSView, let page, r === page || r.isDescendant(of: page) { w.makeFirstResponder(self) }
    }

    /// While a tool call runs: the glow breathes; between calls it rests (calm, no animation while idle).
    func setActing(_ on: Bool) {
        guard on != acting else { return }
        acting = on
        guard case .working = mode else { glow.removeAnimation(forKey: "breathe"); return }
        if on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.55
            a.toValue = 1
            a.duration = 0.9
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(a, forKey: "breathe")
            glow.opacity = 0.8
        } else {
            glow.removeAnimation(forKey: "breathe")
            fade(glow, to: 0.7, animated: true)
        }
    }

    private func fade(_ l: CALayer, to v: Float, animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.35 : 0)
        CATransaction.setDisableActions(!animated)
        l.opacity = v
        CATransaction.commit()
    }

    var shields: Bool { if case .working = mode { return true }; return false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        glow.frame = bounds
        pulseLayer.frame = bounds
        // CGPath's rounded rect traps when the corner is more than half the side (an empty frame before layout).
        guard bounds.width > 2 * cornerRadius + 2, bounds.height > 2 * cornerRadius + 2 else { CATransaction.commit(); return }
        let inner = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let ring = CGMutablePath()
        ring.addRect(bounds.insetBy(dx: -60, dy: -60))
        ring.addPath(inner)
        glowRing.path = ring
        edgeLine.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: max(0, cornerRadius - 0.75),
                               cornerHeight: max(0, cornerRadius - 0.75), transform: nil)
        CATransaction.commit()
        // A fixed height (bar + room for the hint), the content pinned to its top: the bar never moves while the hint
        // comes and goes (a click on it must land where it was).
        let size = barHost.fittingSize
        let w = min(bounds.width - 24, max(size.width, 200))
        barHost.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: 10, width: w, height: 66)
    }

    // MARK: The shield

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let sv = superview else { return nil }
        let p = convert(point, from: sv)
        // The bar's own strip: its clicks are dispatched here (barButton), the rest of the host's room goes to the page.
        if !barHost.isHidden, barStrip.contains(p) { return self }
        return shields && bounds.contains(p) ? self : nil
    }

    override var acceptsFirstResponder: Bool { shields || landed }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var barStrip: NSRect { NSRect(x: barHost.frame.minX, y: barHost.frame.minY, width: barHost.frame.width, height: 36) }

    /// The bar button under a point of this view (its key in BarModel.hitRects), if any.
    private func barButton(at p: NSPoint) -> String? {
        let local = CGPoint(x: p.x - barHost.frame.minX, y: p.y - barHost.frame.minY)
        return bar.hitRects.first { $0.value.insetBy(dx: -2, dy: -3).contains(local) }?.key
    }

    private func fire(_ key: String) {
        switch key {
        case "takeover": bar.onTakeOver()
        case "handback": bar.onHandBack()
        case "stop": bar.onStop()
        default: break
        }
    }

    override func mouseDown(with event: NSEvent) {
        landed = false
        let p = convert(event.locationInWindow, from: nil)
        if !barHost.isHidden, barStrip.contains(p) {
            bar.pressed = barButton(at: p)
            return
        }
        guard shields else { return super.mouseDown(with: event) }
        blockedClicks += 1
        window?.makeFirstResponder(self)
        showHint()
    }
    override func rightMouseDown(with event: NSEvent) { if shields { blockedClicks += 1; showHint() } else { super.rightMouseDown(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if shields { blockedClicks += 1; showHint() } else { super.otherMouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let pressed = bar.pressed else { return }
        bar.pressed = nil
        let p = convert(event.locationInWindow, from: nil)
        if barButton(at: p) == pressed { fire(pressed) }
    }

    /// A "needs you" click landed here: Return takes over (the person chose to answer), until they click or type.
    var landed = false

    override func keyDown(with event: NSEvent) {
        if landed, event.keyCode == 36 || event.keyCode == 76 {
            landed = false
            return bar.onTakeOver()
        }
        landed = false
        guard shields else { return super.keyDown(with: event) }
        // Esc and Tab are calm: no hint for them.
        if event.keyCode == 53 || event.keyCode == 48 { return }
        blockedKeys += 1
        showHint()
    }
    override func keyUp(with event: NSEvent) {}

    /// Scrolling to look is allowed: the agent looks again before it clicks (AgentMainView.viewChanged).
    override func scrollWheel(with event: NSEvent) {
        guard shields, let page else { return super.scrollWheel(with: event) }
        let p = page.convert(event.locationInWindow, from: nil)
        (page.hitTest(page.superview.map { page.convert(p, to: $0) } ?? p) ?? page).scrollWheel(with: event)
        onPersonScroll?()
    }

    func showHint(_ text: String = "Take over to use this page") {
        hintWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { bar.hint = text }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.25)) { self?.bar.hint = nil } }
        hintWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
        needsLayout = true
    }

    // MARK: Where the agent clicks

    /// A small pulse at a point of the page (its top-left coordinates, the agent's): the person sees what it touches.
    func pulse(at p: CGPoint) {
        guard !isHidden, bounds.contains(p) else { return }
        pulses += 1
        lastPulse = p
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let ring = CAShapeLayer()
        let r: CGFloat = 9
        ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        ring.position = p
        ring.fillColor = accent.withAlphaComponent(0.18).cgColor
        ring.strokeColor = accent.cgColor
        ring.lineWidth = 2
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7), transform: nil)
        dot.position = p
        dot.fillColor = accent.cgColor
        dot.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.lineWidth = 1.5
        pulseLayer.addSublayer(ring)
        pulseLayer.addSublayer(dot)
        let d = reduce ? 0.6 : 0.65
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer(); dot.removeFromSuperlayer() }
        if !reduce {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 0.4
            s.toValue = 2.6
            s.duration = d
            s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(s, forKey: "s")
        }
        for (l, len) in [(ring, d), (dot, d + 0.35)] {
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 1
            o.toValue = 0
            o.duration = len
            o.timingFunction = CAMediaTimingFunction(name: .easeIn)
            o.fillMode = .forwards
            o.isRemovedOnCompletion = false
            l.add(o, forKey: "o")
        }
        CATransaction.commit()
    }

    #if AIRC_TESTING
    /// Checks: the glow's resting opacity and whether it breathes.
    var glowState: (opacity: Float, breathing: Bool) { (glow.opacity, glow.animation(forKey: "breathe") != nil) }
    var barFrame: NSRect { barHost.isHidden ? .zero : barHost.frame }
    #endif
}

/// The slim bar at the top of the page: who uses the tab, and Take over / Stop (or Hand back).
struct AgentMainBar: View {
    @ObservedObject var model: AgentMainChromeView.BarModel
    @Environment(\.aircTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent.color)
                Text(title).aircFont(AircFont.caption).foregroundStyle(theme.surfaceText.color).lineLimit(1)
                    .testAnchor("agentmain.bar.title")
                Spacer(minLength: 6)
                switch model.mode {
                case .takenOver:
                    Button("Hand back") { model.onHandBack() }.buttonStyle(.airc(.primary, size: .small)).testAnchor("agentmain.handback")
                        .modifier(BarHit(key: "handback", model: model))
                default:
                    Button("Take over") { model.onTakeOver() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentmain.takeover")
                        .help("Use this page yourself; the agent waits until you hand it back")
                        .modifier(BarHit(key: "takeover", model: model))
                }
                Button("Stop") { model.onStop() }.buttonStyle(.airc(.secondary, size: .small)).testAnchor("agentmain.stop")
                    .help("Stop the task")
                    .modifier(BarHit(key: "stop", model: model))
            }
            .padding(.leading, 12).padding(.trailing, 5).frame(height: 34)
            .background(Capsule(style: .continuous).fill(.regularMaterial))
            .overlay(Capsule(style: .continuous).strokeBorder(theme.surfaceBorder.color))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .fixedSize()
            if let h = model.hint {
                Text(h).aircFont(AircFont.caption).foregroundStyle(theme.surfaceText.color)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule(style: .continuous).fill(.regularMaterial))
                    .overlay(Capsule(style: .continuous).strokeBorder(theme.accent.color.opacity(0.5)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .testAnchor("agentmain.hint")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: AgentMainBar.space)
        .testAnchor("agentmain.bar")
    }

    static let space = "agentmain.bar.space"

    /// Each button's frame in the bar's space (the chrome view dispatches the clicks: a SwiftUI host this close to the
    /// title bar didn't get them), and a pressed look while held.
    struct BarHit: ViewModifier {
        let key: String
        @ObservedObject var model: AgentMainChromeView.BarModel
        func body(content: Content) -> some View {
            content
                .opacity(model.pressed == key ? 0.6 : 1)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(AgentMainBar.space)) }) { model.hitRects[key] = $0 }
                .onDisappear { model.hitRects[key] = nil }
        }
    }

    private var title: String {
        switch model.mode {
        case .takenOver: return "You're using this tab · \(model.name) waits"
        case .working(waiting: true): return "\(model.name) is waiting for your OK"
        default: return "\(model.name) is using this tab"
        }
    }
}
