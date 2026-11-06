// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import SwiftUI

/// A floating first-run window (spec ON-5): a fixed-size card over the desktop with large continuous corners,
/// the system window shadow, and no title bar or traffic lights. It is dragged by its background, centred on
/// the active screen, and Esc calls `onEscape` (go back a step). It can't be closed, minimised or zoomed;
/// finishing the flow calls `expand(into:)`, which grows it into the first browser window.
///
/// ```swift
/// let window = AircFloatingWindow(theme: theme, translucency: settings.translucency)
/// window.onEscape = { flow.back() }
/// window.setContent(OnboardingFlow())          // SwiftUI; empty areas drag the window
/// window.present()                             // centred, fades in and rises 8 pt
/// …
/// browser.setFrame(frame, display: true)
/// window.expand(into: browser) { flow.finish() }
/// ```
@MainActor
public final class AircFloatingWindow: NSWindow {
    /// 760 × 540 (`AircMetrics.Onboarding.windowSize`).
    public static let defaultSize = AircMetrics.Onboarding.windowSize

    /// The themed (optionally translucent) background, rounded with the window.
    public let background: SpaceBackgroundView
    /// Add content here, or call `setContent(_:)`. It is clipped to the window's rounded shape.
    public let contentContainer: NSView
    /// Called for Esc. Onboarding goes back a step.
    public var onEscape: (() -> Void)?
    /// The window's corner radius (continuous).
    public let cornerRadius: CGFloat

    private let root: FloatingRootView

    public init(size: CGSize = AircFloatingWindow.defaultSize, theme: ResolvedTheme,
                translucency: AircTranslucency = .default, cornerRadius: CGFloat = AircMetrics.Onboarding.windowRadius) {
        self.cornerRadius = cornerRadius
        background = SpaceBackgroundView(theme: theme, translucency: translucency)
        contentContainer = NSView()
        root = FloatingRootView(cornerRadius: cornerRadius)
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        // No explicit collectionBehavior: on macOS 26.6, `.fullScreenNone` or `.managed` keep a borderless window
        // off screen (verified on the build Mac). Without `.resizable` it can't enter full screen anyway.
        animationBehavior = .none
        level = .normal

        background.cornerRadius = cornerRadius
        background.autoresizingMask = [.width, .height]
        contentContainer.autoresizingMask = [.width, .height]
        root.addSubview(background)
        root.addSubview(contentContainer)
        contentView = root
        root.frame = CGRect(origin: .zero, size: size)
        background.frame = root.bounds
        contentContainer.frame = root.bounds
        root.updateBorder(isDark: theme.isDark)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// Puts a SwiftUI view in the window, over the background, with empty areas dragging the window.
    public func setContent<V: View>(_ view: V) {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let host = NSHostingView(rootView: view.background(AircWindowDragArea()))
        host.frame = contentContainer.bounds
        host.autoresizingMask = [.width, .height]
        contentContainer.addSubview(host)
    }

    /// Switches the background theme (cross-fade when animated) and the window's hairline.
    public func setTheme(_ theme: ResolvedTheme, animated: Bool) {
        background.setTheme(theme, animated: animated)
        root.updateBorder(isDark: theme.isDark)
    }

    // MARK: Placement

    /// The screen a new window belongs on: the one with the key window, else the one under the pointer,
    /// else the main screen.
    public static var activeScreen: NSScreen? {
        if let s = NSApp.keyWindow?.screen { return s }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// A frame of `size`, centred horizontally in `visibleFrame` and slightly above centre (optical centre).
    public static func centeredFrame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let x = visibleFrame.midX - size.width / 2
        let free = max(0, visibleFrame.height - size.height)
        let y = visibleFrame.minY + free * AircMetrics.Onboarding.opticalCenterBias
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Moves the window to the optical centre of `screen` (default: the active screen).
    public func centerOnActiveScreen(_ screen: NSScreen? = nil) {
        guard let s = screen ?? Self.activeScreen else { return center() }
        setFrame(Self.centeredFrame(size: frame.size, in: s.visibleFrame), display: false)
    }

    /// Centres the window, then fades it in while it rises 8 pt (`AircCurve.entrance`); a plain fade under
    /// Reduce Motion. With `focus` (the default) it becomes key; without, it is ordered front without taking focus
    /// from the active app (snapshot runs, background launches with `open -g`).
    public func present(on screen: NSScreen? = nil, focus: Bool = true, reduceMotion: Bool = AircMotion.prefersReducedMotion) {
        centerOnActiveScreen(screen)
        let final = frame
        alphaValue = 0
        if !reduceMotion { setFrameOrigin(CGPoint(x: final.minX, y: final.minY - AircMetrics.Onboarding.entranceRise)) }
        if focus { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? AircMotion.reducedDuration : AircCurve.entrance.duration
            ctx.timingFunction = reduceMotion ? CAMediaTimingFunction(name: .easeInEaseOut) : AircCurve.entrance.timingFunction
            animator().alphaValue = 1
            if !reduceMotion { animator().setFrame(final, display: true) }
        }
    }

    // MARK: Keys

    public override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape { onEscape() } else { super.keyDown(with: event) }
    }

    // MARK: Expansion

    /// Grows this window into `target` (the first browser window, already at its final frame and laid out,
    /// not yet visible) on `AircSpring.expand`: the themed shape springs from the card's frame and corner
    /// radius to the target's while the card's content fades out, then the target is revealed under it and
    /// this window closes. Under Reduce Motion the two windows cross-fade in 150 ms.
    ///
    /// The steps run on wall-clock timers, not on animation callbacks, so `completion` fires (exactly once, after
    /// about 0.53 s) even when the display sleeps and Core Animation stops drawing.
    ///
    /// `expandForCapture(into:freezeAt:onFrozen:completion:)` pauses the expansion mid-way for snapshots.
    public func expand(into target: NSWindow, targetCornerRadius: CGFloat = AircMetrics.Onboarding.browserWindowRadius,
                       reduceMotion: Bool = AircMotion.prefersReducedMotion, completion: (@MainActor () -> Void)? = nil) {
        startExpansion(into: target, targetCornerRadius: targetCornerRadius, reduceMotion: reduceMotion, freezeAt: nil,
                       onFrozen: nil, completion: completion)
    }

    /// Like `expand(into:)`, but pauses at `freezeAt` (0…1 of the spring's settle time) and calls `onFrozen` with the
    /// overlay window, so a snapshot run can capture that frame. Call `resumeExpansion()` to finish.
    public func expandForCapture(into target: NSWindow, freezeAt: Double,
                                 targetCornerRadius: CGFloat = AircMetrics.Onboarding.browserWindowRadius,
                                 onFrozen: @escaping @MainActor (NSWindow) -> Void, completion: (@MainActor () -> Void)? = nil) {
        startExpansion(into: target, targetCornerRadius: targetCornerRadius, reduceMotion: false, freezeAt: freezeAt,
                       onFrozen: onFrozen, completion: completion)
    }

    private func startExpansion(into target: NSWindow, targetCornerRadius: CGFloat, reduceMotion: Bool, freezeAt: Double?,
                                onFrozen: (@MainActor (NSWindow) -> Void)?, completion: (@MainActor () -> Void)?) {
        let once = AircOnce()
        let finish: @MainActor () -> Void = { [weak self] in
            guard once.claim() else { return }
            self?.expansion = nil
            self?.orderOut(nil)
            self?.close()
            target.makeKeyAndOrderFront(nil)
            completion?()
        }
        if reduceMotion {
            target.alphaValue = 0
            target.order(.below, relativeTo: windowNumber)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = AircMotion.reducedDuration
                target.animator().alphaValue = 1
                self.animator().alphaValue = 0
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(AircMotion.reducedDuration))
                finish()
            }
            return
        }
        let overlay = AircExpansionOverlay(from: frame, fromRadius: cornerRadius, to: target.frame, toRadius: targetCornerRadius,
                                           theme: background.theme, snapshot: Self.snapshot(contentContainer),
                                           arriving: target.contentView.flatMap(Self.snapshot), level: level)
        target.alphaValue = 0
        target.orderFront(nil)
        overlay.order(.above, relativeTo: target.windowNumber)
        orderOut(nil)
        expansion = overlay
        overlay.run(spring: AircSpring.expand, freezeAt: freezeAt, onFrozen: onFrozen, reveal: {
            target.alphaValue = 1
        }, completion: {
            finish()
        })
    }

    /// Finishes an expansion paused with `expandForCapture(into:freezeAt:onFrozen:)`.
    public func resumeExpansion() {
        expansion?.resume()
    }

    /// The overlay window of a running expansion, or nil.
    public var expansionWindow: NSWindow? { expansion }

    private var expansion: AircExpansionOverlay?

    private static func snapshot(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}

/// The window's root: rounds and clips everything to the window shape and draws the 0.5 pt rim macOS draws
/// on its own windows (light in dark themes, dark in light ones).
@MainActor
private final class FloatingRootView: NSView {
    private let rim = CALayer()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        rim.cornerRadius = cornerRadius
        rim.cornerCurve = .continuous
        rim.borderWidth = 0.5
        rim.zPosition = 100
        rim.actions = ["bounds": NSNull(), "position": NSNull(), "borderColor": NSNull()]
        layer?.addSublayer(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }

    func updateBorder(isDark: Bool) {
        rim.borderColor = (isDark ? AircColor.white(0.14) : AircColor.black(0.10)).cgColor
    }

    override func layout() {
        super.layout()
        rim.frame = bounds
    }
}

/// A transparent overlay window that draws the expansion: one themed, rounded shape springing from the
/// floating window's frame to the browser window's. The onboarding content fades out on it in 120 ms; the
/// browser window's own content (a snapshot, pinned to the top-left like the real sidebar) fades in as the room
/// grows, so the sidebar and page card arrive with it.
@MainActor
final class AircExpansionOverlay: NSWindow {
    private let from: CGRect
    private let to: CGRect
    private let fromRadius: CGFloat
    private let toRadius: CGFloat
    private let shape = CALayer()
    private let shadow = CALayer()
    private let underlay = CALayer()
    private let color = CALayer()
    private let grain = AircGrainLayer()
    private let snapshot = CALayer()
    private let arriving = CALayer()

    init(from: CGRect, fromRadius: CGFloat, to: CGRect, toRadius: CGFloat, theme: ResolvedTheme, snapshot image: CGImage?,
         arriving arrivingImage: CGImage?, level: NSWindow.Level) {
        self.from = from
        self.to = to
        self.fromRadius = fromRadius
        self.toRadius = toRadius
        let canvas = from.union(to).insetBy(dx: -80, dy: -80)
        super.init(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        self.level = level

        let view = NSView(frame: CGRect(origin: .zero, size: canvas.size))
        let rootLayer = CALayer()
        view.layer = rootLayer
        view.wantsLayer = true
        contentView = view
        let scale = NSScreen.screens.first { $0.frame.intersects(to) }?.backingScaleFactor ?? 2

        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.32
        shadow.shadowRadius = 24
        shadow.shadowOffset = CGSize(width: 0, height: -14)
        shape.masksToBounds = true
        shape.cornerCurve = .continuous
        underlay.backgroundColor = theme.underlay.cgColor
        color.contents = theme.colorLayerImage(for: to.size)
        color.contentsGravity = .resize
        grain.opacity = Float(theme.grainOpacity())
        grain.frame = CGRect(origin: .zero, size: CGSize(width: max(from.width, to.width), height: max(from.height, to.height)))
        snapshot.contents = image
        snapshot.contentsScale = scale
        snapshot.contentsGravity = .resize
        arriving.contents = arrivingImage
        arriving.contentsScale = scale
        arriving.contentsGravity = .resize
        arriving.anchorPoint = CGPoint(x: 0, y: 1)
        arriving.bounds = CGRect(origin: .zero, size: to.size)
        arriving.opacity = 0
        for l in [shadow, shape, underlay, color, snapshot, arriving] as [CALayer] { l.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull(), "shadowPath": NSNull(), "opacity": NSNull()] }
        rootLayer.addSublayer(shadow)
        rootLayer.addSublayer(shape)
        shape.addSublayer(underlay)
        shape.addSublayer(color)
        shape.addSublayer(grain)
        shape.addSublayer(arriving)
        shape.addSublayer(snapshot)
        place(rect: local(from), radius: fromRadius)
        arriving.position = CGPoint(x: 0, y: from.height)
        snapshot.frame = CGRect(origin: .zero, size: from.size)
    }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    private func place(rect: CGRect, radius: CGFloat) {
        let bounds = CGRect(origin: .zero, size: rect.size)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        shape.bounds = bounds
        shape.position = center
        shape.cornerRadius = radius
        shadow.bounds = bounds
        shadow.position = center
        shadow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        for l in [underlay, color] { l.bounds = bounds; l.position = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    private var pendingRemaining: (() -> Void)?

    /// Runs the spring. `reveal` is called once the shape reads as arrived (the target becomes visible under
    /// the overlay), `completion` after the overlay has faded off it. Both run on wall-clock timers.
    func run(spring: AircSpring, freezeAt: Double? = nil, onFrozen: (@MainActor (NSWindow) -> Void)? = nil,
             reveal: @escaping @MainActor () -> Void, completion: @escaping @MainActor () -> Void) {
        orderFront(nil)
        let a = local(from), b = local(to)
        let bBounds = CGRect(origin: .zero, size: b.size)
        let aBounds = CGRect(origin: .zero, size: a.size)
        func add(_ layer: CALayer, _ keyPath: String, _ fromValue: Any, _ toValue: Any) {
            layer.add(spring.caAnimation(keyPath: keyPath, from: fromValue, to: toValue), forKey: keyPath)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let aCenter = NSValue(point: CGPoint(x: a.midX, y: a.midY)), bCenter = NSValue(point: CGPoint(x: b.midX, y: b.midY))
        for l in [shape, shadow] {
            add(l, "bounds", NSValue(rect: aBounds), NSValue(rect: bBounds))
            add(l, "position", aCenter, bCenter)
        }
        add(shape, "cornerRadius", fromRadius, toRadius)
        add(shadow, "shadowPath", CGPath(roundedRect: aBounds, cornerWidth: fromRadius, cornerHeight: fromRadius, transform: nil),
            CGPath(roundedRect: bBounds, cornerWidth: toRadius, cornerHeight: toRadius, transform: nil))
        for l in [underlay, color] {
            add(l, "bounds", NSValue(rect: aBounds), NSValue(rect: bBounds))
            add(l, "position", NSValue(point: CGPoint(x: aBounds.midX, y: aBounds.midY)), NSValue(point: CGPoint(x: bBounds.midX, y: bBounds.midY)))
        }
        // The card's content rides along at its own size, centred, and fades out in the first 120 ms.
        add(snapshot, "position", NSValue(point: CGPoint(x: aBounds.midX, y: aBounds.midY)), NSValue(point: CGPoint(x: bBounds.midX, y: bBounds.midY)))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        snapshot.add(fade, forKey: "fade")
        snapshot.opacity = 0
        // The browser's content rides the top-left corner and fades in over the middle of the motion.
        add(arriving, "position", NSValue(point: CGPoint(x: 0, y: aBounds.height)), NSValue(point: CGPoint(x: 0, y: bBounds.height)))
        arriving.position = CGPoint(x: 0, y: bBounds.height)
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        appear.beginTime = CACurrentMediaTime() + 0.06
        appear.duration = 0.2
        appear.fillMode = .backwards
        appear.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        arriving.add(appear, forKey: "appear")
        arriving.opacity = 1
        snapshot.position = CGPoint(x: bBounds.midX, y: bBounds.midY)
        place(rect: b, radius: toRadius)
        CATransaction.commit()

        // ≈ 99 % of the travel: the shape reads as arrived; reveal the window under it and fade the overlay off.
        let arrive = spring.settlingDuration * 0.62
        let fadeOff = 0.18
        let tail: (Double) -> Void = { [weak self] delay in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                reveal()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = fadeOff
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self?.animator().alphaValue = 0
                }, completionHandler: nil)
                // Don't wait for the fade's own callback: it never comes while the display sleeps.
                try? await Task.sleep(for: .seconds(fadeOff + 0.02))
                self?.orderOut(nil)
                self?.close()
                completion()
            }
        }
        if let freezeAt, let root = contentView?.layer {
            let t = spring.settlingDuration * min(1, max(0, freezeAt))
            let now = root.convertTime(CACurrentMediaTime(), from: nil)
            root.speed = 0
            root.timeOffset = now + t
            pendingRemaining = { [weak root] in
                guard let root else { return }
                let paused = root.timeOffset
                root.speed = 1
                root.timeOffset = 0
                root.beginTime = 0
                root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - paused
                tail(max(0, arrive - t))
            }
            displayIfNeeded()
            onFrozen?(self)
        } else {
            tail(arrive)
        }
    }

    /// Resumes a frozen expansion.
    func resume() {
        let r = pendingRemaining
        pendingRemaining = nil
        r?()
    }
}

/// A SwiftUI background that drags its window: put it behind content so empty areas move the window
/// (`.background(AircWindowDragArea())`). Controls on top keep their clicks.
public struct AircWindowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { DragAreaView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Lets empty areas of this view drag the window (borderless windows such as `AircFloatingWindow`).
    public func aircWindowDraggable() -> some View {
        background(AircWindowDragArea())
    }
}

final class DragAreaView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Lets a completion run exactly once.
@MainActor
final class AircOnce {
    private var done = false
    func claim() -> Bool {
        defer { done = true }
        return !done
    }
}
