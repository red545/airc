// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// A Space's look, as the user picks it: up to three colours, intensity, grain and appearance.
///
/// This is the stored model (it maps 1:1 to Arc's `windowTheme`, so imported themes look identical).
/// Call `resolved(systemIsDark:)` to get every colour the UI needs.
///
/// Rendering follows Arc 1.167+: colours 1 and 2 mix in OKLab along a 45° diagonal, reaching colour 2 at
/// 75 %; colour 3 fades in from top to bottom. The colour layer is drawn at `0.2 + 0.55 × intensity` over a
/// white (light) or black (dark) underlay, with grain on top.
public struct SpaceTheme: Hashable, Sendable, Codable {
    public enum Appearance: String, Hashable, Sendable, Codable, CaseIterable {
        /// Follows the system, except very light colours stay light and very dark colours stay dark.
        case auto, light, dark
    }

    /// Arc's four overlay textures and their strengths.
    public enum Texture: String, Hashable, Sendable, Codable, CaseIterable {
        case grain, sand, denim, tweed

        public var strength: Double {
            switch self {
            case .grain: 0.8
            case .sand: 0.15
            case .denim: 0.6
            case .tweed: 0.4
            }
        }
    }

    public static let maxColors = 3
    /// Arc's default intensity.
    public static let defaultIntensity = 0.81

    /// 0 to 3 colours. Empty means the default (warm neutral) theme. Extra colours are ignored.
    public var colors: [AircColor]
    /// 0...1. Lower washes the colour out toward the underlay.
    public var intensity: Double
    /// 0...1. Arc's `noiseFactor`.
    public var grain: Double
    public var texture: Texture
    public var appearance: Appearance

    public init(
        colors: [AircColor] = [],
        intensity: Double = SpaceTheme.defaultIntensity,
        grain: Double = 0,
        texture: Texture = .grain,
        appearance: Appearance = .auto
    ) {
        self.colors = colors
        self.intensity = intensity
        self.grain = grain
        self.texture = texture
        self.appearance = appearance
    }

    /// The default theme: no colours, warm neutral, follows the system appearance.
    public static let `default` = SpaceTheme()

    /// The nine swatches in the theme picker (Arc's own).
    public static let swatches: [AircColor] = [
        AircColor(0xF0EAE5), AircColor(0xE59EBA), AircColor(0x9E749B), AircColor(0xE1676F), AircColor(0xEF8C63),
        AircColor(0xF2D46C), AircColor(0x73E49B), AircColor(0x7EB6D5), AircColor(0x656786),
    ]
}

// MARK: - Presets

extension SpaceTheme {
    public struct Preset: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let theme: SpaceTheme
    }

    /// Twelve curated themes: six light, six dark. Shown in onboarding and the theme picker.
    public static let presets: [Preset] = [
        Preset(id: "paper", name: "Paper", theme: SpaceTheme()),
        Preset(id: "mint", name: "Mint", theme: SpaceTheme(colors: [AircColor(0x53CA9F)], appearance: .light)),
        Preset(id: "sky", name: "Sky", theme: SpaceTheme(colors: [AircColor(0x86CDF5), AircColor(0x6D8CF0)], grain: 0.25, appearance: .light)),
        Preset(id: "lilac", name: "Lilac", theme: SpaceTheme(colors: [AircColor(0xB9A2F2), AircColor(0xEFA3C4)], grain: 0.25, appearance: .light)),
        Preset(id: "peach", name: "Peach", theme: SpaceTheme(colors: [AircColor(0xF7B184), AircColor(0xF08A9A)], grain: 0.25, appearance: .light)),
        Preset(id: "lemon", name: "Lemon", theme: SpaceTheme(colors: [AircColor(0xF4DA6E), AircColor(0x9BDB8A)], grain: 0.25, appearance: .light)),
        Preset(id: "ocean", name: "Ocean", theme: SpaceTheme(colors: [AircColor(0x2F6AF0), AircColor(0x13B5B0)], grain: 0.35, appearance: .dark)),
        Preset(id: "grape", name: "Grape", theme: SpaceTheme(colors: [AircColor(0x7A4CF0), AircColor(0xE0559F), AircColor(0x3A4FD8)], grain: 0.35, appearance: .dark)),
        Preset(id: "forest", name: "Forest", theme: SpaceTheme(colors: [AircColor(0x2A8A5C), AircColor(0x7A9A2E)], grain: 0.35, appearance: .dark)),
        Preset(id: "ember", name: "Ember", theme: SpaceTheme(colors: [AircColor(0xF0642A), AircColor(0xB0254A)], grain: 0.35, appearance: .dark)),
        Preset(id: "slate", name: "Slate", theme: SpaceTheme(colors: [AircColor(0x656786)], grain: 0.2, appearance: .dark)),
        Preset(id: "midnight", name: "Midnight", theme: SpaceTheme(colors: [AircColor(0x3B4470), AircColor(0x1B1E2E)], grain: 0.3, appearance: .dark)),
    ]

    /// Looks up a preset theme by id (`"mint"`), or nil.
    public static func preset(_ id: String) -> SpaceTheme? {
        presets.first { $0.id == id }?.theme
    }
}

/// AircDesign's `SpaceTheme` under a name that doesn't clash with AircKit's stored `SpaceTheme` in code that
/// imports both (Airc.app). Same type; prefer it there over `AircDesign.SpaceTheme`.
public typealias AircSpaceTheme = SpaceTheme
