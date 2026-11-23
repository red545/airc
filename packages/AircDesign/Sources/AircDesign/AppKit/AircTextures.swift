// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// Arc's sand, denim and tweed textures (TH-4), as tiles Airc makes itself: procedural and deterministic, built once
/// per process on first use. No image file of Arc's is copied or shipped.
///
/// Arc multiplies its texture into the window at `noiseFactor × strength` (arc_behavior_spec §4.2). A multiply by t is
/// the same as black drawn over the result at alpha 1 − t, on any background, so each tile here is black at alpha
/// 1 − t and the layer's opacity is `grain × strength`: plain source-over, the way grain is drawn, light and dark alike.
///
/// What a tile has to match is Arc's own image: the mean of t (how much it darkens) and its spread, per device pixel,
/// plus the scale and direction of its structure. `Target` holds those, measured from Arc 1.171's shader textures
/// (artifacts/arctextures/REPORT.md, "Measuring Arc's textures"); sand darkens 0.344 at full strength, 5× grain's 0.069.
/// Airc's grain keeps its own tile (`AircGrain`), unchanged.
public enum AircTextures {
    /// Arc's image statistics for one texture: t = the multiply factor per device pixel, 0 (black) … 1 (no change).
    public struct Target: Sendable, Equatable {
        /// Mean of t. 1 − mean is how much the texture darkens at full strength.
        public let mean: Double
        /// Standard deviation of t.
        public let spread: Double
        public var darkening: Double { 1 - mean }
    }

    /// Arc 1.171's `<texture>_metal` images (the ones its shader samples), at 2× (artifacts/arctextures/run/texstats.txt).
    /// Grain's is 0.259 alpha over luma 0.734: t = 1 − 0.259 × (1 − 0.734).
    public static func arcTarget(_ texture: SpaceTheme.Texture) -> Target {
        switch texture {
        case .grain: Target(mean: 0.9312, spread: 0.0409)
        case .sand: Target(mean: 0.6559, spread: 0.2071)
        case .denim: Target(mean: 0.8413, spread: 0.0493)
        case .tweed: Target(mean: 0.7056, spread: 0.0460)
        }
    }

    /// One texture's tile: black at alpha 1 − t, premultiplied, 2× (one sample per device pixel), seamless.
    public struct Tile: @unchecked Sendable {
        public let image: CGImage
        /// Edge length in points.
        public let size: CGFloat
        /// The tile's own t values, row-major, for checks and tests.
        public let values: [Double]
    }

    /// The tile for a texture other than grain (grain is `AircGrain.tile`). Built on first use, then shared.
    public static func tile(_ texture: SpaceTheme.Texture) -> Tile {
        switch texture {
        case .sand: sand
        case .denim: denim
        case .tweed: tweed
        case .grain: sand  // not used: grain draws AircGrain.tile
        }
    }

    private static let sand = makeSand(pixels: 256, seed: 0x5A4D)
    private static let denim = makeDenim(pixels: 240, seed: 0xDE41)
    private static let tweed = makeTweed(pixels: 256, seed: 0x7EED)

    // MARK: - Generators

    /// Sand: fine, slightly soft speckle. A separable [a, 1, a] blur of white noise with a = 0.338 gives Arc's
    /// neighbour correlation (0.55 across, 0.30 diagonal, ~0.08 at two pixels).
    public static func makeSand(pixels n: Int, seed: UInt64) -> Tile {
        var rng = Noise(seed: seed)
        var z = (0..<(n * n)).map { _ in rng.gaussian() }
        z = blur(z, n: n, n, kx: [0.338, 1, 0.338], ky: [0.338, 1, 0.338])
        return tile(fit(z, to: arcTarget(.sand)), n: n, n)
    }

    /// Denim: a twill. Diagonal ridges with a 5 px horizontal period, stepping 1.104 px per row (≈ 42°), fine noise along
    /// the ridges, and faint vertical warp threads, the shares fitted to Arc's correlations (70 %, 25 %, 5 % of the
    /// variance). Width 240 holds 48 periods; 240 rows step 265 px, 53 periods, so the tile is seamless.
    public static func makeDenim(pixels n: Int, seed: UInt64) -> Tile {
        var rng = Noise(seed: seed)
        let period = 5.0, step = period * 53 / Double(n)
        var noise = (0..<(n * n)).map { _ in rng.gaussian() }
        noise = blurDiagonal(noise, n: n, a: 0.22)
        noise = normalized(noise)
        let warp = normalized(blur((0..<n).map { _ in rng.gaussian() }, n: n, 1, kx: [0.5, 1, 0.5], ky: [1]))
        var z = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let ridge = cos(2 * .pi * (Double(x) - step * Double(y)) / period) * 2.0.squareRoot()
                z[y * n + x] = 0.70.squareRoot() * ridge + 0.25.squareRoot() * noise[y * n + x] + 0.05.squareRoot() * warp[x]
            }
        }
        return tile(fit(z, to: arcTarget(.denim)), n: n, n)
    }

    /// Tweed: soft flecks, a little longer down than across, over a faint 16 × 8 px weave that repeats (Arc's tweed
    /// correlates 0.29 across, 0.39 down and ~0.15 at the weave's period).
    public static func makeTweed(pixels n: Int, seed: UInt64) -> Tile {
        var rng = Noise(seed: seed)
        var flecks = (0..<(n * n)).map { _ in rng.gaussian() }
        flecks = normalized(blur(flecks, n: n, n, kx: [0.18, 1, 0.18], ky: [0.27, 1, 0.27]))
        var cell = (0..<(16 * 8)).map { _ in rng.gaussian() }
        cell = normalized(blur(cell, n: 16, 8, kx: [0.3, 1, 0.3], ky: [0.3, 1, 0.3]))
        var z = [Double](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                z[y * n + x] = 0.85.squareRoot() * flecks[y * n + x] + 0.15.squareRoot() * cell[(y % 8) * 16 + x % 16]
            }
        }
        return tile(fit(z, to: arcTarget(.tweed)), n: n, n)
    }

    // MARK: - Helpers

    /// Scales and shifts `z` so that clamp(m + s·z, 0, 1) has the target's mean and spread.
    static func fit(_ z: [Double], to target: Target) -> [Double] {
        let unit = normalized(z)
        var m = target.mean, s = target.spread
        var t = unit
        for _ in 0..<24 {
            t = unit.map { min(1, max(0, m + s * $0)) }
            let (mean, sd) = moments(t)
            m += target.mean - mean
            if sd > 0 { s *= target.spread / sd }
        }
        return unit.map { min(1, max(0, m + s * $0)) }
    }

    static func moments(_ v: [Double]) -> (mean: Double, sd: Double) {
        let n = Double(v.count)
        let mean = v.reduce(0, +) / n
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, variance.squareRoot())
    }

    static func normalized(_ v: [Double]) -> [Double] {
        let (mean, sd) = moments(v)
        return v.map { sd > 0 ? ($0 - mean) / sd : 0 }
    }

    /// Separable blur with wrap-around (so the tile stays seamless). Kernels are odd-length, centred.
    static func blur(_ v: [Double], n w: Int, _ h: Int, kx: [Double], ky: [Double]) -> [Double] {
        func pass(_ src: [Double], _ k: [Double], horizontal: Bool) -> [Double] {
            let r = k.count / 2
            var out = [Double](repeating: 0, count: src.count)
            for y in 0..<h {
                for x in 0..<w {
                    var acc = 0.0
                    for (i, weight) in k.enumerated() {
                        let d = i - r
                        let sx = horizontal ? (x + d + w) % w : x
                        let sy = horizontal ? y : (y + d + h) % h
                        acc += weight * src[sy * w + sx]
                    }
                    out[y * w + x] = acc
                }
            }
            return out
        }
        return pass(pass(v, kx, horizontal: true), ky, horizontal: false)
    }

    /// A [a, 1, a] blur along the (1, 1) diagonal, wrapping.
    static func blurDiagonal(_ v: [Double], n: Int, a: Double) -> [Double] {
        var out = v
        for y in 0..<n {
            for x in 0..<n {
                out[y * n + x] = v[y * n + x] + a * v[((y + n - 1) % n) * n + (x + n - 1) % n] + a * v[((y + 1) % n) * n + (x + 1) % n]
            }
        }
        return out
    }

    /// t values → black at alpha 1 − t (premultiplied: colour 0).
    static func tile(_ t: [Double], n w: Int, _ h: Int) -> Tile {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { bytes[i * 4 + 3] = UInt8(((1 - t[i]) * 255).rounded()) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        // What the 8-bit tile actually draws, for checks.
        let drawn = (0..<(w * h)).map { 1 - Double(bytes[$0 * 4 + 3]) / 255 }
        return Tile(image: image, size: CGFloat(w) / 2, values: drawn)
    }

    /// xorshift64 with Box–Muller: deterministic on every Mac and build.
    struct Noise {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func uniform() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }
}
