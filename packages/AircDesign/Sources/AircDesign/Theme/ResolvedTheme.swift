// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Every colour the UI needs for one Space, derived from a `SpaceTheme` and the system appearance.
///
/// Sidebar text and glyphs are ink (near-black or near-white) at an alpha, so they pick up the theme's hue
/// the way Arc's do. The derivation guarantees contrast instead of hoping for it:
/// - primary text ≥ 4.5:1 on every point of the background and on the selected row;
/// - secondary text and glyphs ≥ 3:1; tertiary (placeholders, "+ New Tab") ≥ 2.4:1;
/// - text on the accent ≥ 4.5:1; text on `surface` ≥ 7:1.
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
            let cs = colors.prefix(SpaceTheme.maxColors)
            guard !cs.isEmpty else { return systemIsDark }
            let l = cs.map(\.oklab.l).reduce(0, +) / Double(cs.count)
            if l >= 0.80 { return false }
            if l <= 0.42 { return true }
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
    }

    /// Nominal ink alphas before contrast correction (Arc's tokens).
    enum Ink {
        static func text(_ dark: Bool) -> Double { dark ? 0.92 : 0.86 }
        static func secondary(_ dark: Bool) -> Double { 0.60 }
        static func tertiary(_ dark: Bool) -> Double { dark ? 0.40 : 0.42 }
        static func disabled(_ dark: Bool) -> Double { 0.26 }
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

        // 1. Wash the colour layer out until full-strength ink passes the primary floor with margin.
        var opacity = 0.2 + 0.55 * theme.intensity.clamped01
        var bgs = samples(opacity)
        while opacity > 0.02, worst(ink, textGrounds(bgs)) < Floor.text + 0.6 {
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
        self.text = inkAlpha(start: Ink.text(dark), floor: Floor.text, on: grounds)
        self.textSecondary = inkAlpha(start: Ink.secondary(dark), floor: Floor.textSecondary, on: grounds)
        self.textTertiary = inkAlpha(start: Ink.tertiary(dark), floor: Floor.textTertiary, on: bgs)
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
        self.surfaceTextSecondary = surfaceInk.alpha(dark ? 0.62 : 0.58)
        self.surfaceTextTertiary = surfaceInk.alpha(dark ? 0.40 : 0.38)
        self.surfaceBorder = surfaceInk.alpha(dark ? 0.10 : 0.08)
        self.surfaceHover = surfaceInk.alpha(dark ? 0.06 : 0.04)

        // 4. Accent: the most chromatic theme colour at a fixed lightness, adjusted until its label passes.
        let source = cs.max { $0.oklab.chroma < $1.oklab.chroma } ?? (dark ? AircColor.aircBlueDark : AircColor.aircBlue)
        let (accent, onAccent) = Self.accent(from: source, dark: dark, surface: surface)
        self.accent = accent
        self.onAccent = onAccent
        self.focusRing = accent.alpha(dark ? 0.75 : 0.55)
        self.surfaceSelected = accent.alpha(dark ? 0.26 : 0.12)
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
