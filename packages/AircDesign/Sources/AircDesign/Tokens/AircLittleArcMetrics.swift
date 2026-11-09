// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import CoreGraphics

extension AircMetrics {
    /// LA-1 Little Arc's window. Arc never had its Little Arc measured (docs/research/arc_behavior_spec.md, Gaps), so
    /// these follow Arc's main window: one themed surface, the page a card inset on every side, a row of controls in
    /// the Space colour above it, everything on the 4 pt grid and concentric with the macOS window corner.
    public enum LittleArc {
        /// The row above the page: traffic lights, favicon, host and title, the Open in chip.
        public static let barHeight: CGFloat = 38
        /// The page card's inset from the window's sides and bottom (the bar is above it).
        public static let cardInset: CGFloat = 6
        /// The card's corner: the window's (about 16 pt on macOS 26) less the inset, so the two curves are concentric.
        public static let cardRadius: CGFloat = 10
        /// Traffic light centres: the row's middle, as far in from the left as from the top; the system's 20 pt pitch.
        public static let trafficLightCenters: [CGPoint] = [CGPoint(x: 19, y: 19), CGPoint(x: 39, y: 19), CGPoint(x: 59, y: 19)]
        /// The favicon, 14 pt after the zoom light's edge.
        public static let favicon: CGFloat = 16
        public static let faviconX: CGFloat = 80
        /// Host and title start after the favicon.
        public static let textX: CGFloat = 102
        /// Gap between the host and the title.
        public static let titleGap: CGFloat = 6
        /// The Open in chip: 26 pt tall, 8 pt from the window's right edge.
        public static let chipHeight: CGFloat = 26
        public static let chipTrailing: CGFloat = 8
        public static let chipRadius: CGFloat = 8
        /// The chevron's part of the chip (its own hover plate and the menu).
        public static let chevronWidth: CGFloat = 22
        /// The loading line, under the row, above the page.
        public static let progressHeight: CGFloat = 2
    }
}
