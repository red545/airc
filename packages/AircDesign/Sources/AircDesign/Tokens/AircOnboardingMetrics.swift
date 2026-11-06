// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics

extension AircMetrics {
    /// The floating onboarding window (spec ON-5): a fixed-size card over the desktop, no title bar.
    public enum Onboarding {
        /// The window. Fixed, so steps cross-fade in place without resizing.
        public static let windowSize = CGSize(width: 760, height: 540)
        /// Window corners (continuous).
        public static let windowRadius: CGFloat = AircRadius.floatingWindow
        /// The live sidebar preview on the left, on the window's theme, exactly as wide as the real sidebar.
        public static let previewWidth: CGFloat = AircMetrics.Sidebar.defaultWidth
        /// The page card's inset in a browser window (the onboarding card no longer uses it: it is flush with the
        /// onboarding window, so no strip of theme shows around it; importux, 2026-11-06).
        public static let cardInset: CGFloat = AircMetrics.Window.cardInset
        /// The card's corners when it stands alone (the design gallery); in the window it takes the window's.
        public static let cardRadius: CGFloat = AircRadius.popover
        /// The card next to the preview, flush with the window: 760 − 228 by 540.
        public static let cardSize = CGSize(width: 532, height: 540)
        public static let cardPadding: CGFloat = 32
        /// The window sits slightly above the screen's centre (optical centre): this share of the free
        /// vertical space goes below it.
        public static let opticalCenterBias: CGFloat = 0.55
        /// Entrance: the window rises this far while fading in.
        public static let entranceRise: CGFloat = 8
        /// The corner radius of the browser window the onboarding expands into (a titled macOS 26 window
        /// without a toolbar; measured on the build Mac).
        public static let browserWindowRadius: CGFloat = 16
    }
}
