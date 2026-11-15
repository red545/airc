// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Easels (Arc's Easels: "a whiteboard for the internet"; parity N07, docs/user/easels.md). An Easel is a freeform canvas
// document: typed blocks on an endless plane, in points, y down. Each block has a frame, an optional rotation about its
// centre, a stacking order (`z`, higher in front) and an optional group; it holds one kind of content, tagged by `type`:
// text (rich, the same runs a note has), image, shape (rectangle, ellipse), line (an arrow or a plain line between two
// ends), link (a card) and capture (a page's picture, static or live: EaselLive.swift).
//
// The document is versioned JSON (EaselFiles.swift) with its pictures in an assets folder beside it. Additive: a reader
// keeps keys and block kinds it doesn't know (`EaselContent.unknown`, `EaselDocument.extra`) and writes them back
// unchanged, so an older build editing a newer build's Easel moves and deletes those blocks but never loses them.

/// Arc's measures, and the editor's.
public enum EaselMetrics {
    /// How near an edge or centre must come to snap to another's, in screen points (divided by the zoom).
    public static let snapDistance: Double = 6
    /// Arrow keys move the selection this far, in points (⇧: `bigNudge`).
    public static let nudge: Double = 1
    public static let bigNudge: Double = 10
    /// The smallest a block gets while resizing, in points.
    public static let minimumSide: Double = 8
    /// Zoom limits (⌘-, ⌘+, pinch).
    public static let minimumZoom: Double = 0.1
    public static let maximumZoom: Double = 8
    /// Where pasted and duplicated copies land, from their originals.
    public static let copyOffset: Double = 20
}

// MARK: - Colours and type

public enum EaselPalette: String, Codable, Sendable, CaseIterable {
    case chill, vibrant
}

/// Arc's eleven named colours.
public enum EaselColor: String, Codable, Sendable, CaseIterable {
    case black, gray, white, pink, red, yellow, lightGreen, darkGreen, lightBlue, darkBlue, purple

    /// Its value as #RRGGBB (or #RRGGBBAA): Arc's per palette, in light or dark appearance. White's stroke is a 10 % line.
    public func hex(_ palette: EaselPalette, dark: Bool, stroke: Bool = false) -> String {
        if stroke, self == .white { return dark ? "#FFFFFF1A" : "#0000001A" }
        switch self {
        case .black: return dark ? "#FFFFFF" : "#000000"
        case .white: return dark ? "#000000" : "#FFFFFF"
        case .gray: return "#BBBBBB"
        case .darkBlue: return "#3139FB"
        default: break
        }
        let chill: [EaselColor: String] = [.pink: "#F2C2AC", .red: "#D74807", .yellow: "#C2A12A", .lightGreen: "#D0D87F",
                                           .darkGreen: "#1D5914", .lightBlue: "#55A2BD", .purple: "#A6729D"]
        let vibrant: [EaselColor: String] = [.pink: "#FF994E", .red: "#F53714", .yellow: "#FFD335", .lightGreen: "#34E895",
                                             .darkGreen: "#107A00", .lightBlue: "#00C7F3", .purple: "#C0009F"]
        return (palette == .chill ? chill : vibrant)[self] ?? "#000000"
    }

    public var displayName: String {
        switch self {
        case .lightGreen: "Light Green"
        case .darkGreen: "Dark Green"
        case .lightBlue: "Light Blue"
        case .darkBlue: "Dark Blue"
        default: rawValue.capitalized
        }
    }
}

/// An Easel's background, light and dark (Arc's).
public enum EaselBackground {
    public static let light = "#FEFDFE"
    public static let dark = "#201F2E"
}

/// Arc's four type families.
public enum EaselFont: String, Codable, Sendable, CaseIterable {
    /// The system font (the default).
    case clean
    case mono
    /// A serif.
    case fancy
    /// A wide grotesque (the system font, expanded, here).
    case hip
}

public enum EaselAlignment: String, Codable, Sendable, CaseIterable {
    case left, center, right
}

// MARK: - Geometry

public struct EaselPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public func offsetBy(dx: Double, dy: Double) -> EaselPoint { EaselPoint(x + dx, y + dy) }
}

/// A frame in points on the Easel's plane (y down).
public struct EaselRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The box two points span, either way round.
    public init(spanning a: EaselPoint, _ b: EaselPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public var minX: Double { x }
    public var midX: Double { x + width / 2 }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var midY: Double { y + height / 2 }
    public var maxY: Double { y + height }
    public var center: EaselPoint { EaselPoint(midX, midY) }

    public func offsetBy(dx: Double, dy: Double) -> EaselRect { EaselRect(x: x + dx, y: y + dy, width: width, height: height) }

    public func union(_ o: EaselRect) -> EaselRect {
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return EaselRect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    public func intersects(_ o: EaselRect) -> Bool { minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY }

    public func contains(_ p: EaselPoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }

    public func insetBy(_ d: Double) -> EaselRect { EaselRect(x: x + d, y: y + d, width: max(0, width - 2 * d), height: max(0, height - 2 * d)) }

    /// `p` in this box mapped to the same place in `to` (resizing a selection maps every block's corners this way).
    public func map(_ p: EaselPoint, to: EaselRect) -> EaselPoint {
        let fx = width == 0 ? 0 : (p.x - x) / width, fy = height == 0 ? 0 : (p.y - y) / height
        return EaselPoint(to.x + fx * to.width, to.y + fy * to.height)
    }

    /// The bounding box of this rect turned by `angle` radians about its centre.
    public func rotatedBounds(_ angle: Double) -> EaselRect {
        guard angle != 0 else { return self }
        let c = cos(angle), s = sin(angle)
        let w = abs(width * c) + abs(height * s), h = abs(width * s) + abs(height * c)
        return EaselRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// Every value finite (a damaged file can say anything).
    public var isFinite: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0 }
}

// MARK: - Content

/// Rich text: the runs and lines a note has (Notes.swift's NoteDocument: bold, italic, underline, strikethrough, code,
/// links, headings, lists), drawn in an Easel family at a size and colour of its own.
public struct EaselText: Codable, Hashable, Sendable {
    public var text: NoteDocument
    public var font: EaselFont
    /// The body text's size in points; headings scale with it.
    public var size: Double
    /// nil: the Easel's text colour (black, or white on a dark Easel).
    public var color: EaselColor?
    public var alignment: EaselAlignment

    public static let defaultSize: Double = 17

    public init(_ text: NoteDocument = NoteDocument(blocks: [NoteBlock(kind: .paragraph)]), font: EaselFont = .clean,
                size: Double = EaselText.defaultSize, color: EaselColor? = nil, alignment: EaselAlignment = .left) {
        self.text = text
        self.font = font
        self.size = size
        self.color = color
        self.alignment = alignment
    }

    /// Plain lines as paragraphs.
    public init(plain: String, font: EaselFont = .clean, size: Double = EaselText.defaultSize) {
        let lines = plain.components(separatedBy: .newlines)
        self.init(NoteDocument(blocks: lines.map { NoteBlock(kind: .paragraph, runs: $0.isEmpty ? [] : [NoteRun($0)]) }), font: font, size: size)
    }

    public var plainText: String { text.plainText }

    private enum CodingKeys: String, CodingKey { case text, font, size, color, alignment }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(NoteDocument.self, forKey: .text)) ?? NoteDocument(blocks: [NoteBlock(kind: .paragraph)])
        font = (try? c.decodeIfPresent(EaselFont.self, forKey: .font)) ?? .clean
        let s = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? Self.defaultSize
        size = s.isFinite ? min(400, max(4, s)) : Self.defaultSize
        color = try? c.decodeIfPresent(EaselColor.self, forKey: .color)
        alignment = (try? c.decodeIfPresent(EaselAlignment.self, forKey: .alignment)) ?? .left
    }
}

/// A picture: a file in the Easel's assets folder, named by its bytes.
public struct EaselImage: Codable, Hashable, Sendable {
    public var asset: String
    /// Its size in pixels, as it came.
    public var pixelWidth: Double
    public var pixelHeight: Double
    /// Where it came from (the page it was dragged or copied from), when known.
    public var source: String?
    public var altText: String?

    public init(asset: String, pixelWidth: Double, pixelHeight: Double, source: String? = nil, altText: String? = nil) {
        self.asset = asset
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
        self.altText = altText
    }

    public var aspect: Double { pixelWidth > 0 && pixelHeight > 0 ? pixelHeight / pixelWidth : 1 }
}

public struct EaselShape: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case rectangle, ellipse }

    public var kind: Kind
    /// nil: no fill.
    public var fill: EaselColor?
    /// nil: no outline.
    public var stroke: EaselColor?
    public var strokeWidth: Double
    /// A rectangle's corners, in points.
    public var cornerRadius: Double

    public init(_ kind: Kind, fill: EaselColor? = nil, stroke: EaselColor? = nil, strokeWidth: Double = 2.5, cornerRadius: Double = 0) {
        self.kind = kind
        self.fill = fill ?? (stroke == nil ? (kind == .rectangle ? .lightGreen : .red) : nil)
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.cornerRadius = cornerRadius
    }

    private enum CodingKeys: String, CodingKey { case kind, fill, stroke, strokeWidth, cornerRadius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .rectangle
        fill = try? c.decodeIfPresent(EaselColor.self, forKey: .fill)
        stroke = try? c.decodeIfPresent(EaselColor.self, forKey: .stroke)
        strokeWidth = (try? c.decodeIfPresent(Double.self, forKey: .strokeWidth)) ?? 2.5
        cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? 0
    }
}

/// A line between two ends, in the Easel's points: an arrow when either end has a head.
public struct EaselLine: Codable, Hashable, Sendable {
    public var from: EaselPoint
    public var to: EaselPoint
    public var startHead: Bool
    public var endHead: Bool
    public var color: EaselColor
    public var width: Double

    public init(from: EaselPoint, to: EaselPoint, startHead: Bool = false, endHead: Bool = true, color: EaselColor = .lightBlue,
                width: Double = 3) {
        self.from = from
        self.to = to
        self.startHead = startHead
        self.endHead = endHead
        self.color = color
        self.width = width
    }

    public var bounds: EaselRect { EaselRect(spanning: from, to) }
    public var isArrow: Bool { startHead || endHead }
    public var length: Double { hypot(to.x - from.x, to.y - from.y) }

    private enum CodingKeys: String, CodingKey { case from, to, startHead, endHead, color, width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(EaselPoint.self, forKey: .from)
        to = try c.decode(EaselPoint.self, forKey: .to)
        startHead = (try? c.decodeIfPresent(Bool.self, forKey: .startHead)) ?? false
        endHead = (try? c.decodeIfPresent(Bool.self, forKey: .endHead)) ?? true
        color = (try? c.decodeIfPresent(EaselColor.self, forKey: .color)) ?? .lightBlue
        width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? 3
    }
}

/// An address as a card (Arc's link card: its picture | title, description, host).
public struct EaselLink: Codable, Hashable, Sendable {
    public var url: String
    public var title: String?
    public var detail: String?
    /// The card's picture (an asset), when one was saved.
    public var image: String?

    public init(url: String, title: String? = nil, detail: String? = nil, image: String? = nil) {
        self.url = url
        self.title = title
        self.detail = detail
        self.image = image
    }

    /// The card's host line ("example.com").
    public var host: String {
        let h = URL(string: url)?.host ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static let defaultSize = (width: 320.0, height: 96.0)
}

/// A Capture on an Easel: the picture of part of a page, with the page's address and title. With `live` (P19b,
/// EaselLive.swift) it can be taken again from the page; without, it's a static picture.
public struct EaselCapture: Codable, Hashable, Sendable {
    public var asset: String
    public var pixelWidth: Double
    public var pixelHeight: Double
    public var url: String?
    public var title: String?
    public var capturedAt: Date?
    /// Where the picture comes from, for Refresh and Live; nil: static (never captured live, or detached).
    public var live: EaselLiveSource?

    public init(asset: String, pixelWidth: Double, pixelHeight: Double, url: String? = nil, title: String? = nil, capturedAt: Date? = nil,
                live: EaselLiveSource? = nil) {
        self.asset = asset
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.url = url
        self.title = title
        self.capturedAt = capturedAt
        self.live = live
    }

    public var aspect: Double { pixelWidth > 0 && pixelHeight > 0 ? pixelHeight / pixelWidth : 1 }

    private enum CodingKeys: String, CodingKey { case asset, pixelWidth, pixelHeight, url, title, capturedAt, live }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decode(String.self, forKey: .asset)
        pixelWidth = try c.decode(Double.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Double.self, forKey: .pixelHeight)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        capturedAt = try? c.decodeIfPresent(Date.self, forKey: .capturedAt)
        // A source that doesn't read (or makes no sense) leaves a static picture, never a lost block.
        live = (try? c.decodeIfPresent(EaselLiveSource.self, forKey: .live)).flatMap { $0?.isValid == true ? $0 : nil }
    }
}

/// A JSON value kept as it was read (content of a kind this build doesn't know, keys it doesn't know).
public indirect enum EaselJSON: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([EaselJSON]), object([String: EaselJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([EaselJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: EaselJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// What a block holds, tagged by `type`.
public enum EaselContent: Hashable, Sendable {
    case text(EaselText)
    case image(EaselImage)
    case shape(EaselShape)
    case line(EaselLine)
    case link(EaselLink)
    case capture(EaselCapture)
    /// A kind a newer build wrote: kept as it was, drawn as a grey box, written back unchanged.
    case unknown(type: String, fields: [String: EaselJSON])

    public var type: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .shape: "shape"
        case .line: "line"
        case .link: "link"
        case .capture: "capture"
        case .unknown(let t, _): t
        }
    }

    /// The asset files it shows.
    public var assets: [String] {
        switch self {
        case .image(let i): [i.asset]
        case .link(let l): l.image.map { [$0] } ?? []
        case .capture(let c): [c.asset]
        default: []
        }
    }

    public var isLine: Bool { if case .line = self { return true }; return false }
}

extension EaselContent: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let type = Key(stringValue: "type")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "text": self = .text(try EaselText(from: decoder))
        case "image": self = .image(try EaselImage(from: decoder))
        case "shape": self = .shape(try EaselShape(from: decoder))
        case "line": self = .line(try EaselLine(from: decoder))
        case "link": self = .link(try EaselLink(from: decoder))
        case "capture": self = .capture(try EaselCapture(from: decoder))
        default:
            var fields: [String: EaselJSON] = [:]
            for k in c.allKeys where k.stringValue != "type" { fields[k.stringValue] = try c.decode(EaselJSON.self, forKey: k) }
            self = .unknown(type: type, fields: fields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .text(let v): try v.encode(to: encoder)
        case .image(let v): try v.encode(to: encoder)
        case .shape(let v): try v.encode(to: encoder)
        case .line(let v): try v.encode(to: encoder)
        case .link(let v): try v.encode(to: encoder)
        case .capture(let v): try v.encode(to: encoder)
        case .unknown(_, let fields): for (k, v) in fields { try c.encode(v, forKey: Key(stringValue: k)) }
        }
    }
}

// MARK: - Blocks

public struct EaselBlock: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Where it is, unrotated. A line's frame is the box its ends span (kept by `setLine`).
    public var frame: EaselRect
    /// Radians, clockwise on screen, about the frame's centre. Lines never rotate (their ends say where they go).
    public var rotation: Double
    /// Stacking: higher is in front.
    public var z: Double
    /// Blocks with the same group select, move and resize together (⌘G; ⇧⌘G ungroups).
    public var group: String?
    public var content: EaselContent

    public init(id: String = newID(), frame: EaselRect, rotation: Double = 0, z: Double = 0, group: String? = nil, content: EaselContent) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.z = z
        self.group = group
        self.content = content
        if case .line(let l) = content { self.frame = l.bounds; self.rotation = 0 }
    }

    private enum CodingKeys: String, CodingKey { case id, frame, rotation, z, group, content }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        frame = try c.decode(EaselRect.self, forKey: .frame)
        guard frame.isFinite else { throw DecodingError.dataCorruptedError(forKey: .frame, in: c, debugDescription: "frame isn't finite") }
        let r = (try? c.decodeIfPresent(Double.self, forKey: .rotation)) ?? 0
        rotation = r.isFinite ? r : 0
        z = (try? c.decodeIfPresent(Double.self, forKey: .z)) ?? 0
        group = try? c.decodeIfPresent(String.self, forKey: .group)
        content = try c.decode(EaselContent.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(frame, forKey: .frame)
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        try c.encode(z, forKey: .z)
        try c.encodeIfPresent(group, forKey: .group)
        try c.encode(content, forKey: .content)
    }

    /// The box it covers on the plane (its rotated frame's bounds).
    public var bounds: EaselRect { frame.rotatedBounds(rotation) }

    public var line: EaselLine? { if case .line(let l) = content { return l }; return nil }

    /// A line's new ends; its frame follows.
    public mutating func setLine(_ l: EaselLine) {
        content = .line(l)
        frame = l.bounds
        rotation = 0
    }

    /// Moved by (dx, dy) points.
    public func offsetBy(dx: Double, dy: Double) -> EaselBlock {
        var b = self
        b.frame = frame.offsetBy(dx: dx, dy: dy)
        if var l = line {
            l.from = l.from.offsetBy(dx: dx, dy: dy)
            l.to = l.to.offsetBy(dx: dx, dy: dy)
            b.content = .line(l)
        }
        return b
    }

    /// Resizing a selection from box `from` to box `to`: the block's frame (or a line's ends) mapped from one to the other.
    public func mapped(from: EaselRect, to: EaselRect) -> EaselBlock {
        var b = self
        if var l = line {
            l.from = from.map(l.from, to: to)
            l.to = from.map(l.to, to: to)
            b.setLine(l)
            return b
        }
        let a = from.map(EaselPoint(frame.minX, frame.minY), to: to), z = from.map(EaselPoint(frame.maxX, frame.maxY), to: to)
        b.frame = EaselRect(spanning: a, z)
        return b
    }

    /// Whether `p` (on the plane) is on it: inside its turned frame, or within `slop` points of a line.
    public func hit(_ p: EaselPoint, slop: Double = 4) -> Bool {
        if let l = line { return EaselGeometry.distance(p, segment: l.from, l.to) <= max(slop, l.width / 2 + 2) }
        let q = EaselGeometry.rotate(p, about: frame.center, by: -rotation)
        return frame.insetBy(-slop / 4).contains(q)
    }
}

public enum EaselGeometry {
    public static func rotate(_ p: EaselPoint, about c: EaselPoint, by angle: Double) -> EaselPoint {
        guard angle != 0 else { return p }
        let s = sin(angle), co = cos(angle), dx = p.x - c.x, dy = p.y - c.y
        return EaselPoint(c.x + dx * co - dy * s, c.y + dx * s + dy * co)
    }

    public static func distance(_ p: EaselPoint, segment a: EaselPoint, _ b: EaselPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Where the editor looked last: the plane point at the view's centre, and the zoom.
public struct EaselViewport: Codable, Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var zoom: Double

    public init(centerX: Double = 0, centerY: Double = 0, zoom: Double = 1) {
        self.centerX = centerX
        self.centerY = centerY
        self.zoom = zoom
    }
}

// MARK: - The document

public struct EaselDocument: Codable, Hashable, Sendable {
    /// The format this build writes. A document with a higher one still opens; what this build doesn't know is kept.
    public static let currentFormat = 1

    public var formatVersion: Int
    public var id: String
    /// What the person named it; empty: `EaselURL.untitled`.
    public var title: String
    public var palette: EaselPalette
    public var blocks: [EaselBlock]
    public var viewport: EaselViewport?
    public var createdAt: Date
    public var updatedAt: Date
    /// A new value at every save; the undo history saved beside the document names the one it belongs to.
    public var revision: String
    /// Top-level keys a newer build wrote, kept.
    public var extra: [String: EaselJSON]

    public init(id: String = newID(), title: String = "", palette: EaselPalette = .chill, blocks: [EaselBlock] = [],
                createdAt: Date = Date()) {
        formatVersion = Self.currentFormat
        self.id = id
        self.title = title
        self.palette = palette
        self.blocks = blocks
        viewport = nil
        self.createdAt = createdAt
        updatedAt = createdAt
        revision = newID()
        extra = [:]
    }

    public static let maxTitleLength = 120

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? EaselURL.untitled : String(t.prefix(Self.maxTitleLength))
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static let knownKeys: Set<String> = ["formatVersion", "id", "title", "palette", "blocks", "viewport", "createdAt", "updatedAt", "revision"]

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, lenient: false, skipped: nil)
    }

    /// `lenient`: blocks that don't decode are left out and described in `skipped` (recovery, EaselFiles).
    init(from decoder: Decoder, lenient: Bool, skipped: ((Int, String?, String) -> Void)?) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func key(_ s: String) -> Key { Key(stringValue: s) }
        formatVersion = (try? c.decodeIfPresent(Int.self, forKey: key("formatVersion"))) ?? 1
        id = (try? c.decodeIfPresent(String.self, forKey: key("id"))) ?? newID()
        title = (try? c.decodeIfPresent(String.self, forKey: key("title"))) ?? ""
        palette = (try? c.decodeIfPresent(EaselPalette.self, forKey: key("palette"))) ?? .chill
        viewport = try? c.decodeIfPresent(EaselViewport.self, forKey: key("viewport"))
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: key("createdAt"))) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: key("updatedAt"))) ?? createdAt
        revision = (try? c.decodeIfPresent(String.self, forKey: key("revision"))) ?? ""
        if lenient {
            var out: [EaselBlock] = []
            if var list = try? c.nestedUnkeyedContainer(forKey: key("blocks")) {
                var i = 0
                while !list.isAtEnd {
                    if let b = try? list.decode(EaselBlock.self) {
                        out.append(b)
                    } else {
                        // What it was, as far as it reads: its id and the reason.
                        let raw = try? list.decode(EaselJSON.self)
                        var id: String?
                        if case .object(let o)? = raw, case .string(let s)? = o["id"] { id = s }
                        skipped?(i, id, raw == nil ? "unreadable" : "doesn't decode as a block")
                        if raw == nil { break }
                    }
                    i += 1
                }
            }
            blocks = out
        } else {
            blocks = try c.decodeIfPresent([EaselBlock].self, forKey: key("blocks")) ?? []
        }
        var extra: [String: EaselJSON] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            if let v = try? c.decode(EaselJSON.self, forKey: k) { extra[k.stringValue] = v }
        }
        self.extra = extra
        // Two blocks with one id would make every edit ambiguous: later copies get new ids.
        var seen = Set<String>()
        for i in blocks.indices where !seen.insert(blocks[i].id).inserted { blocks[i].id = newID() }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, v) in extra where !Self.knownKeys.contains(k) { try c.encode(v, forKey: Key(stringValue: k)) }
        // A newer document keeps its mark: this build only adds what it knows.
        try c.encode(max(formatVersion, Self.currentFormat), forKey: Key(stringValue: "formatVersion"))
        try c.encode(id, forKey: Key(stringValue: "id"))
        try c.encode(title, forKey: Key(stringValue: "title"))
        try c.encode(palette, forKey: Key(stringValue: "palette"))
        try c.encode(blocks, forKey: Key(stringValue: "blocks"))
        try c.encodeIfPresent(viewport, forKey: Key(stringValue: "viewport"))
        try c.encode(createdAt, forKey: Key(stringValue: "createdAt"))
        try c.encode(updatedAt, forKey: Key(stringValue: "updatedAt"))
        try c.encode(revision, forKey: Key(stringValue: "revision"))
    }

    public var isEmpty: Bool { blocks.isEmpty }

    /// The blocks back to front.
    public var stacked: [EaselBlock] { blocks.sorted { ($0.z, $0.id) < ($1.z, $1.id) } }

    public func block(_ id: String) -> EaselBlock? { blocks.first { $0.id == id } }

    public func index(_ id: String) -> Int? { blocks.firstIndex { $0.id == id } }

    /// The box every block covers; nil for an empty Easel.
    public var contentBounds: EaselRect? { blocks.map(\.bounds).reduce(nil as EaselRect?) { $0?.union($1) ?? $1 } }

    public var assets: Set<String> { Set(blocks.flatMap(\.content.assets)) }

    /// The text of its text blocks, top to bottom, then left to right (search; Library).
    public var plainText: String {
        blocks.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }.compactMap {
            if case .text(let t) = $0.content { return t.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The topmost block at `p`.
    public func hit(_ p: EaselPoint, slop: Double = 4) -> EaselBlock? { stacked.reversed().first { $0.hit(p, slop: slop) } }

    /// The blocks a marquee touches.
    public func blocks(in r: EaselRect) -> [EaselBlock] { blocks.filter { $0.bounds.intersects(r) } }

    // MARK: Groups

    /// `ids` with every block that shares a group with one of them (a click on one member selects the group).
    public func expandingGroups(_ ids: Set<String>) -> Set<String> {
        let groups = Set(blocks.filter { ids.contains($0.id) }.compactMap(\.group))
        guard !groups.isEmpty else { return ids }
        return ids.union(blocks.filter { $0.group.map(groups.contains) == true }.map(\.id))
    }

    /// ⌘G: one group of `ids` (groups among them merge into it). Its id, or nil for fewer than two blocks.
    @discardableResult
    public mutating func group(_ ids: Set<String>) -> String? {
        let all = expandingGroups(ids)
        guard all.count >= 2 else { return nil }
        let g = newID()
        for i in blocks.indices where all.contains(blocks[i].id) { blocks[i].group = g }
        return g
    }

    /// ⇧⌘G: the groups among `ids` let go.
    public mutating func ungroup(_ ids: Set<String>) {
        let all = expandingGroups(ids)
        for i in blocks.indices where all.contains(blocks[i].id) { blocks[i].group = nil }
    }

    // MARK: Editing

    public var topZ: Double { blocks.map(\.z).max() ?? 0 }

    /// Adds `b` in front of everything.
    public mutating func add(_ b: EaselBlock) {
        var b = b
        b.z = topZ + 1
        blocks.append(b)
    }

    public mutating func update(_ id: String, _ change: (inout EaselBlock) -> Void) {
        guard let i = index(id) else { return }
        change(&blocks[i])
    }

    public mutating func remove(_ ids: Set<String>) { blocks.removeAll { ids.contains($0.id) } }

    /// Bring to Front / Send to Back, keeping the order among the moved blocks.
    public mutating func bringToFront(_ ids: Set<String>) {
        var top = blocks.filter { !ids.contains($0.id) }.map(\.z).max() ?? 0
        for b in stacked where ids.contains(b.id) {
            top += 1
            update(b.id) { $0.z = top }
        }
    }

    public mutating func sendToBack(_ ids: Set<String>) {
        var bottom = blocks.filter { !ids.contains($0.id) }.map(\.z).min() ?? 0
        for b in stacked.reversed() where ids.contains(b.id) {
            bottom -= 1
            update(b.id) { $0.z = bottom }
        }
    }

    /// Bring Forward / Send Backward: past the next block above (below) that overlaps, one step.
    public mutating func bringForward(_ ids: Set<String>) { step(ids, up: true) }
    public mutating func sendBackward(_ ids: Set<String>) { step(ids, up: false) }

    private mutating func step(_ ids: Set<String>, up: Bool) {
        let moving = blocks.filter { ids.contains($0.id) }
        guard let box = moving.map(\.bounds).reduce(nil as EaselRect?, { $0?.union($1) ?? $1 }) else { return }
        let others = stacked.filter { !ids.contains($0.id) && $0.bounds.intersects(box) }
        let edge = up ? moving.map(\.z).max()! : moving.map(\.z).min()!
        guard let pass = up ? others.first(where: { $0.z > edge }) : others.last(where: { $0.z < edge }) else {
            return up ? bringToFront(ids) : sendToBack(ids)
        }
        // Renumber: the moved blocks just past `pass`, everything else in its order.
        var order = stacked.filter { !ids.contains($0.id) }.map(\.id)
        let at = order.firstIndex(of: pass.id)! + (up ? 1 : 0)
        order.insert(contentsOf: stacked.filter { ids.contains($0.id) }.map(\.id), at: at)
        for (n, id) in order.enumerated() { update(id) { $0.z = Double(n + 1) } }
    }

    /// Moves blocks by points.
    public mutating func move(_ ids: Set<String>, dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        for i in blocks.indices where ids.contains(blocks[i].id) { blocks[i] = blocks[i].offsetBy(dx: dx, dy: dy) }
    }

    /// Copies of blocks (Duplicate, Paste): new ids, offset, in front, in their order, their groups new groups.
    @discardableResult
    public mutating func duplicate(_ ids: Set<String>, offset: Double = EaselMetrics.copyOffset) -> [String] {
        insert(copies: stacked.filter { ids.contains($0.id) }, offset: offset)
    }

    /// Pasted blocks (from this Easel or another): new ids and groups, offset, in front. Their ids, in order.
    @discardableResult
    public mutating func insert(copies: [EaselBlock], offset: Double) -> [String] {
        var groups: [String: String] = [:]
        var made: [String] = []
        var z = topZ
        for var c in copies.sorted(by: { ($0.z, $0.id) < ($1.z, $1.id) }) {
            c.id = newID()
            c = c.offsetBy(dx: offset, dy: offset)
            if let g = c.group {
                if groups[g] == nil { groups[g] = newID() }
                c.group = groups[g]
            }
            z += 1
            c.z = z
            blocks.append(c)
            made.append(c.id)
        }
        return made
    }

    /// The selection's box resized: every block in `ids` maps from `from` to `to`.
    public mutating func resize(_ ids: Set<String>, from: EaselRect, to: EaselRect) {
        for i in blocks.indices where ids.contains(blocks[i].id) { blocks[i] = blocks[i].mapped(from: from, to: to) }
    }

    /// Turns blocks about the selection's centre by `angle` radians (lines turn their ends).
    public mutating func rotate(_ ids: Set<String>, by angle: Double, about c: EaselPoint) {
        for i in blocks.indices where ids.contains(blocks[i].id) {
            if var l = blocks[i].line {
                l.from = EaselGeometry.rotate(l.from, about: c, by: angle)
                l.to = EaselGeometry.rotate(l.to, about: c, by: angle)
                blocks[i].setLine(l)
            } else {
                let m = EaselGeometry.rotate(blocks[i].frame.center, about: c, by: angle)
                blocks[i].frame = blocks[i].frame.offsetBy(dx: m.x - blocks[i].frame.midX, dy: m.y - blocks[i].frame.midY)
                var r = (blocks[i].rotation + angle).truncatingRemainder(dividingBy: 2 * .pi)
                if abs(r) < 1e-9 { r = 0 }
                blocks[i].rotation = r
            }
        }
    }
}

// MARK: - Snapping

/// Snap guides: a moving box's left, centre and right snap to other blocks' (and their top, middle and bottom to theirs)
/// within a distance, and the guides it snapped to are shown.
public enum EaselSnapping {
    public struct Guide: Hashable, Sendable {
        public enum Axis: Sendable { case vertical, horizontal }
        public var axis: Axis
        /// Where the line is, in points on the plane.
        public var at: Double
        /// The span the guide is drawn over (both boxes).
        public var from: Double
        public var to: Double
    }

    public struct Result: Hashable, Sendable {
        /// What to add to the box, in points.
        public var dx: Double
        public var dy: Double
        public var guides: [Guide]
    }

    /// `distance` in points on the plane (the editor divides its screen distance by the zoom).
    public static func snap(_ box: EaselRect, to others: [EaselRect], distance d: Double) -> Result {
        func best(_ mine: [Double], _ theirs: [(Double, EaselRect)]) -> (Double, Double, EaselRect)? {
            var found: (Double, Double, EaselRect)?
            for m in mine {
                for (t, r) in theirs where abs(t - m) <= d && abs(t - m) < abs(found?.0 ?? .infinity) { found = (t - m, t, r) }
            }
            return found
        }
        let xs = others.flatMap { r in [(r.minX, r), (r.midX, r), (r.maxX, r)] }
        let ys = others.flatMap { r in [(r.minY, r), (r.midY, r), (r.maxY, r)] }
        let sx = best([box.minX, box.midX, box.maxX], xs)
        let sy = best([box.minY, box.midY, box.maxY], ys)
        var guides: [Guide] = []
        let moved = box.offsetBy(dx: sx?.0 ?? 0, dy: sy?.0 ?? 0)
        if let sx { guides.append(Guide(axis: .vertical, at: sx.1, from: min(moved.minY, sx.2.minY), to: max(moved.maxY, sx.2.maxY))) }
        if let sy { guides.append(Guide(axis: .horizontal, at: sy.1, from: min(moved.minX, sy.2.minX), to: max(moved.maxX, sy.2.maxX))) }
        return Result(dx: sx?.0 ?? 0, dy: sy?.0 ?? 0, guides: guides)
    }

    /// Resizing: the moving edges (`left`/`right`/`top`/`bottom` true for the ones the handle drags) snap to other
    /// blocks' edges and centres. What to add to each of the box's edges, and the guides.
    public static func snapEdges(_ box: EaselRect, left: Bool, right: Bool, top: Bool, bottom: Bool, to others: [EaselRect],
                                 distance d: Double) -> (box: EaselRect, guides: [Guide]) {
        var b = box
        var guides: [Guide] = []
        func nearest(_ v: Double, _ cands: [(Double, EaselRect)]) -> (Double, EaselRect)? {
            cands.filter { abs($0.0 - v) <= d }.min { abs($0.0 - v) < abs($1.0 - v) }
        }
        let xs = others.flatMap { r in [(r.minX, r), (r.midX, r), (r.maxX, r)] }
        let ys = others.flatMap { r in [(r.minY, r), (r.midY, r), (r.maxY, r)] }
        if left, let (t, r) = nearest(b.minX, xs), b.maxX - t >= EaselMetrics.minimumSide {
            b = EaselRect(x: t, y: b.y, width: b.maxX - t, height: b.height)
            guides.append(Guide(axis: .vertical, at: t, from: min(b.minY, r.minY), to: max(b.maxY, r.maxY)))
        } else if right, let (t, r) = nearest(b.maxX, xs), t - b.minX >= EaselMetrics.minimumSide {
            b.width = t - b.minX
            guides.append(Guide(axis: .vertical, at: t, from: min(b.minY, r.minY), to: max(b.maxY, r.maxY)))
        }
        if top, let (t, r) = nearest(b.minY, ys), b.maxY - t >= EaselMetrics.minimumSide {
            b = EaselRect(x: b.x, y: t, width: b.width, height: b.maxY - t)
            guides.append(Guide(axis: .horizontal, at: t, from: min(b.minX, r.minX), to: max(b.maxX, r.maxX)))
        } else if bottom, let (t, r) = nearest(b.maxY, ys), t - b.minY >= EaselMetrics.minimumSide {
            b.height = t - b.minY
            guides.append(Guide(axis: .horizontal, at: t, from: min(b.minX, r.minX), to: max(b.maxX, r.maxX)))
        }
        return (b, guides)
    }
}
