// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import SwiftUI

/// Reduce Motion (System Settings › Accessibility › Display). When it is on, Airc's springs become 150 ms
/// cross-fades: nothing slides, grows or bounces, but changes still don't cut hard. The Space pager cuts.
///
/// ```swift
/// // SwiftUI: the environment decides
/// content.aircAnimation(.toggle, value: isOn)
/// withAircAnimation(.settle) { page = next }
///
/// // Core Animation: sets the model value and either springs or fades the change
/// AircSpring.row.animate(rowLayer, keyPath: "position", to: NSValue(point: p))
/// ```
public enum AircMotion {
    /// The cross-fade every spring and curve becomes under Reduce Motion.
    public static let reducedDuration: Double = 0.15

    /// Whether the user turned on Reduce Motion.
    @MainActor public static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// SwiftUI: the 150 ms ease-in-out every motion becomes.
    public static var crossfade: Animation { .easeInOut(duration: reducedDuration) }

    /// Core Animation: a 150 ms fade of whatever changes in a layer's tree in this transaction.
    public static func crossfadeTransition() -> CATransition {
        let t = CATransition()
        t.type = .fade
        t.duration = reducedDuration
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return t
    }
}

extension AircSpring {
    /// The spring, or the Reduce Motion cross-fade.
    public func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? AircMotion.crossfade : animation
    }

    /// Animates `keyPath` of `layer` to `value` and sets the model value. With Reduce Motion (the system
    /// setting unless given) the change is not interpolated; the layer's superlayer cross-fades it in 150 ms.
    @MainActor
    public func animate(_ layer: CALayer, keyPath: String, to value: Any?, initialVelocity: Double = 0,
                        reduceMotion: Bool = AircMotion.prefersReducedMotion) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        if reduceMotion {
            (layer.superlayer ?? layer).add(AircMotion.crossfadeTransition(), forKey: kCATransition)
        } else {
            layer.add(caAnimation(keyPath: keyPath, from: from, to: value, initialVelocity: initialVelocity), forKey: "airc.\(keyPath)")
        }
    }
}

extension AircCurve {
    /// The curve, or the Reduce Motion cross-fade.
    public func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? AircMotion.crossfade : animation
    }
}

extension View {
    /// `.animation(spring.animation, value:)` that becomes a 150 ms cross-fade under Reduce Motion.
    public func aircAnimation<V: Equatable>(_ spring: AircSpring, value: V) -> some View {
        modifier(AircSpringAnimationModifier(spring: spring, value: value))
    }

    /// `.animation(curve.animation, value:)` that becomes a 150 ms cross-fade under Reduce Motion.
    public func aircAnimation<V: Equatable>(_ curve: AircCurve, value: V) -> some View {
        modifier(AircCurveAnimationModifier(curve: curve, value: value))
    }
}

private struct AircSpringAnimationModifier<V: Equatable>: ViewModifier {
    let spring: AircSpring
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(spring.animation(reduceMotion: reduceMotion), value: value)
    }
}

private struct AircCurveAnimationModifier<V: Equatable>: ViewModifier {
    let curve: AircCurve
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(curve.animation(reduceMotion: reduceMotion), value: value)
    }
}

/// `withAnimation(spring.animation)` that becomes a 150 ms cross-fade under Reduce Motion.
@MainActor
public func withAircAnimation<Result>(_ spring: AircSpring, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(spring.animation(reduceMotion: AircMotion.prefersReducedMotion), body)
}

extension AnyTransition {
    /// A transition that is replaced by a plain fade under Reduce Motion.
    @MainActor
    public static func airc(_ transition: AnyTransition) -> AnyTransition {
        AircMotion.prefersReducedMotion ? .opacity.animation(AircMotion.crossfade) : transition
    }
}
