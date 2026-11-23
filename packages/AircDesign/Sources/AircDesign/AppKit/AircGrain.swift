// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore

/// Grain for Space backgrounds: a tile of monochrome noise, light and dark specks around transparent, drawn
/// with plain source-over so it reads the same on light and dark themes and in every snapshot path.
public enum AircGrain {
    /// Tile size in points. The tile is rendered at 2× so the specks are one device pixel.
    public static let tileSize: CGFloat = 128

    /// The shared noise tile (256 × 256 px, deterministic).
    public static let tile: CGImage = makeTile(pixels: Int(tileSize * 2), seed: 0xA1C)

    /// Makes a noise tile: each pixel is white or black with an alpha from a triangular distribution.
    public static func makeTile(pixels n: Int, seed: UInt64) -> CGImage {
        var state = seed &* 0x9E3779B97F4A7C15 | 1
        func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 1_000_003) / 1_000_003
        }
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let v = next() + next() - 1  // triangular, −1...1
            let a = min(1, abs(v) * 0.9)
            let alpha = UInt8((a * 255).rounded())
            let c: UInt8 = v > 0 ? alpha : 0  // premultiplied white or black
            bytes[i * 4] = c
            bytes[i * 4 + 1] = c
            bytes[i * 4 + 2] = c
            bytes[i * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

extension SpaceTheme.Texture {
    /// The tile this texture draws (2×) and its edge in points: Airc's grain, or AircTextures' sand, denim and tweed.
    public var tile: (image: CGImage, size: CGFloat) {
        if self == .grain { return (AircGrain.tile, AircGrain.tileSize) }
        let t = AircTextures.tile(self)
        return (t.image, t.size)
    }
}

/// A layer that tiles the Space's texture over its bounds with two nested replicator layers (one tile in memory,
/// GPU-composited, crisp at 2×). Set `texture` from the theme and `opacity` from
/// `ResolvedTheme.grainOpacity(isWindowActive:)`. Changing the texture swaps the tile once; nothing runs per frame.
public final class AircGrainLayer: CALayer {
    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()
    private let tileLayer = CALayer()

    /// Which texture the layer draws. Grain by default.
    public var texture: SpaceTheme.Texture = .grain {
        didSet {
            guard texture != oldValue else { return }
            applyTile()
            setNeedsLayout()
        }
    }
    private var tileSize: CGFloat = AircGrain.tileSize

    public override init() {
        super.init()
        setUp()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        masksToBounds = true
        tileLayer.contentsScale = 2
        tileLayer.magnificationFilter = .nearest
        columns.addSublayer(tileLayer)
        rows.addSublayer(columns)
        addSublayer(rows)
        actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        rows.actions = actions
        columns.actions = actions
        tileLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        applyTile()
    }

    private func applyTile() {
        let tile = texture.tile
        tileSize = tile.size
        tileLayer.contents = tile.image
        tileLayer.frame = CGRect(x: 0, y: 0, width: tile.size, height: tile.size)
        columns.instanceTransform = CATransform3DMakeTranslation(tile.size, 0, 0)
        rows.instanceTransform = CATransform3DMakeTranslation(0, tile.size, 0)
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        let size = tileSize
        columns.instanceCount = max(1, Int((bounds.width / size).rounded(.up)))
        rows.instanceCount = max(1, Int((bounds.height / size).rounded(.up)))
        rows.frame = bounds
        columns.frame = bounds
    }
}
