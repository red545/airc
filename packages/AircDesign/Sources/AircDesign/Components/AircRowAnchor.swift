// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import SwiftUI

private struct AircRowHighlightKey: EnvironmentKey {
    static let defaultValue: Set<String>? = nil
}

public extension EnvironmentValues {
    /// Settings search: the anchors (`AircRowAnchor.anchor(_:)`) of the rows to highlight now. A container that sets it,
    /// even to an empty set, also gives its rows scroll ids; nil (the default) leaves rows as they are.
    var aircRowHighlight: Set<String>? {
        get { self[AircRowHighlightKey.self] }
        set { self[AircRowHighlightKey.self] = newValue }
    }
}

/// A row a search can find: inside a container that sets `aircRowHighlight`, the row gets the scroll id
/// `anchor(title)` and a soft accent highlight while its anchor is in the set (as System Settings marks a found row).
public struct AircRowAnchor: ViewModifier {
    private let anchor: String
    @Environment(\.aircRowHighlight) private var highlight
    @Environment(\.aircTheme) private var theme

    public init(title: String) { anchor = Self.anchor(title) }

    public static func anchor(_ title: String) -> String { "row:" + title }

    public func body(content: Content) -> some View {
        if let highlight {
            let on = highlight.contains(anchor)
            content
                .background(
                    RoundedRectangle(cornerRadius: AircRadius.control, style: .continuous)
                        .fill(theme.accent.alpha(theme.isDark ? 0.24 : 0.16).color)
                        .padding(3)
                        .opacity(on ? 1 : 0)
                        .animation(.easeOut(duration: on ? 0.15 : 0.6), value: on)
                        .allowsHitTesting(false)
                )
                .id(anchor)
        } else {
            content
        }
    }
}

public extension View {
    /// See `AircRowAnchor`.
    func aircRowAnchor(_ title: String) -> some View { modifier(AircRowAnchor(title: title)) }
}
