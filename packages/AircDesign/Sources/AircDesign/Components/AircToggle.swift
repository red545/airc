// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A switch: 32 × 20 track, 16 pt knob, accent when on, knob follows on the `toggle` spring.
public struct AircSwitch: View {
    @Binding private var isOn: Bool
    @Environment(\.aircTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    public init(isOn: Binding<Bool>) {
        self._isOn = isOn
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill((isOn ? theme.accent : theme.surfaceText.alpha(theme.isDark ? 0.18 : 0.14)).color)
                .overlay(Capsule().inset(by: 0.25).stroke(AircColor.black(isOn ? 0.06 : 0.04).color, lineWidth: 0.5))
            Circle()
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .shadow(color: .black.opacity(0.06), radius: 0.25, y: 0)
                .padding(2)
        }
        .frame(width: 32, height: 20)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture { withAircAnimation(AircSpring.toggle) { isOn.toggle() } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAction { isOn.toggle() }
    }
}

/// A settings row: title, optional subtitle and icon, a switch at the trailing edge. 44 pt minimum height;
/// the whole row toggles.
public struct AircToggleRow: View {
    private let title: String
    private let subtitle: String?
    private let icon: String?
    @Binding private var isOn: Bool
    @Environment(\.aircTheme) private var theme

    public init(_ title: String, subtitle: String? = nil, icon: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self._isOn = isOn
    }

    public var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.surfaceTextSecondary.color)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.surfaceText.color)
                if let subtitle {
                    Text(subtitle)
                        .aircFont(AircFont.callout)
                        .foregroundStyle(theme.surfaceTextSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            AircSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { withAircAnimation(AircSpring.toggle) { isOn.toggle() } }
    }
}

/// A settings group: rows on a surface card with inset hairlines between them.
///
/// ```swift
/// AircGroup {
///     AircToggleRow("Archive tabs automatically", isOn: $archive)
///     AircToggleRow("Show Space header", isOn: $header)
/// }
/// ```
public struct AircGroup<Content: View>: View {
    private let content: Content
    @Environment(\.aircTheme) private var theme

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.control + 2, style: .continuous)
        VStack(spacing: 0) {
            if #available(macOS 15.0, *) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                        if index > 0 {
                            Rectangle()
                                .fill(theme.surfaceBorder.color)
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                        }
                        subview
                    }
                }
            } else {
                content  // macOS 14: no automatic hairlines between rows.
            }
        }
        .background(shape.fill((theme.isDark ? AircColor.white(0.035).over(theme.surface) : AircColor.white()).color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
    }
}
