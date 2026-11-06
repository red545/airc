// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore
import SwiftUI

// The page card's edge (docs/design.md §4 "Shadows", `card` / `cardDark`; docs/qa/visual-review.md #15). The web page
// is clipped to 6 pt circular corners, so the shadow can't live on the clipping layer: it goes on a container behind
// the clip, and the 0.5 pt hairline on an overlay above the page.

extension ResolvedTheme {
    /// The page card's elevation: `card` in light themes, `cardDark` in dark ones.
    public var pageCardShadow: AircShadow { isDark ? .cardDark : .card }
}

/// The page card: a container that draws the `card` / `cardDark` shadow and hairline around a clipped content view.
/// Put the engine's view in `contentView`; it is clipped to `AircMetrics.Window.cardRadius` (circular, as Arc draws it).
/// With no content it shows `surface` (the empty-Space colour, never black).
@MainActor
public final class AircPageCardView: NSView {
    public var theme: ResolvedTheme { didSet { if theme != oldValue { restyle() } } }
    /// The page. Replaces the previous one.
    public var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let v = contentView {
                v.frame = clip.bounds
                v.autoresizingMask = [.width, .height]
                clip.addSubview(v)
            }
        }
    }
    public var cornerRadius: CGFloat = AircMetrics.Window.cardRadius { didSet { restyle() } }

    private let shadowLayer = CALayer()
    private let clip = NSView()
    private let hairline = AircHairlineView()

    public init(theme: ResolvedTheme, frame: NSRect = .zero) {
        self.theme = theme
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.actions = ["shadowPath": NSNull(), "bounds": NSNull(), "position": NSNull()]
        shadowLayer.zPosition = -1
        layer?.addSublayer(shadowLayer)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .circular
        clip.autoresizingMask = [.width, .height]
        clip.frame = bounds
        addSubview(clip)
        hairline.autoresizingMask = [.width, .height]
        hairline.frame = bounds
        addSubview(hairline)
        restyle()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func restyle() {
        let s = theme.pageCardShadow
        let key = s.layers.first
        shadowLayer.shadowColor = (key?.color.alpha(1) ?? .black()).cgColor
        shadowLayer.shadowOpacity = Float(key?.color.alpha ?? 0)
        shadowLayer.shadowRadius = key?.radius ?? 0
        shadowLayer.shadowOffset = CGSize(width: key?.x ?? 0, height: -(key?.y ?? 0))
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.backgroundColor = theme.surface.cgColor
        hairline.color = s.hairline ?? .clear
        hairline.radius = cornerRadius
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }
}

/// A 0.5 pt inside border that never takes clicks: the layer's own border, so a size change (every frame of a window
/// resize, ⌘S or the Library) moves it without drawing anything. It used to stroke a path in `draw(_:)`, which
/// re-rasterised a card-sized bitmap on every size change (§2.12).
final class AircHairlineView: NSView {
    var color: AircColor = .clear { didSet { if color != oldValue { apply() } } }
    var radius: CGFloat = 6 { didSet { if radius != oldValue { apply() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.borderWidth = 0.5
        layer.borderColor = color.cgColor
        layer.cornerRadius = radius
        layer.cornerCurve = .circular
        CATransaction.commit()
    }
}

extension View {
    /// The page card in SwiftUI (mockup sheets, the onboarding preview): `surface` under the content, clipped to
    /// 6 pt circular corners, with the theme's `card` / `cardDark` shadow and hairline.
    public func aircPageCard(_ theme: ResolvedTheme, radius: CGFloat = AircMetrics.Window.cardRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        let s = theme.pageCardShadow
        return background(theme.surface.color)
            .clipShape(shape)
            .overlay(shape.inset(by: 0.25).stroke((s.hairline ?? .clear).color, lineWidth: 0.5))
            .background(shape.fill(theme.surface.color).aircShadow(s))
    }
}
