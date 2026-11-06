// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Airc's button style.
///
/// ```swift
/// Button("Continue") { … }.buttonStyle(.aircPrimary)
/// Button("Back") { … }.buttonStyle(.airc(.plain, size: .large))
/// ```
/// Primary is the theme accent with a 1 pt top highlight; secondary is a raised neutral; plain has no fill
/// until hovered. Press shrinks to 0.97; disabled is 40 % opacity.
public struct AircButtonStyle: ButtonStyle {
    public enum Kind: Hashable, Sendable { case primary, secondary, plain, destructive }

    public enum Size: Hashable, Sendable {
        /// 24 pt: inline actions, toasts.
        case small
        /// 30 pt: settings, dialogs.
        case regular
        /// 38 pt: onboarding, the Create Space card.
        case large

        public var height: CGFloat {
            switch self {
            case .small: 24
            case .regular: 30
            case .large: 38
            }
        }

        var padding: CGFloat {
            switch self {
            case .small: 10
            case .regular: 14
            case .large: 18
            }
        }

        var radius: CGFloat {
            switch self {
            case .small: AircRadius.small
            case .regular: AircRadius.control
            case .large: AircRadius.controlLarge
            }
        }

        var text: AircTextStyle {
            switch self {
            case .small: AircFont.callout.weight(.medium)
            case .regular: AircFont.body.weight(.medium)
            case .large: AircTextStyle(size: 14, weight: .semibold, lineHeight: 18, tracking: -0.1)
            }
        }
    }

    public var kind: Kind
    public var size: Size
    public var fullWidth: Bool

    public init(_ kind: Kind = .primary, size: Size = .regular, fullWidth: Bool = false) {
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        AircButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == AircButtonStyle {
    public static var aircPrimary: AircButtonStyle { AircButtonStyle(.primary) }
    public static var aircSecondary: AircButtonStyle { AircButtonStyle(.secondary) }
    public static var aircPlain: AircButtonStyle { AircButtonStyle(.plain) }
    public static func airc(_ kind: AircButtonStyle.Kind, size: AircButtonStyle.Size = .regular, fullWidth: Bool = false) -> AircButtonStyle {
        AircButtonStyle(kind, size: size, fullWidth: fullWidth)
    }
}

private struct AircButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AircButtonStyle.Kind
    let size: AircButtonStyle.Size
    let fullWidth: Bool

    @Environment(\.aircTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .aircFont(size.text)
            .lineLimit(1)
            .foregroundStyle(foreground.color)
            .padding(.horizontal, size.padding)
            .frame(height: size.height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(shape.fill(fill(pressed: pressed).color))
            .overlay {
                switch kind {
                case .primary, .destructive:
                    // T3-style top highlight: light catching the top edge.
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(colors: [.white.opacity(pressed ? 0.06 : 0.20), .white.opacity(0)], startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                case .secondary:
                    shape.inset(by: 0.25).stroke(theme.surfaceText.alpha(theme.isDark ? 0.12 : 0.14).color, lineWidth: 0.5)
                case .plain:
                    EmptyView()
                }
            }
            .aircShadow(kind == .plain || pressed || !isEnabled ? .none : shadow)
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .aircAnimation(AircCurve.press, value: pressed)
            .onHover { isHovered = $0 }
    }

    private var foreground: AircColor {
        switch kind {
        case .primary: theme.onAccent
        case .destructive: .white()
        case .secondary, .plain: theme.surfaceText
        }
    }

    private var shadow: AircShadow {
        switch kind {
        case .primary: AircShadow([.init(color: theme.accent.alpha(0.28), radius: 1, y: 1)])
        case .destructive: AircShadow([.init(color: AircColor.destructive.alpha(0.28), radius: 1, y: 1)])
        default: .control
        }
    }

    private func fill(pressed: Bool) -> AircColor {
        let hover = isHovered && isEnabled
        switch kind {
        case .primary, .destructive:
            let base = kind == .primary ? theme.accent : AircColor.destructive
            if pressed { return AircColor.black(0.10).over(base) }
            if hover { return AircColor.white(0.08).over(base) }
            return base
        case .secondary:
            let base = theme.isDark ? AircColor.white(0.09).over(theme.surface) : AircColor.white()
            if pressed { return theme.surfaceText.alpha(0.07).over(base) }
            if hover { return theme.surfaceText.alpha(0.035).over(base) }
            return base
        case .plain:
            if pressed { return theme.surfaceText.alpha(theme.isDark ? 0.10 : 0.07) }
            if hover { return theme.surfaceText.alpha(theme.isDark ? 0.07 : 0.045) }
            return .clear
        }
    }
}
