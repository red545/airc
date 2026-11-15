// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import AircDesign

/// Dark-mode readability (darkmode, 2026-11-14): WCAG AA for every text token of a dark theme, measured on every ground
/// it is drawn on, plus a guard that light themes keep their exact tokens.
///
/// Set `AIRC_CONTRAST_TABLE=<path>` to also write the measured table (Markdown) for artifacts/darkmode.
@Suite struct DarkModeContrastTests {
    /// Every curated theme and Arc swatch, under the system's dark and light appearance.
    static let named: [(String, SpaceTheme)] =
        SpaceTheme.presets.map { ("preset \($0.id)", $0.theme) }
        + SpaceTheme.swatches.map { ("swatch \($0.hexString)", SpaceTheme(colors: [$0])) }

    struct Row {
        var label: String
        var mode: String
        var values: [(String, Double, Double)]   // name, ratio, floor
    }

    /// The worst contrast of each text token of `r`, with its floor.
    static func measure(_ r: ResolvedTheme) -> [(String, Double, Double)] {
        var text = 21.0, secondary = 21.0, tertiary = 21.0, secondaryOnHoveredSelection = 21.0
        for aspect in [0.25, 1.0, 1.6, 4.0] {
            for i in 0...10 {
                for j in 0...10 {
                    let bg = r.backgroundColor(x: Double(i) / 10, y: Double(j) / 10, aspect: aspect)
                    for g in [bg, r.selectedFill.over(bg), r.hoverFill.over(bg)] {
                        text = min(text, r.text.contrast(on: g))
                        secondary = min(secondary, r.textSecondary.contrast(on: g))
                    }
                    // The selected row under the pointer: a transient state, so secondary ink keeps the 3:1 of icons there.
                    let hoveredSelection = r.selectedHoverFill.over(bg)
                    if r.isDark { text = min(text, r.text.contrast(on: hoveredSelection)) }
                    secondaryOnHoveredSelection = min(secondaryOnHoveredSelection, r.textSecondary.contrast(on: hoveredSelection))
                    tertiary = min(tertiary, r.textTertiary.contrast(on: bg))
                }
            }
        }
        let s = r.surface
        let surfaceGrounds = [s, r.surfaceHover.over(s), r.surfaceSelected.over(s)]
        func worst(_ ink: AircColor, _ grounds: [AircColor]) -> Double { grounds.map { ink.contrast(on: $0) }.min() ?? 21 }
        let dark = r.isDark
        // The window itself (panels on the Space, such as the Library), on the derivation's own 9 × 9 grid.
        let window = (0...8).flatMap { i in (0...8).map { j in r.backgroundColor(x: Double(i) / 8, y: Double(j) / 8) } }
        return [
            ("sidebar text", text, ResolvedTheme.Floor.text),
            ("sidebar secondary", secondary, r.secondaryFloor),
            ("sidebar tertiary", tertiary, r.tertiaryFloor),
            ("secondary, hovered selection", secondaryOnHoveredSelection, 3.0),
            ("surface text", worst(r.surfaceText, surfaceGrounds), 4.5),
            ("surface secondary", worst(r.surfaceTextSecondary, surfaceGrounds), dark ? 4.5 : 4.3),
            ("surface tertiary", worst(r.surfaceTextTertiary, dark ? surfaceGrounds : [s, r.surfaceHover.over(s)]), dark ? ResolvedTheme.Floor.surfaceTextTertiaryDark : 2.4),
            ("accent text", worst(r.accentText, dark ? surfaceGrounds + window : [s]), dark ? ResolvedTheme.Floor.accentTextDark : 3.0),
            ("on accent", r.onAccent.contrast(on: r.accent), ResolvedTheme.Floor.onAccent),
            ("inline completion", r.inlineCompletionText.contrast(on: s), 3.0),
        ]
    }

    @Test func darkThemesMeetWCAGAAOnEveryGround() {
        for (label, theme) in Self.named {
            for systemIsDark in [true, false] {
                for appearance in SpaceTheme.Appearance.allCases {
                    var t = theme
                    t.appearance = appearance
                    let r = t.resolved(systemIsDark: systemIsDark)
                    guard r.isDark else { continue }
                    for (name, ratio, floor) in Self.measure(r) {
                        #expect(ratio >= floor - 0.01, "\(label)/\(appearance)/sys-\(systemIsDark ? "dark" : "light"): \(name) \(ratio) < \(floor)")
                    }
                    // Hierarchy: secondary stays visibly below primary ink.
                    #expect(r.textSecondary.alpha <= r.text.alpha - 0.1 + 1e-9, "\(label): secondary \(r.textSecondary.alpha) vs text \(r.text.alpha)")
                    #expect(r.surfaceTextTertiary.alpha < r.surfaceTextSecondary.alpha, "\(label): surface tertiary above secondary")
                }
            }
        }
    }

    @Test func randomDarkThemesMeetWCAGAA() {
        var rng = SplitMix(seed: 0xDA4C)
        var checked = 0
        while checked < 600 {
            let count = Int(rng.next() % 4)
            let colors = (0..<count).map { _ in AircColor(UInt32(rng.next() & 0xFFFFFF)) }
            let theme = SpaceTheme(colors: colors, intensity: Double(rng.next() % 1001) / 1000, appearance: .dark)
            let r = theme.resolved(systemIsDark: true)
            checked += 1
            for (name, ratio, floor) in Self.measure(r) {
                #expect(ratio >= floor - 0.01, "random \(checked) \(colors): \(name) \(ratio) < \(floor)")
            }
        }
    }

    /// Inactive windows (the dimmed sidebar), Increase Contrast and every translucency level keep the dark floors.
    @Test func darkFloorsHoldInactiveTranslucentAndIncreasedContrast() {
        for p in SpaceTheme.presets {
            let r = p.theme.resolved(systemIsDark: true)
            guard r.isDark else { continue }
            let k = r.sidebarInactiveOpacity()
            #expect(r.sidebarMeetsFloors(atOpacity: k), "\(p.id): dimmed sidebar at \(k)")
            #expect(r.sidebarInactiveOpacity(increaseContrast: true) == 1)
            for level in AircTranslucency.allCases {
                let a = r.underlayOpacity(for: level)
                #expect(r.meetsFloors(underlayOpacity: a), "\(p.id) \(level) at \(a)")
                // Reduce Transparency draws opaque.
                #expect(r.underlayOpacity(for: level, reduceTransparency: true) == 1)
            }
            let off = r.forWindow(isActive: false)
            for i in 0...8 {
                for j in 0...8 {
                    let bg = r.backgroundColor(x: Double(i) / 8, y: Double(j) / 8)
                    #expect(off.textSecondary.contrast(on: bg) >= r.secondaryFloor - 0.01, "\(p.id) inactive secondary")
                    #expect(off.textTertiary.contrast(on: bg) >= r.tertiaryFloor - 0.01, "\(p.id) inactive tertiary")
                }
            }
        }
    }

    /// Light themes are unchanged by the dark-mode pass: the same ink alphas, colour layer, surface ink and accent as
    /// before it (values from 04fdc849).
    @Test func lightThemesKeepTheirTokens() {
        let expected: [String: (layer: Double, text: Double, secondary: Double, tertiary: Double)] = [
            "paper": (0.65, 0.86, 0.60, 0.42), "mint": (0.65, 0.86, 0.60, 0.42), "sky": (0.65, 0.86, 0.60, 0.43),
            "lilac": (0.65, 0.86, 0.60, 0.42), "peach": (0.65, 0.86, 0.60, 0.42), "lemon": (0.65, 0.86, 0.60, 0.42),
        ]
        for p in SpaceTheme.presets {
            let r = p.theme.resolved(systemIsDark: false)
            guard !r.isDark, let e = expected[p.id] else { continue }
            #expect(abs(r.layerOpacity - e.layer) < 0.005, "\(p.id) layer \(r.layerOpacity)")
            #expect(abs(r.text.alpha - e.text) < 0.005, "\(p.id) text \(r.text.alpha)")
            #expect(abs(r.textSecondary.alpha - e.secondary) < 0.005, "\(p.id) secondary \(r.textSecondary.alpha)")
            #expect(abs(r.textTertiary.alpha - e.tertiary) < 0.005, "\(p.id) tertiary \(r.textTertiary.alpha)")
            #expect(abs(r.surfaceTextSecondary.alpha - 0.58) < 1e-9 && abs(r.surfaceTextTertiary.alpha - 0.38) < 1e-9, "\(p.id) surface ink")
            #expect(r.accentText == r.accent, "\(p.id) accent text")
        }
        #expect(SpaceTheme.presets.filter { !$0.theme.resolved(systemIsDark: false).isDark }.count == 6)
    }

    /// Writes the measured table when `AIRC_CONTRAST_TABLE` names a file.
    @Test func writeContrastTable() throws {
        guard let path = ProcessInfo.processInfo.environment["AIRC_CONTRAST_TABLE"], !path.isEmpty else { return }
        var rows: [Row] = []
        for (label, theme) in Self.named {
            for systemIsDark in [true, false] {
                let r = theme.resolved(systemIsDark: systemIsDark)
                rows.append(Row(label: label, mode: "\(r.isDark ? "dark" : "light") (system \(systemIsDark ? "dark" : "light"))", values: Self.measure(r)))
            }
        }
        let names = rows[0].values.map(\.0)
        var md = "| Theme | Renders | " + names.joined(separator: " | ") + " |\n|---|---|" + names.map { _ in "---:" }.joined(separator: "|") + "|\n"
        for row in rows {
            md += "| \(row.label) | \(row.mode) | " + row.values.map { v in
                String(format: "%.2f", v.1) + (v.1 < v.2 - 0.01 ? " ✗" : "")
            }.joined(separator: " | ") + " |\n"
        }
        md += "\nFloors: " + rows.first(where: { $0.mode.hasPrefix("dark") })!.values.map { "\($0.0) \(String(format: "%.1f", $0.2))" }.joined(separator: ", ")
            + " (dark); " + rows.first(where: { $0.mode.hasPrefix("light") })!.values.map { "\($0.0) \(String(format: "%.1f", $0.2))" }.joined(separator: ", ") + " (light).\n"
        try md.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
