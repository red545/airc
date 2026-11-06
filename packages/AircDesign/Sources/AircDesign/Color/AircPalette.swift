// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Fixed colour tokens. Theme-dependent colours (sidebar ink, fills, accent) come from `ResolvedTheme`.
extension AircColor {
    /// The warm neutral ramp ("stone"). Used for app chrome that sits outside a Space theme: settings,
    /// onboarding cards, menus, the default theme. Slightly warm, like paper, never blue-grey.
    public enum Stone {
        public static let s0 = AircColor(0xFFFFFF)
        public static let s25 = AircColor(0xFCFBFA)
        public static let s50 = AircColor(0xF7F6F4)
        public static let s100 = AircColor(0xEFEDEA)
        public static let s200 = AircColor(0xE3E0DC)
        public static let s300 = AircColor(0xCFCAC5)
        public static let s400 = AircColor(0xA9A39E)
        public static let s500 = AircColor(0x7F7873)
        public static let s600 = AircColor(0x5F5955)
        public static let s700 = AircColor(0x47413E)
        public static let s800 = AircColor(0x2F2A28)
        public static let s900 = AircColor(0x1D1A18)
        public static let s950 = AircColor(0x110F0E)

        /// The ramp in order, light to dark, for galleries and docs.
        public static let ramp: [(name: String, color: AircColor)] = [
            ("0", s0), ("25", s25), ("50", s50), ("100", s100), ("200", s200), ("300", s300), ("400", s400),
            ("500", s500), ("600", s600), ("700", s700), ("800", s800), ("900", s900), ("950", s950),
        ]
    }

    /// Ink on light surfaces: a warm near-black, always used with alpha.
    public static let inkLight = AircColor(0x14110F)
    /// Ink on dark surfaces: Arc's slightly cool white, always used with alpha.
    public static let inkDark = AircColor(0xFAFBFF)

    /// Airc blue: the accent of the default theme and of app chrome outside a Space (Arc's #2129FB, calmed).
    public static let aircBlue = AircColor(0x3139FB)
    public static let aircBlueDark = AircColor(0x7078FF)

    /// Status colours. Use sparingly: one status colour per view.
    public static let red = AircColor(0xE5484D)
    public static let green = AircColor(0x2F9E62)
    public static let amber = AircColor(0xF5A524)
    /// The unread dot on Favorites (matches Arc's unread dot on a Gmail tile).
    public static let unreadDot = AircColor(0xE5453A)
}
