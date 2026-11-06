// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AircDesign

// MARK: - Translucency: contrast over the worst desktop

/// Checks every ink floor with the window translucent at `underlay` over each worst-case desktop, over the
/// whole window at four shapes (finer than the derivation's own sample grid).
func assertTranslucentContrast(_ r: ResolvedTheme, underlay a: Double, _ label: String) {
    let cs = Array(r.theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
    let fallback = r.isDark ? AircColor.Stone.s800 : AircColor.Stone.s200
    var worstText = 21.0, worstSecondary = 21.0, worstTertiary = 21.0
    for desktop in AircTranslucency.worstCaseBackdrops(isDark: r.isDark) {
        let base = r.underlay.alpha(a).over(desktop)
        for aspect in [0.25, 1.0, 1.6, 4.0] {
            for i in 0...10 {
                for j in 0...10 {
                    let bg = ResolvedTheme.composite(colors: cs, fallback: fallback, underlay: base, opacity: r.layerOpacity,
                                                     x: Double(i) / 10, y: Double(j) / 10, aspect: aspect)
                    for g in [bg, r.selectedFill.over(bg), r.hoverFill.over(bg)] {
                        worstText = min(worstText, r.text.contrast(on: g))
                        worstSecondary = min(worstSecondary, r.textSecondary.contrast(on: g))
                    }
                    worstTertiary = min(worstTertiary, r.textTertiary.contrast(on: bg))
                }
            }
        }
    }
    let F = ResolvedTheme.Floor.self
    #expect(worstText >= F.text - 0.05, "\(label): text \(worstText)")
    #expect(worstSecondary >= F.textSecondary - 0.05, "\(label): secondary \(worstSecondary)")
    #expect(worstTertiary >= F.textTertiary - 0.05, "\(label): tertiary \(worstTertiary)")
}

@Suite struct TranslucencyTests {
    @Test(arguments: SpaceTheme.presets)
    func presetsKeepTheirFloorsOverAnyDesktop(preset: SpaceTheme.Preset) {
        for dark in [false, true] {
            let r = preset.theme.resolved(systemIsDark: dark)
            for level in AircTranslucency.allCases {
                let a = r.underlayOpacity(for: level)
                #expect(a >= level.nominalUnderlayOpacity(isDark: r.isDark) - 1e-9)
                #expect(a <= 1)
                assertTranslucentContrast(r, underlay: a, "\(preset.id)/\(dark ? "dark" : "light")/\(level)")
            }
        }
    }

    @Test func randomThemesKeepTheirFloorsOverAnyDesktop() {
        var rng = SplitMix(seed: 0x7A11)
        for n in 0..<250 {
            let count = Int(rng.next() % 4)
            let colors = (0..<count).map { _ in AircColor(UInt32(rng.next() & 0xFFFFFF)) }
            let theme = SpaceTheme(colors: colors, intensity: Double(rng.next() % 1001) / 1000,
                                   appearance: SpaceTheme.Appearance.allCases[Int(rng.next() % 3)])
            let r = theme.resolved(systemIsDark: rng.next() % 2 == 0)
            let level: AircTranslucency = rng.next() % 2 == 0 ? .subtle : .more
            assertTranslucentContrast(r, underlay: r.underlayOpacity(for: level), "random #\(n) \(colors) \(level)")
        }
    }

    @Test func offInactiveAndReduceTransparencyAreOpaque() {
        let r = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        #expect(r.underlayOpacity(for: .off) == 1)
        #expect(r.underlayOpacity(for: .subtle, isWindowActive: false) == 1)
        #expect(r.underlayOpacity(for: .more, reduceTransparency: true) == 1)
        #expect(r.desktopFraction(underlayOpacity: 1) == 0)
    }

    @Test func levelsAreOrderedAndActuallySeeThrough() {
        for p in SpaceTheme.presets {
            let r = p.theme.resolved(systemIsDark: false)
            let subtle = r.underlayOpacity(for: .subtle), more = r.underlayOpacity(for: .more)
            #expect(more <= subtle, "\(p.id)")
            #expect(r.desktopFraction(underlayOpacity: more) >= r.desktopFraction(underlayOpacity: subtle))
        }
        // The default theme and the light presets really let the desktop through at the default level, and so
        // does the default theme in dark mode. (Saturated dark presets floor near opaque: their white text has
        // no margin left on the selected row.)
        let darkPaper = SpaceTheme.default.resolved(systemIsDark: true)
        #expect(darkPaper.desktopFraction(underlayOpacity: darkPaper.underlayOpacity(for: .subtle)) > 0.12)
        for id in ["paper", "mint", "sky", "lilac", "peach", "lemon"] {
            let r = SpaceTheme.preset(id)!.resolved(systemIsDark: false)
            #expect(r.desktopFraction(underlayOpacity: r.underlayOpacity(for: .subtle)) > 0.07, "\(id)")
        }
    }

    @Test func defaultIsSubtle() {
        #expect(AircTranslucency.default == .subtle)
        #expect(AircTranslucency.allCases.map(\.rawValue) == ["off", "subtle", "more"])
    }

    @Test func colorLayerImageIsPremultipliedAtTheLayerOpacity() {
        let r = SpaceTheme.preset("mint")!.resolved(systemIsDark: false)
        let img = r.colorLayerImage(for: CGSize(width: 400, height: 250))
        #expect(img.width == 200 && img.height == 125)
        #expect(img.alphaInfo == .premultipliedLast)
        let bytes = CFDataGetBytePtr(img.dataProvider!.data!)!
        #expect(abs(Double(bytes[3]) / 255 - r.layerOpacity) < 1 / 255)
        // Composited over the underlay, it is the opaque background.
        let c = AircColor(red: Double(bytes[0]) / 255 / r.layerOpacity, green: Double(bytes[1]) / 255 / r.layerOpacity,
                          blue: Double(bytes[2]) / 255 / r.layerOpacity).alpha(r.layerOpacity).over(r.underlay)
        #expect(close(c, r.backgroundColor(x: 0, y: 0), 2 / 255))
    }

    @Test func translucencyRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode([AircTranslucency.more])
        #expect(try JSONDecoder().decode([AircTranslucency].self, from: data) == [.more])
    }
}

// MARK: - Inactive windows dim their ink

@Suite struct InactiveWindowTests {
    @Test(arguments: SpaceTheme.presets)
    func inactiveInkDimsButKeepsItsFloors(preset: SpaceTheme.Preset) {
        for dark in [false, true] {
            let active = preset.theme.resolved(systemIsDark: dark)
            let inactive = active.forWindow(isActive: false)
            #expect(!inactive.isWindowActive)
            #expect(inactive.text.alpha <= active.text.alpha)
            #expect(inactive.textSecondary.alpha <= active.textSecondary.alpha)
            #expect(inactive.textSecondary.alpha >= active.textSecondary.alpha * ResolvedTheme.inactiveInkFactor - 1e-9)
            // Floors still hold on the opaque window (inactive windows are opaque).
            for i in 0...8 {
                for j in 0...8 {
                    let bg = inactive.backgroundColor(x: Double(i) / 8, y: Double(j) / 8, aspect: 1.6)
                    #expect(inactive.text.contrast(on: bg) >= ResolvedTheme.Floor.text - 0.05)
                    #expect(inactive.textSecondary.contrast(on: bg) >= ResolvedTheme.Floor.textSecondary - 0.05)
                }
            }
        }
    }

    @Test func lightAndNeutralPresetsVisiblyDim() {
        // Saturated dark presets already draw their ink at the contrast floor, so they barely dim.
        for id in ["paper", "mint", "sky", "lilac", "peach", "lemon", "midnight"] {
            let r = SpaceTheme.preset(id)!.resolved(systemIsDark: false)
            #expect(r.forWindow(isActive: false).textSecondary.alpha < r.textSecondary.alpha - 0.05, "\(id)")
            #expect(r.forWindow(isActive: false).text.alpha < r.text.alpha - 0.05, "\(id)")
        }
    }

    @Test func activeIsIdentity() {
        let r = SpaceTheme.preset("ocean")!.resolved(systemIsDark: true)
        #expect(r.forWindow(isActive: true) == r)
    }
}

// MARK: - Reduce Motion

@Suite struct ReduceMotionTests {
    @Test func springsBecomeShortCrossfades() {
        #expect(AircMotion.reducedDuration == 0.15)
        for (_, s) in AircSpring.all {
            #expect(s.animation(reduceMotion: true) == AircMotion.crossfade)
            #expect(s.animation(reduceMotion: false) == s.animation)
        }
        #expect(AircCurve.entrance.animation(reduceMotion: true) == AircMotion.crossfade)
    }

    @MainActor @Test func coreAnimationFadesInsteadOfMoving() {
        let parent = CALayer(), layer = CALayer()
        parent.addSublayer(layer)
        AircSpring.row.animate(layer, keyPath: "position", to: NSValue(point: CGPoint(x: 0, y: 41)), reduceMotion: true)
        #expect(layer.position == CGPoint(x: 0, y: 41))
        #expect(layer.animationKeys() == nil)
        #expect((parent.animation(forKey: kCATransition) as? CATransition)?.type == .fade)
        #expect(parent.animation(forKey: kCATransition)?.duration == AircMotion.reducedDuration)

        AircSpring.row.animate(layer, keyPath: "position", to: NSValue(point: CGPoint(x: 0, y: 82)), reduceMotion: false)
        #expect(layer.position == CGPoint(x: 0, y: 82))
        #expect(layer.animation(forKey: "airc.position") is CASpringAnimation)
    }

    @Test func expandSpringIsSoft() {
        let s = AircSpring.expand
        #expect(s.dampingRatio > 0.85 && s.dampingRatio < 1)
        #expect(s.settlingDuration < 0.6)
    }
}

// MARK: - Floating window (ON-5)

@MainActor @Suite struct FloatingWindowTests {
    @Test func isABorderlessCardWithoutButtons() {
        let w = AircFloatingWindow(theme: SpaceTheme.default.resolved(systemIsDark: false))
        #expect(w.frame.size == CGSize(width: 760, height: 540))
        #expect(!w.styleMask.contains(.titled) && !w.styleMask.contains(.closable) && !w.styleMask.contains(.miniaturizable) && !w.styleMask.contains(.resizable))
        #expect(w.standardWindowButton(.closeButton) == nil)
        #expect(w.standardWindowButton(.miniaturizeButton) == nil)
        #expect(w.standardWindowButton(.zoomButton) == nil)
        #expect(w.canBecomeKey && w.canBecomeMain)
        #expect(w.isMovableByWindowBackground && w.hasShadow && !w.isOpaque)
        #expect(!w.collectionBehavior.contains(.fullScreenPrimary))
        #expect(w.contentView?.layer?.cornerRadius == AircRadius.floatingWindow)
        #expect(w.background.translucency == .subtle)
    }

    @Test func escapeGoesBack() {
        let w = AircFloatingWindow(theme: SpaceTheme.default.resolved(systemIsDark: false))
        var backs = 0
        w.onEscape = { backs += 1 }
        w.cancelOperation(nil)
        #expect(backs == 1)
    }

    @Test func centresSlightlyAboveTheMiddle() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let f = AircFloatingWindow.centeredFrame(size: AircMetrics.Onboarding.windowSize, in: screen)
        #expect(f.midX == screen.midX)
        #expect(f.midY > screen.midY && f.midY - screen.midY < 30)
        // Another screen to the left.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        #expect(left.contains(AircFloatingWindow.centeredFrame(size: AircMetrics.Onboarding.windowSize, in: left)))
    }

    @Test func emptyAreasDragTheWindowAndControlsDont() {
        let w = AircFloatingWindow(theme: SpaceTheme.default.resolved(systemIsDark: false), translucency: .off)
        w.setContent(VStack { Button("Continue") {}.frame(width: 120, height: 40) }.frame(maxWidth: .infinity, maxHeight: .infinity))
        w.contentView?.layoutSubtreeIfNeeded()
        let root = w.contentView!
        let empty = root.hitTest(CGPoint(x: 40, y: 40))
        #expect(empty is DragAreaView, "got \(String(describing: empty))")
        let button = root.hitTest(CGPoint(x: 380, y: 270))
        #expect(!(button is DragAreaView), "got \(String(describing: button))")
    }

    @Test func onboardingFitsTheWindow() {
        let m = AircMetrics.Onboarding.self
        #expect(m.previewWidth + m.cardSize.width + m.cardInset == m.windowSize.width)
        #expect(m.cardSize.height + 2 * m.cardInset == m.windowSize.height)
        #expect(m.cardRadius == m.windowRadius - m.cardInset)
        #expect(AircOnboardingCard<EmptyView, EmptyView>.size == m.cardSize)
    }
}

