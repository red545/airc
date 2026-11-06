// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
import QuartzCore

// The dragged row (docs/design.md §5 "Nothing reflows under a drag", §7 "Loading rows and title fades";
// docs/qa/visual-review.md #7). The row looks like itself, lifted: an opaque plate (rows beneath never show through),
// the favicon at x 17, the title at x 43 fading over its last 24 pt, and a soft lift shadow. Built from data, not from a
// `cacheDisplay` of the row, so nothing is drawn twice and nothing is clipped.

extension AircShadow {
    /// A row or tile held under the pointer: closer and softer than a popover.
    public static let dragLift = AircShadow([Layer(color: .black(0.18), radius: 6, y: 4), Layer(color: .black(0.10), radius: 1, y: 0.5)])
}

/// A drag ghost for a sidebar row or a Favorites tile. Add it to the sidebar's layer (above the rows), set its
/// `position` from the pointer minus the grab offset each frame, and remove it on drop.
///
/// ```swift
/// let ghost = AircDragGhostLayer(kind: .row, width: sidebar.bounds.width, theme: r)
/// ghost.configure(title: tab.title, favicon: favicon.cgImage)
/// sidebar.layer?.addSublayer(ghost)
/// ```
public final class AircDragGhostLayer: CALayer {
    public enum Kind: Sendable { case row, tile }

    public private(set) var kind: Kind
    public private(set) var theme: ResolvedTheme
    private let plate = CALayer()
    private let ambient = CALayer()
    private let favicon = CALayer()
    private let title = CATextLayer()
    private let fade = CAGradientLayer()
    private var titleText = ""

    /// - Parameters:
    ///   - width: the row's full width (the sidebar's); for a tile, the tile's width.
    ///   - scale: the window's backing scale.
    public init(kind: Kind, width: CGFloat, theme: ResolvedTheme, scale: CGFloat = 2) {
        self.kind = kind
        self.theme = theme
        super.init()
        let h = kind == .row ? AircMetrics.Row.pitch : AircMetrics.Favorites.tileHeight
        bounds = CGRect(x: 0, y: 0, width: width, height: h)
        contentsScale = scale
        zPosition = 200
        actions = Self.still
        for l in [ambient, plate, favicon, title, fade] as [CALayer] {
            l.actions = Self.still
            l.contentsScale = scale
        }
        addSublayer(ambient)
        addSublayer(plate)
        plate.addSublayer(favicon)
        plate.addSublayer(title)
        title.truncationMode = .none
        title.isWrapped = false
        title.alignmentMode = .left
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        favicon.contentsGravity = .resizeAspect
        favicon.masksToBounds = true
        favicon.cornerRadius = 3
        setTheme(theme)
    }

    public override init(layer: Any) {
        let other = layer as? AircDragGhostLayer
        kind = other?.kind ?? .row
        theme = other?.theme ?? SpaceTheme.default.resolved(systemIsDark: false)
        super.init(layer: layer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated(unsafe) private static let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                                      "backgroundColor": NSNull(), "string": NSNull(), "opacity": NSNull()]

    /// The plate colour: the selected fill composited over the window colour, so it is opaque.
    public static func plateColor(for theme: ResolvedTheme) -> AircColor {
        theme.selectedFill.over(theme.background).alpha(1)
    }

    public func setTheme(_ theme: ResolvedTheme) {
        self.theme = theme
        plate.backgroundColor = Self.plateColor(for: theme).cgColor
        ambient.backgroundColor = Self.plateColor(for: theme).cgColor
        let lift = AircShadow.dragLift
        for (layer, s) in [(plate, lift.layers[0]), (ambient, lift.layers[1])] {
            layer.shadowColor = s.color.alpha(1).cgColor
            layer.shadowOpacity = Float(s.color.alpha * (theme.isDark ? 1.6 : 1))
            layer.shadowRadius = s.radius
        }
        if !titleText.isEmpty { configure(title: titleText, favicon: favicon.contents.map { $0 as! CGImage }) }
        setNeedsLayout()
    }

    /// Sets the row's content. `favicon` nil draws the theme's placeholder square.
    public func configure(title text: String, favicon image: CGImage?) {
        titleText = text
        favicon.contents = image
        favicon.backgroundColor = image == nil ? theme.tileHoverFill.over(Self.plateColor(for: theme)).cgColor : nil
        title.string = NSAttributedString(string: text, attributes: [.font: AircFont.row.nsFont, .foregroundColor: theme.text.nsColor])
        title.isHidden = kind == .tile
        setNeedsLayout()
        layoutIfNeeded()
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        let r = AircMetrics.Row.self
        switch kind {
        case .row:
            let inset = AircMetrics.Sidebar.inset
            plate.frame = CGRect(x: inset, y: (bounds.height - r.plateHeight) / 2, width: bounds.width - 2 * inset, height: r.plateHeight)
            plate.cornerRadius = r.plateRadius
            favicon.frame = CGRect(x: r.faviconX - inset, y: (r.plateHeight - r.favicon) / 2, width: r.favicon, height: r.favicon)
            let tx = r.titleX - inset
            let width = max(0, plate.bounds.width - tx - (r.titleTrailing - inset))
            let lineH = AircFont.row.lineHeight
            title.frame = CGRect(x: tx, y: (r.plateHeight - lineH - 2) / 2, width: width, height: lineH + 2)
            let natural = (title.string as? NSAttributedString)?.size().width ?? 0
            if natural > width, width > 0 {
                fade.frame = title.bounds
                fade.locations = [0, NSNumber(value: Double(max(0, (width - AircMetrics.Row.titleFade) / width))), 1]
                title.mask = fade
            } else {
                title.mask = nil
            }
        case .tile:
            let f = AircMetrics.Favorites.self
            plate.frame = bounds
            plate.cornerRadius = f.radius
            favicon.frame = CGRect(x: (bounds.width - f.favicon) / 2, y: (bounds.height - f.favicon) / 2, width: f.favicon, height: f.favicon)
        }
        plate.cornerCurve = .continuous
        ambient.frame = plate.frame
        ambient.cornerRadius = plate.cornerRadius
        ambient.cornerCurve = .continuous
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: plate.cornerRadius, cornerHeight: plate.cornerRadius, transform: nil)
        ambient.shadowPath = plate.shadowPath
        // The layout is symmetric top to bottom, so it reads the same in flipped and unflipped sidebars; only the shadow
        // needs to know which way is down.
        let down: CGFloat = contentsAreFlipped() ? 1 : -1
        let lift = AircShadow.dragLift
        plate.shadowOffset = CGSize(width: lift.layers[0].x, height: down * lift.layers[0].y)
        ambient.shadowOffset = CGSize(width: lift.layers[1].x, height: down * lift.layers[1].y)
    }
}
