// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import ImageIO

// P19d: a shared Easel link (aircbrowser.com/e/<id>) added to Airc as a local Easel. Arc offered a shared Easel as a
// shared item in your sidebar, kept live with the original; Airc has no realtime service, so "Add to Airc" makes a copy
// that is the person's own: new ids, no link to the original, and sharing it again makes a new link.
//
// Everything here comes from the network, so it's checked as strictly as the service checks what it takes
// (apps/marketing/src/lib/easel-core.js, `decodeEasel`), all or nothing:
//   - the JSON: at most 1 MB, exactly each kind's keys, finite numbers in range, no control or direction characters,
//     web addresses only (http and https with a host, no user name or password), every picture listed and only those;
//   - each picture: exactly the bytes its name promises (SHA-256 and size), PNG, JPEG, GIF or WebP by its bytes, at most
//     4 MB, 20 MB in all, and a size in pixels that decodes (at most 16,384 on a side, 64 million pixels).
// What it holds becomes plain blocks: text, pictures, shapes, arrows, link cards and Captures (a Capture as its picture,
// never live). Nothing in it runs: there are no scripts in the form, and links open only when the person clicks them.

public enum EaselImport {
    public enum Failure: Error, Equatable, LocalizedError {
        case damaged, tooLarge, unsafeAddress, newerVersion
        /// A picture that isn't the bytes its name promises, or isn't a picture Airc takes.
        case picture

        public var errorDescription: String? {
            switch self {
            case .damaged: "This shared Easel isn’t in a form Airc can read."
            case .tooLarge: "This shared Easel is larger than Airc takes."
            case .unsafeAddress: "This shared Easel has an address that isn’t a web address, so nothing from it was added."
            case .newerVersion: "This Easel was shared by a newer version of Airc. Update Airc to add it."
            case .picture: "A picture on this shared Easel didn’t arrive whole, so nothing from it was added."
            }
        }
    }

    static let titleLimit = 120, textLimit = 20_000, paragraphLimit = 2_000, runLimit = 4_000, labelLimit = 500
    static let coordinateLimit = 1_000_000.0, sideLimit = 100_000.0
    /// Pictures larger than this in pixels are refused before they're decoded.
    public static let maxPixelSide = 16_384
    public static let maxPixels = 64_000_000

    // MARK: The JSON

    /// The shared Easel in `data` (the service's `easel` object), fully checked.
    public static func decode(_ data: Data) throws -> EaselPublic {
        guard data.count <= EaselPublic.maxJSON else { throw Failure.tooLarge }
        guard ShareLink.nestingDepth(data, stopAt: 16) <= 16 else { throw Failure.damaged }
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], top["kind"] as? String == "easel" else {
            throw Failure.damaged
        }
        if let v = top["version"] as? NSNumber, !isBool(v), v.doubleValue > Double(EaselPublic.version) { throw Failure.newerVersion }
        try exact(top, ["kind", "version", "title", "background", "blocks", "assets"])
        guard let version = top["version"] as? NSNumber, !isBool(version), version.doubleValue == Double(EaselPublic.version),
              let rawBlocks = top["blocks"] as? [Any], let rawAssets = top["assets"] as? [Any] else { throw Failure.damaged }
        guard rawBlocks.count <= EaselPublic.maxBlocks, rawAssets.count <= EaselPublic.maxAssets else { throw Failure.tooLarge }
        let blocks = try rawBlocks.map { raw -> EaselPublic.Block in
            let o = try object(raw, ["frame", "content"], ["rotation"])
            let rotation = try o["rotation"].map { try number($0, -2 * .pi, 2 * .pi) }
            return EaselPublic.Block(frame: try frame(o["frame"]), rotation: rotation, content: try content(o["content"]))
        }
        let used = Set(blocks.flatMap(\.content.pictures))
        guard !blocks.isEmpty else { throw Failure.damaged }
        var assets: [EaselPublic.Asset] = [], total = 0
        for raw in rawAssets {
            let o = try object(raw, ["name", "size"])
            guard let name = o["name"] as? String, isAssetName(name), let n = o["size"] as? NSNumber, !isBool(n),
                  n.doubleValue == n.doubleValue.rounded(), n.doubleValue >= 1, n.doubleValue <= Double(EaselPublic.maxAssetBytes),
                  !assets.contains(where: { $0.name == name }) else { throw Failure.damaged }
            total += n.intValue
            guard total <= EaselPublic.maxTotalAssetBytes else { throw Failure.tooLarge }
            assets.append(.init(name: name, size: n.intValue))
        }
        // Every picture a block shows is listed, and only those.
        guard Set(assets.map(\.name)) == used else { throw Failure.damaged }
        return EaselPublic(title: try text(top["title"], titleLimit), background: try hex(top["background"]), blocks: blocks, assets: assets)
    }

    /// The `easel` object of the service's answer (`{ id, createdAt, easel }`).
    public static func decodeAnswer(_ data: Data) throws -> EaselPublic {
        guard data.count <= EaselPublic.maxJSON + 4096, ShareLink.nestingDepth(data, stopAt: 17) <= 17,
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let easel = top["easel"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: easel) else { throw Failure.damaged }
        return try decode(raw)
    }

    static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func exact(_ o: [String: Any], _ required: Set<String>, _ optional: Set<String> = []) throws {
        let k = Set(o.keys)
        guard required.isSubset(of: k), k.isSubset(of: required.union(optional)), !o.values.contains(where: { $0 is NSNull }) else {
            throw Failure.damaged
        }
    }

    static func object(_ v: Any?, _ required: Set<String>, _ optional: Set<String> = []) throws -> [String: Any] {
        guard let o = v as? [String: Any] else { throw Failure.damaged }
        try exact(o, required, optional)
        return o
    }

    static func number(_ v: Any?, _ lo: Double, _ hi: Double) throws -> Double {
        guard let n = v as? NSNumber, !isBool(n) else { throw Failure.damaged }
        let d = n.doubleValue
        guard d.isFinite, d >= lo, d <= hi else { throw Failure.damaged }
        return d
    }

    static func bool(_ v: Any?) throws -> Bool {
        guard let n = v as? NSNumber, isBool(n) else { throw Failure.damaged }
        return n.boolValue
    }

    /// The service's `hasControl`: C0 but tab and newline, DEL, C1, and direction overrides and isolates.
    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            let v = u.value
            return (v < 0x20 && v != 0x09 && v != 0x0A) || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
        }
    }

    /// Text that may be empty, `limit` UTF-16 units at most (JavaScript's length); tabs and newlines only in `lines`.
    static func text(_ v: Any?, _ limit: Int, lines: Bool = false) throws -> String {
        guard let s = v as? String, s.utf16.count <= limit, !hasControl(s), lines || !s.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\t" }) else {
            throw Failure.damaged
        }
        return s
    }

    static func label(_ v: Any?) throws -> String {
        let s = try text(v, labelLimit)
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.damaged }
        return s
    }

    static func hex(_ v: Any?) throws -> String {
        guard let s = v as? String, s.range(of: #"^#[0-9A-F]{6}([0-9A-F]{2})?$"#, options: .regularExpression) != nil else { throw Failure.damaged }
        return s
    }

    /// A web address (absolute http or https with a host, no user name or password); anything else refuses the Easel.
    static func address(_ v: Any?) throws -> String {
        guard let s = v as? String else { throw Failure.damaged }
        guard ShareLink.isSafeAddress(s), !s.contains("\\") else { throw Failure.unsafeAddress }
        return s
    }

    /// The SHA-256 of a picture's bytes and its type.
    public static func isAssetName(_ s: String) -> Bool { s.range(of: #"^[0-9a-f]{64}\.(png|jpg|gif|webp)$"#, options: .regularExpression) != nil }

    static func point(_ v: Any?) throws -> EaselPoint {
        let o = try object(v, ["x", "y"])
        return EaselPoint(try number(o["x"], -coordinateLimit, coordinateLimit), try number(o["y"], -coordinateLimit, coordinateLimit))
    }

    static func frame(_ v: Any?) throws -> EaselRect {
        let o = try object(v, ["x", "y", "width", "height"])
        return EaselRect(x: try number(o["x"], -coordinateLimit, coordinateLimit), y: try number(o["y"], -coordinateLimit, coordinateLimit),
                         width: try number(o["width"], 0, sideLimit), height: try number(o["height"], 0, sideLimit))
    }

    static let marks = ["bold", "italic", "underline", "strike", "code"]

    static func asset(_ a: Any?) throws -> String {
        guard let s = a as? String, isAssetName(s) else { throw Failure.damaged }
        return s
    }

    static func content(_ v: Any?) throws -> EaselPublic.Content {
        guard let o = v as? [String: Any], let type = o["type"] as? String else { throw Failure.damaged }
        var c = EaselPublic.Content(type: type)
        switch type {
        case "text":
            try exact(o, ["type", "paragraphs", "font", "size", "color", "alignment"])
            guard let ps = o["paragraphs"] as? [Any], ps.count <= paragraphLimit,
                  let font = (o["font"] as? String).flatMap(EaselFont.init(rawValue:)),
                  let alignment = (o["alignment"] as? String).flatMap(EaselAlignment.init(rawValue:)) else { throw Failure.damaged }
            var chars = 0, runs = 0
            c.paragraphs = try ps.map { raw in
                let p = try object(raw, ["kind", "runs"], ["indent", "checked"])
                guard let kind = (p["kind"] as? String).flatMap(NoteBlock.Kind.init(rawValue:)), let rs = p["runs"] as? [Any] else { throw Failure.damaged }
                var out = EaselPublic.Paragraph(kind: kind, indent: nil, checked: nil, runs: [])
                if let i = p["indent"] {
                    let n = try number(i, 0, 8)
                    guard n == n.rounded() else { throw Failure.damaged }
                    out.indent = Int(n)
                }
                if let ch = p["checked"] {
                    guard try bool(ch), kind == .checkbox else { throw Failure.damaged }
                    out.checked = true
                }
                for raw in rs {
                    runs += 1
                    guard runs <= runLimit else { throw Failure.tooLarge }
                    let r = try object(raw, ["text"], Set(marks + ["link"]))
                    let t = try text(r["text"], textLimit, lines: true)
                    chars += t.utf16.count
                    guard chars <= textLimit else { throw Failure.tooLarge }
                    var run = EaselPublic.Run(text: t)
                    for m in marks where r[m] != nil {
                        guard try bool(r[m]) else { throw Failure.damaged }
                        switch m {
                        case "bold": run.bold = true
                        case "italic": run.italic = true
                        case "underline": run.underline = true
                        case "strike": run.strike = true
                        default: run.code = true
                        }
                    }
                    if let l = r["link"] { run.link = try address(l) }
                    out.runs.append(run)
                }
                return out
            }
            c.font = font
            c.size = try number(o["size"], 4, 400)
            c.color = try hex(o["color"])
            c.alignment = alignment
        case "image":
            try exact(o, ["type", "asset"], ["alt"])
            c.asset = try asset(o["asset"])
            c.alt = try o["alt"].map { try text($0, labelLimit) }
        case "shape":
            try exact(o, ["type", "kind", "strokeWidth", "cornerRadius"], ["fill", "stroke"])
            guard let kind = (o["kind"] as? String).flatMap(EaselShape.Kind.init(rawValue:)) else { throw Failure.damaged }
            c.kind = kind
            c.fill = try o["fill"].map(hex)
            c.stroke = try o["stroke"].map(hex)
            c.strokeWidth = try number(o["strokeWidth"], 0, 200)
            c.cornerRadius = try number(o["cornerRadius"], 0, sideLimit)
        case "line":
            try exact(o, ["type", "from", "to", "startHead", "endHead", "color", "width"])
            c.from = try point(o["from"])
            c.to = try point(o["to"])
            c.startHead = try bool(o["startHead"])
            c.endHead = try bool(o["endHead"])
            c.color = try hex(o["color"])
            c.width = try number(o["width"], 0.25, 200)
        case "link":
            try exact(o, ["type", "url"], ["title", "detail", "image"])
            c.url = try address(o["url"])
            c.title = try o["title"].map(label)
            c.detail = try o["detail"].map { try text($0, 2 * labelLimit, lines: true) }
            c.image = try o["image"].map(asset)
        case "capture":
            try exact(o, ["type", "asset"], ["url", "title"])
            c.asset = try asset(o["asset"])
            c.url = try o["url"].map(address)
            c.title = try o["title"].map(label)
        default:
            throw Failure.damaged
        }
        return c
    }

    // MARK: Pictures

    /// A picture as it arrived, checked: exactly the bytes `asset` names (size, SHA-256, type by the bytes), and a size
    /// in pixels that ImageIO reads and decodes within the limits. Its size in pixels, or nil.
    public static func checkPicture(_ data: Data, as asset: EaselPublic.Asset) -> (width: Double, height: Double)? {
        guard data.count == asset.size, data.count <= EaselPublic.maxAssetBytes, EaselPublic.pictureName(data) == asset.name else { return nil }
        let types = ["png": "public.png", "jpg": "public.jpeg", "gif": "com.compuserve.gif", "webp": "org.webmproject.webp"]
        guard let ext = asset.name.split(separator: ".").last.map(String.init), let uti = types[ext],
              let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(src) as String? == uti, CGImageSourceGetCount(src) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w >= 1, h >= 1, w <= maxPixelSide, h <= maxPixelSide, w * h <= maxPixels else { return nil }
        // It decodes (a small thumbnail: the whole picture is never drawn here).
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard CGImageSourceCreateThumbnailAtIndex(src, 0, opts) != nil else { return nil }
        // Pixels as stored, as the app's own pictures are measured (EaselCenter.storePicture).
        return (Double(w), Double(h))
    }

    // MARK: Into a local Easel

    /// The palette whose colours `e` uses: the one that names more of its colours exactly (Chill on a tie).
    static func palette(of e: EaselPublic) -> EaselPalette {
        let hexes = e.blocks.flatMap { b in [b.content.color, b.content.fill, b.content.stroke].compactMap { $0 } }
        func score(_ p: EaselPalette) -> Int {
            let known = Set(EaselColor.allCases.flatMap { [$0.hex(p, dark: false), $0.hex(p, dark: false, stroke: true)] })
            return hexes.filter(known.contains).count
        }
        return score(.vibrant) > score(.chill) ? .vibrant : .chill
    }

    /// The named colour nearest `hex` in `palette`'s light look (exact when it was one of them).
    static func color(_ hex: String, _ palette: EaselPalette, stroke: Bool = false) -> EaselColor {
        func rgb(_ s: String) -> (Double, Double, Double, Double) {
            let v = s.dropFirst()
            func at(_ i: Int) -> Double {
                let a = v.index(v.startIndex, offsetBy: i)
                return Double(Int(v[a..<v.index(a, offsetBy: 2)], radix: 16) ?? 0)
            }
            return (at(0), at(2), at(4), v.count == 8 ? at(6) : 255)
        }
        if let exact = EaselColor.allCases.first(where: { $0.hex(palette, dark: false, stroke: stroke) == hex }) { return exact }
        let (r, g, b, a) = rgb(hex)
        return EaselColor.allCases.min { x, y in
            func d(_ c: EaselColor) -> Double {
                let (r2, g2, b2, a2) = rgb(c.hex(palette, dark: false, stroke: stroke))
                return pow(r - r2, 2) + pow(g - g2, 2) + pow(b - b2, 2) + pow(a - a2, 2)
            }
            return d(x) < d(y)
        } ?? .black
    }

    /// The text colour the public form writes for "the Easel's own" (EaselPublic.make).
    static let defaultTextColor = "#141414"

    /// A local Easel with `e`'s blocks under new ids, back to front as they were. `pixels` gives each picture's size in
    /// pixels (from `checkPicture`); asset names stay as they are (both name pictures by the SHA-256 of their bytes).
    public static func document(_ e: EaselPublic, id: String = newID(), now: Date = Date(),
                                pixels: [String: (width: Double, height: Double)]) -> EaselDocument {
        let palette = palette(of: e)
        var doc = EaselDocument(id: id, title: String(e.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EaselDocument.maxTitleLength)),
                                palette: palette, createdAt: now)
        for (i, b) in e.blocks.enumerated() {
            let c = b.content
            let content: EaselContent
            switch c.type {
            case "text":
                let blocks = (c.paragraphs ?? []).map { p in
                    NoteBlock(kind: p.kind, indent: min(p.indent ?? 0, NoteBlock.maxIndent), checked: p.checked ?? false, runs: p.runs.map { r in
                        var m = Set<NoteRun.Mark>()
                        if r.bold == true { m.insert(.bold) }
                        if r.italic == true { m.insert(.italic) }
                        if r.underline == true { m.insert(.underline) }
                        if r.strike == true { m.insert(.strikethrough) }
                        if r.code == true { m.insert(.code) }
                        return NoteRun(r.text, marks: m, link: r.link)
                    })
                }
                let tint = c.color.flatMap { $0 == defaultTextColor ? nil : color($0, palette) }
                content = .text(EaselText(NoteDocument(blocks: blocks.isEmpty ? [NoteBlock(kind: .paragraph)] : blocks), font: c.font ?? .clean,
                                          size: c.size ?? EaselText.defaultSize, color: tint, alignment: c.alignment ?? .left))
            case "image":
                guard let a = c.asset else { continue }
                let p = pixels[a] ?? (b.frame.width, b.frame.height)
                content = .image(EaselImage(asset: a, pixelWidth: p.width, pixelHeight: p.height, altText: c.alt))
            case "shape":
                content = .shape(EaselShape(c.kind ?? .rectangle, fill: c.fill.map { color($0, palette) }, stroke: c.stroke.map { color($0, palette, stroke: true) },
                                            strokeWidth: c.strokeWidth ?? 0, cornerRadius: c.cornerRadius ?? 0))
            case "line":
                guard let from = c.from, let to = c.to else { continue }
                content = .line(EaselLine(from: from, to: to, startHead: c.startHead ?? false, endHead: c.endHead ?? false,
                                          color: c.color.map { color($0, palette) } ?? .lightBlue, width: c.width ?? 3))
            case "link":
                guard let url = c.url else { continue }
                content = .link(EaselLink(url: url, title: c.title, detail: c.detail, image: c.image))
            case "capture":
                guard let a = c.asset else { continue }
                let p = pixels[a] ?? (b.frame.width, b.frame.height)
                content = .capture(EaselCapture(asset: a, pixelWidth: p.width, pixelHeight: p.height, url: c.url, title: c.title))
            default:
                continue
            }
            doc.blocks.append(EaselBlock(frame: b.frame, rotation: b.rotation ?? 0, z: Double(i), content: content))
        }
        doc.updatedAt = now
        return doc
    }

    /// What the import preview says: "12 items · 3 pictures".
    public static func summary(_ e: EaselPublic) -> String {
        let items = e.blocks.count == 1 ? "1 item" : "\(e.blocks.count) items"
        return items + (e.assets.isEmpty ? "" : e.assets.count == 1 ? " · 1 picture" : " · \(e.assets.count) pictures")
    }
}
