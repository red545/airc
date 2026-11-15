// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import QuartzCore

// How an Easel's blocks look. Each block is one CALayer (EaselBlockLayer) whose contents are drawn once and kept: the
// canvas pans and zooms by moving one parent layer (EaselCanvas.swift), so 500 blocks cost the GPU a composite per
// frame, not a redraw. Contents are redrawn only when a block changes, or at a sharper scale once a zoom settles.

/// An Easel's look in one appearance.
struct EaselLook: Equatable {
    var palette: EaselPalette
    var dark: Bool

    var background: NSColor { NSColor(easelHex: dark ? EaselBackground.dark : EaselBackground.light) }
    var ink: NSColor { dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1) }
    var secondaryInk: NSColor { ink.withAlphaComponent(0.6) }
    var cardFill: NSColor { dark ? NSColor(white: 1, alpha: 0.07) : NSColor.white }
    var cardStroke: NSColor { dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1) }
    var accent: NSColor { NSColor(srgbRed: 0.27, green: 0.45, blue: 0.98, alpha: 1) }

    func color(_ c: EaselColor, stroke: Bool = false) -> NSColor { NSColor(easelHex: c.hex(palette, dark: dark, stroke: stroke)) }
}

// MARK: - Text

/// An Easel text block's runs, through the note's own conversion (NoteText), in the block's family, size and colour.
enum EaselTextRender {
    static func attributed(_ t: EaselText, look: EaselLook, scale: CGFloat = 1) -> NSAttributedString {
        var style = NoteStyle(DesignTheme.default.resolved(systemIsDark: look.dark))
        style.text = t.color.map { look.color($0) } ?? look.ink
        style.secondary = style.text.withAlphaComponent(0.6)
        style.tertiary = style.text.withAlphaComponent(0.4)
        // An Easel's text never holds pictures (they're blocks of their own).
        var doc = t.text
        for i in doc.blocks.indices { doc.blocks[i].runs.removeAll { $0.image != nil } }
        let (base, _) = NoteText.attributedString(doc, style: style)
        let out = NSMutableAttributedString(attributedString: base)
        let factor = CGFloat(t.size) / NoteStyle.bodySize * scale
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.font, in: full) { v, r, _ in
            guard let f = v as? NSFont else { return }
            out.addAttribute(.font, value: font(f, family: t.font, size: f.pointSize * factor), range: r)
        }
        out.enumerateAttribute(.paragraphStyle, in: full) { v, r, _ in
            let p = ((v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.lineSpacing *= factor
            p.paragraphSpacing *= factor
            p.paragraphSpacingBefore = 0
            p.firstLineHeadIndent *= factor
            p.headIndent *= factor
            p.alignment = switch t.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            out.addAttribute(.paragraphStyle, value: p, range: r)
        }
        if out.length == 0 { return NSAttributedString(string: "", attributes: typingAttributes(t, look: look, scale: scale)) }
        return out
    }

    /// What an empty text block types with.
    static func typingAttributes(_ t: EaselText, look: EaselLook, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        var style = NoteStyle(DesignTheme.default.resolved(systemIsDark: look.dark))
        style.text = t.color.map { look.color($0) } ?? look.ink
        var a = style.attributes(.paragraph, [])
        let factor = CGFloat(t.size) / NoteStyle.bodySize * scale
        if let f = a[.font] as? NSFont { a[.font] = font(f, family: t.font, size: f.pointSize * factor) }
        let p = NSMutableParagraphStyle()
        p.alignment = t.alignment == .center ? .center : t.alignment == .right ? .right : .left
        a[.paragraphStyle] = p
        return a
    }

    /// `f`'s weight and slant in the Easel family, at `size`.
    static func font(_ f: NSFont, family: EaselFont, size: CGFloat) -> NSFont {
        let traits = f.fontDescriptor.symbolicTraits
        let weightValue = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        let weight = NSFont.Weight(rawValue: weightValue ?? (traits.contains(.bold) ? NSFont.Weight.bold.rawValue : 0))
        let italic = traits.contains(.italic)
        if traits.contains(.monoSpace) { return NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
        var out: NSFont
        switch family {
        case .clean: out = NSFont(descriptor: f.fontDescriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        case .mono: out = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .fancy:
            let d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)
            out = d.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
        case .hip: out = NSFont.systemFont(ofSize: size, weight: weight, width: .expanded)
        }
        if italic, family != .clean { out = NSFontManager.shared.convert(out, toHaveTrait: .italicFontMask) }
        return out
    }

    /// The height the text needs at `width` points (scale 1).
    static func height(_ t: EaselText, width: Double, look: EaselLook) -> Double {
        let s = attributed(t, look: look)
        let size = s.length == 0
            ? NSAttributedString(string: "M", attributes: typingAttributes(t, look: look, scale: 1)).size()
            : s.boundingRect(with: NSSize(width: max(1, width - 2 * textInset), height: .greatestFiniteMagnitude),
                             options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        return ceil(size.height) + 2 * textInset
    }

    static let textInset: Double = 4
}

// MARK: - Pictures

/// Asset pictures, decoded once and kept (downsampled to at most 2048 px on their long side: a 500-block Easel of
/// photographs stays light).
enum EaselPictures {
    private static let cache: NSCache<NSString, CGImageBox> = {
        let c = NSCache<NSString, CGImageBox>()
        c.countLimit = 600
        c.totalCostLimit = 512 * 1024 * 1024
        return c
    }()

    final class CGImageBox: @unchecked Sendable {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    static func image(_ easelID: String, _ asset: String?) -> CGImage? {
        guard let asset else { return nil }
        let key = "\(easelID)/\(asset)" as NSString
        if let b = cache.object(forKey: key) { return b.image }
        guard let url = EaselCenter.shared.files.assetURL(easelID, asset),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                                     kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        cache.setObject(CGImageBox(img), forKey: key, cost: img.bytesPerRow * img.height)
        return img
    }
}

// MARK: - A block's layer

final class EaselBlockLayer: CALayer {
    var block: EaselBlock
    var look: EaselLook
    let easelID: String
    /// The text being edited in place is drawn by its text view, not here.
    var hidesText = false { didSet { if hidesText != oldValue { setNeedsDisplay() } } }
    /// P19b: a refresh of this live Capture is under way (its chip says so).
    var refreshing = false { didSet { if refreshing != oldValue { setNeedsDisplay() } } }
    /// P19c: drawn for an export or Copy Image: a live Capture is its last picture, without its chip or veil.
    var exporting = false

    init(block: EaselBlock, look: EaselLook, easelID: String) {
        self.block = block
        self.look = look
        self.easelID = easelID
        super.init()
        needsDisplayOnBoundsChange = true
        actions = ["position": NSNull(), "bounds": NSNull(), "transform": NSNull(), "contents": NSNull(), "hidden": NSNull(),
                   "contentsScale": NSNull(), "zPosition": NSNull(), "anchorPoint": NSNull(), "opacity": NSNull()]
        place()
    }

    override init(layer: Any) {
        let l = layer as! EaselBlockLayer
        block = l.block
        look = l.look
        easelID = l.easelID
        refreshing = l.refreshing
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How far a line's drawing reaches past its ends (its width, its heads).
    private var pad: Double {
        if let l = block.line { return l.width / 2 + (l.isArrow ? l.width * 3 + 6 : 2) }
        if case .shape(let s) = block.content, s.stroke != nil { return s.strokeWidth / 2 + 1 }
        if case .link = block.content { return 12 }
        if case .capture = block.content { return 12 }
        if case .image = block.content { return 8 }
        return 0
    }

    func update(_ b: EaselBlock, look l: EaselLook) {
        let redraw = b.content != block.content || b.frame.width != block.frame.width || b.frame.height != block.frame.height || l != look
        block = b
        look = l
        place()
        if redraw { setNeedsDisplay() }
    }

    /// Frame and turn, in the canvas's world (plane points).
    private func place() {
        let f = block.frame, p = pad
        bounds = CGRect(x: 0, y: 0, width: max(1, f.width + 2 * p), height: max(1, f.height + 2 * p))
        position = CGPoint(x: f.midX, y: f.midY)
        setAffineTransform(block.rotation == 0 ? .identity : CGAffineTransform(rotationAngle: block.rotation))
        zPosition = 0
    }

    override func draw(in ctx: CGContext) {
        ctx.saveGState()
        // Draw y-down, whatever the layer tree's orientation.
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let p = CGFloat(pad)
        ctx.translateBy(x: p, y: p)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let r = CGRect(x: 0, y: 0, width: block.frame.width, height: block.frame.height)
        switch block.content {
        case .text(let t): if !hidesText { drawText(t, in: r) }
        case .image(let i): drawPicture(EaselPictures.image(easelID, i.asset), in: r, radius: 6, shadow: true, ctx: ctx)
        case .shape(let s): drawShape(s, in: r, ctx: ctx)
        case .line(let l): drawLine(l, ctx: ctx)
        case .link(let l): drawLink(l, in: r, ctx: ctx)
        case .capture(let c): drawCapture(c, in: r, ctx: ctx)
        case .unknown(let type, _): drawUnknown(type, in: r, ctx: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawText(_ t: EaselText, in r: CGRect) {
        let s = EaselTextRender.attributed(t, look: look)
        let inset = CGFloat(EaselTextRender.textInset)
        s.draw(with: r.insetBy(dx: inset, dy: inset), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }

    private func drawShape(_ s: EaselShape, in r: CGRect, ctx: CGContext) {
        let path: CGPath
        switch s.kind {
        case .rectangle:
            let radius = min(CGFloat(s.cornerRadius), min(r.width, r.height) / 2)
            path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            path = CGPath(ellipseIn: r, transform: nil)
        }
        if let f = s.fill {
            ctx.addPath(path)
            ctx.setFillColor(look.color(f).cgColor)
            ctx.fillPath()
        }
        if let st = s.stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(look.color(st, stroke: true).cgColor)
            ctx.setLineWidth(CGFloat(s.strokeWidth))
            ctx.strokePath()
        }
    }

    private func drawLine(_ l: EaselLine, ctx: CGContext) {
        let o = block.frame
        let a = CGPoint(x: l.from.x - o.x, y: l.from.y - o.y), b = CGPoint(x: l.to.x - o.x, y: l.to.y - o.y)
        let w = CGFloat(l.width)
        let color = look.color(l.color).cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let head = w * 3 + 6
        let angle = atan2(b.y - a.y, b.x - a.x)
        // The shaft stops short of a head so its round cap doesn't poke through the tip.
        var s = a, e = b
        let len = hypot(b.x - a.x, b.y - a.y)
        if l.startHead, len > head { s = CGPoint(x: a.x + cos(angle) * head * 0.6, y: a.y + sin(angle) * head * 0.6) }
        if l.endHead, len > head { e = CGPoint(x: b.x - cos(angle) * head * 0.6, y: b.y - sin(angle) * head * 0.6) }
        ctx.move(to: s)
        ctx.addLine(to: e)
        ctx.strokePath()
        func arrowHead(at tip: CGPoint, angle: CGFloat) {
            let spread: CGFloat = .pi / 7
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x - cos(angle - spread) * head, y: tip.y - sin(angle - spread) * head))
            ctx.addLine(to: CGPoint(x: tip.x - cos(angle + spread) * head, y: tip.y - sin(angle + spread) * head))
            ctx.closePath()
            ctx.fillPath()
        }
        if l.endHead { arrowHead(at: b, angle: angle) }
        if l.startHead { arrowHead(at: a, angle: angle + .pi) }
    }

    private func card(_ r: CGRect, ctx: CGContext) {
        let path = CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: NSColor(white: 0, alpha: look.dark ? 0.4 : 0.12).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(look.cardFill.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(look.cardStroke.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private func drawPicture(_ image: CGImage?, in r: CGRect, radius: CGFloat, shadow: Bool, ctx: CGContext) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: look.dark ? 0.35 : 0.12).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(look.cardFill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let image {
            // Fill the frame, keeping the picture's shape (centre crop).
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let s = max(r.width / iw, r.height / ih)
            let dw = iw * s, dh = ih * s
            let dest = CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh)
            // CGContext draws images y-up: flip about the destination.
            ctx.translateBy(x: 0, y: dest.maxY + dest.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: dest)
        } else {
            ctx.setFillColor(look.ink.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
        }
        ctx.restoreGState()
    }

    private func drawLink(_ l: EaselLink, in r: CGRect, ctx: CGContext) {
        card(r, ctx: ctx)
        var textX: CGFloat = 14
        if let img = EaselPictures.image(easelID, l.image) {
            let side = r.height - 16
            drawPicture(img, in: CGRect(x: 8, y: 8, width: side, height: side), radius: 6, shadow: false, ctx: ctx)
            textX = side + 20
        } else {
            let icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            let box = CGRect(x: 12, y: (r.height - 36) / 2, width: 36, height: 36)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(look.accent.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            if let icon {
                let tinted = icon.tinted(look.accent)
                let s = tinted.size
                tinted.draw(in: CGRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height))
            }
            textX = 60
        }
        let width = max(10, r.width - textX - 12)
        let title = NSAttributedString(string: l.title?.isEmpty == false ? l.title! : l.host, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: look.ink,
        ])
        let detail = NSAttributedString(string: l.detail ?? "", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: look.secondaryInk])
        let host = NSAttributedString(string: l.host, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: look.secondaryInk])
        var y: CGFloat = 12
        let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        title.draw(with: CGRect(x: textX, y: y, width: width, height: 20), options: opts)
        y += 21
        if detail.length > 0, r.height > 70 {
            detail.draw(with: CGRect(x: textX, y: y, width: width, height: max(16, r.height - y - 26)), options: opts)
        }
        host.draw(with: CGRect(x: textX, y: r.height - 24, width: width, height: 16), options: opts)
    }

    private func drawCapture(_ c: EaselCapture, in r: CGRect, ctx: CGContext) {
        drawPicture(EaselPictures.image(easelID, c.asset), in: r, radius: 8, shadow: true, ctx: ctx)
        if let live = c.live, !exporting { drawLive(live, in: r, ctx: ctx) }
        // The page it came from, on a small chip in the corner.
        guard let host = c.url.flatMap({ URL(string: $0)?.host }), r.width > 120, r.height > 40 else { return }
        let text = NSAttributedString(string: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let chip = CGRect(x: 8, y: r.height - size.height - 14, width: min(r.width - 16, size.width + 14), height: size.height + 6)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2, transform: nil))
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.fillPath()
        text.draw(with: chip.insetBy(dx: 7, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// P19b: a live Capture's chip (top right: "Live", "Refreshing…"), and over its last picture, when the last refresh
    /// didn't work, a quiet veil with what to do ("Sign in to refresh", "Offline").
    private func drawLive(_ live: EaselLiveSource, in r: CGRect, ctx: CGContext) {
        guard r.width > 60, r.height > 36 else { return }
        if let problem = live.problem, !refreshing {
            let clip = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.saveGState()
            ctx.addPath(clip)
            ctx.clip()
            ctx.setFillColor(NSColor(white: 0, alpha: 0.38).cgColor)
            ctx.fill(r)
            ctx.restoreGState()
            let symbol = live.status == .offline ? "wifi.slash" : live.status == .signedOut ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle"
            let text = NSAttributedString(string: problem, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
            let ts = text.size()
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))?.tinted(.white)
            let iw: CGFloat = icon == nil ? 0 : 20
            let pill = CGRect(x: r.midX - min(r.width - 16, ts.width + iw + 24) / 2, y: r.midY - (ts.height + 12) / 2,
                              width: min(r.width - 16, ts.width + iw + 24), height: ts.height + 12)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
            ctx.setFillColor(NSColor(white: 0.08, alpha: 0.82).cgColor)
            ctx.fillPath()
            icon?.draw(in: CGRect(x: pill.minX + 12, y: pill.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            text.draw(with: CGRect(x: pill.minX + 12 + iw, y: pill.minY + 6, width: pill.width - 24 - iw, height: ts.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let label = refreshing ? "Refreshing…" : live.mode == .live ? "Live" : nil
        guard let label else { return }
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let dot: CGFloat = 6
        let chip = CGRect(x: r.maxX - size.width - dot - 26, y: 8, width: size.width + dot + 18, height: size.height + 6)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2, transform: nil))
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.fillPath()
        // Green when it's up to date, amber while refreshing or when the last one didn't work.
        let ok = live.status == .ok && !refreshing
        ctx.setFillColor((ok ? NSColor(srgbRed: 0.20, green: 0.84, blue: 0.47, alpha: 1) : NSColor(srgbRed: 1, green: 0.74, blue: 0.2, alpha: 1)).cgColor)
        ctx.fillEllipse(in: CGRect(x: chip.minX + 7, y: chip.midY - dot / 2, width: dot, height: dot))
        text.draw(with: CGRect(x: chip.minX + 7 + dot + 4, y: chip.minY + 3, width: size.width + 2, height: size.height), options: [.usesLineFragmentOrigin])
    }

    private func drawUnknown(_ type: String, in r: CGRect, ctx: CGContext) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(look.ink.withAlphaComponent(0.06).cgColor)
        ctx.fillPath()
        let s = NSAttributedString(string: "Made by a newer Airc (\(type))", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: look.secondaryInk])
        s.draw(with: r.insetBy(dx: 8, dy: 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA".
    convenience init(easelHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255; b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255; a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
