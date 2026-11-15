// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// favbacking: a small light plate behind a dark site icon on a dark surface, so a black glyph (a newspaper's "T") isn't
/// black on black. Arc ships the same idea: a 14 pt white rounded square (`FaviconBackground`) behind favicons.
///
/// Whether an icon is dark is read from its pixels (`classify`), once per icon (the app caches it). Only dark contexts
/// draw the plate; light surfaces and light icons look exactly as before.
public enum AircFavBacking {
    /// What an icon's pixels say.
    public enum Tone: String, Sendable, Equatable {
        /// Its visible pixels are dark on average and have no light parts to speak of: it disappears on a dark surface.
        case dark
        /// Light, colourful, or dark with light parts (a white glyph on a black tile): it reads on a dark surface.
        case light
        /// Next to nothing opaque: nothing to back.
        case empty
    }

    // MARK: Classifier

    /// A pixel counts as visible from this alpha up.
    public static let opaqueAlpha = 0.5
    /// At least this share of the icon must be visible (a thin outline icon has ~20 %; a stray dot doesn't count).
    public static let minCoverage = 0.04
    /// The visible pixels' mean relative luminance (WCAG) below which an icon is dark. A dark sidebar ground sits near
    /// 0.02–0.05, so 0.09 is under ~1.7:1 against it.
    public static let darkLuminance = 0.09
    /// Visible pixels at least this bright are the icon's light parts...
    public static let lightPartLuminance = 0.35
    /// ...and an icon with more than this share of them reads on its own (X's white mark on its black tile).
    public static let maxLightShare = 0.08
    /// The side the app renders an icon at before classifying it.
    public static let sampleSide = 32

    /// The tone of an RGBA8 buffer (sRGB, `width * height * 4` bytes, row order doesn't matter). `premultiplied`: the
    /// colour channels are multiplied by alpha, as CGContext's `premultipliedLast` gives them.
    public static func classify(rgba: [UInt8], width: Int, height: Int, premultiplied: Bool = true) -> Tone {
        let n = width * height
        guard n > 0, rgba.count >= n * 4 else { return .empty }
        var visible = 0, light = 0
        var lumSum = 0.0
        for i in 0..<n {
            let a = Double(rgba[i * 4 + 3]) / 255
            guard a >= opaqueAlpha else { continue }
            func ch(_ k: Int) -> Double {
                let v = Double(rgba[i * 4 + k]) / 255
                return premultiplied ? min(1, v / a) : v
            }
            let l = AircColor(red: ch(0), green: ch(1), blue: ch(2)).relativeLuminance
            visible += 1
            lumSum += l
            if l >= lightPartLuminance { light += 1 }
        }
        guard Double(visible) / Double(n) >= minCoverage else { return .empty }
        let mean = lumSum / Double(visible)
        return mean < darkLuminance && Double(light) / Double(visible) <= maxLightShare ? .dark : .light
    }

    /// The tone of `image`, drawn at `sampleSide` square (aspect-fit, as the icon views show it).
    public static func classify(_ image: CGImage) -> Tone {
        let side = sampleSide
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let w = Double(image.width), h = Double(image.height)
            guard w > 0, h > 0 else { return false }
            let s = Double(side) / max(w, h)
            let rect = CGRect(x: (Double(side) - w * s) / 2, y: (Double(side) - h * s) / 2, width: w * s, height: h * s)
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: rect)
            return true
        }
        return drawn ? classify(rgba: bytes, width: side, height: side) : .empty
    }

    // MARK: Look

    /// How the plate is drawn.
    public struct Look: Equatable, Sendable {
        /// Its fill (over the surface).
        public var fill: AircColor
        /// Its corner radius as a share of its side (Arc's plate: 3.5 of 14).
        public var cornerFraction: Double
        /// How far it reaches past the icon's frame on each side, in points.
        public var outset: Double
    }

    /// The plate for the current accessibility settings. Subtle by default: white at 78 % over the dark surface.
    /// Reduce Transparency: the same light grey, opaque. Increase Contrast: opaque white, a hair larger.
    public static func look(increaseContrast: Bool = false, reduceTransparency: Bool = false) -> Look {
        if increaseContrast { return Look(fill: AircColor(0xFFFFFF), cornerFraction: 0.25, outset: 0.5) }
        if reduceTransparency { return Look(fill: AircColor(0xCBCBCB), cornerFraction: 0.25, outset: 0) }
        return Look(fill: AircColor(red: 1, green: 1, blue: 1, alpha: 0.78), cornerFraction: 0.25, outset: 0)
    }
}
