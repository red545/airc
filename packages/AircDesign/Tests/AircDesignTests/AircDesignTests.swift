// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import AircDesign

// MARK: - Colour maths

@Suite struct ColorMathTests {
    @Test func wcagContrastMatchesReferenceValues() {
        #expect(abs(AircColor.black().contrast(on: .white()) - 21) < 0.01)
        #expect(abs(AircColor(0x777777).contrast(on: .white()) - 4.48) < 0.01)
        #expect(abs(AircColor.white().contrast(on: AircColor(0x0000FF)) - 8.59) < 0.01)
        // A translucent foreground is composited first: black at 0.5 on white is #808080-ish.
        #expect(abs(AircColor.black(0.5).contrast(on: .white()) - AircColor(0x808080).contrast(on: .white())) < 0.05)
    }

    @Test func oklabMatchesReferenceValues() {
        let white = AircColor.white().oklab
        #expect(abs(white.l - 1) < 1e-4 && white.chroma < 1e-4)
        #expect(AircColor.black().oklab.l < 1e-6)
        let red = AircColor(0xFF0000).oklab  // Ottosson: L 0.62796, a 0.22486, b 0.12585
        #expect(abs(red.l - 0.62796) < 1e-3 && abs(red.a - 0.22486) < 1e-3 && abs(red.b - 0.12585) < 1e-3)
    }

    @Test func oklabRoundTripsEverySRGBColourOnAGrid() {
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 17) {
                for b in stride(from: 0, through: 255, by: 17) {
                    let c = AircColor(UInt32(r << 16 | g << 8 | b))
                    let back = AircColor(oklab: c.oklab)
                    #expect(abs(back.red - c.red) < 0.5 / 255 && abs(back.green - c.green) < 0.5 / 255 && abs(back.blue - c.blue) < 0.5 / 255)
                }
            }
        }
    }

    @Test func outOfGamutKeepsLightness() {
        let c = AircColor(oklab: .lch(0.7, 0.4, 150))
        #expect(abs(c.oklab.l - 0.7) < 0.01)
    }

    @Test func hexParsing() {
        #expect(AircColor(hex: "#90DDC1") == AircColor(0x90DDC1))
        #expect(AircColor(hex: "90ddc1")?.hexString == "#90DDC1")
        #expect(AircColor(hex: "#00000080")?.alpha ?? 0 > 0.5)
        #expect(AircColor(hex: "nope") == nil)
    }
}

func close(_ a: AircColor, _ b: AircColor, _ tolerance: Double = 0.5 / 255) -> Bool {
    abs(a.red - b.red) < tolerance && abs(a.green - b.green) < tolerance && abs(a.blue - b.blue) < tolerance
}

// MARK: - Space themes: Arc's rendering model

@Suite struct SpaceThemeRenderingTests {
    @Test func mintPresetMatchesTheOwnersArcScreenshot() {
        // Arc's mint reference Space renders as a flat #90DDC1.
        let bg = SpaceTheme.preset("mint")!.resolved(systemIsDark: false).background
        let target = AircColor(0x90DDC1)
        #expect(abs(bg.red - target.red) < 3 / 255 && abs(bg.green - target.green) < 3 / 255 && abs(bg.blue - target.blue) < 3 / 255, "got \(bg)")
    }

    @Test func layerOpacityFollowsArcsFormula() {
        let t = SpaceTheme(colors: [AircColor(0x7EB6D5)], intensity: 0.81, appearance: .light).resolved(systemIsDark: false)
        #expect(abs(t.layerOpacity - (0.2 + 0.55 * 0.81)) < 1e-9)
    }

    @Test func twoColoursBlendAlongTheDiagonalReachingColourTwoAt75Percent() {
        let c1 = AircColor(0x2F6AF0), c2 = AircColor(0x13B5B0)
        let t = SpaceTheme(colors: [c1, c2], intensity: 1, appearance: .dark).resolved(systemIsDark: true)
        let topLeft = t.backgroundColor(x: 0, y: 0)
        let atThreeQuarters = t.backgroundColor(x: 0.75, y: 0.75)
        let bottomRight = t.backgroundColor(x: 1, y: 1)
        #expect(close(topLeft, c1.alpha(t.layerOpacity).over(.black())))
        #expect(close(atThreeQuarters, bottomRight))
        #expect(close(bottomRight, c2.alpha(t.layerOpacity).over(.black())))
    }

    @Test func thirdColourFadesInTopToBottom() {
        let t = SpaceTheme(colors: [AircColor(0x7A4CF0), AircColor(0xE0559F), AircColor(0x3A4FD8)], appearance: .dark).resolved(systemIsDark: true)
        let bottom = t.backgroundColor(x: 0.5, y: 1)
        let expected = AircColor(0x3A4FD8).alpha(t.layerOpacity).over(.black()).alpha(1)
        #expect(abs(bottom.blue - expected.blue) < 1e-6)
        #expect(t.overlay == AircColor(0x3A4FD8))
    }

    @Test func autoAppearanceKeepsVeryLightAndVeryDarkColours() {
        #expect(SpaceTheme(colors: [AircColor(0xF0EAE5)]).rendersDark(systemIsDark: true) == false)
        #expect(SpaceTheme(colors: [AircColor(0x1B1E3A)]).rendersDark(systemIsDark: false) == true)
        #expect(SpaceTheme(colors: [AircColor(0xE1676F)]).rendersDark(systemIsDark: true) == true)
        #expect(SpaceTheme().rendersDark(systemIsDark: false) == false)
    }

    @Test func tooStrongColoursAreWashedOutInsteadOfFailingContrast() {
        // Navy forced light: black text can't read on navy, so the layer must thin out.
        let navy = SpaceTheme(colors: [AircColor(0x14215C)], appearance: .light).resolved(systemIsDark: false)
        #expect(navy.layerOpacity < 0.2 + 0.55 * 0.81)
        // Lemon forced dark: white text can't read on yellow.
        let lemon = SpaceTheme(colors: [AircColor(0xF4DA6E)], appearance: .dark).resolved(systemIsDark: true)
        #expect(lemon.layerOpacity < 0.2 + 0.55 * 0.81)
    }

    @Test func backgroundImageHasTheRequestedAspect() {
        let img = SpaceTheme.preset("grape")!.resolved(systemIsDark: true).backgroundImage(for: CGSize(width: 1440, height: 900))
        #expect(img.width == 200 && img.height == 125)
    }

    @Test func presetsAreTwelveWithUniqueIds() {
        #expect(SpaceTheme.presets.count == 12)
        #expect(Set(SpaceTheme.presets.map(\.id)).count == 12)
        #expect(SpaceTheme.swatches.count == 9)
    }

    @Test func themesRoundTripThroughCodable() throws {
        let theme = SpaceTheme.preset("grape")!
        let data = try JSONEncoder().encode(theme)
        #expect(try JSONDecoder().decode(SpaceTheme.self, from: data) == theme)
    }
}

// MARK: - Contrast guarantees (WCAG)

/// Checks every contrast floor of a resolved theme over the whole window, at three window shapes.
func assertContrast(_ theme: SpaceTheme, systemIsDark: Bool, _ label: String) {
    let r = theme.resolved(systemIsDark: systemIsDark)
    var worstText = 21.0, worstSecondary = 21.0, worstTertiary = 21.0
    for aspect in [0.25, 1.0, 1.6, 4.0] {
        for i in 0...10 {
            for j in 0...10 {
                let bg = r.backgroundColor(x: Double(i) / 10, y: Double(j) / 10, aspect: aspect)
                let grounds = [bg, r.selectedFill.over(bg), r.hoverFill.over(bg)]
                for g in grounds {
                    worstText = min(worstText, r.text.contrast(on: g))
                    worstSecondary = min(worstSecondary, r.textSecondary.contrast(on: g))
                }
                worstTertiary = min(worstTertiary, r.textTertiary.contrast(on: bg))
            }
        }
    }
    let F = ResolvedTheme.Floor.self
    #expect(worstText >= F.text, "\(label): text \(worstText)")
    #expect(worstSecondary >= F.textSecondary, "\(label): secondary \(worstSecondary)")
    #expect(worstTertiary >= F.textTertiary, "\(label): tertiary \(worstTertiary)")
    #expect(r.onAccent.contrast(on: r.accent) >= F.onAccent, "\(label): onAccent \(r.onAccent.contrast(on: r.accent)) accent \(r.accent)")
    #expect(r.surfaceText.contrast(on: r.surface) >= F.surfaceText, "\(label): surface text")
    #expect(r.surfaceTextSecondary.contrast(on: r.surface) >= 4.5, "\(label): surface secondary")
    #expect(r.surfaceText.contrast(on: r.surfaceSelected.over(r.surface)) >= 4.5, "\(label): command bar selection")
    #expect(r.accent.contrast(on: r.surface) >= 3.0, "\(label): accent on surface \(r.accent.contrast(on: r.surface))")
}

@Suite struct ContrastTests {
    @Test(arguments: SpaceTheme.presets)
    func presetMeetsEveryFloor(preset: SpaceTheme.Preset) {
        assertContrast(preset.theme, systemIsDark: false, "\(preset.id)/light-system")
        assertContrast(preset.theme, systemIsDark: true, "\(preset.id)/dark-system")
        // The same colours under every forced appearance must also hold.
        for appearance in SpaceTheme.Appearance.allCases {
            var t = preset.theme
            t.appearance = appearance
            assertContrast(t, systemIsDark: false, "\(preset.id)/\(appearance)")
        }
    }

    @Test func arcSwatchesMeetEveryFloor() {
        for swatch in SpaceTheme.swatches {
            for appearance in SpaceTheme.Appearance.allCases {
                assertContrast(SpaceTheme(colors: [swatch], appearance: appearance), systemIsDark: false, "\(swatch)/\(appearance)")
                assertContrast(SpaceTheme(colors: [swatch], appearance: appearance), systemIsDark: true, "\(swatch)/\(appearance)/dark")
            }
        }
    }

    @Test func randomThemesMeetEveryFloor() {
        var rng = SplitMix(seed: 0xA12C)
        for n in 0..<1500 {
            let count = Int(rng.next() % 4)
            let colors = (0..<count).map { _ in AircColor(UInt32(rng.next() & 0xFFFFFF)) }
            let theme = SpaceTheme(
                colors: colors,
                intensity: Double(rng.next() % 1001) / 1000,
                grain: Double(rng.next() % 101) / 100,
                appearance: SpaceTheme.Appearance.allCases[Int(rng.next() % 3)]
            )
            assertContrast(theme, systemIsDark: rng.next() % 2 == 0, "random #\(n) \(colors)")
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Tokens and motion

@Suite struct TokenTests {
    @Test func favoritesColumnRuleMatchesArc() {
        let w = AircMetrics.Sidebar.defaultWidth - 2 * AircMetrics.Sidebar.inset
        #expect(AircMetrics.Favorites.columns(count: 2, width: w) == 2)
        #expect(AircMetrics.Favorites.columns(count: 4, width: w) == 4)
        #expect(AircMetrics.Favorites.columns(count: 5, width: w) == 3)
        #expect(AircMetrics.Favorites.columns(count: 6, width: w) == 3)
        #expect(AircMetrics.Favorites.columns(count: 7, width: w) == 4)
        #expect(AircMetrics.Favorites.columns(count: 9, width: w) == 3)
        #expect(AircMetrics.Favorites.columns(count: 4, width: 200) == 2)
        #expect(AircMetrics.Favorites.columns(count: 0, width: w) == 0)
    }

    @Test func springsConvertToStiffnessAndDamping() {
        // Space settle: ω ≈ 33 rad/s, critically damped.
        let s = AircSpring.settle
        #expect(abs(s.stiffness.squareRoot() - 33.07) < 0.05)
        #expect(abs(s.damping - 2 * s.stiffness.squareRoot()) < 1e-9)
        // Favorites/folder: ω = 25.
        #expect(abs(AircSpring.fold.stiffness.squareRoot() - 25) < 1e-9)
        // Toast pop is underdamped; row settles in well under 200 ms to 0.1 %.
        #expect(AircSpring.pop.dampingRatio < 1)
        #expect(AircSpring.row.settlingDuration < 0.2)
        let ca = AircSpring.reveal.caAnimation(keyPath: "position.x", from: 0, to: 228)
        #expect(ca.stiffness == AircSpring.reveal.stiffness && ca.duration == AircSpring.reveal.settlingDuration)
    }

    @Test func grainTileIsDeterministic() {
        let a = AircGrain.makeTile(pixels: 32, seed: 7), b = AircGrain.makeTile(pixels: 32, seed: 7)
        #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?)
        #expect(AircGrain.tile.width == 256)
    }
}
