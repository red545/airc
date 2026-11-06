// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics

/// Corner radii, in points. Arc-measured values first; use continuous corners (`.continuous`) for everything
/// except the page card, which Arc draws circular.
public enum AircRadius {
    /// Page card (Arc, circular).
    public static let card: CGFloat = 6
    /// Header buttons, small icon buttons (Arc).
    public static let headerButton: CGFloat = 6
    /// Small buttons, chips, keycaps.
    public static let small: CGFloat = 6
    /// Buttons and text fields in settings, onboarding and dialogs.
    public static let control: CGFloat = 8
    /// Large (38 pt) buttons.
    public static let controlLarge: CGFloat = 10
    /// Favorites tiles (Arc).
    public static let tile: CGFloat = 10
    /// Menus.
    public static let menu: CGFloat = 10
    /// Sidebar row plates and the URL field (Arc).
    public static let row: CGFloat = 12
    /// Toasts and the floating sidebar.
    public static let toast: CGFloat = 12
    /// Popovers, settings groups.
    public static let popover: CGFloat = 14
    /// The command bar and dialogs.
    public static let commandBar: CGFloat = 16
    /// The theme picker card (Arc) and onboarding cards.
    public static let panel: CGFloat = 20
    /// Floating windows without a title bar: onboarding (ON-5). Large, like macOS 26 windows.
    public static let floatingWindow: CGFloat = 24
    /// Fully round.
    public static let capsule: CGFloat = 999
}
