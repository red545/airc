// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A single-line text field: 32 pt tall, 8 pt corners, optional label above, icon inside, message below.
///
/// ```swift
/// AircTextField("Space name", text: $name, placeholder: "Work", icon: "square.grid.2x2")
/// ```
public struct AircTextField: View {
    private let label: String?
    @Binding private var text: String
    private let placeholder: String
    private let icon: String?
    private let message: String?
    private let isError: Bool

    @Environment(\.aircTheme) private var theme
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    public init(_ label: String? = nil, text: Binding<String>, placeholder: String = "", icon: String? = nil, message: String? = nil, isError: Bool = false) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.icon = icon
        self.message = message
        self.isError = isError
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .aircFont(AircFont.callout.weight(.medium))
                    .foregroundStyle(theme.surfaceTextSecondary.color)
            }
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle((isFocused ? theme.accent : theme.surfaceTextTertiary).color)
                        .frame(width: 16)
                }
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.surfaceTextTertiary.color))
                    .textFieldStyle(.plain)
                    .aircFont(AircFont.body)
                    .foregroundStyle(theme.surfaceText.color)
                    .focused($isFocused)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(AircFieldBackground(isFocused: isFocused, isHovered: isHovered, isError: isError))
            .onHover { isHovered = $0 }
            .aircAnimation(AircCurve.previewIn, value: isFocused)
            if let message {
                Text(message)
                    .aircFont(AircFont.callout)
                    .foregroundStyle((isError ? AircColor.destructive : theme.surfaceTextTertiary).color)
            }
        }
    }
}

/// The field chrome on its own, for custom fields (search, URL, key recorder): fill, hairline border,
/// and the accent focus ring (1 pt border + 3 pt soft ring).
public struct AircFieldBackground: View {
    private let isFocused: Bool
    private let isHovered: Bool
    private let isError: Bool
    private let radius: CGFloat

    @Environment(\.aircTheme) private var theme

    public init(isFocused: Bool, isHovered: Bool = false, isError: Bool = false, radius: CGFloat = AircRadius.control) {
        self.isFocused = isFocused
        self.isHovered = isHovered
        self.isError = isError
        self.radius = radius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ring = isError ? AircColor.destructive : theme.accent
        let border: AircColor = isError || isFocused
            ? ring
            : theme.surfaceText.alpha(isHovered ? (theme.isDark ? 0.20 : 0.20) : (theme.isDark ? 0.13 : 0.13))
        shape
            .fill((theme.isDark ? AircColor.white(0.05) : AircColor.white()).color)
            .overlay(shape.inset(by: 0.5).stroke(border.color, lineWidth: isFocused ? 1 : 1))
            .background(
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .fill(ring.alpha(isFocused || isError ? (theme.isDark ? 0.30 : 0.18) : 0).color)
                    .padding(-3)
            )
    }
}
