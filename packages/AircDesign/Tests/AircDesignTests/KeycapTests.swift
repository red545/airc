// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreText
import Testing
@testable import AircDesign

// Keycaps (the command bar's ↵ and shortcut keys, Settings' shortcut list). They crashed the app twice on the build Mac
// while CoreText measured a keycap: the font in the attribute dictionary was nil. Every key the app can show is
// measured and drawn here, in the face it's drawn in, and that face must have the glyph (no CoreText fallback).

/// Every key the app puts on a keycap: the command bar's ↵ and action shortcuts, and Settings' shortcut list
/// (`CommandResult.keys(of:)`, `ShortcutsPage.keys(_:)`), plus keys a shortcut may use next.
private let keysInUse: [String] =
    ["↵", "⌘", "⌥", "⇧", "⌃", "←", "→", "↑", "↓", "⇥", "1–9", "-", "=", "[", "]", ",", ".", "/", "\\", ";", "'", "`"]
    + "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)
    + ["↩", "⌫", "⎋", "Space"]

@MainActor
private func render(_ size: NSSize, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx.cgContext, flipped: true)
    ctx.cgContext.translateBy(x: 0, y: size.height)
    ctx.cgContext.scaleBy(x: 1, y: -1)
    draw(NSRect(origin: .zero, size: size))
    return rep
}

/// Pixels that differ between two renders of the same size.
private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard let pa = a.bitmapData, let pb = b.bitmapData else { return 0 }
    var n = 0
    for i in stride(from: 0, to: a.bytesPerRow * a.pixelsHigh, by: 4) where abs(Int(pa[i]) - Int(pb[i])) > 24 || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 24 {
        n += 1
    }
    return n
}

@MainActor
@Suite struct KeycapTests {
    @Test func everyKeyHasItsGlyphInTheFaceItIsDrawnIn() {
        for key in keysInUse {
            switch AircKeycapGlyph(key) {
            case .text(let s, let style):
                let chars = Array(s.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: chars.count)
                let covered = CTFontGetGlyphsForCharacters(style.nsFont as CTFont, chars, &glyphs, chars.count)
                #expect(covered, "\(key) isn't in \(style.nsFont.fontName): CoreText would fall back to another font")
            case .symbol(let name):
                #expect(AircKeycapView.symbol(name, color: AircColor(red: 0, green: 0, blue: 0)) != nil, "no SF Symbol \(name) for \(key)")
            }
        }
    }

    @Test func keySymbolsUseTheSystemFontOrSFSymbols() {
        #expect(AircKeycapGlyph("D") == .text("D", AircFont.mono))
        #expect(AircKeycapGlyph("1–9") == .text("1–9", AircFont.mono))
        #expect(AircKeycapGlyph("⌘") == .text("⌘", AircKeycapGlyph.symbolStyle))
        #expect(AircKeycapGlyph("←") == .text("←", AircKeycapGlyph.symbolStyle))
        #expect(AircKeycapGlyph("↵") == .symbol("return"))
        #expect(AircKeycapGlyph("⇥") == .symbol("arrow.right.to.line"))
        #expect(AircKeycapGlyph.symbolStyle.design == .default)
    }

    @Test func everyKeyMeasuresAndDraws() {
        let m = AircMetrics.CommandBar.self
        for isDark in [false, true] {
            let theme = SpaceTheme.default.resolved(systemIsDark: isDark)
            let size = AircKeycapView.size(for: "")
            let empty = render(NSSize(width: 60, height: size.height)) { _ in AircKeycapView.draw("", in: NSRect(origin: .zero, size: size), theme: theme) }
            for key in keysInUse {
                let size = AircKeycapView.size(for: key)
                #expect(size.height == m.keycapHeight)
                #expect(size.width >= m.keycapHeight && size.width < 60, "\(key) is \(size.width) pt wide")
                #expect(AircKeycapView.size(for: key) == size)
                let drawn = render(NSSize(width: 60, height: size.height)) { _ in
                    AircKeycapView.draw(key, in: NSRect(origin: .zero, size: size), theme: theme)
                }
                #expect(differing(drawn, empty) > 6, "\(key) drew no ink (\(isDark ? "dark" : "light"))")
            }
        }
    }

    @Test func viewsDrawEveryKey() {
        let theme = SpaceTheme.default.resolved(systemIsDark: false)
        for key in keysInUse {
            let cap = AircKeycapView(key, theme: theme)
            cap.frame = NSRect(origin: .zero, size: cap.intrinsicContentSize)
            let rep = cap.bitmapImageRepForCachingDisplay(in: cap.bounds)!
            cap.cacheDisplay(in: cap.bounds, to: rep)
            #expect(rep.pixelsWide > 0)
        }
        let action = AircCommandActionView(title: "Open", keys: ["⌥", "⇧", "⌘", "C", "↵"], theme: theme)
        action.isSelected = true
        action.frame = NSRect(origin: .zero, size: action.intrinsicContentSize)
        let rep = action.bitmapImageRepForCachingDisplay(in: action.bounds)!
        action.cacheDisplay(in: action.bounds, to: rep)
        #expect(action.intrinsicContentSize.width > 5 * AircMetrics.CommandBar.keycapHeight)
    }

    @Test func fontsAreCachedPerStyle() {
        #expect(AircFont.mono.nsFont === AircFont.mono.nsFont)
        #expect(AircKeycapGlyph.symbolStyle.nsFont === AircKeycapGlyph.symbolStyle.nsFont)
        #expect(AircFont.mono.nsFont !== AircKeycapGlyph.symbolStyle.nsFont)
        #expect(AircFont.mono.nsFont.isFixedPitch)
        #expect(AircFont.display.nsFont.fontDescriptor.symbolicTraits.contains(.bold) || AircFont.display.nsFont.pointSize == 34)
    }

    @Test func aMissingSystemFontIsCaughtAndReplaced() {
        let missing = unsafeBitCast(UInt(0), to: NSFont.self)
        #expect(AircFontCache.present(missing) == nil)
        let real = NSFont.systemFont(ofSize: 11)
        #expect(AircFontCache.present(real) === real)
        let fallback = AircFontCache.fallback(size: 11)
        #expect(fallback.pointSize == 11)
        // The fallback is a font CoreText can lay out with.
        let s = ("⌘ D" as NSString).size(withAttributes: [.font: fallback])
        #expect(s.width > 0)
    }
}
