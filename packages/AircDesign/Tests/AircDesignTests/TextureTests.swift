// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import Testing
@testable import AircDesign

/// arctextures (TH-4): Airc's own sand, denim and tweed tiles match Arc's measured mean darkening and spread, tile
/// seamlessly, are deterministic, and draw at Arc's strengths.
@Suite struct TextureTests {
    static let textures: [SpaceTheme.Texture] = [.sand, .denim, .tweed]

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
        // Grain is unchanged: 0.8 × 0.55.
        #expect(abs(opacity(.grain, grain: 1) - 0.44) < 1e-9)
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
            let opacity = grain * texture.strength * texture.layerScale
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
