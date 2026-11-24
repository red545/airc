// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

// Airc.app draws with packages/AircDesign. This file only connects AircKit's stored model to it; it holds
// no visual values of its own except `DesignGaps`, the few Arc measurements AircDesign doesn't have yet.

/// Both packages have a `SpaceTheme`: AircKit's is what SpacesStore persists; AircDesign's is what the UI
/// resolves. Inside the app the bare name means the stored one.
typealias SpaceTheme = AircKit.SpaceTheme
typealias DesignTheme = AircDesign.SpaceTheme

extension RGBA {
    var aircColor: AircColor { AircColor(red: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { aircColor.nsColor }
    init(_ c: AircColor) { self.init(c.red, c.green, c.blue, c.alpha) }
}

extension AircKit.SpaceTheme {
    /// The design system's view of this stored theme.
    var design: DesignTheme {
        let appearance: DesignTheme.Appearance = switch self.appearance {
        case .auto: .auto
        case .light: .light
        case .dark: .dark
        }
        return DesignTheme(colors: colors.map(\.aircColor), intensity: intensity, grain: grain, appearance: appearance)
    }
}

extension DesignTheme {
    /// A design preset as a theme SpacesStore can store.
    var model: AircKit.SpaceTheme {
        let a: AircKit.Appearance = switch appearance {
        case .auto: .auto
        case .light: .light
        case .dark: .dark
        }
        return AircKit.SpaceTheme(colors: colors.map(RGBA.init), intensity: intensity, grain: grain, appearance: a)
    }
}

/// The colours one Space's theme gives every surface (TH-3), straight from AircDesign's ResolvedTheme.
struct Palette: Equatable {
    let resolved: ResolvedTheme

    init(theme: AircKit.SpaceTheme, systemDark: Bool) {
        resolved = theme.design.resolved(systemIsDark: systemDark)
    }

    var isDark: Bool { resolved.isDark }
    var textPrimary: NSColor { resolved.text.nsColor }
    var textSecondary: NSColor { resolved.textSecondary.nsColor }
    var textMuted: NSColor { resolved.textTertiary.nsColor }
    var textFaint: NSColor { resolved.textTertiary.nsColor }
    var glyph: NSColor { resolved.textSecondary.nsColor }
    var glyphDisabled: NSColor { resolved.textDisabled.nsColor }
    var spaceName: NSColor { resolved.textSecondary.nsColor }
    var hover: NSColor { resolved.hoverFill.nsColor }
    var pressed: NSColor { resolved.pressedFill.nsColor }
    var selected: NSColor { resolved.selectedFill.nsColor }
    var selectedHover: NSColor { resolved.selectedFill.nsColor }
    var selectedShadow: AircShadow? { resolved.selectedHasShadow ? .rowSelected : nil }
    /// SB-36: rows of a multi-selection other than the shown tab (Arc's secondary selection).
    var multiSelected: NSColor { resolved.multiSelectFill.nsColor }
    var multiSelectedHover: NSColor { resolved.multiSelectHoverFill.nsColor }
    var separator: NSColor { resolved.separator.nsColor }
    var urlFieldFill: NSColor { resolved.fieldFill.nsColor }
    var tileFill: NSColor { resolved.tileFill.nsColor }
    var tileHover: NSColor { resolved.tileHoverFill.nsColor }
    var dropLine: NSColor { resolved.text.nsColor }
    var clearIdle: NSColor { resolved.textTertiary.nsColor }
    var clearHover: NSColor { resolved.text.nsColor }
    var placeholderIcon: NSColor { resolved.tileHoverFill.nsColor }
    var panelBackground: NSColor { resolved.surface.nsColor }
    var panelSelection: NSColor { resolved.surfaceSelected.nsColor }
    var panelText: NSColor { resolved.surfaceText.nsColor }
    var panelSecondary: NSColor { resolved.surfaceTextSecondary.nsColor }
    var panelBorder: NSColor { resolved.surfaceBorder.nsColor }
    var cardEmpty: NSColor { resolved.surface.nsColor }
    var cardShadow: AircShadow { isDark ? .cardDark : .card }
}

/// Arc measurements and app layout values AircDesign doesn't have yet (asked for in the design report).
enum DesignGaps {
    /// A label NSTextField draws its text 2 pt in from its frame; frames start this much left of the text's x
    /// (visual review #19: titles at 43, the Space name at 41).
    static let labelInset: CGFloat = 2
    /// Reload ends 6 pt from the sidebar edge (Arc ref §2.1).
    static let headerButtonEndInset: CGFloat = 6
    /// In full screen the toggle moves left: glyph at x 20–38.5 (Arc ref §1).
    static let toggleXFullscreen: CGFloat = 13
    /// Favorites start one URL-field height plus the side inset below the URL field's top.
    static var favoritesTop: CGFloat { AircMetrics.Sidebar.urlFieldHeight + AircMetrics.Sidebar.inset }
    /// Height the divider takes in the list; its line sits 7 pt down.
    static let dividerBlock: CGFloat = 14
    /// Width of the window-edge strip that reveals a hidden sidebar.
    static let revealEdge: CGFloat = 6
    /// Pointer dwell before the hidden sidebar slides in (Arc ref §2.10).
    static let revealDelay: Double = 0.100
    /// The Create Space form leaving (Arc ref §3.2: 150 ms).
    static let createFormOut: Double = 0.150
    /// Arc's icon picker popover (Arc ref §2.4).
    static let iconPicker = NSSize(width: 273, height: 273)
}

extension CALayer {
    /// Applies an AircDesign shadow (its first layer) and hairline.
    func apply(_ shadow: AircShadow) {
        if let s = shadow.layers.first {
            shadowColor = s.color.cgColor
            shadowOpacity = 1
            shadowRadius = s.radius
            shadowOffset = CGSize(width: s.x, height: -s.y)
        } else {
            shadowOpacity = 0
        }
    }
}

extension Spring {
    init(_ s: AircSpring) { self.init(response: s.response, dampingRatio: s.dampingRatio) }
}

extension AircCurve {
    /// The curve's progress at `t` (0...1 of its duration): solves the cubic Bézier for x, returns y.
    func value(at t: Double) -> Double {
        let t = min(max(t, 0), 1)
        let (x1, y1, x2, y2) = (Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y))
        func bez(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * a * u * (1 - u) * (1 - u) + 3 * b * u * u * (1 - u) + u * u * u
        }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<24 {
            u = (lo + hi) / 2
            if bez(u, x1, x2) < t { lo = u } else { hi = u }
        }
        return bez(u, y1, y2)
    }
}

enum Easing {
    static let sidebar: (Double) -> Double = { AircCurve.sidebarHide.value(at: $0) }
}

enum Symbols {
    /// SF Symbol images are made once per (name, size, weight): creating one costs ~0.1 ms, and the header and
    /// rows ask again on every Space switch.
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let hit = cache[key] { return hit }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        if let img { cache[key] = img }
        return img
    }
}

/// Airc's UI runs on the main thread. AircDesign is a Swift 6 module whose AppKit and SwiftUI API is `@MainActor`;
/// this bridges calls from the app's Swift 5 classes that AppKit always calls on the main thread.
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T { try MainActor.assumeIsolated(body) }

extension AircTextStyle {
    /// `nsFont` for code outside a main-actor context. All of Airc's UI runs on the main thread.
    var appFont: NSFont { MainActor.assumeIsolated { nsFont } }
}
