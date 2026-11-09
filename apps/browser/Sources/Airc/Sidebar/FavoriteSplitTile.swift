// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircKit

/// SV-2: a Favorite split's tile (Arc ref §2.3, "Split as a Favorite: one tile cut by a 2 pt gap along the split
/// axis"). The tile's plate is cut into one part per pane, side by side or stacked like the split, each with its pane's
/// favicon centred. The parts sit in a container clipped to the tile's rounded shape, so the outer corners stay round
/// and the cuts are straight. They take the tile's fill (rest, hover, selected); the tile itself keeps only its shadow,
/// and its press scales them with it. A pane whose page isn't loaded draws its favicon at half strength (SB-15), as
/// unloaded rows do.
///
/// With a custom icon (Arc: "Favorited Split Views can have custom icons"; Change Icon… in its menu) the tile is whole:
/// the emoji in the middle and a small split mark where a Favorite's unread dot would be, so it still reads as a split.
@MainActor final class FavoriteSplitFace {
    static let gap: CGFloat = 2
    private weak var tile: CALayer?
    private weak var host: NSView?
    private let cut = CALayer()
    private var parts: [CALayer] = []
    private var icons: [FaviconView] = []
    private var axis: SplitAxis = .horizontal
    /// The tile's name: the split's, else its panes' joined (tooltip and drag ghost).
    private(set) var title = ""
    /// The custom icon (an emoji), when the split has one.
    private var emoji: NSTextField?
    private let mark = CALayer()
    /// What the tile shows instead of the panes' favicons (the checks read it).
    var customIcon: String? { emoji?.isHidden == false ? emoji?.stringValue : nil }

    init(tile: CALayer, in host: NSView) {
        self.tile = tile
        self.host = host
        cut.masksToBounds = true
        cut.cornerRadius = AircMetrics.Favorites.radius
        cut.cornerCurve = .continuous
        cut.actions = LayerImage.noActions
        tile.addSublayer(cut)
        mark.actions = LayerImage.noActions
        mark.contentsGravity = .center
        mark.isHidden = true
        tile.addSublayer(mark)
    }

    func configure(_ item: Item, controller c: WindowController?, palette: Palette) {
        guard let c, let host else { return }
        var panes = c.store.panes(ofSplitItem: item.id)
        axis = item.splitLayout?.axis ?? .horizontal
        title = item.title ?? panes.map(\.displayTitle).joined(separator: " | ")
        if let icon = item.icon, !icon.isEmpty {
            let field = emoji ?? {
                let f = NSTextField(labelWithString: "")
                f.font = NSFont.systemFont(ofSize: AircMetrics.Favorites.favicon + 2)
                f.alignment = .center
                host.addSubview(f)
                emoji = f
                return f
            }()
            if field.stringValue != icon { field.stringValue = icon }
            field.isHidden = false
            let symbol = axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2"
            LayerImage.set(LayerImage.symbol(symbol, size: 8, weight: .semibold, color: palette.textSecondary), on: mark, in: host)
            mark.isHidden = false
            // One whole part: the panes' favicons stay hidden.
            panes = Array(panes.prefix(1))
            icons.forEach { $0.isHidden = true }
        } else {
            emoji?.isHidden = true
            mark.isHidden = true
            icons.forEach { $0.isHidden = false }
        }
        let whole = emoji?.isHidden == false
        while icons.count < panes.count {
            let f = FaviconView()
            host.addSubview(f)
            icons.append(f)
        }
        while icons.count > panes.count { icons.removeLast().removeFromSuperview() }
        while parts.count < panes.count {
            let l = CALayer()
            l.actions = LayerImage.noActions
            cut.addSublayer(l)
            parts.append(l)
        }
        while parts.count > panes.count { parts.removeLast().removeFromSuperlayer() }
        for (icon, pane) in zip(icons, panes) where !whole {
            let t = c.store.liveTab(forItem: pane.id)
            let page = t.flatMap { c.engineTab(for: $0.id) }
            let saved = pane.savedURL ?? t?.url ?? ""
            let calendar = URLRules.isCalendar(saved)
            let iconURL = calendar ? URLRules.calendarIconURL(day: Calendar.current.component(.day, from: Date())) : (t?.faviconURL ?? pane.faviconURL)
            icon.set(image: calendar ? nil : page?.favicon, url: iconURL, fallbackPage: saved, palette: palette)
            icon.alphaValue = c.isPageUnloaded(t?.id) ? 0.5 : 1
        }
        if whole {
            icons.forEach { $0.isHidden = true }
            // SB-15: half strength while none of its pages is loaded.
            emoji?.alphaValue = c.store.paneTabs(ofSplitItem: item.id).contains { !c.isPageUnloaded($0.id) } ? 1 : 0.5
        }
        host.needsLayout = true
    }

    /// The tile's state as just styled moves onto the parts: their fill; the tile keeps the shadow.
    func applyStyle(of tile: CALayer) {
        for p in parts { p.backgroundColor = tile.backgroundColor }
        tile.backgroundColor = nil
    }

    func layout(in bounds: NSRect) {
        let frames = Self.parts(of: bounds, count: max(parts.count, 1), axis: axis)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cut.frame = bounds
        tile?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: AircMetrics.Favorites.radius,
                                  cornerHeight: AircMetrics.Favorites.radius, transform: nil)
        for (l, f) in zip(parts, frames) { l.frame = f }
        let d = AircMetrics.Favorites.unreadDot + 4, o = AircMetrics.Favorites.unreadDotOffset
        mark.frame = NSRect(x: bounds.width - o.x - d / 2, y: bounds.height - o.y - d / 2, width: d, height: d)
        CATransaction.commit()
        if let emoji, !emoji.isHidden {
            let h = ceil(emoji.intrinsicContentSize.height)
            emoji.frame = NSRect(x: bounds.minX, y: floor(bounds.midY - h / 2), width: bounds.width, height: h)
        }
        for (icon, f) in zip(icons, frames) {
            let s = max(10, min(AircMetrics.Favorites.favicon, f.width - 10, f.height - 8))
            icon.frame = NSRect(x: f.midX - s / 2, y: f.midY - s / 2, width: s, height: s)
        }
    }

    /// One part per pane along the axis, with `gap` between them (in the host's flipped coordinates: the first pane is
    /// at the left, or at the top).
    static func parts(of b: NSRect, count n: Int, axis: SplitAxis) -> [NSRect] {
        let k = CGFloat(n)
        if axis == .horizontal {
            let w = (b.width - gap * (k - 1)) / k
            return (0..<n).map { NSRect(x: b.minX + CGFloat($0) * (w + gap), y: b.minY, width: w, height: b.height) }
        }
        let h = (b.height - gap * (k - 1)) / k
        return (0..<n).map { NSRect(x: b.minX, y: b.minY + CGFloat($0) * (h + gap), width: b.width, height: h) }
    }

    /// The first pane's icon (the drag ghost's).
    var firstIcon: CGImage? { icons.first?.cgImage }
    /// Each part's favicon alpha (the checks read it: unloaded panes are at half strength).
    var iconAlphas: [CGFloat] { icons.map(\.alphaValue) }
    /// The parts' frames in the host (the checks read the cut).
    var partFrames: [NSRect] { parts.map(\.frame) }

    /// Back to a plain tile.
    func remove() {
        icons.forEach { $0.removeFromSuperview() }
        emoji?.removeFromSuperview()
        mark.removeFromSuperlayer()
        cut.removeFromSuperlayer()
        tile?.shadowPath = nil
    }
}
