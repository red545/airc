// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import Testing
@testable import AircDesign

/// arctextures (TH-4) and grainmatch: Airc's own grain, sand, denim and tweed tiles match Arc's measured mean darkening
/// and spread, tile seamlessly, are deterministic, and draw at Arc's strengths.
@Suite struct TextureTests {
    static let textures: [SpaceTheme.Texture] = [.grain, .sand, .denim, .tweed]

    @Test(arguments: textures) func tileMatchesArcMeanAndSpread(_ texture: SpaceTheme.Texture) {
        let tile = AircTextures.tile(texture)
        let target = AircTextures.arcTarget(texture)
        let (mean, sd) = AircTextures.moments(tile.values)
        // 8-bit quantisation moves the mean by < 1/510.
        #expect(abs(mean - target.mean) < 0.002, "\(texture) mean \(mean) vs Arc \(target.mean)")
        #expect(abs(sd - target.spread) < 0.003, "\(texture) spread \(sd) vs Arc \(target.spread)")
        #expect(tile.image.width == Int(tile.size * 2) && tile.image.height == tile.image.width)
    }

    @Test func arcDarkeningRatiosAsMeasured() {
        // Sand's image darkens about 5× grain's (paritysweep's finding, measured here from Arc's shader textures).
        let ratio = AircTextures.arcTarget(.sand).darkening / AircTextures.arcTarget(.grain).darkening
        #expect(ratio > 4.8 && ratio < 5.2, "\(ratio)")
    }

    @Test(arguments: textures) func tileIsSeamless(_ texture: SpaceTheme.Texture) {
        let tile = AircTextures.tile(texture)
        let n = tile.image.width
        let v = tile.values
        func columnStep(_ a: Int, _ b: Int) -> Double {
            (0..<n).reduce(0) { $0 + abs(v[$1 * n + a] - v[$1 * n + b]) } / Double(n)
        }
        func rowStep(_ a: Int, _ b: Int) -> Double {
            (0..<n).reduce(0) { $0 + abs(v[a * n + $1] - v[b * n + $1]) } / Double(n)
        }
        let inside = (1..<n).map { columnStep($0 - 1, $0) }.reduce(0, +) / Double(n - 1)
        let insideRows = (1..<n).map { rowStep($0 - 1, $0) }.reduce(0, +) / Double(n - 1)
        // The step across the seam is like any step inside: no visible tile edge.
        #expect(abs(columnStep(n - 1, 0) - inside) < 0.25 * inside, "\(texture) column seam")
        #expect(abs(rowStep(n - 1, 0) - insideRows) < 0.25 * insideRows, "\(texture) row seam")
    }

    @Test func tilesAreDeterministic() {
        #expect(AircTextures.makeGrain(pixels: 64, seed: 3).values == AircTextures.makeGrain(pixels: 64, seed: 3).values)
        #expect(AircTextures.makeSand(pixels: 64, seed: 3).values == AircTextures.makeSand(pixels: 64, seed: 3).values)
        #expect(AircTextures.makeDenim(pixels: 80, seed: 3).values == AircTextures.makeDenim(pixels: 80, seed: 3).values)
        #expect(AircTextures.makeTweed(pixels: 64, seed: 3).values == AircTextures.makeTweed(pixels: 64, seed: 3).values)
    }

    @Test func layerOpacityIsArcsStrength() {
        func opacity(_ t: SpaceTheme.Texture, grain: Double, active: Bool = true) -> Double {
            SpaceTheme(colors: [AircColor(0x7EB6D5)], grain: grain, texture: t).resolved(systemIsDark: false).grainOpacity(isWindowActive: active)
        }
        #expect(abs(opacity(.sand, grain: 1) - 0.15) < 1e-9)
        #expect(abs(opacity(.denim, grain: 1) - 0.6) < 1e-9)
        #expect(abs(opacity(.tweed, grain: 0.5) - 0.2) < 1e-9)
        #expect(abs(opacity(.tweed, grain: 0.5, active: false) - 0.05) < 1e-9)
        // Grain is Arc's multiply at strength 0.8 (grainmatch; before it, Airc's speck tile at 0.8 × 0.55).
        #expect(abs(opacity(.grain, grain: 1) - 0.8) < 1e-9)
        #expect(abs(opacity(.grain, grain: 0.25) - 0.2) < 1e-9)
        #expect(opacity(.sand, grain: 0) == 0)
    }

    /// The drawn result is Arc's multiply: a flat colour under the layer darkens by grain × strength × (1 − mean).
    @Test(arguments: textures) func drawnDarkeningIsArcsMultiply(_ texture: SpaceTheme.Texture) {
        let tile = AircTextures.tile(texture)
        let n = tile.image.width
        for (base, grain) in [(0.85, 1.0), (0.85, 0.5), (0.2, 1.0)] {
            let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: base, green: base, blue: base, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            let opacity = grain * texture.strength
            ctx.setAlpha(opacity)
            ctx.draw(tile.image, in: CGRect(x: 0, y: 0, width: n, height: n))
            let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
            var sum = 0.0
            for i in 0..<(n * n) { sum += Double(px[i * 4]) / 255 }
            let drawn = sum / Double(n * n)
            let expected = base * (1 - opacity * AircTextures.arcTarget(texture).darkening)
            #expect(abs(drawn - expected) < 0.004, "\(texture) on \(base) at \(grain): \(drawn) vs Arc \(expected)")
        }
    }

    /// grainmatch: grain darkens, never lightens (Airc's old speck tile lightened dark Spaces × 1.18), and its structure is
    /// Arc's: one-pixel noise, neighbour correlation 0.39 across and down, ~0.15 diagonal, ~0 at two pixels; its
    /// percentiles follow Arc's image (t = 1 − 0.259 × (1 − luma): p01 0.827, p50 0.938, p99 0.994).
    @Test func grainIsArcsMultiplyNoise() {
        let tile = AircTextures.tile(.grain)
        let v = tile.values, n = tile.image.width
        #expect(n == 256 && tile.size == AircGrain.tileSize)
        #expect(tile.image === AircGrain.tile)
        // Black only: the colour channels are 0 (premultiplied), so it can only darken.
        let data = tile.image.dataProvider!.data! as Data
        #expect(stride(from: 0, to: data.count, by: 4).allSatisfy { data[$0] == 0 && data[$0 + 1] == 0 && data[$0 + 2] == 0 })
        let (mean, sd) = AircTextures.moments(v)
        func corr(_ dx: Int, _ dy: Int) -> Double {
            var acc = 0.0
            for y in 0..<n { for x in 0..<n { acc += (v[y * n + x] - mean) * (v[((y + dy) % n) * n + (x + dx) % n] - mean) } }
            return acc / Double(n * n) / (sd * sd)
        }
        #expect(abs(corr(1, 0) - 0.39) < 0.04 && abs(corr(0, 1) - 0.39) < 0.04, "lag-1 \(corr(1, 0)), \(corr(0, 1))")
        #expect(abs(corr(1, 1) - 0.15) < 0.04, "diagonal \(corr(1, 1))")
        #expect(abs(corr(2, 0)) < 0.08, "lag-2 \(corr(2, 0))")
        let sorted = v.sorted()
        func p(_ f: Double) -> Double { sorted[Int(f * Double(sorted.count))] }
        let arc = [(0.01, 1 - 0.259 * (1 - 0.333)), (0.5, 1 - 0.259 * (1 - 0.762)), (0.99, 1 - 0.259 * (1 - 0.978))]
        for (f, want) in arc { #expect(abs(p(f) - want) < 0.006, "p\(Int(f * 100)) \(p(f)) vs Arc \(want)") }
        #expect(sorted.filter { $0 >= 1 }.count < sorted.count / 50, "clamped at 1")
    }

    @Test @MainActor func layerSwapsTheTileOnlyWhenTheTextureChanges() {
        let layer = AircGrainLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        layer.layoutIfNeeded()
        func tileLayer() -> CALayer? { layer.sublayers?.first?.sublayers?.first?.sublayers?.first }
        #expect(tileLayer()?.contents as! CGImage === AircGrain.tile)
        layer.texture = .denim
        layer.layoutIfNeeded()
        #expect(tileLayer()?.contents as! CGImage === AircTextures.tile(.denim).image)
        #expect(tileLayer()?.frame.width == AircTextures.tile(.denim).size)
        let columns = layer.sublayers?.first?.sublayers?.first as? CAReplicatorLayer
        #expect(columns?.instanceCount == Int((600 / AircTextures.tile(.denim).size).rounded(.up)))
        layer.texture = .grain
        #expect(tileLayer()?.contents as! CGImage === AircGrain.tile)
    }
}
