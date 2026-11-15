// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// How far the sidebar's content may fade while its window isn't main (Arc: "the sidebar dims slightly").
///
/// The sidebar fades as a whole (header, rows, footer, tray: `NSView.alphaValue`), so every ink in it loses the same
/// share of its alpha *and* the fills under it fade too. A fixed share (0.85) pushes the ink tokens of the saturated
/// Spaces (ember, ocean, forest, grape: ink derived to sit 0.02–0.2 above its floor) below their contrast floors, so the
/// share is clamped per Space: the lowest opacity at which every sidebar ink role still meets the floor `ResolvedTheme.Floor`
/// gives it, on every ground it is drawn on, however the fade composites.
extension ResolvedTheme {
    /// The ink roles the sidebar draws, each with the design system's floor.
    public enum SidebarInk: CaseIterable, Sendable {
        /// Tab titles, the Space name (4.5:1).
        case text
        /// URL field text, header and footer glyphs, secondary labels (3:1, the icon floor).
        case textSecondary
        /// "+ New Tab", placeholders (2.4:1, `Floor.textTertiary`: the design system's own minimum for them).
        case textTertiary

        /// The floor in a light theme.
        public var floor: Double { floor(dark: false) }
        /// The floor in a light (`false`) or dark (`true`) theme (`ResolvedTheme.Floor`).
        public func floor(dark: Bool) -> Double {
            switch self {
            case .text: ResolvedTheme.Floor.text
            case .textSecondary: ResolvedTheme.Floor.textSecondary(dark: dark)
            case .textTertiary: ResolvedTheme.Floor.textTertiary(dark: dark)
            }
        }
    }

    /// How a faded view tree composites; the sidebar's real tree may do either (a layer with group opacity, or each
    /// layer on its own), so both must hold.
    public enum FadeModel: CaseIterable, Sendable {
        /// Fill and ink fade as one group, then composite over the ground (Core Animation group opacity).
        case group
        /// Each layer fades on its own: the fill over the ground, then the ink over that.
        case perLayer
    }

    /// The least a faded sidebar shows (Arc's "dims slightly", `inactiveInkFactor`): the deepest dim any Space gets.
    public static let deepestSidebarDim = inactiveInkFactor

    /// The opacity the sidebar's content fades to while the window isn't main: `inactiveInkFactor` (0.85), raised in whole
    /// percent steps until every `SidebarInk` role meets its floor on the window and on the selected and hovered rows, as
    /// both fade models composite it; 1 (no dim) when no dim keeps the floors, and under Increase Contrast (the system
    /// asks for ink that stands out, so nothing fades; the active ink meets its floors by construction).
    ///
    /// Inactive windows and Reduce Transparency draw an opaque background (`underlayOpacity`), so the grounds are the
    /// same with and without Reduce Transparency; the clamp has no input for it.
    /// `textDisabled` (back with no history) has no floor in the design system (a disabled control is exempt) and
    /// fades with the rest.
    public func sidebarInactiveOpacity(increaseContrast: Bool = false) -> Double {
        guard !increaseContrast else { return 1 }
        var step = Int((Self.deepestSidebarDim * 100).rounded())
        while step < 100 {
            let k = Double(step) / 100
            if sidebarMeetsFloors(atOpacity: k) { return k }
            step += 1
        }
        return 1
    }

    /// Whether every sidebar ink role meets its floor with the content faded to `k`.
    public func sidebarMeetsFloors(atOpacity k: Double) -> Bool {
        SidebarInk.allCases.allSatisfy { role in
            FadeModel.allCases.allSatisfy { sidebarContrast(role, atOpacity: k, model: $0) >= role.floor(dark: isDark) }
        }
    }

    /// The lowest contrast `role` has anywhere in the sidebar with the content faded to `k` (1 = the active window):
    /// over the window's colour at every sample point, and for text and secondary ink also on the selected and hovered
    /// row, as `ResolvedTheme`'s floors are defined. The ground is the opaque window background (an inactive window).
    public func sidebarContrast(_ role: SidebarInk, atOpacity k: Double, model: FadeModel = .group) -> Double {
        let ink: AircColor
        let fills: [AircColor?]
        switch role {
        case .text: ink = text; fills = [nil, selectedFill, hoverFill]
        case .textSecondary: ink = textSecondary; fills = [nil, selectedFill, hoverFill]
        case .textTertiary: ink = textTertiary; fills = [nil]
        }
        var worst = Double.infinity
        for ground in inactiveWindowGrounds {
            for fill in fills {
                worst = min(worst, Self.fadedContrast(ink: ink, fill: fill, ground: ground, k: k, model: model))
            }
        }
        return worst
    }

    /// The contrast of ink (over `fill`, if any) on the fill, with both faded to `k` over an opaque `ground`.
    static func fadedContrast(ink: AircColor, fill: AircColor?, ground: AircColor, k: Double, model: FadeModel) -> Double {
        let under = fill ?? .clear
        let around = under.opacity(k).over(ground)
        let glyph: AircColor
        switch model {
        case .group: glyph = ink.over(under).opacity(k).over(ground)
        case .perLayer: glyph = ink.opacity(k).over(around)
        }
        return glyph.alpha(1).contrast(on: around.alpha(1))
    }

    /// The opaque window background at the contrast sample points (what an inactive window shows).
    var inactiveWindowGrounds: [AircColor] {
        let cs = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        let fallback = isDark ? AircColor.Stone.s800 : AircColor.Stone.s200
        return Self.sampleGrid.map {
            Self.composite(colors: cs, fallback: fallback, underlay: underlay, opacity: layerOpacity, t: $0.0, y: $0.1)
        }
    }
}
