// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Colours added in design pass 3. They derive from the tokens `ResolvedTheme` already computes, so they keep
// its contrast floors (the tests check the new pairs too).
extension ResolvedTheme {
    /// The selected row under the pointer: dark is ink 0.36 (Arc), light stays white 0.85 with its shadow, nudged
    /// by the hover ink so the pointer still registers.
    public var selectedHoverFill: AircColor {
        isDark ? AircColor.inkDark.alpha(AircMetrics.Row.selectedHoverAlphaDark) : AircColor.white(0.92)
    }

    /// The 2 pt line (and its 8 pt ring) that marks where a dragged row will land. Arc: white 0.9 in dark
    /// themes; light themes use the theme's primary ink at 0.80, because white would vanish on them.
    public var dropLine: AircColor {
        isDark ? AircColor.white(0.90) : AircColor.inkLight.alpha(0.80)
    }

    /// The Command Bar's inline completion (the part after the caret). One step above `surfaceTextTertiary` so it
    /// reads as a suggestion but stays legible at 3 : 1 on `surface`.
    public var inlineCompletionText: AircColor {
        let ink: AircColor = isDark ? .inkDark : .inkLight
        var a = isDark ? 0.46 : 0.44
        while a < 0.9, ink.alpha(a).over(surface).contrast(on: surface) < 3.0 { a += 0.01 }
        return ink.alpha(a)
    }

    /// The inline completion's selection highlight (it is selected text): accent at 0.18 / 0.30.
    public var inlineCompletionHighlight: AircColor { accent.alpha(isDark ? 0.30 : 0.18) }

    /// A segmented control's recessed track on `surface`.
    public var segmentedTrack: AircColor { (isDark ? AircColor.inkDark : AircColor.inkLight).alpha(isDark ? 0.08 : 0.05) }

    /// The raised selected segment. Light: white. Dark: white 0.20 over `surface` (the app's 0.12 sat too close to
    /// the track), plus a 0.5 pt `surfaceBorder` hairline and the `control` shadow.
    public var segmentedSelection: AircColor {
        isDark ? AircColor.white(0.20).over(surface) : AircColor.white()
    }

    /// The selected segment's label: full `surfaceText`; the others use `surfaceTextSecondary`.
    public var segmentedSelectedText: AircColor { surfaceText }

    /// The cut-out ring around profile dots on footer icons: the window's own colour, so the dot reads as punched
    /// through.
    public var profileDotRing: AircColor { background }

    /// A sidebar card on the theme (the "Sign in to Google" card, banners): the selected-row fill, so it reads as an
    /// object, with `selectedHasShadow` deciding the shadow.
    public var sidebarCardFill: AircColor { selectedFill }

    /// Fill of a 22 pt pill on a 36 pt `fieldFill` row (the Profile pill in Create a Space).
    public var pillFill: AircColor { tileHoverFill }
}

/// A profile's identity colours (SP-15).
public enum AircProfileColor {
    /// The nine colours offered in Create Profile and Settings → Profiles.
    public static let choices: [AircColor] = [
        AircColor(0x4C7DF0), AircColor(0x2F9E62), AircColor(0x14A3A3), AircColor(0x8B5CF6), AircColor(0xE0559F),
        AircColor(0xE5484D), AircColor(0xF0782A), AircColor(0xE8B21E), AircColor(0x6B6560),
    ]

    /// The pastel disc an emoji avatar sits on: the colour mixed with white in OKLab
    /// (`AircMetrics.Profile.pastelShare` of colour). Constant across themes, so a profile looks the same everywhere.
    public static func pastel(_ color: AircColor) -> AircColor {
        AircColor.mix(.white(), color.alpha(1), AircMetrics.Profile.pastelShare)
    }

    /// Emoji suggested first in Create Profile (the full picker sits behind "•••").
    public static let suggestedEmoji = ["🪴", "🌱", "⚡️", "🍊", "🎧", "📚", "🧪", "🏄", "🐙"]
}
