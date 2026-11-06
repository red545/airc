// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore

/// The themed window background: Arc's gradient (computed exactly, per pixel) plus grain. Put it behind the
/// sidebar and the page card, filling the window.
///
/// ```swift
/// let bg = SpaceBackgroundView(theme: space.theme.resolved(systemIsDark: isDark), translucency: .subtle)
/// bg.setTheme(next.resolved(systemIsDark: isDark), animated: true)   // 90 ms cross-fade, Arc's τ ≈ 30 ms
/// ```
///
/// Layers, back to front (Arc's order): the macOS behind-window blur (`AircMaterialView`, only when
/// translucent), the white or black underlay at `ResolvedTheme.underlayOpacity(for:)`, the colour layer at
/// `layerOpacity`, then grain. With `translucency: .off` the underlay is opaque and nothing shows through.
///
/// Tracked automatically: grain drops to ¼ and the window goes opaque while it is not main (as in Arc), and
/// Reduce Transparency makes it opaque. A translucent background makes its window non-opaque with a clear
/// background colour when it moves into it (set `configuresWindow = false` to do that yourself).
@MainActor
public final class SpaceBackgroundView: NSView {
    public private(set) var theme: ResolvedTheme
    /// Overrides the automatic main-window tracking when set.
    public var isWindowActiveOverride: Bool? { didSet { updateState(animated: false) } }
    /// Overrides the system's Reduce Transparency setting when set (tests, snapshots).
    public var reduceTransparencyOverride: Bool? { didSet { updateState(animated: false) } }
    /// How much of the desktop shows through. `.off` by default here; the app passes the user's setting
    /// (`AircTranslucency.default` is `.subtle`).
    public var translucency: AircTranslucency {
        didSet {
            guard translucency != oldValue else { return }
            configureMaterial()
            updateState(animated: false)
        }
    }
    /// Draws the behind-window blur under the theme. Turn it off for a second background stacked over a first
    /// one (a swipe between two Spaces), so the blur isn't drawn twice.
    public var drawsMaterial = true { didSet { configureMaterial() } }
    /// Makes the window non-opaque with a clear background when translucent. On by default.
    public var configuresWindow = true
    /// Rounds the background, its blur included (continuous corners). 0 by default: the window clips it.
    public var cornerRadius: CGFloat = 0 { didSet { applyCornerRadius() } }
    /// The underlay opacity currently drawn: 1 is opaque.
    public private(set) var currentUnderlayOpacity: Double = 1

    private let material = AircMaterialView()
    private let themeView = NSView()
    private let underlayLayer = CALayer()
    private let colorLayer = CALayer()
    private let grainLayer = AircGrainLayer()
    private let blendUnderlayLayer = CALayer()
    private let blendColorLayer = CALayer()
    private var blendTheme: ResolvedTheme?
    private var prerendered: (theme: ResolvedTheme, image: CGImage)?
    private var renderedAspect: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var floorCache: (theme: ResolvedTheme, translucency: AircTranslucency, value: Double)?

    public init(theme: ResolvedTheme, translucency: AircTranslucency = .off, frame: NSRect = .zero) {
        self.theme = theme
        self.translucency = translucency
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        material.autoresizingMask = [.width, .height]
        themeView.autoresizingMask = [.width, .height]
        themeView.wantsLayer = true
        themeView.layerContentsRedrawPolicy = .never
        addSubview(material)
        addSubview(themeView)
        colorLayer.contentsGravity = .resize
        let still: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
        underlayLayer.actions = still
        colorLayer.actions = still
        grainLayer.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        themeView.layer?.addSublayer(underlayLayer)
        themeView.layer?.addSublayer(colorLayer)
        blendColorLayer.contentsGravity = .resize
        for l in [blendUnderlayLayer, blendColorLayer] {
            l.actions = still
            l.opacity = 0
            themeView.layer?.addSublayer(l)
        }
        themeView.layer?.addSublayer(grainLayer)
        underlayLayer.backgroundColor = theme.underlay.cgColor
        configureMaterial()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateState(animated: true) }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isOpaque: Bool { translucency == .off && cornerRadius == 0 }
    public override var mouseDownCanMoveWindow: Bool { true }
    /// The background never takes clicks from its own layers; it behaves as one plain view.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Switches theme. Animated, the colour cross-fades in 90 ms (Arc's neighbour-Space τ ≈ 30 ms).
    public func setTheme(_ newTheme: ResolvedTheme, animated: Bool) {
        setTheme(newTheme, colorLayer: nil, animated: animated)
    }

    /// Switches theme using a colour layer rendered ahead of time, off the main thread
    /// (`AircBackgroundCache.colorLayer(for:size:)` or `ResolvedTheme.colorLayerImage(for:)` for this view's aspect
    /// ratio). With nil, the view takes it from `AircBackgroundCache.shared`, rendering only on a miss.
    public func setTheme(_ newTheme: ResolvedTheme, colorLayer image: CGImage?, animated: Bool) {
        guard newTheme != theme else { return }
        if let image { prerendered = (newTheme, image) }
        let oldUnderlay = theme.underlay
        theme = newTheme
        if animated {
            let fade = CABasicAnimation(keyPath: "contents")
            fade.duration = AircCurve.themeCrossfade.duration
            fade.timingFunction = AircCurve.themeCrossfade.timingFunction
            colorLayer.add(fade, forKey: "themeCrossfade")
            if oldUnderlay != newTheme.underlay {
                let u = CABasicAnimation(keyPath: "backgroundColor")
                u.fromValue = oldUnderlay.cgColor
                u.duration = fade.duration
                u.timingFunction = fade.timingFunction
                underlayLayer.add(u, forKey: "themeCrossfade")
            }
        }
        underlayLayer.backgroundColor = newTheme.underlay.cgColor
        material.appearance = NSAppearance(named: newTheme.isDark ? .darkAqua : .aqua)
        render()
        updateState(animated: animated)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = themeView.bounds
        underlayLayer.frame = b
        colorLayer.frame = b
        blendUnderlayLayer.frame = b
        blendColorLayer.frame = b
        blendColorLayer.contentsScale = window?.backingScaleFactor ?? 2
        grainLayer.frame = b
        colorLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        // The 45° axis depends on the aspect ratio; re-render only when it changes noticeably.
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 1
        if abs(aspect - renderedAspect) > 0.02 { render() }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateState(animated: true) }
            })
        }
        configureWindow()
        updateState(animated: false)
    }

    private func render() {
        let size = bounds.size == .zero ? CGSize(width: 16, height: 10) : bounds.size
        renderedAspect = size.height > 0 ? size.width / size.height : 1
        if let p = prerendered, p.theme == theme {
            colorLayer.contents = p.image
            prerendered = nil
        } else {
            colorLayer.contents = AircBackgroundCache.shared.colorLayer(for: theme, size: size)
        }
        if let blend = blendTheme {
            blendColorLayer.contents = AircBackgroundCache.shared.colorLayer(for: blend, size: size)
        }
    }

    // MARK: Blending (swipes between Spaces)

    /// Blends toward another Space's background by `fraction` (0 = this theme, 1 = `other`), in one view: the
    /// other theme's underlay and colour layer are drawn over this one's at that opacity. Use it while a swipe
    /// shows parts of two Spaces, instead of stacking two background views; call `setBlend(nil, fraction: 0)` (or
    /// `setTheme`) when the swipe settles. Cheap enough to call every frame; images come from the cache.
    public func setBlend(_ other: ResolvedTheme?, fraction: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let other, fraction > 0 else {
            blendTheme = nil
            blendUnderlayLayer.opacity = 0
            blendColorLayer.opacity = 0
            blendColorLayer.contents = nil
            blendFraction = 0
            return
        }
        if other != blendTheme {
            blendTheme = other
            blendUnderlayLayer.backgroundColor = other.underlay.cgColor
            let size = bounds.size == .zero ? CGSize(width: 16, height: 10) : bounds.size
            blendColorLayer.contents = AircBackgroundCache.shared.colorLayer(for: other, size: size)
        }
        let f = Float(min(1, max(0, fraction)))
        // The other underlay at the same opacity as ours, so translucency stays constant through the blend.
        blendUnderlayLayer.opacity = f * underlayLayer.opacity
        blendColorLayer.opacity = f
        blendFraction = Double(f)
    }

    /// The current blend fraction (0 when not blending).
    public private(set) var blendFraction: Double = 0

    private func configureMaterial() {
        material.isHidden = translucency == .off || !drawsMaterial
        material.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        configureWindow()
    }

    private func configureWindow() {
        guard configuresWindow, translucency != .off, let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }

    private func applyCornerRadius() {
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
        material.maskImage = cornerRadius > 0 ? AircMaterialView.roundedMask(radius: cornerRadius) : nil
    }

    private func underlayTarget(active: Bool, reduce: Bool) -> Double {
        guard translucency != .off, active, !reduce else { return 1 }
        if let c = floorCache, c.theme == theme, c.translucency == translucency { return c.value }
        let v = theme.underlayOpacity(for: translucency)
        floorCache = (theme, translucency, v)
        return v
    }

    private func updateState(animated: Bool) {
        let active = isWindowActiveOverride ?? (window?.isMainWindow ?? true)
        let reduce = reduceTransparencyOverride ?? AircTranslucency.systemReducesTransparency
        let grain = Float(theme.grainOpacity(isWindowActive: active))
        let underlay = Float(underlayTarget(active: active, reduce: reduce))
        currentUnderlayOpacity = Double(underlay)
        if animated {
            for (layer, target) in [(grainLayer as CALayer, grain), (underlayLayer, underlay)] where layer.opacity != target {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = layer.presentation()?.opacity ?? layer.opacity
                a.toValue = target
                a.duration = 0.2
                a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(a, forKey: "state")
            }
        }
        grainLayer.opacity = grain
        underlayLayer.opacity = underlay
    }
}

/// The macOS behind-window blur that translucent Airc surfaces sit on: `.underWindowBackground`, blending
/// behind the window, always active (Airc decides when to go opaque, not the material). Set its appearance to
/// match the theme so the blur leans light or dark with it (Arc's `TranslucencyStyle`).
@MainActor
public class AircMaterialView: NSVisualEffectView {
    public override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var mouseDownCanMoveWindow: Bool { true }

    /// A stretchable rounded-rectangle mask (continuous corners) for `maskImage`.
    public static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
