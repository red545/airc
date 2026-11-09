// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import AircDesign

/// P07/P05 and Q02: Arc's page palette from a theme, and the theme's contrast at its extremes (light and dark, intensity
/// 0 and 1, active and inactive windows).
struct PagePaletteTests {
    /// Every preset and swatch, each appearance, the system light and dark, intensity 0, ½ and 1.
    static var extremes: [(SpaceTheme, Bool, String)] {
        var out: [(SpaceTheme, Bool, String)] = []
        let bases = SpaceTheme.presets.map { ($0.theme, $0.id) } + SpaceTheme.swatches.map { (SpaceTheme(colors: [$0]), $0.hexString) }
        for (base, name) in bases {
            for appearance in SpaceTheme.Appearance.allCases {
                for intensity in [0.0, 0.5, 1.0] {
                    for dark in [false, true] {
                        var t = base
                        t.appearance = appearance
                        t.intensity = intensity
                        out.append((t, dark, "\(name)/\(appearance)/i\(intensity)/\(dark ? "dark" : "light") system"))
                    }
                }
            }
        }
        return out
    }

    @Test func everyArcNameHasAColour() {
        let p = SpaceTheme.presets[0].theme.resolved(systemIsDark: false).pagePalette
        #expect(Set(p.colors.keys) == Set(ResolvedTheme.PagePalette.names))
        #expect(ResolvedTheme.PagePalette.names.count == 12)
        #expect(p.gradient.count == 3 && p.overlay.count == 3)
        #expect(p.colors.values.allSatisfy { $0.alpha == 1 }, "palette colours are flat, usable as they are")
    }

    @Test func pagePaletteInkReadsOnItsBackground() {
        for (theme, dark, label) in Self.extremes {
            let r = theme.resolved(systemIsDark: dark)
            let p = r.pagePalette
            let bg = p.colors["background"]!
            #expect(p.colors["foregroundPrimary"]!.contrast(on: bg) >= ResolvedTheme.Floor.text - 0.05, "\(label)")
            #expect(p.colors["foregroundSecondary"]!.contrast(on: bg) >= ResolvedTheme.Floor.textSecondary - 0.05, "\(label)")
            #expect(p.colors["foregroundTertiary"]!.contrast(on: bg) >= ResolvedTheme.Floor.textTertiary - 0.05, "\(label)")
            #expect(p.colors["cutoutColor"]!.contrast(on: r.accent.alpha(1)) >= ResolvedTheme.Floor.onAccent - 0.05, "\(label)")
            #expect(p.colors["maxContrastColor"]!.contrast(on: bg) >= p.colors["minContrastColor"]!.contrast(on: bg), "\(label)")
            #expect(p.isDark == r.isDark, "\(label)")
        }
    }

    /// Q02: inactive windows dim their ink, never below the floors.
    @Test func inactiveWindowsKeepTheFloorsAtTheExtremes() {
        for (theme, dark, label) in Self.extremes {
            let r = theme.resolved(systemIsDark: dark)
            let off = r.forWindow(isActive: false)
            for i in 0...8 {
                for j in 0...8 {
                    let bg = r.backgroundColor(x: Double(i) / 8, y: Double(j) / 8)
                    #expect(off.text.contrast(on: bg) >= ResolvedTheme.Floor.text - 0.05, "\(label) (\(i),\(j))")
                    #expect(off.textSecondary.contrast(on: bg) >= ResolvedTheme.Floor.textSecondary - 0.05, "\(label) (\(i),\(j))")
                }
            }
            #expect(off.text.alpha <= r.text.alpha, "\(label): inactive ink is never stronger")
        }
    }

    @Test func appearanceDecidesThePalette() {
        let auto = SpaceTheme(colors: [AircColor(0x7EB6D5)], appearance: .auto)
        #expect(auto.resolved(systemIsDark: false).pagePalette.isDark == false)
        #expect(auto.resolved(systemIsDark: true).pagePalette.isDark == true)
        #expect(auto.resolved(systemIsDark: true).pagePalette.colors["background"] != auto.resolved(systemIsDark: false).pagePalette.colors["background"])
        let light = SpaceTheme(colors: [AircColor(0x7EB6D5)], appearance: .light)
        #expect(light.resolved(systemIsDark: true).pagePalette.isDark == false, "a light theme stays light in dark mode")
    }
}
