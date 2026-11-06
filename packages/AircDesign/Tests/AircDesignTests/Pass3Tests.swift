// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
@testable import AircDesign

// Design pass 3: profile flow pieces, new tokens, the background cache, loading rows.

private func everyResolvedTheme() -> [ResolvedTheme] {
    SpaceTheme.presets.flatMap { p in [false, true].map { p.theme.resolved(systemIsDark: $0) } }
        + SpaceTheme.swatches.flatMap { c in [false, true].map { SpaceTheme(colors: [c]).resolved(systemIsDark: $0) } }
}

@Suite struct Pass3TokenTests {
    @Test func inlineCompletionIsLegibleButQuieterThanText() {
        for r in everyResolvedTheme() {
            let ink = r.inlineCompletionText.over(r.surface)
            #expect(ink.contrast(on: r.surface) >= 3.0, "\(r.theme)")
            #expect(r.inlineCompletionText.alpha < r.surfaceText.alpha)
            #expect(r.inlineCompletionText.alpha > r.surfaceTextTertiary.alpha - 0.001)
        }
    }

    @Test func segmentedSelectionStandsOffTheTrack() {
        // The raised segment must differ visibly from the recessed track (owner: "low contrast" in dark).
        for r in everyResolvedTheme() {
            let track = r.segmentedTrack.over(r.surface)
            let sel = r.segmentedSelection
            let dl = abs(sel.oklab.l - track.oklab.l)
            #expect(dl >= (r.isDark ? 0.07 : 0.03), "\(r.theme) ΔL \(dl)")
            #expect(r.segmentedSelectedText.over(sel).contrast(on: sel) >= 7)
        }
    }

    @Test func dropLineAndSelectedHoverRead() {
        for r in everyResolvedTheme() {
            let bg = r.background
            #expect(r.dropLine.over(bg).contrast(on: bg) >= 3, "\(r.theme)")
            if r.isDark {
                #expect(abs(r.selectedHoverFill.alpha - 0.36) < 1e-9)
                #expect(r.text.over(r.selectedHoverFill.over(bg)).contrast(on: r.selectedHoverFill.over(bg)) >= 3)
            }
        }
    }

    @Test func profilePastelsAreLightAndKeepTheirHue() {
        for c in AircProfileColor.choices {
            let p = AircProfileColor.pastel(c)
            #expect(p.oklab.l > 0.85)
            #expect(AircColor.inkLight.contrast(on: p) > 7)
        }
    }

    @Test func nsFontWorksOffTheMainThread() async {
        let size = await Task.detached { AircFont.row.nsFont.pointSize }.value
        #expect(size == 14)
    }

    @Test func dialogFitsTheSmallestPageCard() {
        // 164 pt sidebar is the minimum; a 900 pt-wide window leaves a page card wider than the dialog.
        #expect(AircMetrics.Profile.dialogWidth + 2 * 24 < 900 - AircMetrics.Sidebar.defaultWidth - 2 * AircMetrics.Window.cardInset)
        // Five Space tiles fit the dialog's content width.
        let content = AircMetrics.Profile.dialogWidth - 2 * AircMetrics.Profile.dialogPadding
        #expect(5 * AircMetrics.Profile.spaceTile.width + 4 * AircMetrics.Profile.spaceTileGap <= content)
        #expect(AircMetrics.CreateSpace.width <= AircMetrics.Sidebar.defaultWidth - 2 * 14)
    }
}

@Suite struct ColorFieldTests {
    @Test func hslRoundTrips() {
        for h in stride(from: 0.0, to: 1, by: 0.05) {
            for l in stride(from: 0.15, through: 0.85, by: 0.1) {
                let c = AircColor(hue: h, saturation: 1, lightness: l)
                let back = c.hsl
                #expect(abs(back.lightness - l) < 1e-6)
                #expect(abs(back.saturation - 1) < 1e-6)
                #expect(min(abs(back.hue - h), 1 - abs(back.hue - h)) < 1e-6)
            }
        }
    }

    @Test func pointAndColourAreInverse() {
        let g = AircColorFieldGeometry()
        for c in [AircColor(0x86CDF5), AircColor(0x6D8CF0), AircColor(0xF0642A), AircColor(0x53CA9F)] {
            let p = g.point(for: c)
            let back = g.color(at: p)
            #expect(abs(back.hsl.hue - c.hsl.hue) < 0.01)
            #expect(abs(back.hsl.lightness - c.hsl.lightness) < 0.01)
        }
        // Hue runs clockwise from the right (screen y grows down): straight right is red.
        let right = g.color(at: CGPoint(x: g.center.x + g.radius * 0.5, y: g.center.y))
        #expect(right.red > 0.9 && right.green < 0.1 && right.blue < 0.1)
        let below = g.color(at: CGPoint(x: g.center.x, y: g.center.y + g.radius * 0.5)).hsl.hue
        #expect(abs(below - 0.25) < 0.01)
    }

    @Test func companionsFollowArc() {
        let base = AircColor(hue: 0.1, saturation: 1, lightness: 0.6)
        let two = AircColorFieldGeometry.companions(of: base, count: 2).map(\.hsl.hue)
        #expect(abs(two[1] - 0.6) < 0.01)
        let three = AircColorFieldGeometry.companions(of: base, count: 3).map(\.hsl.hue)
        #expect(abs(three[1] - (0.1 + 150.0 / 360)) < 0.01 && abs(three[2] - (0.1 + 210.0 / 360)) < 0.01)
    }
}

@Suite struct BackgroundCacheTests {
    @Test func cachesPerThemeAndAspectAndMatchesDirectRender() {
        let cache = AircBackgroundCache()
        let mint = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let a = cache.colorLayer(for: mint, size: CGSize(width: 1440, height: 900))
        let b = cache.colorLayer(for: mint, size: CGSize(width: 1438, height: 899))   // same 2 % bucket
        #expect(a === b)
        let c = cache.colorLayer(for: mint, size: CGSize(width: 900, height: 900))
        #expect(a !== c)
        let direct = mint.colorLayerImage(for: CGSize(width: 1440, height: 900))
        #expect(direct.width == a.width && direct.height == a.height)
        #expect(cache.cachedColorLayer(for: SpaceTheme.preset("ocean")!.resolved(systemIsDark: true), size: .init(width: 1, height: 1)) == nil)
    }

    @Test func prerendersOffTheMainThread() async {
        let cache = AircBackgroundCache()
        let themes = SpaceTheme.presets.map { $0.theme.resolved(systemIsDark: true) }
        await cache.prerenderAndWait(themes, size: CGSize(width: 1512, height: 945))
        for t in themes { #expect(cache.cachedColorLayer(for: t, size: CGSize(width: 1512, height: 945)) != nil) }
    }

    @Test func evictsBeyondCapacity() {
        let cache = AircBackgroundCache()
        cache.capacity = 4
        let themes = SpaceTheme.presets.prefix(6).map { $0.theme.resolved(systemIsDark: false) }
        for t in themes { _ = cache.colorLayer(for: t, size: CGSize(width: 16, height: 10)) }
        #expect(cache.cachedColorLayer(for: themes[0], size: CGSize(width: 16, height: 10)) == nil)
        #expect(cache.cachedColorLayer(for: themes[5], size: CGSize(width: 16, height: 10)) != nil)
    }
}

@Suite @MainActor struct Pass3ViewTests {
    @Test func blendTracksFractionAndClears() {
        let mint = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let ocean = SpaceTheme.preset("ocean")!.resolved(systemIsDark: true)
        let v = SpaceBackgroundView(theme: mint, frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        v.setBlend(ocean, fraction: 0.3)
        #expect(abs(v.blendFraction - 0.3) < 1e-6)
        v.setBlend(nil, fraction: 0)
        #expect(v.blendFraction == 0)
        v.setTheme(ocean, colorLayer: AircBackgroundCache.shared.colorLayer(for: ocean, size: v.bounds.size), animated: false)
        #expect(v.theme == ocean)
    }

    @Test func fadingLabelMasksOnlyWhenOverflowing() {
        let l = AircFadingLabel(style: AircFont.row)
        l.frame = CGRect(x: 0, y: 0, width: 120, height: 18)
        l.stringValue = "Short"
        l.layout()
        #expect(!l.isOverflowing && l.layer?.mask == nil)
        l.stringValue = "TechCrunch | Startup and Technology News, every day"
        l.layout()
        #expect(l.isOverflowing && l.layer?.mask != nil)
    }

    @Test func loadingRingWaitsBeforeShowing() async throws {
        let ring = AircLoadingIndicator()
        var shown: [Bool] = []
        ring.onVisibilityChange = { shown.append($0) }
        ring.setLoading(true)
        ring.setLoading(false)              // a fast load: never shows
        try await Task.sleep(for: .milliseconds(220))
        #expect(shown.isEmpty && !ring.isShowing)
        ring.setLoading(true)
        // Wait for the delayed show instead of a fixed sleep: under load the timer fires late (flaked 2026-11-06).
        for _ in 0..<100 where !ring.isShowing { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ring.isShowing && shown == [true])
        ring.setLoading(false)
        #expect(!ring.isShowing && shown == [true, false])
    }

    @Test func avatarRendersForMenus() {
        let img = AircProfileAvatar.image(AircProfileIdentity(name: "Freelance", emoji: "🪴", color: AircProfileColor.choices[2]))
        #expect(img.size == NSSize(width: 22, height: 22))
    }

    @Test func indicatorCondensesBeforeTheNameFades() {
        #expect(AircProfileIndicator.size(forAvailableWidth: 120, nameWidth: 50) == .full)
        #expect(AircProfileIndicator.size(forAvailableWidth: 60, nameWidth: 50) == .condensed)
    }
}
