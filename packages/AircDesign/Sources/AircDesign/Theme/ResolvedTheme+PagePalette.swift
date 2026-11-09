// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Arc's page palette (P07; research §4.2): the theme of a page's Space, as the CSS custom properties Arc set on every
/// page and Boost. Arc's names, read from its app bundle: `--arc-palette-{foregroundPrimary, foregroundSecondary,
/// foregroundTertiary, maxContrastColor, minContrastColor, backgroundExtra, background, focus, hover, cutoutColor,
/// title, subtitle}`, `--arc-background-simple-color`, and `--arc-background-gradient-color0…2` /
/// `--arc-background-gradient-overlay-color0…2`. AircKit's ThemeCSS writes them; this is what each one is in Airc's
/// own theme model:
///
/// | Arc name | Airc |
/// |---|---|
/// | background | the window's average background (`ResolvedTheme.background`) |
/// | backgroundExtra | the elevated surface (Command Bar, menus): `surface` |
/// | foregroundPrimary / title | primary ink on the background (≥ 4.5:1) |
/// | foregroundSecondary / subtitle | secondary ink on the background (≥ 3:1) |
/// | foregroundTertiary | tertiary ink on the background |
/// | maxContrastColor / minContrastColor | the ink pole (black on light, white on dark) / the underlay |
/// | focus | the focus ring (the theme's accent) |
/// | hover | the hover fill on the background |
/// | cutoutColor | text on the accent (`onAccent`) |
/// | background-simple-color | the flat background |
/// | background-gradient-color0…2 | each theme colour as drawn (at the layer's opacity over the underlay) |
/// | background-gradient-overlay-color0…2 | each theme colour at the layer's opacity, translucent |
///
/// Ink is flattened onto the background so a page can use every colour as is. Fewer than three theme colours repeat
/// the last one; no colour at all is the theme's warm neutral.
extension ResolvedTheme {
    public struct PagePalette: Hashable, Sendable {
        /// Arc's `--arc-palette-*` names, in Arc's order.
        public static let names = ["foregroundPrimary", "foregroundSecondary", "foregroundTertiary", "maxContrastColor",
                                   "minContrastColor", "backgroundExtra", "background", "focus", "hover", "cutoutColor",
                                   "title", "subtitle"]
        /// By name (every name in `names`).
        public var colors: [String: AircColor]
        public var simple: AircColor
        /// Three, opaque.
        public var gradient: [AircColor]
        /// Three, at the colour layer's opacity.
        public var overlay: [AircColor]
        public var isDark: Bool

        public subscript(_ name: String) -> AircColor? { colors[name] }
    }

    public var pagePalette: PagePalette {
        let bg = background.alpha(1)
        let ink = text.over(bg), second = textSecondary.over(bg), third = textTertiary.over(bg)
        let colors: [String: AircColor] = [
            "foregroundPrimary": ink, "foregroundSecondary": second, "foregroundTertiary": third,
            "maxContrastColor": isDark ? .white() : .black(), "minContrastColor": underlay.alpha(1),
            "backgroundExtra": surface.over(bg), "background": bg, "focus": focusRing.over(bg),
            "hover": hoverFill.over(bg), "cutoutColor": onAccent.over(accent.alpha(1)),
            "title": ink, "subtitle": second,
        ]
        let raw = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        let stops = raw.isEmpty ? [bg] : raw
        let full = (0..<3).map { stops[min($0, stops.count - 1)] }
        let gradient = raw.isEmpty ? [bg, bg, bg] : full.map { $0.alpha(layerOpacity).over(underlay.alpha(1)) }
        let overlay = raw.isEmpty ? [bg.alpha(0), bg.alpha(0), bg.alpha(0)] : full.map { $0.alpha(layerOpacity) }
        return PagePalette(colors: colors, simple: bg, gradient: gradient, overlay: overlay, isDark: isDark)
    }
}
