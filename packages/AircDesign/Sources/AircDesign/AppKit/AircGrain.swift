// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore

/// Grain for Space backgrounds: Arc's grain as a multiply (grainmatch). The tile is `AircTextures`' grain, black at alpha
/// 1 − t matched to Arc 1.171's grain image (mean darkening 0.069, spread 0.041, one-pixel noise), drawn at
/// `grain × 0.8` like Arc's shader, so it darkens light and dark Spaces by the same factor (× 0.945 at full grain).
public enum AircGrain {
    /// Tile size in points. The tile is rendered at 2× so the noise is one device pixel.
    public static let tileSize: CGFloat = 128

    /// The shared grain tile (256 × 256 px, deterministic).
    public static var tile: CGImage { AircTextures.tile(.grain).image }

    /// Makes a grain tile of `n` × `n` pixels.
    public static func makeTile(pixels n: Int, seed: UInt64) -> CGImage {
        AircTextures.makeGrain(pixels: n, seed: seed).image
    }
}

extension SpaceTheme.Texture {
    /// The tile this texture draws (2×) and its edge in points (AircTextures).
    public var tile: (image: CGImage, size: CGFloat) {
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
