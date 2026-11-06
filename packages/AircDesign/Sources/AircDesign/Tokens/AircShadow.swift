// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import QuartzCore
import SwiftUI

/// An elevation: up to two drop shadows plus an optional hairline border. `radius` is the SwiftUI and
/// Core Animation radius; the CSS blur in the mockups is twice it. Shadows stay soft and close; depth
/// comes from tone first, shadow second.
public struct AircShadow: Hashable, Sendable {
    public struct Layer: Hashable, Sendable {
        public let color: AircColor
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat

        public init(color: AircColor, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
            self.color = color
            self.radius = radius
            self.x = x
            self.y = y
        }
    }

    public let layers: [Layer]
    /// A 0.5 pt border drawn inside the shape, or nil.
    public let hairline: AircColor?

    public init(_ layers: [Layer], hairline: AircColor? = nil) {
        self.layers = layers
        self.hairline = hairline
    }

    public static let none = AircShadow([])

    /// The selected sidebar row in light themes (Arc: white 0.85 + black 0.2 shadow).
    public static let rowSelected = AircShadow([Layer(color: .black(0.20), radius: 1, y: 0.5)])
    /// Buttons and switch knobs.
    public static let control = AircShadow([Layer(color: .black(0.10), radius: 0.5, y: 0.5)])
    /// The page card. Light: a hairline and a whisper of shadow. Dark: hairline only.
    public static let card = AircShadow([Layer(color: .black(0.10), radius: 1.5, y: 1)], hairline: .black(0.08))
    public static let cardDark = AircShadow([Layer(color: .black(0.35), radius: 1.5, y: 1)], hairline: .white(0.06))
    /// Menus and popovers.
    public static let popover = AircShadow(
        [Layer(color: .black(0.16), radius: 12, y: 8), Layer(color: .black(0.08), radius: 1.5, y: 1)],
        hairline: .black(0.08)
    )
    /// The command bar: the highest thing on screen.
    public static let commandBar = AircShadow(
        [Layer(color: .black(0.26), radius: 30, y: 20), Layer(color: .black(0.10), radius: 3, y: 2)],
        hairline: .black(0.10)
    )
    /// Toasts.
    public static let toast = AircShadow(
        [Layer(color: .black(0.18), radius: 8, y: 6), Layer(color: .black(0.08), radius: 1, y: 1)],
        hairline: .black(0.08)
    )
    /// Onboarding and settings cards floating on a theme.
    public static let panel = AircShadow(
        [Layer(color: .black(0.18), radius: 24, y: 20), Layer(color: .black(0.06), radius: 2, y: 1)],
        hairline: .black(0.06)
    )
}

extension View {
    /// Applies the shadow layers of an elevation (the hairline is the caller's, since it follows the shape).
    /// The view is flattened first, so the shadow follows its outline, not every child's.
    ///
    /// The structure is fixed: always two `.shadow` modifiers, with clear zero-radius ones for missing layers, and
    /// no `AnyView`. A button that drops its shadow while pressed must keep its view identity, or SwiftUI
    /// resets the press and the click never fires (the "Create Space does nothing" bug).
    public func aircShadow(_ shadow: AircShadow) -> some View {
        let key = shadow.layers.first
        let ambient = shadow.layers.dropFirst().first
        return compositingGroup()
            .shadow(color: key?.color.color ?? .clear, radius: key?.radius ?? 0, x: key?.x ?? 0, y: key?.y ?? 0)
            .shadow(color: ambient?.color.color ?? .clear, radius: ambient?.radius ?? 0,
                    x: ambient?.x ?? 0, y: ambient?.y ?? 0)
    }
}

extension CALayer {
    /// Applies the first (key) shadow layer of an elevation. Core Animation draws one shadow per layer; nest a
    /// second layer for the ambient shadow if you need it.
    public func applyAircShadow(_ shadow: AircShadow) {
        guard let s = shadow.layers.first else {
            shadowOpacity = 0
            return
        }
        shadowColor = s.color.alpha(1).cgColor
        shadowOpacity = Float(s.color.alpha)
        shadowRadius = s.radius
        // AppKit layers are not flipped: positive y moves the shadow down only in a flipped geometry.
        shadowOffset = CGSize(width: s.x, height: isGeometryFlipped ? s.y : -s.y)
    }
}
