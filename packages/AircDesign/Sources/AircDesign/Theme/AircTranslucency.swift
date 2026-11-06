// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit

/// How much of the desktop shows through a themed window, as in Arc: the macOS behind-window blur, then the
/// theme's white (light) or black (dark) underlay at an opacity, then the colour layer and grain on top.
///
/// The user picks the level in Settings › Appearance. `subtle` is the default.
/// Whatever the level, text keeps its contrast floors over any desktop (see
/// `ResolvedTheme.underlayOpacity(for:isWindowActive:reduceTransparency:)`). Inactive windows and
/// Reduce Transparency fall back to opaque, as Arc's blur does.
public enum AircTranslucency: String, Hashable, Sendable, Codable, CaseIterable {
    /// Opaque: the theme over a solid underlay (v1's original look).
    case off
    /// The desktop shows through faintly (Arc's look). The default.
    case subtle
    /// Noticeably see-through, still legible.
    case more

    public static let `default`: AircTranslucency = .subtle

    /// The underlay opacity before the contrast floor: 1 is opaque. Dark underlays go lower because black
    /// over the dark blur material hides less than white over the light one.
    public func nominalUnderlayOpacity(isDark: Bool) -> Double {
        switch self {
        case .off: 1
        case .subtle: isDark ? 0.55 : 0.70
        case .more: isDark ? 0.25 : 0.40
        }
    }

    /// Whether the user turned on System Settings › Accessibility › Display › Reduce transparency.
    @MainActor public static var systemReducesTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public var title: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .more: "More"
        }
    }
}

extension AircTranslucency {
    /// The blur material's own tint (`.underWindowBackground`), read off the material on the build Mac
    /// (macOS 26.6) for the light and dark appearance.
    public static func materialTint(isDark: Bool) -> AircColor {
        isDark ? AircColor(0x5A5D5C) : AircColor(0xE8EBEA)
    }

    /// The most of the desktop the material lets through to the theme, as a share. The real response can't be
    /// captured without Screen Recording permission (the window server leaves the backdrop out of window
    /// captures), so this is a conservative bound: macOS's window materials pass well under half of a
    /// blurred desktop. Raise it if a permitted capture shows more.
    public static let materialPassThrough = 0.5

    /// The worst things a busy wallpaper can put behind the theme, after the material: pure black, white, grey
    /// and the six primaries and secondaries, each passed through the material.
    public static func worstCaseBackdrops(isDark: Bool) -> [AircColor] {
        let tint = materialTint(isDark: isDark)
        return ResolvedTheme.worstCaseDesktops.map { tint.lerp(to: $0, materialPassThrough) }
    }
}

extension ResolvedTheme {
    /// Raw desktop extremes. Luminance is monotonic in each channel, so black and white bound it; the
    /// primaries and secondaries cover hue shifts of the composited ink.
    static let worstCaseDesktops: [AircColor] = [
        .black(), .white(), AircColor(0x808080),
        AircColor(0xFF0000), AircColor(0x00FF00), AircColor(0x0000FF),
        AircColor(0x00FFFF), AircColor(0xFF00FF), AircColor(0xFFFF00),
    ]

    /// The underlay opacity to draw for a translucency level. It starts at the level's nominal value and rises
    /// until `text`, `textSecondary` and `textTertiary` meet their floors over every worst-case backdrop
    /// (`AircTranslucency.worstCaseBackdrops`), at every
    /// point of the window and on the selected and hovered rows. Inactive windows and Reduce Transparency get 1
    /// (opaque), as Arc's blur goes opaque when the window resigns main.
    public func underlayOpacity(for translucency: AircTranslucency, isWindowActive: Bool = true, reduceTransparency: Bool = false) -> Double {
        guard translucency != .off, isWindowActive, !reduceTransparency else { return 1 }
        // Whole percent steps, so levels that hit the same floor return exactly the same value.
        var step = Int((translucency.nominalUnderlayOpacity(isDark: isDark) * 100).rounded())
        while step < 100, !meetsFloors(underlayOpacity: Double(step) / 100) { step += 1 }
        return Double(step) / 100
    }

    /// The share of the blurred desktop that reaches the eye at an underlay opacity: what the colour layer and
    /// the underlay both let through.
    public func desktopFraction(underlayOpacity: Double) -> Double {
        (1 - layerOpacity) * (1 - underlayOpacity)
    }

    /// Whether the ink tokens meet their floors over every worst-case desktop at this underlay opacity.
    func meetsFloors(underlayOpacity a: Double) -> Bool {
        let window = translucentGrounds(underlayOpacity: a)
        let rows = window.flatMap { [selectedFill.over($0), hoverFill.over($0)] }
        let textGrounds = window + rows
        func passes(_ ink: AircColor, _ floor: Double, _ grounds: [AircColor]) -> Bool {
            grounds.allSatisfy { ink.contrast(on: $0) >= floor }
        }
        return passes(text, Floor.text, textGrounds)
            && passes(textSecondary, Floor.textSecondary, textGrounds)
            && passes(textTertiary, Floor.textTertiary, window)
    }

    /// The window background at the contrast sample points, over each worst-case desktop.
    func translucentGrounds(underlayOpacity a: Double) -> [AircColor] {
        let cs = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        let fallback = isDark ? AircColor.Stone.s800 : AircColor.Stone.s200
        var out: [AircColor] = []
        out.reserveCapacity(Self.sampleGrid.count * Self.worstCaseDesktops.count)
        for desktop in AircTranslucency.worstCaseBackdrops(isDark: isDark) {
            let base = underlay.alpha(a).over(desktop)
            for (t, y) in Self.sampleGrid {
                out.append(Self.composite(colors: cs, fallback: fallback, underlay: base, opacity: layerOpacity, t: t, y: y))
            }
        }
        return out
    }

    /// The colour layer alone (gradient and third colour, no underlay) with alpha `layerOpacity`, as a small
    /// premultiplied image to stretch over a view. Draw it over the underlay at `underlayOpacity(for:)`.
    public func colorLayerImage(for size: CGSize, maxPixels: Int = 200) -> CGImage {
        renderBackground(for: size, maxPixels: maxPixels, includeUnderlay: false)
    }

    /// Ink for an inactive window: Arc dims sidebar text and header glyphs slightly when the window isn't main.
    /// Each ink token's alpha drops by `inactiveInkFactor`, but never below its contrast floor.
    public func forWindow(isActive: Bool) -> ResolvedTheme {
        guard !isActive else { return self }
        let cs = Array(theme.colors.prefix(SpaceTheme.maxColors)).map { $0.alpha(1) }
        let fallback = isDark ? AircColor.Stone.s800 : AircColor.Stone.s200
        let window = Self.sampleGrid.map { Self.composite(colors: cs, fallback: fallback, underlay: underlay, opacity: layerOpacity, t: $0.0, y: $0.1) }
        let rows = window + window.flatMap { [selectedFill.over($0), hoverFill.over($0)] }
        func dim(_ ink: AircColor, floor: Double, on grounds: [AircColor]) -> AircColor {
            var a = ink.alpha * Self.inactiveInkFactor
            while a < ink.alpha, grounds.contains(where: { ink.alpha(a).contrast(on: $0) < floor }) { a = min(ink.alpha, a + 0.01) }
            return ink.alpha(a)
        }
        var copy = self
        copy.text = dim(text, floor: Floor.text, on: rows)
        copy.textSecondary = dim(textSecondary, floor: Floor.textSecondary, on: rows)
        copy.textTertiary = dim(textTertiary, floor: Floor.textTertiary, on: window)
        copy.textDisabled = textDisabled.alpha(textDisabled.alpha * Self.inactiveInkFactor)
        copy.isWindowActive = false
        return copy
    }

    /// Inactive windows draw ink at this share of its active alpha (Arc "dims slightly").
    public static let inactiveInkFactor = 0.85
}
