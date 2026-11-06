// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// One step of the type scale: size, weight, design, line height and tracking, in points.
public struct AircTextStyle: Hashable, Sendable {
    public enum Weight: Hashable, Sendable { case regular, medium, semibold, bold }
    public enum Design: Hashable, Sendable { case `default`, rounded, monospaced }

    public let size: CGFloat
    public let weight: Weight
    public let design: Design
    public let lineHeight: CGFloat
    /// Letter spacing in points (negative tightens).
    public let tracking: CGFloat

    public init(size: CGFloat, weight: Weight = .regular, design: Design = .default, lineHeight: CGFloat, tracking: CGFloat = 0) {
        self.size = size
        self.weight = weight
        self.design = design
        self.lineHeight = lineHeight
        self.tracking = tracking
    }

    public func weight(_ w: Weight) -> AircTextStyle {
        AircTextStyle(size: size, weight: w, design: design, lineHeight: lineHeight, tracking: tracking)
    }

    public var font: Font {
        .system(size: size, weight: weight.swiftUI, design: design.swiftUI)
    }

    /// The AppKit font, created once per style and cached (text is measured and drawn on every frame that changes).
    /// Not main-actor-bound: NSFont is immutable and safe to share across threads.
    public var nsFont: NSFont { AircFontCache.font(for: self) }

    /// A new font for this style, or nil when AppKit hands back none (see `AircFontCache.present`).
    func makeFont() -> NSFont? {
        let base = AircFontCache.present(design == .monospaced
            ? .monospacedSystemFont(ofSize: size, weight: weight.appKit)
            : .systemFont(ofSize: size, weight: weight.appKit))
        guard let base else { return nil }
        if design == .rounded, let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
            return f
        }
        return base
    }
}

/// One font per text style. A style whose font can't be made gets a fallback that isn't cached, so the next use tries
/// again.
enum AircFontCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fonts: [AircTextStyle: NSFont] = [:]

    static func font(for style: AircTextStyle) -> NSFont {
        lock.lock()
        let cached = fonts[style]
        lock.unlock()
        if let cached { return cached }
        guard let made = style.makeFont() else { return fallback(size: style.size) }
        lock.lock()
        defer { lock.unlock() }
        if let raced = fonts[style] { return raced }
        fonts[style] = made
        return made
    }

    /// AppKit declares its system font constructors non-null, but they have returned nil on the build Mac (the command
    /// bar's keycaps, twice in about eight runs, with the screen locked). Swift doesn't check a non-null return, so the
    /// nil went into an attribute dictionary and CoreText threw "attempt to insert nil object" while measuring text.
    /// This reads the reference's bits, which the optimiser can't assume away.
    @inline(never)
    static func present(_ font: NSFont) -> NSFont? {
        unsafeBitCast(font, to: UInt.self) == 0 ? nil : font
    }

    /// Any real font of the right size, for when the system font isn't available.
    static func fallback(size: CGFloat) -> NSFont {
        if let f = NSFont.userFont(ofSize: size) { return f }
        if let f = NSFont(name: "HelveticaNeue", size: size) { return f }
        if let f = NSFont(name: "Helvetica", size: size) { return f }
        return .labelFont(ofSize: size)
    }
}

extension AircTextStyle.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var appKit: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension AircTextStyle.Design {
    var swiftUI: Font.Design {
        switch self {
        case .default: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

/// The type scale. SF Pro everywhere; SF Pro Rounded only for display moments (onboarding, empty states,
/// the Space creation card); SF Mono only for metadata (shortcuts, versions, counts).
public enum AircFont {
    // Display
    /// Onboarding hero, the finish card. 34/40 rounded semibold.
    public static let display = AircTextStyle(size: 34, weight: .semibold, design: .rounded, lineHeight: 40, tracking: -0.7)
    /// Onboarding step titles. 26/32 rounded semibold.
    public static let title1 = AircTextStyle(size: 26, weight: .semibold, design: .rounded, lineHeight: 32, tracking: -0.45)
    /// Settings page titles, dialog titles. 20/26 semibold.
    public static let title2 = AircTextStyle(size: 20, weight: .semibold, lineHeight: 26, tracking: -0.3)
    /// Section titles, card titles. 15/20 semibold.
    public static let title3 = AircTextStyle(size: 15, weight: .semibold, lineHeight: 20, tracking: -0.1)

    // Browser chrome (Arc's measured sizes)
    /// Command bar input (Arc ≈ 18 pt).
    public static let commandInput = AircTextStyle(size: 18, weight: .regular, lineHeight: 24, tracking: -0.2)
    /// Sidebar tab and pinned rows (Arc 14 pt).
    public static let row = AircTextStyle(size: 14, weight: .regular, lineHeight: 18, tracking: -0.08)
    /// Space name in the sidebar header.
    public static let spaceName = AircTextStyle(size: 14, weight: .semibold, lineHeight: 18, tracking: -0.08)
    /// URL field (Arc 13 pt).
    public static let urlField = AircTextStyle(size: 13, weight: .regular, lineHeight: 16, tracking: -0.04)

    // Text
    /// Onboarding and empty-state body copy.
    public static let lead = AircTextStyle(size: 15, weight: .regular, lineHeight: 22, tracking: -0.1)
    /// Default UI text: settings, menus, command bar rows, buttons.
    public static let body = AircTextStyle(size: 13, weight: .regular, lineHeight: 18, tracking: -0.04)
    /// Secondary lines, hints, toggle descriptions.
    public static let callout = AircTextStyle(size: 12, weight: .regular, lineHeight: 16)
    /// Tooltips (Arc 12 pt semibold).
    public static let tooltip = AircTextStyle(size: 12, weight: .semibold, lineHeight: 16)
    /// Section labels ("Pinned"), timestamps, host lines.
    public static let caption = AircTextStyle(size: 11, weight: .medium, lineHeight: 14, tracking: 0.06)
    /// "Clear" on the divider (Arc ≈ 10 pt semibold).
    public static let micro = AircTextStyle(size: 10, weight: .semibold, lineHeight: 12, tracking: 0.1)

    // Metadata
    /// Keyboard shortcuts, versions, counts.
    public static let mono = AircTextStyle(size: 11, weight: .medium, design: .monospaced, lineHeight: 14)
}

extension View {
    /// Applies a type-scale step: font, tracking and line spacing.
    public func aircFont(_ style: AircTextStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(max(0, style.lineHeight - style.size * 1.2))
    }
}
