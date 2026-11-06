// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

private struct AircThemeKey: EnvironmentKey {
    static let defaultValue = SpaceTheme.default.resolved(systemIsDark: false)
}

extension EnvironmentValues {
    /// The resolved theme every Airc component draws with. Defaults to the light default theme.
    public var aircTheme: ResolvedTheme {
        get { self[AircThemeKey.self] }
        set { self[AircThemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the theme for Airc components below, and the matching SwiftUI colour scheme.
    public func aircTheme(_ theme: ResolvedTheme) -> some View {
        environment(\.aircTheme, theme)
            .environment(\.colorScheme, theme.colorScheme)
            .tint(theme.accent.color)
    }

    /// Sets the theme and, with `followsWindowActiveState`, dims its ink while the window isn't key or main
    /// (Arc dims sidebar text and glyphs slightly; `ResolvedTheme.forWindow(isActive:)`).
    public func aircTheme(_ theme: ResolvedTheme, followsWindowActiveState: Bool) -> some View {
        modifier(AircActiveThemeModifier(theme: theme, follows: followsWindowActiveState))
    }
}

private struct AircActiveThemeModifier: ViewModifier {
    let theme: ResolvedTheme
    let follows: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.aircTheme(follows && activeState == .inactive ? theme.forWindow(isActive: false) : theme)
    }
}

extension AircColor {
    /// Destructive buttons: a deeper red that carries white text at ≥ 4.5:1.
    public static let destructive = AircColor(0xC9363B)
}

/// The themed window background for SwiftUI: Arc's gradient plus grain. Same pixels as `SpaceBackgroundView`.
public struct SpaceBackground: View {
    private let theme: ResolvedTheme
    private let isWindowActive: Bool

    public init(_ theme: ResolvedTheme, isWindowActive: Bool = true) {
        self.theme = theme
        self.isWindowActive = isWindowActive
    }

    /// A translucent background (`AircTranslucency`): the desktop shows through the theme faintly, as in
    /// Arc. It goes opaque while the window is inactive (or `isWindowActive` is false) and under Reduce
    /// Transparency, and makes its window non-opaque. `.off` draws exactly the opaque background.
    public init(_ theme: ResolvedTheme, isWindowActive: Bool? = nil, translucency: AircTranslucency) {
        self.theme = theme
        self.isWindowActive = isWindowActive ?? true
        self.followsWindow = isWindowActive == nil
        self.translucency = translucency
    }

    private var followsWindow = false
    private var translucency: AircTranslucency = .off

    public var body: some View {
        if translucency == .off {
            opaque
        } else {
            TranslucentSpaceBackground(theme: theme, isWindowActive: isWindowActive, followsWindow: followsWindow, translucency: translucency)
        }
    }

    private var opaque: some View {
        GeometryReader { geo in
            ZStack {
                Image(decorative: theme.backgroundImage(for: geo.size), scale: 1)
                    .resizable()
                    .interpolation(.high)
                AircGrainOverlay(opacity: theme.grainOpacity(isWindowActive: isWindowActive))
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct TranslucentSpaceBackground: View {
    let theme: ResolvedTheme
    let isWindowActive: Bool
    let followsWindow: Bool
    let translucency: AircTranslucency
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let active = isWindowActive && !(followsWindow && activeState == .inactive)
        let underlay = theme.underlayOpacity(for: translucency, isWindowActive: active, reduceTransparency: reduceTransparency)
        GeometryReader { geo in
            ZStack {
                AircMaterialBackground(isDark: theme.isDark)
                Rectangle().fill(theme.underlay.color).opacity(underlay)
                Image(decorative: theme.colorLayerImage(for: geo.size), scale: 1)
                    .resizable()
                    .interpolation(.high)
                AircGrainOverlay(opacity: theme.grainOpacity(isWindowActive: active))
            }
            .animation(.easeOut(duration: 0.2), value: underlay)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The behind-window blur (`AircMaterialView`) for SwiftUI. It makes its window non-opaque so the blur shows.
public struct AircMaterialBackground: NSViewRepresentable {
    private let isDark: Bool

    public init(isDark: Bool) {
        self.isDark = isDark
    }

    public func makeNSView(context: Context) -> AircMaterialView {
        let view = WindowClearingMaterialView()
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        return view
    }

    public func updateNSView(_ view: AircMaterialView, context: Context) {
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

private final class WindowClearingMaterialView: AircMaterialView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}

/// Tiled grain at an opacity.
public struct AircGrainOverlay: View {
    private let opacity: Double

    public init(opacity: Double) {
        self.opacity = opacity
    }

    public var body: some View {
        if opacity > 0.001 {
            Image(decorative: AircGrain.tile, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .allowsHitTesting(false)
        }
    }
}
