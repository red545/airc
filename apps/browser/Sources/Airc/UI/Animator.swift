// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit
import QuartzCore

/// Per-frame animations driven by the display's own refresh (120 Hz on ProMotion) through
/// NSView.displayLink. Used where the main thread must lay out every frame: Space paging, theme
/// blending, sidebar hide/show (the page reflows at each step).
final class FrameAnimator: NSObject {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var animations: [String: Animation] = [:]
    private var idleRelease: DispatchWorkItem?

    private final class Animation {
        let tick: (Double) -> Bool   // elapsed seconds → keep running?
        let start: CFTimeInterval
        let completion: (() -> Void)?
        init(tick: @escaping (Double) -> Bool, completion: (() -> Void)?) {
            self.tick = tick
            self.completion = completion
            start = CACurrentMediaTime()
        }
    }

    init(view: NSView) {
        self.view = view
    }

    /// Runs `tick(t)` every frame until it returns false. Replaces an animation with the same key. `immediate`
    /// applies the first frame now (gestures); a spring from rest starts where it is, so it waits for the next vsync.
    func run(_ key: String, immediate: Bool = true, tick: @escaping (Double) -> Bool, completion: (() -> Void)? = nil) {
        animations[key] = Animation(tick: tick, completion: completion)
        ensureLink()
        if immediate { step(now: CACurrentMediaTime()) }
    }

    func cancel(_ key: String) { animations[key] = nil }
    func isRunning(_ key: String) -> Bool { animations[key] != nil }

    /// A spring from `from` to `to`, starting at `velocity` (units per second).
    func spring(_ key: String, from: Double, to: Double, velocity: Double = 0, spring: Spring,
                epsilon: Double = 0.001, update: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        let x0 = from - to
        let v0 = velocity
        run(key, immediate: velocity != 0, tick: { t in
            let s = spring.state(at: t, x0: x0, v0: v0)
            let done = abs(s.x) < epsilon && abs(s.v) < epsilon * 20
            update(done ? to : to + s.x)
            return !done
        }, completion: completion)
    }

    /// A timed curve from 0 to 1.
    func curve(_ key: String, duration: Double, easing: @escaping (Double) -> Double,
               update: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        run(key, tick: { t in
            let p = duration <= 0 ? 1 : min(1, t / duration)
            update(easing(p))
            return p < 1
        }, completion: completion)
    }

    /// The display link is made once per animator and paused when idle (making one costs ~1 ms).
    private func ensureLink() {
        if let link { link.isPaused = false; return }
        guard let view else { return }
        let l = view.displayLink(target: self, selector: #selector(frame(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frame(_ link: CADisplayLink) {
        step(now: link.targetTimestamp)
    }

    private func step(now: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, a) in animations {
            if !a.tick(max(0, now - a.start)) {
                if animations[key] === a { animations[key] = nil }
                a.completion?()
            }
        }
        CATransaction.commit()
        if animations.isEmpty {
            // Paused, then released after 2 s idle (the link retains its target, so it can't outlive use).
            link?.isPaused = true
            idleRelease?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.animations.isEmpty else { return }
                self.link?.invalidate()
                self.link = nil
            }
            idleRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
}

extension CALayer {
    /// Moves the layer with a Core Animation spring (runs in the render server, no main-thread work).
    func springPosition(from old: CGPoint, spring: Spring = Spring(AircSpring.row)) {
        guard old != position else { return }
        let a = CASpringAnimation(keyPath: "position")
        a.fromValue = NSValue(point: old)
        a.toValue = NSValue(point: position)
        a.mass = 1
        a.stiffness = spring.omega * spring.omega
        a.damping = 2 * spring.dampingRatio * spring.omega
        a.duration = a.settlingDuration
        add(a, forKey: "springPosition")
    }

    func fade(from: Float, to: Float, duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        opacity = to
        add(a, forKey: "fade")
    }
}

extension NSView {
    /// Sets the frame; if it moved, the layer glides there on Arc's row spring (115 ms).
    func setFrameAnimated(_ frame: NSRect, animated: Bool, spring: Spring = Spring(AircSpring.row)) {
        let oldPosition = layer?.position
        self.frame = frame
        guard animated, let layer, let oldPosition else { return }
        layer.springPosition(from: oldPosition, spring: spring)
    }
}
