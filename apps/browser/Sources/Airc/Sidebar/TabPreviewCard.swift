// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit

/// The tab preview card (TabPreview.swift): the page's picture, its favicon and title, the host, and the quick actions
/// (pin, Favorites, split, Peek). Drawn with layers on the Space's `surface` at `popover` elevation, like the folder
/// preview; one per window, made on first use and reused. The view is larger than the card by the shadow's reach and
/// hit-tests only the card.
final class TabPreviewCardView: NSView {
    enum Button: CaseIterable { case pin, favorite, split, peek }

    struct Content {
        var title: String
        var host: String
        var favicon: NSImage?
        var faviconURL: String?
        var pageURL: String
        var isPinned: Bool
        var isFavorite: Bool
        var canSplit: Bool
        var canPeek: Bool
    }

    static let width: CGFloat = 280
    static let inset: CGFloat = 6
    static let thumbnailHeight: CGFloat = 168
    static let thumbnailRadius: CGFloat = AircRadius.popover - inset
    static let margin: CGFloat = 24
    static let buttonSize: CGFloat = 28
    static var height: CGFloat { inset + thumbnailHeight + 10 + 33 + 8 + buttonSize + 8 }

    var onButton: ((Button) -> Void)?
    var onHover: ((Bool) -> Void)?

    private let ambient = CALayer()
    private let plate = CALayer()
    private let thumbnail = CALayer()
    private let thumbnailEdge = CALayer()
    private let placeholderIcon = FaviconView()
    private let favicon = FaviconView()
    private let title = AircFadingLabel(style: AircFont.row)
    private let host = AircFadingLabel(style: AircFont.caption)
    private var buttons: [Button: GlyphButton] = [:]
    private(set) var content: Content?
    private var palette: Palette?
    /// What the picture area shows now.
    private(set) var thumbnailImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [ambient, plate, thumbnail, thumbnailEdge] {
            l.actions = LayerImage.noActions.merging(["backgroundColor": NSNull(), "borderColor": NSNull(), "shadowPath": NSNull()]) { a, _ in a }
            l.cornerCurve = .continuous
        }
        plate.cornerRadius = AircRadius.popover
        ambient.cornerRadius = AircRadius.popover
        thumbnail.cornerRadius = Self.thumbnailRadius
        thumbnail.masksToBounds = true
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnailEdge.cornerRadius = Self.thumbnailRadius
        thumbnailEdge.borderWidth = 0.5
        layer?.addSublayer(ambient)
        layer?.addSublayer(plate)
        layer?.addSublayer(thumbnail)
        layer?.addSublayer(thumbnailEdge)
        title.font = AircFont.row.weight(.medium).appFont
        title.lineBreakMode = .byClipping
        host.font = AircFont.caption.appFont
        host.lineBreakMode = .byClipping
        for v in [placeholderIcon, favicon, title, host] as [NSView] { addSubview(v) }
        for b in Button.allCases {
            let g = GlyphButton(symbol: "pin", size: 13)
            g.plateRadius = AircRadius.control
            g.action = { [weak self] in self?.onButton?(b) }
            addSubview(g)
            buttons[b] = g
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card inside the view (the rest is room for the shadow).
    var cardRect: NSRect { NSRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, cardRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    /// The card takes its presses (between the buttons too), so nothing under it gets them.
    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    func apply(_ c: Content, palette p: Palette) {
        content = c
        if palette != p {
            palette = p
            let t = p.resolved
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            plate.backgroundColor = t.surface.nsColor.cgColor
            plate.borderColor = t.surfaceBorder.nsColor.cgColor
            plate.borderWidth = 0.5
            // `popover` elevation: the key shadow on the plate, the ambient one on a layer under it.
            plate.applyAircShadow(.popover)
            if let a = AircShadow.popover.layers.dropFirst().first {
                ambient.backgroundColor = t.surface.nsColor.cgColor
                ambient.shadowColor = a.color.alpha(1).cgColor
                ambient.shadowOpacity = Float(a.color.alpha)
                ambient.shadowRadius = a.radius
                ambient.shadowOffset = CGSize(width: a.x, height: -a.y)
            }
            thumbnail.backgroundColor = t.surfaceHover.nsColor.cgColor
            thumbnailEdge.borderColor = t.surfaceBorder.nsColor.cgColor
            CATransaction.commit()
            title.textColor = t.surfaceText.nsColor
            host.textColor = t.surfaceTextTertiary.nsColor
            for g in buttons.values {
                g.hoverFill = t.surfaceHover.nsColor.withAlphaComponent(min(1, t.surfaceHover.alpha * 2.2))
            }
        }
        let text = TextLimits.clip(c.title.isEmpty ? c.host : c.title)
        if title.stringValue != text { title.stringValue = text }
        let hostText = TextLimits.clip(c.host)
        if host.stringValue != hostText { host.stringValue = hostText }
        favicon.set(image: c.favicon, url: c.faviconURL, fallbackPage: c.pageURL, palette: p)
        placeholderIcon.set(image: c.favicon, url: c.faviconURL, fallbackPage: c.pageURL, palette: p)
        style(.pin, symbol: c.isPinned ? "pin.fill" : "pin", on: c.isPinned, tip: c.isPinned ? "Unpin" : (c.isFavorite ? "Pin to This Space" : "Pin Tab"))
        style(.favorite, symbol: c.isFavorite ? "star.fill" : "star", on: c.isFavorite,
              tip: c.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        style(.split, symbol: "rectangle.split.2x1", on: false, tip: "Open in Split View", enabled: c.canSplit)
        style(.peek, symbol: "eye", on: false, tip: "Peek", enabled: c.canPeek)
        needsLayout = true
    }

    private func style(_ b: Button, symbol: String, on: Bool, tip: String, enabled: Bool = true) {
        guard let g = buttons[b], let t = palette?.resolved else { return }
        g.symbol = symbol
        g.tint = on ? t.accent.nsColor : t.surfaceTextSecondary.nsColor
        g.isEnabled = enabled
        g.toolTip = tip
    }

    /// The page's picture, its top kept (a page reads from the top), or nil for the placeholder: the favicon, faint, on
    /// a soft fill.
    func setThumbnail(_ image: CGImage?) {
        let shown = image.map { Self.topCrop($0, aspect: (Self.width - 2 * Self.inset) / Self.thumbnailHeight) }
        thumbnailImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnail.contents = shown
        CATransaction.commit()
        placeholderIcon.isHidden = image != nil
    }

    /// The largest part of `image` with the given aspect ratio, from its top (centred across).
    static func topCrop(_ image: CGImage, aspect: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard w > 0, h > 0 else { return image }
        let rect: CGRect = w / h < aspect
            ? CGRect(x: 0, y: 0, width: w, height: (w / aspect).rounded())
            : CGRect(x: ((w - h * aspect) / 2).rounded(), y: 0, width: (h * aspect).rounded(), height: h)
        return image.cropping(to: rect) ?? image
    }

    override func layout() {
        super.layout()
        let r = cardRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = r
        ambient.frame = r
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: r.size), cornerWidth: AircRadius.popover,
                          cornerHeight: AircRadius.popover, transform: nil)
        plate.shadowPath = path
        ambient.shadowPath = path
        let thumb = NSRect(x: r.minX + Self.inset, y: r.minY + Self.inset, width: r.width - 2 * Self.inset, height: Self.thumbnailHeight)
        thumbnail.frame = thumb
        thumbnailEdge.frame = thumb
        CATransaction.commit()
        let ps: CGFloat = 28
        placeholderIcon.frame = NSRect(x: thumb.midX - ps / 2, y: thumb.midY - ps / 2, width: ps, height: ps)
        placeholderIcon.alphaValue = 0.55
        let textTop = thumb.maxY + 10
        let fs: CGFloat = 16
        favicon.frame = NSRect(x: r.minX + 12, y: textTop + 1, width: fs, height: fs)
        let x = r.minX + 36 - DesignGaps.labelInset
        let w = r.maxX - 12 - x
        title.frame = NSRect(x: x, y: textTop, width: w, height: 18)
        host.frame = NSRect(x: x, y: textTop + 19, width: w, height: 14)
        let s = Self.buttonSize
        var bx = r.minX + 8
        let by = r.maxY - 8 - s
        for b in Button.allCases {
            buttons[b]?.frame = NSRect(x: bx, y: by, width: s, height: s)
            bx += s + 2
        }
    }

    #if AIRC_TESTING
    /// The button's centre in window coordinates (the checks click it).
    func windowPoint(of b: Button) -> NSPoint? {
        guard let g = buttons[b] else { return nil }
        return g.convert(NSPoint(x: g.bounds.midX, y: g.bounds.midY), to: nil)
    }

    func isEnabled(_ b: Button) -> Bool { buttons[b]?.isEnabled ?? false }
    var titleText: String { title.stringValue }
    var hostText: String { host.stringValue }
    var showsPlaceholder: Bool { !placeholderIcon.isHidden }
    #endif
}
