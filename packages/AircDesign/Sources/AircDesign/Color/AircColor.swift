// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// An sRGB colour with alpha. Components are gamma-encoded, 0...1.
///
/// AircColor is the currency of the design system: every token, theme and contrast check uses it, and it
/// converts to SwiftUI, AppKit and Core Graphics at the edge (`.color`, `.nsColor`, `.cgColor`).
public struct AircColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
        self.alpha = alpha.clamped01
    }

    /// `AircColor(0x90DDC1)`.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Parses `#RRGGBB`, `RRGGBB` or `#RRGGBBAA`.
    public init?(hex string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt32(v))
        } else {
            self.init(UInt32(v >> 8), alpha: Double(v & 0xFF) / 255)
        }
    }

    public static func white(_ alpha: Double = 1) -> AircColor { AircColor(red: 1, green: 1, blue: 1, alpha: alpha) }
    public static func black(_ alpha: Double = 1) -> AircColor { AircColor(red: 0, green: 0, blue: 0, alpha: alpha) }
    public static let clear = AircColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// The same colour with its alpha replaced.
    public func alpha(_ value: Double) -> AircColor {
        AircColor(red: red, green: green, blue: blue, alpha: value)
    }

    /// The same colour with its alpha multiplied.
    public func opacity(_ factor: Double) -> AircColor { alpha(alpha * factor) }

    /// Source-over compositing of `self` on `background`, in gamma-encoded sRGB (what Core Animation does).
    public func over(_ background: AircColor) -> AircColor {
        let a = alpha + background.alpha * (1 - alpha)
        guard a > 0 else { return .clear }
        func ch(_ s: Double, _ b: Double) -> Double { (s * alpha + b * background.alpha * (1 - alpha)) / a }
        return AircColor(red: ch(red, background.red), green: ch(green, background.green), blue: ch(blue, background.blue), alpha: a)
    }

    /// Linear interpolation in gamma-encoded sRGB (used for alpha blends; use `mix` for perceptual blends).
    public func lerp(to other: AircColor, _ t: Double) -> AircColor {
        AircColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    public var hexString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        let base = String(format: "#%02X%02X%02X", r, g, b)
        return alpha < 1 ? base + String(format: " @%.2f", alpha) : base
    }

    public var description: String { hexString }

    // MARK: Contrast (WCAG 2.x)

    /// WCAG relative luminance of the opaque colour (alpha ignored).
    public var relativeLuminance: Double {
        0.2126 * red.linearized + 0.7152 * green.linearized + 0.0722 * blue.linearized
    }

    /// WCAG contrast ratio of `self` drawn on `background`. A translucent foreground is composited first; the
    /// background is treated as opaque.
    public func contrast(on background: AircColor) -> Double {
        let bg = background.alpha(1)
        let fg = alpha < 1 ? over(bg) : self
        let l1 = fg.relativeLuminance, l2 = bg.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    // MARK: Platform bridges

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self.isFinite ? self : 0)) }
    /// sRGB transfer function, encoded → linear.
    var linearized: Double { self <= 0.04045 ? self / 12.92 : pow((self + 0.055) / 1.055, 2.4) }
    /// sRGB transfer function, linear → encoded.
    var gammaEncoded: Double { self <= 0.0031308 ? 12.92 * self : 1.055 * pow(self, 1 / 2.4) - 0.055 }
}
