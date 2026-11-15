// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import AircDesign

// MARK: - The inactive window's sidebar dim keeps every ink role above its floor (W07c, follow-up to W07)

/// The sidebar fades as a whole while its window isn't main. `ResolvedTheme.sidebarInactiveOpacity` is the lowest
/// opacity (≥ 0.85) at which text (4.5:1), secondary ink and icons (3:1) and tertiary ink (2.4:1) still meet their
/// floors on the window and on the selected and hovered rows, however the fade composites.
/// Every built-in palette, light and dark system appearance (the auto-appearance ones follow it).
let inactiveSidebarDimPalettes: [(String, Bool)] = SpaceTheme.presets.flatMap { p in [(p.id, false), (p.id, true)] }

@Suite struct InactiveSidebarDimTests {
    static func resolved(_ id: String, _ dark: Bool) -> ResolvedTheme { SpaceTheme.preset(id)!.resolved(systemIsDark: dark) }

    @Test(arguments: inactiveSidebarDimPalettes)
    func everyRoleKeepsItsFloorOnEveryGround(id: String, dark: Bool) {
        let r = Self.resolved(id, dark)
        let k = r.sidebarInactiveOpacity()
        #expect(k >= ResolvedTheme.deepestSidebarDim && k <= 1, "\(id) \(dark): \(k)")
        for role in ResolvedTheme.SidebarInk.allCases {
            for model in ResolvedTheme.FadeModel.allCases {
                let c = r.sidebarContrast(role, atOpacity: k, model: model)
                #expect(c >= role.floor(dark: r.isDark), "\(id) \(dark ? "dark" : "light") \(role) \(model) at \(k): \(c) < \(role.floor(dark: r.isDark))")
            }
        }
    }

    /// A finer grid than the clamp's own 9 × 9 samples (the window's colour is smooth, so a hair of tolerance).
    @Test(arguments: inactiveSidebarDimPalettes)
    func floorsHoldOnAFinerGridOfTheWindow(id: String, dark: Bool) {
        let r = Self.resolved(id, dark)
        let k = r.sidebarInactiveOpacity()
        var roles: [(AircColor, Double, [AircColor?])] = []
        roles.append((r.text, ResolvedTheme.Floor.text, [nil, r.selectedFill, r.hoverFill]))
        roles.append((r.textSecondary, r.secondaryFloor, [nil, r.selectedFill, r.hoverFill]))
        roles.append((r.textTertiary, r.tertiaryFloor, [nil]))
        for i in 0...24 {
            for j in 0...24 {
                let g = r.backgroundColor(x: Double(i) / 24, y: Double(j) / 24, aspect: 0.4)
                for (ink, floor, fills) in roles {
                    for fill in fills {
                        for model in ResolvedTheme.FadeModel.allCases {
                            let c = ResolvedTheme.fadedContrast(ink: ink, fill: fill, ground: g, k: k, model: model)
                            #expect(c >= floor - 0.05, "\(id) \(dark) at (\(i),\(j)) \(model): \(c) < \(floor)")
                        }
                    }
                }
            }
        }
    }

    /// The bug: the fixed 0.85…0.92 dim (W07) took the saturated Spaces' text and icons below their floors.
    @Test(arguments: ["ember", "ocean", "forest", "grape"])
    func theOldFixedDimBrokeTheSaturatedSpaces(id: String) {
        for dark in [false, true] {
            let r = Self.resolved(id, dark)
            #expect(!r.sidebarMeetsFloors(atOpacity: 0.92), "\(id): 0.92 would still pass, so the clamp isn't needed")
            #expect(!r.sidebarMeetsFloors(atOpacity: 0.85), "\(id)")
            #expect(r.sidebarInactiveOpacity() > 0.92, "\(id): the clamp must raise the dim above the old 0.92 cap")
        }
    }

    /// A Space with headroom dims further than a saturated one, and still visibly.
    @Test func lighterSpacesStillDim() {
        for id in ["lemon", "paper", "midnight"] {
            #expect(Self.resolved(id, false).sidebarInactiveOpacity() <= 0.97, "\(id)")
        }
        let deepest = SpaceTheme.presets.map { Self.resolved($0.id, false).sidebarInactiveOpacity() }.min()!
        #expect(deepest < 0.95)
    }

    /// Increase Contrast: nothing fades, so every role keeps its active contrast (≥ its floor).
    @Test(arguments: inactiveSidebarDimPalettes)
    func increaseContrastDoesNotDim(id: String, dark: Bool) {
        let r = Self.resolved(id, dark)
        #expect(r.sidebarInactiveOpacity(increaseContrast: true) == 1)
        #expect(r.sidebarMeetsFloors(atOpacity: 1), "\(id) \(dark)")
    }

    /// Reduce Transparency (and an inactive window) draw an opaque background: the same grounds, so the same clamp; and
    /// the clamp is deterministic.
    @Test func inactiveGroundsAreOpaqueAndStable() {
        for id in ["sky", "midnight", "ember"] {
            let r = Self.resolved(id, false)
            #expect(r.inactiveWindowGrounds.allSatisfy { $0.alpha == 1 })
            #expect(r.sidebarInactiveOpacity() == r.sidebarInactiveOpacity())
            // Dimmer is never allowed than the inactive ink model's own share.
            #expect(r.sidebarInactiveOpacity() >= ResolvedTheme.inactiveInkFactor)
        }
    }

    /// The pixel formula the check's measurement uses: fading to 1 changes nothing.
    @Test func noFadeIsTheActiveContrast() {
        let r = Self.resolved("sky", false)
        for model in ResolvedTheme.FadeModel.allCases {
            let g = r.backgroundColor(x: 0.3, y: 0.4)
            let c = ResolvedTheme.fadedContrast(ink: r.text, fill: nil, ground: g, k: 1, model: model)
            #expect(abs(c - r.text.contrast(on: g)) < 1e-9)
        }
    }
}
