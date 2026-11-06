// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import QuartzCore
import SwiftUI

/// A named spring, parameterised the way Arc's motion was measured: response (the period of the undamped
/// oscillation, in seconds) and damping ratio ζ, with mass 1.
///
/// stiffness = (2π / response)², damping = 2 ζ √stiffness. ζ = 1 is critically damped (no overshoot).
public struct AircSpring: Hashable, Sendable {
    public let response: Double
    public let dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    public var mass: Double { 1 }
    public var stiffness: Double { pow(2 * .pi / response, 2) }
    public var damping: Double { 2 * dampingRatio * stiffness.squareRoot() }

    /// Time until the motion is within 0.1 % of its travel and stays there.
    public var settlingDuration: Double {
        let w = 2 * .pi / response
        let z = dampingRatio
        if z >= 1 { return 9.23 / w }  // critically damped: (1 + ωt) e^(−ωt) = 0.001
        return -log(0.001 * (1 - z * z).squareRoot()) / (z * w)
    }

    // MARK: Named springs (Arc 1.170/1.171 measurements)

    /// Rows opening, closing and reordering; rows gliding after a drop (≈ 115 ms visually). 0.13 s, ζ 0.9.
    public static let row = AircSpring(response: 0.13, dampingRatio: 0.9)
    /// Space pages settling after a swipe, click or ⌃1–9; critically damped (ω ≈ 33). 0.19 s, ζ 1.
    public static let settle = AircSpring(response: 0.19, dampingRatio: 1)
    /// Favorites making room for a dragged tab; folder close (ω ≈ 25, settled ≈ 240 ms). 0.25 s, ζ 1.
    public static let fold = AircSpring(response: 2 * .pi / 25, dampingRatio: 1)
    /// Hidden sidebar sliding in from the edge, ≈ 4 pt overshoot. 0.175 s, ζ 0.80.
    public static let reveal = AircSpring(response: 0.175, dampingRatio: 0.80)
    /// Hidden sidebar sliding away. 0.175 s, ζ 0.76.
    public static let conceal = AircSpring(response: 0.175, dampingRatio: 0.76)
    /// The Library pushing the sidebar aside. 0.245 s, ζ 0.92.
    public static let push = AircSpring(response: 0.245, dampingRatio: 0.92)
    /// Toasts arriving from 0.7 scale (peaks at ≈ 1.04). 0.32 s, ζ 0.52.
    public static let pop = AircSpring(response: 0.32, dampingRatio: 0.52)
    /// Popovers and the theme picker growing from their anchor (≈ 310 ms, small overshoot). 0.3 s, ζ 0.78.
    public static let grow = AircSpring(response: 0.30, dampingRatio: 0.78)
    /// Switches and small controls following a click. 0.22 s, ζ 0.82.
    public static let toggle = AircSpring(response: 0.22, dampingRatio: 0.82)
    /// The onboarding window expanding into the first browser window (ON-5): soft, ≈ 0.3 % overshoot, reads
    /// as done in ≈ 350 ms. Drives the frame and the corner radius together. 0.40 s, ζ 0.88.
    public static let expand = AircSpring(response: 0.40, dampingRatio: 0.88)

    public static let all: [(name: String, spring: AircSpring)] = [
        ("row", row), ("settle", settle), ("fold", fold), ("reveal", reveal), ("conceal", conceal),
        ("push", push), ("pop", pop), ("grow", grow), ("toggle", toggle), ("expand", expand),
    ]

    // MARK: SwiftUI

    public var animation: Animation {
        .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping, initialVelocity: 0)
    }

    /// The spring with an initial velocity, in units of the total travel per second (gesture hand-off).
    public func animation(initialVelocity: Double) -> Animation {
        .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping, initialVelocity: initialVelocity)
    }

    // MARK: Core Animation

    /// A configured `CASpringAnimation`. `initialVelocity` is in units of the travel per second, as CA expects.
    public func caAnimation(keyPath: String, from: Any? = nil, to: Any? = nil, initialVelocity: Double = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.mass = mass
        a.stiffness = stiffness
        a.damping = damping
        a.initialVelocity = initialVelocity
        a.fromValue = from
        a.toValue = to
        a.duration = settlingDuration
        return a
    }
}

/// A fixed-duration curve, for the few motions Arc runs on curves (keys and clicks, not fingers).
public struct AircCurve: Hashable, Sendable {
    public let duration: Double
    /// Cubic Bézier control points (x1, y1, x2, y2), as in CSS.
    public let c1: CGPoint
    public let c2: CGPoint

    public init(duration: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.duration = duration
        self.c1 = CGPoint(x: x1, y: y1)
        self.c2 = CGPoint(x: x2, y: y2)
    }

    /// ⌘S hides the sidebar: ease-out cubic, 110 ms.
    public static let sidebarHide = AircCurve(duration: 0.110, 0.33, 1, 0.68, 1)
    /// ⌘S shows the sidebar: ease-out cubic, 100 ms.
    public static let sidebarShow = AircCurve(duration: 0.100, 0.33, 1, 0.68, 1)
    /// Folder opening: cubic-bezier(0, 0, 0.58, 1), 200 ms.
    public static let folderOpen = AircCurve(duration: 0.200, 0, 0, 0.58, 1)
    /// Row press: plate to 0.99 scale, linear, 70 ms.
    public static let press = AircCurve(duration: 0.070, 0, 0, 1, 1)
    /// Selected row easing back from hover, 170 ms.
    public static let selectionSettle = AircCurve(duration: 0.170, 0.25, 0.1, 0.25, 1)
    /// Window colour cross-fade to a neighbouring Space (exponential, τ ≈ 30 ms).
    public static let themeCrossfade = AircCurve(duration: 0.090, 0, 0, 0.2, 1)
    /// Folder preview in (90 ms) and tooltip out (270 ms) use ease-out.
    public static let previewIn = AircCurve(duration: 0.090, 0, 0, 0.2, 1)
    public static let tooltipOut = AircCurve(duration: 0.270, 0, 0, 0.2, 1)
    /// Toast out: ease-in, 70 ms.
    public static let toastOut = AircCurve(duration: 0.070, 0.42, 0, 1, 1)
    /// Dialog drop: 32 pt over 275 ms, ease-in-out.
    public static let dialog = AircCurve(duration: 0.275, 0.42, 0, 0.58, 1)
    /// Onboarding page transitions (conductor's entrance ease), 420 ms.
    public static let entrance = AircCurve(duration: 0.420, 0.22, 1, 0.36, 1)

    public var animation: Animation {
        .timingCurve(c1.x, c1.y, c2.x, c2.y, duration: duration)
    }

    public var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(c1.x), Float(c1.y), Float(c2.x), Float(c2.y))
    }
}
