// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import Testing
@testable import AircDesign

/// favbacking: which site icons get the light plate on dark surfaces (`AircFavBacking.classify`).
@Suite struct FavBackingTests {
    typealias Px = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    /// A `side`-square RGBA8 buffer (premultiplied, as CGContext gives it) painted by `paint(x, y)`.
    static func icon(side: Int = 32, _ paint: (Int, Int) -> Px?) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                guard let p = paint(x, y) else { continue }
                let a = Double(p.a) / 255
                let i = (y * side + x) * 4
                out[i] = UInt8((Double(p.r) * a).rounded())
                out[i + 1] = UInt8((Double(p.g) * a).rounded())
                out[i + 2] = UInt8((Double(p.b) * a).rounded())
                out[i + 3] = p.a
            }
        }
        return out
    }

    /// The same buffer as a CGImage (for the image path).
    static func image(_ rgba: [UInt8], side: Int = 32) -> CGImage {
        let data = CFDataCreate(nil, rgba, rgba.count)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func tone(_ rgba: [UInt8]) -> AircFavBacking.Tone { AircFavBacking.classify(rgba: rgba, width: 32, height: 32) }

    /// A newspaper-style black "T" on transparency: a bar across the top and a stem, antialiased edges.
    static let blackGlyph = icon { x, y in
        let bar = y >= 4 && y < 10 && x >= 4 && x < 28
        let stem = y >= 10 && y < 28 && x >= 13 && x < 19
        if bar || stem { return (0, 0, 0, 255) }
        let edge = (y == 3 || y == 10) && x >= 4 && x < 28 || (x == 12 || x == 19) && y >= 10 && y < 28
        return edge ? (0, 0, 0, 90) : nil
    }

    @Test func blackGlyphIsDark() {
        #expect(Self.tone(Self.blackGlyph) == .dark)
        #expect(AircFavBacking.classify(Self.image(Self.blackGlyph)) == .dark)
    }

    /// A full-bleed dark icon in several colours: navy, maroon, forest and near-black quadrants.
    @Test func darkMulticolourIsDark() {
        let quad: [Px] = [(0x1B, 0x2A, 0x4A, 255), (0x5A, 0x14, 0x14, 255), (0x12, 0x3D, 0x24, 255), (0x22, 0x22, 0x22, 255)]
        let rgba = Self.icon { x, y in quad[(x < 16 ? 0 : 1) + (y < 16 ? 0 : 2)] }
        #expect(Self.tone(rgba) == .dark)
        #expect(AircFavBacking.classify(Self.image(rgba)) == .dark)
    }

    /// A thin dark outline (a 2 px ring) around transparency vanishes on a dark sidebar too: dark. A light ring doesn't.
    @Test func transparentOutlineIcon() {
        func ring(_ c: Px) -> [UInt8] {
            Self.icon { x, y in
                let inner = x >= 4 && x < 28 && y >= 4 && y < 28
                let outer = x >= 2 && x < 30 && y >= 2 && y < 30
                return outer && !inner ? c : nil
            }
        }
        let dark = ring((0x14, 0x14, 0x14, 255)), light = ring((0xF0, 0xF0, 0xF0, 255))
        #expect(Double(dark.enumerated().filter { $0.offset % 4 == 3 && $0.element > 127 }.count) / 1024 < 0.25)
        #expect(Self.tone(dark) == .dark)
        #expect(Self.tone(light) == .light)
        // A stray dot is not an icon: nothing to back.
        #expect(Self.tone(Self.icon { x, y in x == 16 && y == 16 ? (0, 0, 0, 255) : nil }) == .empty)
        #expect(Self.tone([UInt8](repeating: 0, count: 32 * 32 * 4)) == .empty)
    }

    @Test func lightIconsAreLight() {
        // A white glyph.
        let white = Self.icon { x, y in (x - 16) * (x - 16) + (y - 16) * (y - 16) < 144 ? (0xFF, 0xFF, 0xFF, 255) : nil }
        #expect(Self.tone(white) == .light)
        // A colourful icon: a mid blue and an orange.
        let colour = Self.icon { x, _ in x < 16 ? (0x1A, 0x73, 0xE8, 255) : (0xFB, 0x8C, 0x00, 255) }
        #expect(Self.tone(colour) == .light)
        // A black tile with a white mark (X's icon): dark ground, but its light part reads, so no plate.
        let tile = Self.icon { x, y in
            let mark = abs(x - y) <= 2 && x >= 6 && x < 26 || abs(x + y - 31) <= 1 && x >= 6 && x < 26
            return mark ? (0xFF, 0xFF, 0xFF, 255) : (0, 0, 0, 255)
        }
        #expect(Self.tone(tile) == .light)
        #expect(AircFavBacking.classify(Self.image(white)) == .light)
    }

    /// Unpremultiplied buffers classify the same.
    @Test func straightAlpha() {
        let half: [UInt8] = (0..<(32 * 32)).flatMap { _ in [UInt8(0x10), 0x10, 0x10, 200] }
        #expect(AircFavBacking.classify(rgba: half, width: 32, height: 32, premultiplied: false) == .dark)
    }

    /// The plate's look: subtle (translucent) by default, opaque under Reduce Transparency, opaque white under Increase
    /// Contrast; a black glyph keeps at least 7:1 on it over a dark ground.
    @Test func looks() {
        let normal = AircFavBacking.look(), reduce = AircFavBacking.look(reduceTransparency: true)
        let contrast = AircFavBacking.look(increaseContrast: true, reduceTransparency: true)
        #expect(normal.fill.alpha < 1 && normal.fill.alpha >= 0.7)
        #expect(reduce.fill.alpha == 1 && contrast.fill.alpha == 1)
        #expect(contrast.fill.relativeLuminance > reduce.fill.relativeLuminance)
        let ground = AircColor(0x1E1E1E)
        for l in [normal, reduce, contrast] {
            #expect(AircColor(0x000000).contrast(on: l.fill.over(ground)) >= 7)
        }
    }
}
