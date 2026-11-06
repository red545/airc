// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A damped spring in SwiftUI's terms: `response` (seconds per oscillation when undamped) and
/// `dampingRatio` (1 = critically damped). The solver only: the named springs are AircDesign's `AircSpring`.
public struct Spring: Equatable, Sendable {
    public var response: Double
    public var dampingRatio: Double

    public init(response: Double, dampingRatio: Double) {
        self.response = max(response, 0.001)
        self.dampingRatio = max(dampingRatio, 0)
    }

    /// Angular frequency ω = 2π / response.
    public var omega: Double { 2 * .pi / response }

    /// Displacement and velocity at time `t` for a spring released at displacement `x0`
    /// (from its target) with velocity `v0`. Units are whatever x0 is in, per second.
    public func state(at t: Double, x0: Double, v0: Double) -> (x: Double, v: Double) {
        let w = omega, z = dampingRatio
        if abs(z - 1) < 1e-6 {
            let c2 = v0 + w * x0
            let e = exp(-w * t)
            return ((x0 + c2 * t) * e, (c2 - w * (x0 + c2 * t)) * e)
        } else if z < 1 {
            let wd = w * sqrt(1 - z * z)
            let a = x0, b = (v0 + z * w * x0) / wd
            let e = exp(-z * w * t)
            let c = cos(wd * t), s = sin(wd * t)
            let x = e * (a * c + b * s)
            let v = e * ((-z * w) * (a * c + b * s) + (-a * wd * s + b * wd * c))
            return (x, v)
        } else {
            let r = sqrt(z * z - 1)
            let r1 = w * (-z + r), r2 = w * (-z - r)
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            return (c1 * exp(r1 * t) + c2 * exp(r2 * t), c1 * r1 * exp(r1 * t) + c2 * r2 * exp(r2 * t))
        }
    }

    /// Time until the spring stays within `epsilon` of rest (sampled at 120 Hz).
    public func settlingTime(x0: Double, v0: Double = 0, epsilon: Double = 0.5) -> Double {
        var lastOutside = 0.0
        var t = 0.0
        while t < 5 {
            let s = state(at: t, x0: x0, v0: v0)
            if abs(s.x) > epsilon || abs(s.v) > epsilon * 10 { lastOutside = t }
            t += 1.0 / 120
        }
        return lastOutside + 1.0 / 120
    }
}

/// Space swipe paging (SP-21, Arc ref §3.3).
public enum SwipePaging {
    /// Release speed (pt/s) at or above which a swipe goes to the next page in its direction.
    public static let flickVelocity: Double = 5
    /// Tracking ratio: page offset per point of scroll delta (Dia's 0.5×; Arc's is unrecorded).
    public static let trackingRatio: Double = 1

    /// The page to settle on. `position` is the fractional page under the sidebar (2.3 = 30 % of the
    /// way from page 2 to page 3); `velocity` in pages per second, positive toward higher pages.
    /// One swipe moves at most one page from `startPage`.
    public static func targetPage(startPage: Int, position: Double, velocity: Double, pageWidth: Double,
                                  pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let speed = velocity * pageWidth
        var target: Int
        if abs(speed) >= flickVelocity {
            target = velocity > 0 ? Int(floor(position)) + 1 : Int(ceil(position)) - 1
            // A flick back toward the start page lands on it.
            if velocity > 0 && position < Double(startPage) { target = startPage }
            if velocity < 0 && position > Double(startPage) { target = startPage }
        } else {
            target = Int(position.rounded())
        }
        target = min(max(target, startPage - 1), startPage + 1)
        return min(max(target, 0), pageCount - 1)
    }

    /// iOS-style rubber band: resistance grows as you pull past the end. `overshoot` and `limit` in points.
    public static func rubberBand(_ overshoot: Double, limit: Double, coefficient: Double = 0.55) -> Double {
        guard limit > 0 else { return 0 }
        let sign: Double = overshoot < 0 ? -1 : 1
        let x = abs(overshoot)
        return sign * (1 - 1 / (x * coefficient / limit + 1)) * limit
    }

    /// The theme blend while a swipe shows parts of two pages: (from, to, t).
    public static func colorBlend(position: Double, pageCount: Int) -> (from: Int, to: Int, t: Double) {
        guard pageCount > 0 else { return (0, 0, 0) }
        let p = min(max(position, 0), Double(pageCount - 1))
        let from = Int(floor(p))
        let to = min(from + 1, pageCount - 1)
        return (from, to, p - Double(from))
    }
}
