// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AppKit
import ImageIO

// Arc's Capture in Portrait Mode (2023: "pretty screenshots of tabs"; 2024: ⌥ on Capture the full page): the page as
// a framed picture, docs/user/capture.md "Portrait". What Arc offered, from its bundle (read-only) and a public
// walkthrough of its panel: a background of the website's colour ("Use Website Color"), of a colour picked on a
// rainbow slider (portraitCaptureColorPercentage) or of the desktop picture ("Use Desktop Wallpaper"), and its mark
// in a corner with a toggle (portraitCaptureHidesWatermark). The proportions are measured from Arc's own preview:
// the page centred with 0.357 × its width of background at each side and 0.168 × its width above and below, the
// background a soft two-way gradient around the colour (the hue turning about 16° from left to right, 15 % darker
// from top to bottom). Airc's mark replaces Arc's.

/// The choices, remembered under Arc's names.
struct PortraitStyle: Equatable {
    enum Background: String { case website, color, wallpaper }
    var background = Background.color
    /// Where the slider is, 0…1 (pink, red, orange, yellow, green, cyan, blue). 0.85: cyan, as Arc's panel opened.
    var colorPercentage = 0.85
    var hidesWatermark = false

    /// Where they're kept (scripted checks give a suite of their own: never the person's choices).
    static var storage: () -> UserDefaults = { .standard }

    static var saved: PortraitStyle {
        get {
            let d = storage()
            var s = PortraitStyle()
            if let b = d.string(forKey: "portraitCaptureBackground").flatMap(Background.init(rawValue:)) { s.background = b }
            if d.object(forKey: "portraitCaptureColorPercentage") != nil { s.colorPercentage = min(1, max(0, d.double(forKey: "portraitCaptureColorPercentage"))) }
            s.hidesWatermark = d.bool(forKey: "portraitCaptureHidesWatermark")
            return s
        }
        set {
            let d = storage()
            d.set(newValue.background.rawValue, forKey: "portraitCaptureBackground")
            d.set(newValue.colorPercentage, forKey: "portraitCaptureColorPercentage")
            d.set(newValue.hidesWatermark, forKey: "portraitCaptureHidesWatermark")
        }
    }
}

enum PortraitCapture {
    /// The desktop picture of `screen`, only read when the person picks it (never for a thumbnail, never in a scripted
    /// check, which gives its own). Downsampled to at most `maxPixels` on its longer side; nothing of the file's
    /// metadata goes on (only its pixels are drawn).
    static var wallpaper: (_ screen: NSScreen?, _ maxPixels: Int) -> CGImage? = { screen, maxPixels in
        guard let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }

    /// The most pixels a portrait may have (as a full page's): fewer pixels per point beyond it.
    static var maxPixels = 48_000_000

    // MARK: Geometry

    struct Layout: Equatable {
        /// The whole picture and the page in it, in points.
        var canvas: CGSize
        var page: CGRect
        var cornerRadius: CGFloat
        /// The mark's rounded square, in points (y from the top).
        var watermark: CGRect
    }

    /// The frame around a page of `page` points.
    static func layout(page: CGSize) -> Layout {
        let w = page.width
        let padX = (0.357 * w).rounded(), padY = (0.168 * w).rounded()
        let canvas = CGSize(width: page.width + 2 * padX, height: page.height + 2 * padY)
        let side = min(64, max(36, (0.06 * canvas.width).rounded()))
        let inset = (side * 0.3).rounded()
        return Layout(canvas: canvas, page: CGRect(x: padX, y: padY, width: page.width, height: page.height),
                      cornerRadius: min(16, max(8, (0.012 * w).rounded())),
                      watermark: CGRect(x: inset, y: canvas.height - inset - side, width: side, height: side))
    }

    // MARK: Colours

    /// The slider's colour at `p`: pink at 0 through red, orange, yellow, green and cyan to blue at 1, at the soft
    /// saturation and lightness of Arc's backgrounds.
    static func sliderColor(_ p: Double) -> HSL {
        HSL(h: (330 + 255 * min(1, max(0, p))).truncatingRemainder(dividingBy: 360), s: 0.77, l: 0.685)
    }

    struct HSL: Equatable {
        var h: Double, s: Double, l: Double

        init(h: Double, s: Double, l: Double) {
            self.h = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            self.s = min(1, max(0, s))
            self.l = min(1, max(0, l))
        }

        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? .white
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
            guard mx > mn else { self.init(h: 0, s: 0, l: l); return }
            let d = mx - mn
            let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            let h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            self.init(h: h * 60, s: s, l: l)
        }

        var rgb: (Double, Double, Double) {
            guard s > 0 else { return (l, l, l) }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            func f(_ t0: Double) -> Double {
                var t = t0
                if t < 0 { t += 1 }
                if t > 1 { t -= 1 }
                if t < 1 / 6 { return p + (q - p) * 6 * t }
                if t < 1 / 2 { return q }
                if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
                return p
            }
            let hh = h / 360
            return (f(hh + 1 / 3), f(hh), f(hh - 1 / 3))
        }

        var cgColor: CGColor { let c = rgb; return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1) }
    }

    /// The four corners of the background around `base`: lighter at the top, the hue turning from left to right.
    static func corners(_ base: HSL) -> (topLeft: HSL, topRight: HSL, bottomLeft: HSL, bottomRight: HSL) {
        (HSL(h: base.h - 8, s: base.s, l: base.l + 0.075), HSL(h: base.h + 8, s: base.s, l: base.l + 0.075),
         HSL(h: base.h - 8, s: base.s - 0.2, l: base.l - 0.075), HSL(h: base.h + 8, s: base.s - 0.2, l: base.l - 0.075))
    }

    /// A page's own colour: its theme colour, else the colour its top edge mostly has.
    static func websiteColor(theme: NSColor?, picture: CGImage?) -> NSColor {
        if let theme, let c = theme.usingColorSpace(.sRGB), c.alphaComponent > 0.5 { return c }
        guard let picture, let ctx = CGContext(data: nil, width: 16, height: 1, bitsPerComponent: 8, bytesPerRow: 64,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let top = picture.cropping(to: CGRect(x: 0, y: 0, width: picture.width, height: max(1, picture.height / 60))) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(top, in: CGRect(x: 0, y: 0, width: 16, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        // The middle of the edge (its most common run), not its average: a logo or a button doesn't tint it.
        var counts: [Int: Int] = [:]
        for i in 0..<16 { counts[(Int(p[i * 4]) >> 4) << 8 | (Int(p[i * 4 + 1]) >> 4) << 4 | Int(p[i * 4 + 2]) >> 4, default: 0] += 1 }
        let key = counts.max { $0.value < $1.value }!.key
        let i = (0..<16).first { (Int(p[$0 * 4]) >> 4) << 8 | (Int(p[$0 * 4 + 1]) >> 4) << 4 | Int(p[$0 * 4 + 2]) >> 4 == key } ?? 0
        return NSColor(srgbRed: CGFloat(p[i * 4]) / 255, green: CGFloat(p[i * 4 + 1]) / 255, blue: CGFloat(p[i * 4 + 2]) / 255, alpha: 1)
    }

    // MARK: The picture

    /// `content` (`contentScale` pixels per point) framed in `style`, at `scale` pixels per point (fewer for a very
    /// large page, within `maxPixels`). `website` is the page's colour; `watermark` the mark to put in the corner.
    static func render(content: CGImage, contentScale: CGFloat, scale: CGFloat, style: PortraitStyle, website: NSColor,
                       wallpaper: CGImage?, watermark: CGImage?) -> (image: CGImage, scale: CGFloat, layout: Layout)? {
        let pagePoints = CGSize(width: CGFloat(content.width) / contentScale, height: CGFloat(content.height) / contentScale)
        guard pagePoints.width >= 1, pagePoints.height >= 1 else { return nil }
        let l = layout(page: pagePoints)
        var s = scale
        let area = Double(l.canvas.width * l.canvas.height)
        if area * Double(s * s) > Double(maxPixels) { s = CGFloat((Double(maxPixels) / area).squareRoot()) }
        let w = Int((l.canvas.width * s).rounded()), h = Int((l.canvas.height * s).rounded())
        let space = content.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        // CG counts from the bottom: a rect in points from the top, in pixels from the bottom.
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * s, y: CGFloat(h) - r.maxY * s, width: r.width * s, height: r.height * s) }

        // The background.
        if style.background == .wallpaper, let wallpaper {
            // Filling the picture, centred (as the desktop shows it).
            let k = max(CGFloat(w) / CGFloat(wallpaper.width), CGFloat(h) / CGFloat(wallpaper.height))
            let size = CGSize(width: CGFloat(wallpaper.width) * k, height: CGFloat(wallpaper.height) * k)
            ctx.draw(wallpaper, in: CGRect(x: (CGFloat(w) - size.width) / 2, y: (CGFloat(h) - size.height) / 2, width: size.width, height: size.height))
        } else {
            let base = style.background == .website ? HSL(website) : sliderColor(style.colorPercentage)
            gradient(ctx, corners(base), in: full)
        }

        // The page: its shadow, then itself in rounded corners, then a hairline rim.
        let page = px(l.page), radius = l.cornerRadius * s
        let shape = CGPath(roundedRect: page, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.014 * l.page.width * s), blur: 0.045 * l.page.width * s,
                      color: CGColor(gray: 0, alpha: 0.30))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(content, in: page)
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: page.insetBy(dx: 0.5 * s, dy: 0.5 * s), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
        ctx.setLineWidth(1 * s)
        ctx.strokePath()

        // The mark: Airc's, in a soft rounded square in the corner (Arc's was its own).
        if !style.hidesWatermark, let watermark {
            let box = px(l.watermark)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.width * 0.24, cornerHeight: box.width * 0.24, transform: nil))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.24))
            ctx.fillPath()
            ctx.saveGState()
            ctx.setAlpha(0.92)
            ctx.draw(watermark, in: box.insetBy(dx: box.width * 0.16, dy: box.width * 0.16))
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { return nil }
        return (image, s, l)
    }

    /// The bilinear blend of the four corners over `rect`: the top edge's gradient, with the bottom edge's laid over it
    /// more and more towards the bottom.
    private static func gradient(_ ctx: CGContext, _ c: (topLeft: HSL, topRight: HSL, bottomLeft: HSL, bottomRight: HSL), in rect: CGRect) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func horizontal(_ a: HSL, _ b: HSL) -> CGGradient { CGGradient(colorsSpace: space, colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])! }
        let start = CGPoint(x: rect.minX, y: rect.midY), end = CGPoint(x: rect.maxX, y: rect.midY)
        ctx.drawLinearGradient(horizontal(c.topLeft, c.topRight), start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // A vertical mask: transparent at the top, opaque at the bottom (CG's y grows upwards).
        let rows = max(2, Int(rect.height))
        var bytes = [UInt8](repeating: 0, count: rows)
        for i in 0..<rows { bytes[i] = UInt8((Double(i) / Double(rows - 1) * 255).rounded()) }   // row 0 is the image's top
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let mask = CGImage(width: 1, height: rows, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 1,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.clip(to: rect, mask: mask)
        ctx.drawLinearGradient(horizontal(c.bottomLeft, c.bottomRight), start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// Airc's mark for the corner: the app's own icon.
    static var watermarkImage: CGImage? {
        var r = NSRect(x: 0, y: 0, width: 128, height: 128)
        return NSApp.applicationIconImage?.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

/// Under a portrait's preview (Arc's panel row): the website's colour, the colour slider, the desktop picture, and the
/// mark's toggle. A press picks; a drag along the slider picks its colour.
final class PortraitControls: NSView {
    var style = PortraitStyle() { didSet { if style != oldValue { needsDisplay = true; updateAccessibility() } } }
    /// The page's own colour, for its circle.
    var websiteColor: NSColor = .white { didSet { needsDisplay = true } }
    var palette: Palette? { didSet { needsDisplay = true } }
    /// The person changed the style.
    var onChange: ((PortraitStyle) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var fittingSize: NSSize { NSSize(width: 316, height: 40) }

    // The parts, left to right: website circle, slider, wallpaper circle, the mark's toggle.
    private var websiteRect: CGRect { CGRect(x: 10, y: 9, width: 22, height: 22) }
    private var sliderRect: CGRect { CGRect(x: 44, y: 15, width: 176, height: 10) }
    private var wallpaperRect: CGRect { CGRect(x: 232, y: 9, width: 22, height: 22) }
    private var watermarkRect: CGRect { CGRect(x: 276, y: 8, width: 30, height: 24) }
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.apply(.toast)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Portrait background")
        toolTip = nil
        addToolTip(websiteRect, owner: self, userData: nil)
        addToolTip(wallpaperRect, owner: self, userData: nil)
        addToolTip(watermarkRect, owner: self, userData: nil)
        addToolTip(sliderRect.insetBy(dx: 0, dy: -6), owner: self, userData: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if websiteRect.insetBy(dx: -4, dy: -4).contains(point) { return "Use Website Color" }
        if wallpaperRect.insetBy(dx: -4, dy: -4).contains(point) { return "Use Desktop Wallpaper" }
        if watermarkRect.contains(point) { return style.hidesWatermark ? "Show the Airc mark" : "Hide the Airc mark" }
        return "Pick a colour"
    }

    // MARK: Picking (also what scripted checks call)

    func pick(_ background: PortraitStyle.Background) {
        var s = style
        s.background = background
        commit(s)
    }

    func pickColor(_ p: Double) {
        var s = style
        s.background = .color
        s.colorPercentage = min(1, max(0, p))
        commit(s)
    }

    func toggleWatermark() {
        var s = style
        s.hidesWatermark.toggle()
        commit(s)
    }

    private func commit(_ s: PortraitStyle) {
        guard s != style else { return }
        style = s
        onChange?(s)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if websiteRect.insetBy(dx: -4, dy: -4).contains(p) { return pick(.website) }
        if wallpaperRect.insetBy(dx: -4, dy: -4).contains(p) { return pick(.wallpaper) }
        if watermarkRect.contains(p) { return toggleWatermark() }
        if sliderRect.insetBy(dx: -8, dy: -10).contains(p) {
            dragging = true
            pickColor(Double((p.x - sliderRect.minX) / sliderRect.width))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        pickColor(Double((p.x - sliderRect.minX) / sliderRect.width))
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = palette
        layer?.backgroundColor = (p?.panelBackground ?? .windowBackgroundColor).cgColor
        layer?.borderColor = (p?.panelBorder ?? .separatorColor).cgColor
        let ring = NSColor.controlAccentColor
        func circle(_ r: CGRect, fill: NSColor, selected: Bool) {
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor((p?.panelBorder ?? .separatorColor).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            if selected {
                ctx.setStrokeColor(ring.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: r.insetBy(dx: -3, dy: -3))
            }
        }
        circle(websiteRect, fill: websiteColor, selected: style.background == .website)
        // The slider: the rainbow, its knob where the colour is (shown when it's the background).
        let track = CGPath(roundedRect: sliderRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(track)
        ctx.clip()
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { PortraitCapture.HSL(h: (330 + 255 * $0).truncatingRemainder(dividingBy: 360), s: 0.85, l: 0.62).cgColor }
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: CGPoint(x: sliderRect.minX, y: 0), end: CGPoint(x: sliderRect.maxX, y: 0), options: [])
        }
        ctx.restoreGState()
        let kx = sliderRect.minX + CGFloat(style.colorPercentage) * sliderRect.width
        let knob = CGRect(x: kx - 9, y: sliderRect.midY - 9, width: 18, height: 18)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor((style.background == .color ? NSColor.white : NSColor.white.withAlphaComponent(0.55)).cgColor)
        ctx.fillEllipse(in: knob)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if style.background == .color {
            ctx.setStrokeColor(ring.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: knob.insetBy(dx: -1, dy: -1))
        }
        // The desktop picture's circle shows a picture symbol, not the picture: it's only read once picked.
        circle(wallpaperRect, fill: (p?.panelSelection ?? .quaternaryLabelColor), selected: style.background == .wallpaper)
        Self.drawSymbol("photo", in: wallpaperRect.insetBy(dx: 5, dy: 5), color: p?.panelText ?? .labelColor)
        // The mark's toggle.
        let markFill = style.hidesWatermark ? NSColor.clear : (p?.panelSelection ?? .quaternaryLabelColor)
        ctx.setFillColor(markFill.cgColor)
        ctx.addPath(CGPath(roundedRect: watermarkRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        Self.drawSymbol(style.hidesWatermark ? "seal" : "checkmark.seal.fill", in: watermarkRect.insetBy(dx: 7, dy: 4),
                        color: style.hidesWatermark ? (p?.panelSecondary ?? .secondaryLabelColor) : (p?.panelText ?? .labelColor))
    }

    private static func drawSymbol(_ name: String, in rect: CGRect, color: NSColor) {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let k = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * k, height: image.size.height * k)
        tinted.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func updateAccessibility() {
        setAccessibilityValue("\(style.background.rawValue), colour \(Int(style.colorPercentage * 100)) %, mark \(style.hidesWatermark ? "hidden" : "shown")")
    }
}
