// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import QuartzCore
import SwiftUI
import Testing
@testable import AircDesign

// Design pass 4 (docs/qa/visual-review.md): sidebar ink as rendered, and the components the app adopts.

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// The darkest pixel of an image, composited over `background` (images may be transparent).
private func darkest(_ image: CGImage, over background: AircColor) -> AircColor {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(background.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var best = (sum: Int.max, r: 0, g: 0, b: 0)
    for i in 0..<(w * h) {
        let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
        if r + g + b < best.sum { best = (r + g + b, r, g, b) }
    }
    return AircColor(red: Double(best.r) / 255, green: Double(best.g) / 255, blue: Double(best.b) / 255)
}

/// The ink alpha that turns `background` into `seen` (green channel, the widest range on light themes).
private func effectiveAlpha(_ seen: AircColor, ink: AircColor, background: AircColor) -> Double {
    (background.green - seen.green) / (background.green - ink.green)
}

/// A light Space's sidebar in a real (offscreen) window: the themed background colour, and a label of a full block
/// glyph so the darkest pixel is fully covered ink.
@MainActor
private final class SidebarFixture {
    let window: NSWindow
    let root: NSView
    let label: NSTextField

    init(background: AircColor, ink: AircColor, label: NSTextField) {
        let size = NSSize(width: 120, height: 60)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = background.cgColor
        self.label = label
        label.font = .systemFont(ofSize: 40)
        label.textColor = ink.nsColor
        label.stringValue = "█"
        label.frame = NSRect(x: 10, y: 5, width: 100, height: 50)
        root.addSubview(label)
        window.contentView = root
        window.orderBack(nil)   // far off screen; never key, never focused
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}

@MainActor
@Suite(.serialized) struct SidebarInkTests {
    let mint = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)

    @Test func colourHelpersCompositeAtTheTokenAlpha() {
        // AircColor → NSColor/CGColor and plain Core Graphics drawing: text and fills land exactly on the token.
        let bg = mint.background
        for ink in [mint.text, mint.textSecondary, mint.textTertiary] {
            let ctx = CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: "█", attributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: ink.nsColor])
                .draw(at: NSPoint(x: 4, y: 2))
            NSGraphicsContext.restoreGraphicsState()
            let seen = darkest(ctx.makeImage()!, over: bg)
            let a = effectiveAlpha(seen, ink: ink.alpha(1), background: bg)
            #expect(abs(a - ink.alpha) < 0.02, "drawn \(seen) for ink \(ink): alpha \(a)")
        }
    }

    @Test func labelsRenderAtTheTokenAlphaInAircSnapshot() {
        // The sidebar's labels (stock NSTextField and AircFadingLabel) captured offscreen the way the screen shows them.
        let bg = mint.background
        for ink in [mint.text, mint.textSecondary, mint.textTertiary] {
            for (kind, label) in [("NSTextField", NSTextField(labelWithString: "")), ("AircFadingLabel", AircFadingLabel(style: AircFont.row))] {
                let f = SidebarFixture(background: bg, ink: ink, label: label)
                let rep = AircSnapshot.bitmap(of: f.root)!
                let a = effectiveAlpha(darkest(rep.cgImage!, over: bg), ink: ink.alpha(1), background: bg)
                #expect(abs(a - ink.alpha) < 0.03, "\(kind) ink \(ink.alpha) captured at \(a)")
                f.window.orderOut(nil)
            }
        }
    }

    @Test func plainCacheDisplayDoublesStockLabels() {
        // Documents the cause of visual-review #5: AppKit's own capture composites a stock label twice
        // (1 − (1 − a)²). If Apple fixes this, the expectation flips and AircSnapshot's workaround can go.
        let bg = mint.background
        let ink = mint.textSecondary
        let f = SidebarFixture(background: bg, ink: ink, label: NSTextField(labelWithString: ""))
        let rep = f.root.bitmapImageRepForCachingDisplay(in: f.root.bounds)!
        f.root.cacheDisplay(in: f.root.bounds, to: rep)
        let a = effectiveAlpha(darkest(rep.cgImage!, over: bg), ink: ink.alpha(1), background: bg)
        let doubled = 1 - (1 - ink.alpha) * (1 - ink.alpha)
        let usesSimpleLabel = f.label.subviews.contains { AircSnapshot.duplicatingViewClasses.contains(String(describing: type(of: $0))) }
        print("cacheDisplay of a stock label: ink \(ink.alpha) → \(a) (doubled would be \(doubled)); simple-label subview: \(usesSimpleLabel)")
        if usesSimpleLabel {
            #expect(abs(a - doubled) < 0.03)
        }
    }

    @Test func onScreenBackingStoreHoldsTheTokenAlpha() {
        // What the window server composites: the private label's own backing store (its ContentLayer), copied into a
        // delegate-free layer so Core Animation can't ask a view to draw again.
        let bg = mint.background
        let ink = mint.textSecondary
        let f = SidebarFixture(background: bg, ink: ink, label: NSTextField(labelWithString: ""))
        func contentLayers(_ l: CALayer) -> [CALayer] {
            (l.contents != nil && l.delegate == nil ? [l] : []) + (l.sublayers ?? []).flatMap(contentLayers)
        }
        guard let backing = f.label.layer.map(contentLayers)?.first else {
            print("no separate content layer on this macOS; nothing to check")
            return
        }
        let copy = CALayer()
        copy.frame = CGRect(origin: .zero, size: backing.bounds.size)
        copy.contents = backing.contents
        copy.contentsScale = backing.contentsScale
        copy.contentsGravity = backing.contentsGravity
        let ctx = CGContext(data: nil, width: Int(copy.bounds.width * 2), height: Int(copy.bounds.height * 2), bitsPerComponent: 8,
                            bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        copy.render(in: ctx)
        let a = effectiveAlpha(darkest(ctx.makeImage()!, over: bg), ink: ink.alpha(1), background: bg)
        #expect(abs(a - ink.alpha) < 0.03, "backing store at \(a)")
    }
}

@MainActor
@Suite struct Pass4ComponentTests {
    @Test func presetPagesFitWithoutCuttingADisc() {
        let room = AircThemePicker.presetRowRoom
        for page in AircThemePicker.presetPages {
            #expect(AircThemePicker.presetRowWidth(discs: page.themes.count) <= room, "\(page.id)")
        }
        let all = AircThemePicker.presetPages.flatMap(\.themes).count
        #expect(all == SpaceTheme.presets.count + SpaceTheme.swatches.count)
    }

    @Test func waveAccentShowsOnThePickerSurface() {
        // The wave uses the edited theme's accent, which must read on the panel (≥ 3 : 1) for every preset and swatch.
        for page in AircThemePicker.presetPages {
            for entry in page.themes {
                for dark in [false, true] {
                    let r = entry.theme.resolved(systemIsDark: dark)
                    #expect(r.accent.contrast(on: r.surface) >= 2.9, "\(entry.name) dark \(dark)")
                }
            }
        }
    }

    @Test func googleMarkHasFourPartsInsideItsArtboard() {
        let parts = AircGoogleMarkGeometry.parts
        #expect(parts.count == 4)
        for p in parts {
            let b = p.path.boundingRect
            #expect(b.minX >= -0.01 && b.minY >= -0.01 && b.maxX <= 48.01 && b.maxY <= 48.01, "\(b)")
            #expect(b.width > 8 && b.height > 8)
        }
        let union = parts.map { $0.path.boundingRect }.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(union.width - 47) < 1.5 && abs(union.height - 48) < 0.5, "\(union)")
    }

    @Test func dragGhostPlateIsOpaque() {
        for p in SpaceTheme.presets {
            for dark in [false, true] {
                let r = p.theme.resolved(systemIsDark: dark)
                #expect(AircDragGhostLayer.plateColor(for: r).alpha == 1)
                // Title ink on the plate still reads.
                let plate = AircDragGhostLayer.plateColor(for: r)
                #expect(r.text.contrast(on: plate) >= 4.5, "\(p.id) dark \(dark)")
            }
        }
    }

    @Test func dragGhostFadesLongTitles() {
        let r = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let g = AircDragGhostLayer(kind: .row, width: AircMetrics.Sidebar.defaultWidth, theme: r)
        g.configure(title: "Short", favicon: nil)
        g.layoutIfNeeded()
        #expect(g.sublayers?.contains { $0.sublayers?.contains { $0 is CATextLayer && $0.mask == nil } == true } == true)
        g.configure(title: "A very long page title that certainly does not fit in the sidebar row", favicon: nil)
        g.layoutIfNeeded()
        #expect(g.sublayers?.contains { $0.sublayers?.contains { $0 is CATextLayer && $0.mask != nil } == true } == true)
    }

    @Test func folderTintIsTheAccent() {
        for p in SpaceTheme.presets {
            let r = p.theme.resolved(systemIsDark: false)
            #expect(r.folderTint(isOpen: false) == r.accent)
            #expect(abs(r.folderTint(isOpen: true).alpha - 0.9) < 1e-9)
            #expect(r.accent.contrast(on: r.background) >= 1.5, "\(p.id): folder visible on the theme")
        }
        #expect(AircFolderGlyph.image(isOpen: false, theme: SpaceTheme.default.resolved(systemIsDark: false)).isValid)
    }

    @Test func profileColoursMapFromLegacySwatches() {
        #expect(AircProfileColor.names.count == AircProfileColor.choices.count)
        for (i, c) in AircProfileColor.choices.enumerated() {
            #expect(AircProfileColor.nearestChoice(to: c) == i)
        }
        // Arc's pastel swatches land on a designed colour; the greys on Graphite.
        #expect(AircProfileColor.nearestChoice(to: AircColor(0xF0EAE5)) == AircProfileColor.choices.count - 1)
        #expect(AircProfileColor.nearestChoice(to: AircColor(0x73E49B)) == 1)
    }

    @Test func addressLabelFrameEndsBeforeTheButtons() {
        let field = CGRect(x: 8, y: 46, width: 212, height: 36)
        let f = AircAddressFieldLabel.frame(inField: field, trailingControlMinX: 150)
        #expect(f.minX == 20)
        #expect(f.maxX == 150 - AircMetrics.Row.titleFadeGap)
        let r = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let label = AircAddressFieldLabel(theme: r)
        #expect(label.label.stringValue == AircAddressFieldLabel.placeholder)
        label.host = "news.ycombinator.com"
        #expect(label.label.stringValue == "news.ycombinator.com")
        #expect(label.label.lineBreakMode == .byClipping)
    }

    @Test func commandBarAttributesUseThemeColours() {
        for p in SpaceTheme.presets {
            let r = p.theme.resolved(systemIsDark: true)
            let a = r.inlineCompletionAttributes
            #expect((a[.backgroundColor] as? NSColor) == r.inlineCompletionHighlight.nsColor)
            #expect((a[.foregroundColor] as? NSColor) == r.inlineCompletionText.nsColor)
            #expect((r.textSelectionAttributes[.backgroundColor] as? NSColor) != NSColor.selectedTextBackgroundColor)
        }
        #expect(AircCommandText.searchSubtitle(engine: "Google") == "Search Google")
        let r = SpaceTheme.default.resolved(systemIsDark: false)
        let action = AircCommandActionView(title: "Open", theme: r)
        #expect(action.intrinsicContentSize.width > AircKeycapView.size(for: "↵").width)
        #expect(action.isHidden)
        action.isSelected = true
        #expect(!action.isHidden)
    }

    @Test func pageCardShadowFollowsAppearance() {
        #expect(SpaceTheme.default.resolved(systemIsDark: false).pageCardShadow == .card)
        #expect(SpaceTheme.default.resolved(systemIsDark: true).pageCardShadow == .cardDark)
    }
}
