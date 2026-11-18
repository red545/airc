// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Every colour the UI needs for one Space, derived from a `SpaceTheme` and the system appearance.
///
/// Sidebar text and glyphs are ink (near-black or near-white) at an alpha, so they pick up the theme's hue
/// the way Arc's do. The derivation guarantees contrast instead of hoping for it:
/// - primary text ≥ 4.5:1 on every point of the background and on the selected row;
/// - secondary text and glyphs ≥ 3:1 (≥ 4.5:1 in dark themes, WCAG AA for body text);
/// - tertiary (placeholders, "+ New Tab", the Space's profile label, URL suffixes) ≥ 2.4:1 (≥ 4.5:1 on the window in
///   dark themes: it carries information there too);
/// - text on the accent ≥ 4.5:1; text on `surface` ≥ 7:1; `accentText` ≥ 4.5:1 on `surface` in dark themes.
/// Dark themes wash their colour layer a little further toward black than light ones, so secondary ink can reach its
/// floor and still sit visibly below primary ink (darkmode, 2026-11-14: owner feedback on dark-mode readability).
/// If a colour is too strong for its appearance (black text on navy, white text on lemon), the colour layer
/// is washed toward the underlay until text passes. The theme yields to legibility, never the reverse.
public struct ResolvedTheme: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public let color: AircColor
        public let location: Double
    }

    public let theme: SpaceTheme
    public let isDark: Bool

    // MARK: Background (window, sidebar, the 10 pt margin around the page card)

    /// White (light) or black (dark). Drawn first, opaque.
    public let underlay: AircColor
    /// Opacity of the colour layer over the underlay: `0.2 + 0.55 × intensity`, lowered if contrast demands it.
    public let layerOpacity: Double
    /// The diagonal gradient (raw theme colours, OKLab-interpolated), drawn at `layerOpacity`.
    /// Location 0 is the top-left corner and 1 the bottom-right, along a true 45° axis.
    public let gradient: [Stop]
    /// The third colour, faded in from transparent at the top to opaque at the bottom, inside the colour layer.
    public let overlay: AircColor?
    /// The average composited background colour. Use it for solid fills, e.g. under a sheet.
    public let background: AircColor

    // MARK: Ink on the background

    /// Tab titles, Space name, primary sidebar text.
    public internal(set) var text: AircColor
    /// URL field text, header glyphs (back, forward, reload), secondary labels.
    public internal(set) var textSecondary: AircColor
    /// "+ New Tab", placeholders, timestamps. Never the only carrier of information.
    public internal(set) var textTertiary: AircColor
    /// Disabled glyphs (back with no history).
    public internal(set) var textDisabled: AircColor
    /// False for the dimmed ink of an inactive window (`forWindow(isActive: false)`).
    public internal(set) var isWindowActive = true

    // MARK: Fills on the background (Arc 1.170 asset catalog)

    public let hoverFill: AircColor
    public let pressedFill: AircColor
    public let selectedFill: AircColor
    /// Light themes draw the selected row with a soft shadow (white 0.85 + black 0.2 shadow).
    public let selectedHasShadow: Bool
    public let tileFill: AircColor
    public let tileHoverFill: AircColor
    public let fieldFill: AircColor
    public let separator: AircColor

    // MARK: Elevated surfaces (command bar, menus, toasts, onboarding and settings cards)

    /// Opaque, near-white (light) or deep grey (dark), with a hint of the theme hue.
    public let surface: AircColor
    public let surfaceText: AircColor
    public let surfaceTextSecondary: AircColor
    public let surfaceTextTertiary: AircColor
    public let surfaceBorder: AircColor
    public let surfaceHover: AircColor
    /// Selected row in the command bar and lists on a surface.
    public let surfaceSelected: AircColor

    // MARK: Accent

    /// The theme's mid-tone (Arc's `primaryColorPalette.midTone`): primary buttons, toggles, focus, links.
    public let accent: AircColor
    /// Text and glyphs on `accent`.
    public let onAccent: AircColor
    /// Focus ring, 2 pt outside the control.
    public let focusRing: AircColor
    /// The accent as text and small glyphs on `surface`: links, "Undo" in a toast, row actions. The accent itself in
    /// light themes; lighter in dark ones, so it reads (≥ 4.5:1) where the accent fill alone would sit near 3:1.
    public let accentText: AircColor

    public var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Grain layer opacity. Inactive windows show the texture at ¼ strength, as Arc does.
    public func grainOpacity(isWindowActive: Bool = true) -> Double {
        theme.grain.clamped01 * theme.texture.strength * Self.grainScale * (isWindowActive ? 1 : 0.25)
    }

    /// The composited, opaque background at a unit point (0,0 top-left) of a window with the given
    /// width/height aspect ratio. The diagonal runs at a true 45° whatever the aspect.
    public func backgroundColor(x: Double, y: Double, aspect: Double = 1) -> AircColor {
        Self.composite(colors: Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }, fallback: fallbackColor,
                       underlay: underlay, opacity: layerOpacity, x: x, y: y, aspect: aspect)
    }

    /// The exact background (Arc's shader, computed per pixel) as a small image to stretch over a view of
    /// the given size. The gradient is smooth, so ~200 px across is plenty; grain hides any banding.
    public func backgroundImage(for size: CGSize, maxPixels: Int = 200) -> CGImage {
        renderBackground(for: size, maxPixels: maxPixels, includeUnderlay: true)
    }

    /// Renders the shader. With the underlay the image is opaque; without it, the colour layer alone is
    /// returned premultiplied at `layerOpacity`.
    func renderBackground(for size: CGSize, maxPixels: Int, includeUnderlay: Bool) -> CGImage {
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1
        let w = aspect >= 1 ? maxPixels : max(2, Int((Double(maxPixels) * aspect).rounded()))
        let h = aspect >= 1 ? max(2, Int((Double(maxPixels) / aspect).rounded())) : maxPixels
        let cs = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        // The OKLab blend depends only on the position along the diagonal: precompute it once.
        let lut: [AircColor] = (0...255).map { i in
            switch cs.count {
            case 0: fallbackColor
            case 1: cs[0]
            default: AircColor.mix(cs[0], cs[1], Double(i) / 255)
            }
        }
        for j in 0..<h {
            let y = Double(j) / Double(h - 1)
            for i in 0..<w {
                let x = Double(i) / Double(w - 1)
                let t = min(1, ((x * aspect + y) / (aspect + 1)) / 0.75)
                var base = lut[Int((t * 255).rounded())]
                if cs.count >= 3 { base = cs[2].alpha(y).over(base) }
                let k = (j * w + i) * 4
                if includeUnderlay {
                    let c = base.alpha(layerOpacity).over(underlay)
                    bytes[k] = UInt8((c.red * 255).rounded())
                    bytes[k + 1] = UInt8((c.green * 255).rounded())
                    bytes[k + 2] = UInt8((c.blue * 255).rounded())
                } else {
                    let a = layerOpacity
                    bytes[k] = UInt8((base.red * a * 255).rounded())
                    bytes[k + 1] = UInt8((base.green * a * 255).rounded())
                    bytes[k + 2] = UInt8((base.blue * a * 255).rounded())
                    bytes[k + 3] = UInt8((a * 255).rounded())
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: (includeUnderlay ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// The colour of grain at full strength is tuned so 1.0 reads as Arc's heaviest grain.
    static let grainScale = 0.55

    private var fallbackColor: AircColor { isDark ? AircColor.Stone.s800 : AircColor.Stone.s200 }
}

// MARK: - Derivation

extension SpaceTheme {
    /// Resolves the theme for the given system appearance.
    public func resolved(systemIsDark: Bool) -> ResolvedTheme {
        ResolvedTheme(theme: self, systemIsDark: systemIsDark)
    }

    /// Whether this theme renders dark under the given system appearance.
    public func rendersDark(systemIsDark: Bool) -> Bool {
        switch appearance {
        case .light: return false
        case .dark: return true
        case .auto:
            // darkfix: Auto follows the app's appearance (Settings › Appearance; macOS when that is Auto), whatever
            // the colours. It used to keep very light colours light and very dark ones dark, so an Arc-style pastel
            // Space stayed light under a dark Mac and nothing in Settings could change it.
            return systemIsDark
        }
    }
}

extension ResolvedTheme {
    /// Contrast floors. Tests assert these on every preset and on thousands of random themes.
    public enum Floor {
        public static let text = 4.5
        public static let textSecondary = 3.0
        public static let textTertiary = 2.4
        public static let onAccent = 4.5
        public static let surfaceText = 7.0
        /// Dark themes (darkmode): secondary and tertiary ink are body text (URLs, subtitles, the profile label, "+ New
        /// Tab"), so both get WCAG AA's 4.5:1. Tertiary only on the window (not on selected rows), so it keeps a clear
        /// step below secondary (about 0.54 vs 0.78 alpha).
        public static let textSecondaryDark = 4.5
        public static let textTertiaryDark = 4.5
        /// Dark surfaces (Command Bar, menus, Settings, cards): tertiary text there carries timestamps, hints and
        /// subtitles, so it reads as body text too; and accent-coloured text (links, actions) on them.
        public static let surfaceTextTertiaryDark = 4.5
        public static let accentTextDark = 4.5

        /// The secondary floor for a light (`false`) or dark (`true`) theme.
        public static func textSecondary(dark: Bool) -> Double { dark ? textSecondaryDark : textSecondary }
        public static func textTertiary(dark: Bool) -> Double { dark ? textTertiaryDark : textTertiary }
    }

    /// The floors this theme's sidebar ink meets (`Floor`, by appearance).
    public var secondaryFloor: Double { Floor.textSecondary(dark: isDark) }
    public var tertiaryFloor: Double { Floor.textTertiary(dark: isDark) }

    /// Nominal ink alphas before contrast correction (Arc's tokens).
    enum Ink {
        static func text(_ dark: Bool) -> Double { dark ? 0.92 : 0.86 }
        /// Dark starts higher than Arc's 0.60 / 0.40 (darkmode): at the 4.5:1 floor exactly, Subtle translucency would
        /// have to go opaque over a bright desktop to keep it; this headroom keeps the desktop showing through.
        static func secondary(_ dark: Bool) -> Double { dark ? 0.75 : 0.60 }
        static func tertiary(_ dark: Bool) -> Double { dark ? 0.60 : 0.42 }
        static func disabled(_ dark: Bool) -> Double { 0.26 }
        /// Dark themes wash the colour layer until secondary ink passes its floor at this alpha or less, so it keeps a
        /// clear step below primary ink (0.92).
        static let secondaryCapDark = 0.78
    }

    /// Sample grid used for contrast checks: 9 × 9 (diagonal position, height) pairs.
    static let sampleGrid: [(Double, Double)] = {
        var pts: [(Double, Double)] = []
        for i in 0...8 { for j in 0...8 { pts.append((Double(i) / 8, Double(j) / 8)) } }
        return pts
    }()

    init(theme: SpaceTheme, systemIsDark: Bool) {
        let dark = theme.rendersDark(systemIsDark: systemIsDark)
        let cs = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        let fallback = dark ? AircColor.Stone.s800 : AircColor.Stone.s200
        let underlay: AircColor = dark ? .black() : .white()
        let ink: AircColor = dark ? .inkDark : .inkLight

        // Fills (Arc 1.170 asset catalog; light tile value read off a reference screenshot).
        let hover = dark ? AircColor.inkDark.alpha(0.10) : AircColor.inkLight.alpha(0.05)
        let pressed = dark ? AircColor.inkDark.alpha(0.065) : AircColor.inkLight.alpha(0.065)
        let selected = dark ? AircColor.inkDark.alpha(0.20) : AircColor.white(0.85)

        func samples(_ opacity: Double) -> [AircColor] {
            Self.sampleGrid.map { Self.composite(colors: cs, fallback: fallback, underlay: underlay, opacity: opacity, t: $0.0, y: $0.1) }
        }
        func worst(_ fg: AircColor, _ bgs: [AircColor]) -> Double {
            bgs.map { fg.contrast(on: $0) }.min() ?? 21
        }
        /// Backgrounds text must read on: the window, and the selected and hovered rows on it.
        func textGrounds(_ bgs: [AircColor]) -> [AircColor] {
            bgs + bgs.map { selected.over($0) } + bgs.map { hover.over($0) }
        }
        /// Primary ink also reads on the selected row under the pointer in dark themes (its fill is the brightest
        /// ground in the sidebar). Light themes' is near-white, never the binding ground, so they leave it out.
        let selectedHover = AircColor.inkDark.alpha(AircMetrics.Row.selectedHoverAlphaDark)
        func primaryGrounds(_ bgs: [AircColor]) -> [AircColor] {
            dark ? textGrounds(bgs) + bgs.map { selectedHover.over($0) } : textGrounds(bgs)
        }

        // 1. Wash the colour layer out until full-strength ink passes the primary floor with margin (and, in dark themes,
        //    until secondary ink at `Ink.secondaryCapDark` passes its floor).
        let secondaryFloor = Floor.textSecondary(dark: dark)
        func washed(_ bgs: [AircColor]) -> Bool {
            let g = textGrounds(bgs)
            if worst(ink, primaryGrounds(bgs)) < Floor.text + 0.6 { return false }
            return !dark || worst(ink.alpha(Ink.secondaryCapDark), g) >= secondaryFloor + 0.02
        }
        var opacity = 0.2 + 0.55 * theme.intensity.clamped01
        var bgs = samples(opacity)
        while opacity > 0.02, !washed(bgs) {
            opacity -= 0.01
            bgs = samples(opacity)
        }
        let grounds = textGrounds(bgs)

        // 2. Raise each ink alpha until it meets its floor.
        func inkAlpha(start: Double, floor: Double, on grounds: [AircColor]) -> AircColor {
            var a = start
            while a < 1, worst(ink.alpha(a), grounds) < floor + 0.02 { a = min(1, a + 0.01) }
            return ink.alpha(a)
        }

        self.theme = theme
        self.isDark = dark
        self.underlay = underlay
        self.layerOpacity = opacity
        self.text = inkAlpha(start: Ink.text(dark), floor: Floor.text, on: primaryGrounds(bgs))
        self.textSecondary = inkAlpha(start: Ink.secondary(dark), floor: secondaryFloor, on: grounds)
        self.textTertiary = inkAlpha(start: Ink.tertiary(dark), floor: Floor.textTertiary(dark: dark), on: bgs)
        self.textDisabled = ink.alpha(Ink.disabled(dark))

        self.hoverFill = hover
        self.pressedFill = pressed
        self.selectedFill = selected
        self.selectedHasShadow = !dark
        self.tileFill = dark ? AircColor.inkDark.alpha(0.10) : AircColor.inkLight.alpha(0.05)
        self.tileHoverFill = dark ? AircColor.inkDark.alpha(0.18) : AircColor.inkLight.alpha(0.09)
        self.fieldFill = dark ? AircColor.inkDark.alpha(0.10) : AircColor.inkLight.alpha(0.05)
        self.separator = ink.alpha(dark ? 0.15 : 0.15)

        // Gradient stops: OKLab-interpolated, so the blend never goes muddy in the middle.
        var stops: [Stop] = []
        switch cs.count {
        case 0: stops = [Stop(color: fallback, location: 0), Stop(color: fallback, location: 1)]
        case 1: stops = [Stop(color: cs[0], location: 0), Stop(color: cs[0], location: 1)]
        default:
            for i in 0...12 {
                let t = Double(i) / 12
                stops.append(Stop(color: AircColor.mix(cs[0], cs[1], t), location: t * 0.75))
            }
            stops.append(Stop(color: cs[1], location: 1))
        }
        self.gradient = stops
        self.overlay = cs.count >= 3 ? cs[2] : nil

        let avg = bgs.map(\.oklab).reduce(OKLab(l: 0, a: 0, b: 0)) { OKLab(l: $0.l + $1.l, a: $0.a + $1.a, b: $0.b + $1.b) }
        let n = Double(bgs.count)
        let avgLab = OKLab(l: avg.l / n, a: avg.a / n, b: avg.b / n)
        self.background = AircColor(oklab: avgLab)

        // 3. Surface: near-white or deep grey, carrying a whisper of the theme hue.
        let surfaceLab = OKLab.lch(dark ? 0.255 : 0.988, min(avgLab.chroma * 0.25, dark ? 0.018 : 0.012), avgLab.hue)
        let surface = AircColor(oklab: surfaceLab)
        let surfaceInk: AircColor = dark ? .inkDark : .inkLight
        self.surface = surface
        self.surfaceText = surfaceInk.alpha(dark ? 0.94 : 0.90)
        // Dark: 0.62, raised until it passes 4.5:1 on the surface, its hover and the accent-tinted selected row (light
        // accents, such as a yellow theme's, tint that row brightly).
        var secondaryAlpha = dark ? 0.62 : 0.58
        let selectedRow = Self.accentForSelection(cs: cs, dark: dark, surface: surface).alpha(dark ? 0.26 : 0.12).over(surface)
        while dark, secondaryAlpha < 0.9,
              [surface, surfaceInk.alpha(0.06).over(surface), selectedRow]
                  .contains(where: { surfaceInk.alpha(secondaryAlpha).contrast(on: $0) < 4.52 }) {
            secondaryAlpha += 0.01
        }
        // Dark: raised from 0.40 until it passes 4.5:1 on the surface, its hover and the selected row (about 0.52; a selected
        // Command Bar row shows its URL in it). Secondary stays a visible step above.
        var tertiaryAlpha = dark ? 0.40 : 0.38
        while dark, tertiaryAlpha < 0.9,
              [surface, surfaceInk.alpha(0.06).over(surface), selectedRow]
                  .contains(where: { surfaceInk.alpha(tertiaryAlpha).contrast(on: $0) < Floor.surfaceTextTertiaryDark + 0.02 }) {
            tertiaryAlpha += 0.01
        }
        if dark { secondaryAlpha = max(secondaryAlpha, min(0.94, tertiaryAlpha + 0.06)) }
        self.surfaceTextSecondary = surfaceInk.alpha(secondaryAlpha)
        self.surfaceTextTertiary = surfaceInk.alpha(tertiaryAlpha)
        self.surfaceBorder = surfaceInk.alpha(dark ? 0.10 : 0.08)
        self.surfaceHover = surfaceInk.alpha(dark ? 0.06 : 0.04)

        // 4. Accent: the most chromatic theme colour at a fixed lightness, adjusted until its label passes.
        let (accent, onAccent) = Self.accent(from: Self.accentSource(cs, dark: dark), dark: dark, surface: surface)
        self.accent = accent
        self.onAccent = onAccent
        self.focusRing = accent.alpha(dark ? 0.75 : 0.55)
        self.surfaceSelected = accent.alpha(dark ? 0.26 : 0.12)
        self.accentText = Self.accentText(accent: accent, dark: dark, surface: surface, selected: accent.alpha(dark ? 0.26 : 0.12),
                                          window: bgs)
    }

    /// The accent as text on `surface` (links, toast and row actions). Light themes use the accent itself. Dark themes
    /// lighten it in OKLab (same hue) until it passes `Floor.accentTextDark` on the surface, its selected row and the window, since
    /// the accent's own lightness is set by its white label and sits near 3:1 on the dark surface.
    static func accentText(accent: AircColor, dark: Bool, surface: AircColor, selected: AircColor, window: [AircColor] = []) -> AircColor {
        guard dark else { return accent }
        // The surface, its selected and hovered rows, and the window itself (the Library and other panels on the Space).
        let grounds = [surface, selected.over(surface), AircColor.inkDark.alpha(0.06).over(surface)] + window
        let lab = accent.oklab
        var l = lab.l
        var c = accent
        while l < 0.97, grounds.contains(where: { c.contrast(on: $0) < Floor.accentTextDark + 0.05 }) {
            l += 0.01
            c = AircColor(oklab: .lch(l, lab.chroma, lab.hue))
        }
        return c
    }

    /// The accent `init` will derive, for tokens computed before it (the selected row's tint).
    static func accentForSelection(cs: [AircColor], dark: Bool, surface: AircColor) -> AircColor {
        accent(from: accentSource(cs, dark: dark), dark: dark, surface: surface).0
    }

    /// The theme colour the accent comes from: the most chromatic one, or Airc blue.
    static func accentSource(_ cs: [AircColor], dark: Bool) -> AircColor {
        cs.max { $0.oklab.chroma < $1.oklab.chroma } ?? (dark ? AircColor.aircBlueDark : AircColor.aircBlue)
    }

    static func accent(from source: AircColor, dark: Bool, surface: AircColor) -> (AircColor, AircColor) {
        let lab = source.oklab
        if lab.chroma < 0.035 {
            // A grey theme gets a graphite accent.
            return dark ? (AircColor.Stone.s100, AircColor.Stone.s950) : (AircColor.Stone.s900, AircColor.white())
        }
        let hue = lab.hue
        let chroma = min(max(lab.chroma, 0.11), 0.21)
        let yellowish = (75...118).contains(hue)
        if yellowish {
            // Yellows only stay yellow when light, so they carry dark labels. In light themes they deepen to
            // gold so the accent still shows on a white surface (≥ 3:1).
            var l = dark ? 0.84 : 0.66
            let label = AircColor.Stone.s950
            var c = AircColor(oklab: .lch(l, chroma, hue))
            while label.contrast(on: c) < Floor.onAccent + 0.1, l < 0.98 { l += 0.01; c = AircColor(oklab: .lch(l, chroma, hue)) }
            // Light themes: deepen until the accent shows on the surface (focus rings, switches).
            while !dark, c.contrast(on: surface) < 3.05, label.contrast(on: c) > Floor.onAccent + 0.1, l > 0.3 {
                l -= 0.01
                c = AircColor(oklab: .lch(l, chroma, hue))
            }
            return (c, label)
        }
        var l = dark ? 0.60 : 0.56
        var c = AircColor(oklab: .lch(l, chroma, hue))
        while AircColor.white().contrast(on: c) < Floor.onAccent + 0.1, l > 0.2 { l -= 0.01; c = AircColor(oklab: .lch(l, chroma, hue)) }
        return (c, .white())
    }

    /// Arc's shader at one point: OKLab diagonal blend of colours 1→2 (colour 2 reached at 75 %), colour 3
    /// fading in top to bottom, the result drawn at `opacity` over the underlay.
    static func composite(colors cs: [AircColor], fallback: AircColor, underlay: AircColor, opacity: Double, x: Double, y: Double, aspect: Double = 1) -> AircColor {
        // Position along a 45° axis from the top-left to the bottom-right corner, 0...1.
        composite(colors: cs, fallback: fallback, underlay: underlay, opacity: opacity, t: (x * aspect + y) / (aspect + 1), y: y)
    }

    /// The shader at diagonal position `t` and height `y`. Sampling (t, y) over the unit square covers every
    /// point of every window shape, so contrast checks hold at any aspect ratio.
    static func composite(colors cs: [AircColor], fallback: AircColor, underlay: AircColor, opacity: Double, t: Double, y: Double) -> AircColor {
        var base: AircColor
        switch cs.count {
        case 0: base = fallback
        case 1: base = cs[0]
        default: base = AircColor.mix(cs[0], cs[1], min(1, t / 0.75))
        }
        if cs.count >= 3 { base = cs[2].alpha(y).over(base) }
        return base.alpha(opacity).over(underlay).alpha(1)
    }
}
