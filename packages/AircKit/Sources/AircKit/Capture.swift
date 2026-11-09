// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation

/// CB-5 Capture (Arc's ⇧⌘2): a rectangle over the page card, cut out of the engines' own pictures of the pages on
/// screen. This is the arithmetic: where a selection lands in each page's picture, how it moves and resizes, and the
/// saved file's name. Rects are top-left based (the overlay is a flipped view) and in points, except where they say
/// pixels.
public enum CaptureGeometry {
    /// A page under the overlay: its frame in the overlay's points and its picture's size in pixels. The picture is the
    /// engine's copy of the page as composited (device pixels), so page zoom (⌘+) never enters: a zoomed page draws more
    /// pixels per CSS pixel, not more pixels per point. The pixels-per-point is the picture's own, never assumed.
    public struct Page: Equatable, Sendable {
        public var frame: CGRect
        public var pixelSize: CGSize
        public init(frame: CGRect, pixelSize: CGSize) {
            self.frame = frame
            self.pixelSize = pixelSize
        }
    }

    /// Part of page `page`'s picture (`source`, whole pixels, top-left) drawn at `destination` (output pixels, top-left).
    public struct Piece: Equatable, Sendable {
        public var page: Int
        public var source: CGRect
        public var destination: CGRect
        public init(page: Int, source: CGRect, destination: CGRect) {
            self.page = page
            self.source = source
            self.destination = destination
        }
    }

    /// The output image: `pixelSize` and the pieces that fill it, bottom page first.
    public struct Plan: Equatable, Sendable {
        public var pixelSize: CGSize
        public var pieces: [Piece]
        public init(pixelSize: CGSize, pieces: [Piece]) {
            self.pixelSize = pixelSize
            self.pieces = pieces
        }
    }

    /// The smallest selection worth keeping, in points (a click without a drag makes none).
    public static let minimumSide: CGFloat = 4

    /// `selection` (any corner order) kept inside `bounds`, in whole points.
    public static func clamp(_ selection: CGRect, to bounds: CGRect) -> CGRect {
        let r = selection.standardized
        let minX = max(bounds.minX, min(bounds.maxX, r.minX.rounded()))
        let minY = max(bounds.minY, min(bounds.maxY, r.minY.rounded()))
        let maxX = max(minX, min(bounds.maxX, r.maxX.rounded()))
        let maxY = max(minY, min(bounds.maxY, r.maxY.rounded()))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// What `selection` makes at `scale` (the window's backing scale, so a 2× screen gives 2 pixels per point whatever
    /// each picture's own scale was). nil when it's too small or no page is under it. Gaps between pages (split panes)
    /// stay transparent.
    public static func plan(selection: CGRect, pages: [Page], scale: CGFloat) -> Plan? {
        let sel = selection.standardized
        guard scale > 0, sel.width >= 1, sel.height >= 1 else { return nil }
        let size = CGSize(width: (sel.width * scale).rounded(), height: (sel.height * scale).rounded())
        var pieces: [Piece] = []
        for (i, p) in pages.enumerated() {
            guard p.frame.width > 0, p.frame.height > 0, p.pixelSize.width >= 1, p.pixelSize.height >= 1 else { continue }
            let part = sel.intersection(p.frame)
            guard !part.isNull, part.width > 0, part.height > 0 else { continue }
            let sx = p.pixelSize.width / p.frame.width, sy = p.pixelSize.height / p.frame.height
            let source = whole(CGRect(x: (part.minX - p.frame.minX) * sx, y: (part.minY - p.frame.minY) * sy,
                                      width: part.width * sx, height: part.height * sy))
                .intersection(CGRect(origin: .zero, size: p.pixelSize))
            let destination = whole(CGRect(x: (part.minX - sel.minX) * scale, y: (part.minY - sel.minY) * scale,
                                           width: part.width * scale, height: part.height * scale))
                .intersection(CGRect(origin: .zero, size: size))
            guard !source.isNull, !destination.isNull, source.width >= 1, source.height >= 1,
                  destination.width >= 1, destination.height >= 1 else { continue }
            pieces.append(Piece(page: i, source: source, destination: destination))
        }
        return pieces.isEmpty ? nil : Plan(pixelSize: size, pieces: pieces)
    }

    /// The pages' union: Space's "the whole visible page".
    public static func fullPage(_ pages: [Page], in bounds: CGRect) -> CGRect? {
        let frames = pages.map(\.frame).filter { $0.width > 0 && $0.height > 0 }
        guard let first = frames.first else { return nil }
        return clamp(frames.dropFirst().reduce(first) { $0.union($1) }, to: bounds)
    }

    /// A rect rounded out to whole units (corners to the nearest, so a 0.5 px rounding doesn't add a column).
    static func whole(_ r: CGRect) -> CGRect {
        let minX = r.minX.rounded(), minY = r.minY.rounded()
        return CGRect(x: minX, y: minY, width: max(0, r.maxX.rounded() - minX), height: max(0, r.maxY.rounded() - minY))
    }

    // MARK: Editing the selection

    /// A selection's grab points: its corners and its edges' middles.
    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Where it is on `r`.
        public func point(on r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: r.minX, y: r.minY)
            case .top: CGPoint(x: r.midX, y: r.minY)
            case .topRight: CGPoint(x: r.maxX, y: r.minY)
            case .right: CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
            case .left: CGPoint(x: r.minX, y: r.midY)
            }
        }
    }

    /// The handle within `slop` points of `p`, corners first.
    public static func handle(at p: CGPoint, on r: CGRect, slop: CGFloat = 6) -> Handle? {
        let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        return order.first { h in
            let q = h.point(on: r)
            return abs(q.x - p.x) <= slop && abs(q.y - p.y) <= slop
        }
    }

    /// `original` with `handle` dragged to `p`: the opposite side stays, dragging past it flips the rect.
    public static func resize(_ original: CGRect, handle: Handle, to p: CGPoint, in bounds: CGRect) -> CGRect {
        var minX = original.minX, minY = original.minY, maxX = original.maxX, maxY = original.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return clamp(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: bounds)
    }

    /// `original` moved by `delta`, whole, kept inside `bounds` (it stops at an edge without shrinking).
    public static func move(_ original: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        var r = original.standardized
        r.origin.x = min(max(bounds.minX, (r.minX + delta.dx).rounded()), max(bounds.minX, bounds.maxX - r.width))
        r.origin.y = min(max(bounds.minY, (r.minY + delta.dy).rounded()), max(bounds.minY, bounds.maxY - r.height))
        return r
    }

    // MARK: Elements (⌘ held)

    /// An overlay point as the page's CSS pixels (its viewport), for `document.elementFromPoint`.
    public static func cssPoint(_ p: CGPoint, in page: CGRect, zoom: Double) -> CGPoint {
        let z = zoom > 0 ? CGFloat(zoom) : 1
        return CGPoint(x: (p.x - page.minX) / z, y: (p.y - page.minY) / z)
    }

    /// An element's `getBoundingClientRect()` (CSS pixels) as overlay points, cut to the page's frame. nil when nothing
    /// of it is on screen.
    public static func elementRect(css: CGRect, in page: CGRect, zoom: Double, bounds: CGRect) -> CGRect? {
        let z = zoom > 0 ? CGFloat(zoom) : 1
        let r = CGRect(x: page.minX + css.minX * z, y: page.minY + css.minY * z, width: css.width * z, height: css.height * z)
            .intersection(page)
        guard !r.isNull else { return nil }
        let c = clamp(r, to: bounds)
        return c.width >= minimumSide && c.height >= minimumSide ? c : nil
    }
}

/// The saved PNG's name: "Capture example.com 2026-11-07 at 10.15.32.png", like macOS's screenshots.
public enum CaptureFileName {
    /// The site part: the host without "www.", or nothing for a page without one (a file, the new tab page).
    public static func site(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // A name Finder shows as typed: no path separators or colons.
        let safe = bare.map { "/:\\".contains($0) ? "-" : String($0) }.joined()
        return safe.isEmpty ? nil : safe
    }

    /// The name for a capture of `url` taken at `date`, with " 2", " 3"… when `exists` says one is there already.
    public static func make(url: URL?, date: Date, timeZone: TimeZone = .current, exists: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = ["Capture", site(of: url), f.string(from: date)].compactMap { $0 }.joined(separator: " ")
        var name = base + ".png"
        var n = 2
        while exists(name), n < 1000 {
            name = "\(base) \(n).png"
            n += 1
        }
        return name
    }
}
