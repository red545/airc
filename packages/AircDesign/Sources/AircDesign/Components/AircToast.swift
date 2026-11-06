// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A toast: 36 pt tall, 12 pt corners, on the theme's surface. One line of text, an optional glyph in the
/// accent, an optional action ("Undo").
///
/// Show it at the top centre of the page card, 14 pt down, with `.transition(.aircToast)`:
/// it pops in from 0.7 scale on the `pop` spring and leaves in 70 ms.
public struct AircToast: View {
    private let message: String
    private let systemImage: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    @Environment(\.aircTheme) private var theme

    public init(_ message: String, systemImage: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircRadius.toast, style: .continuous)
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
            }
            Text(message)
                .aircFont(AircFont.body.weight(.medium))
                .foregroundStyle(theme.surfaceText.color)
                .lineLimit(1)
            if let actionTitle, let action {
                Rectangle()
                    .fill(theme.surfaceBorder.color)
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .aircFont(AircFont.body.weight(.semibold))
                    .foregroundStyle(theme.accent.color)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: AircMetrics.Toast.height)
        .background(shape.fill(theme.surface.color))
        .overlay(shape.inset(by: 0.25).stroke(theme.surfaceBorder.color, lineWidth: 0.5))
        .aircShadow(.toast)
    }
}

extension AnyTransition {
    /// Toast in: from 0.7 scale on the `pop` spring (peaks ≈ 1.04), fading over 100 ms. Out: 70 ms ease-in.
    /// Under Reduce Motion it fades in and out in 150 ms.
    @MainActor public static var aircToast: AnyTransition {
        .airc(.asymmetric(
            insertion: .scale(scale: 0.7).combined(with: .opacity).animation(AircSpring.pop.animation),
            removal: .opacity.combined(with: .scale(scale: 0.96)).animation(AircCurve.toastOut.animation)
        ))
    }
}
