// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// P19c (parity N08): File › Export Easel… as HTML. A ZIP holding one folder named after the Easel:
//
//     <Name>/index.html          the board, as aircbrowser.com/e/<id> draws it (EaselHTML), with nothing from the web:
//                                no scripts, fonts or requests; pictures from assets/ beside it, so it opens offline in
//                                any browser, from the unzipped folder
//     <Name>/assets/<sha256>.<ext>   its pictures (PNG, JPEG, GIF, WebP)
//     <Name>/easel.json          the same Easel as data (EaselPublic, the form a link holds)
//
// What goes in is EaselPublic's: no ids, profile, live source, cookies or tokens; addresses cleaned (EaselPublic.webAddress).
// Names are safe on every system (`fileName`). The PNG export and Copy Image are the app's (they draw the blocks).

public enum EaselExport {
    /// A file or folder name for `title`: no path separators, colons, control or direction characters, no leading dot
    /// or trailing dot or space, none of Windows' reserved names, at most 80 characters; "Untitled Easel" for nothing.
    public static func fileName(_ title: String) -> String {
        var s = EaselPublic.clean(title, lines: false)
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { u -> Unicode.Scalar in
            "/\\:*?\"<>|".unicodeScalars.contains(u) ? "-" : u
        }))
        s = s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = String(s.prefix(80)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        if reserved.contains(s.uppercased().split(separator: ".").first.map(String.init) ?? "") { s = "Easel " + s }
        return s.isEmpty ? EaselURL.untitled : s
    }

    /// The HTML export: a ZIP of `<name>/index.html`, `<name>/easel.json` and `<name>/assets/…`. `pictures` holds the
    /// bytes of every name in `easel.assets`; one missing or with other bytes than its name says is an error.
    public static func htmlArchive(_ easel: EaselPublic, pictures: [String: Data], date: Date = Date()) throws -> Data {
        let folder = fileName(easel.title)
        var zip = ZipWriter(date: date)
        zip.add("\(folder)/index.html", Data(EaselHTML.page(easel, asset: { "assets/\($0)" }).utf8))
        zip.add("\(folder)/easel.json", try easel.encoded())
        for a in easel.assets {
            guard let d = pictures[a.name], EaselPublic.pictureName(d) == a.name else { throw ExportError.picture(a.name) }
            zip.add("\(folder)/assets/\(a.name)", d)
        }
        return zip.finish()
    }

    public enum ExportError: Error, Equatable { case picture(String) }
}

// MARK: - HTML

/// An Easel as HTML: the same board aircbrowser.com/e/<id> draws (apps/marketing/api/_lib/easel-page.js), positions as
/// percentages of the board and sizes in container query units of its width, so it scales as one picture would.
public enum EaselHTML {
    public static let margin = 24.0

    static let boardCSS = """
    .easel { position: relative; width: 100%; margin: 24px auto 0; container-type: inline-size; overflow: hidden;
      border-radius: 12px; box-shadow: 0 0 0 1px rgb(20 17 15 / 0.08); }
    .easel .b { position: absolute; box-sizing: border-box; transform-origin: 50% 50%; }
    .easel .tx { overflow: hidden; line-height: 1.3; overflow-wrap: anywhere; }
    .easel .tx p, .easel .tx h1, .easel .tx h2, .easel .tx h3 { margin: 0; font-size: 1em; font-weight: inherit; }
    .easel .tx h1 { font-size: 1.6em; font-weight: 700; } .easel .tx h2 { font-size: 1.3em; font-weight: 650; }
    .easel .tx h3 { font-size: 1.12em; font-weight: 650; } .easel .tx .done { opacity: 0.55; text-decoration: line-through; }
    .easel .tx code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
    .easel .tx a { color: inherit; text-decoration: underline; }
    .easel .f-clean { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    .easel .f-mono { font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, monospace; }
    .easel .f-fancy { font-family: ui-serif, "New York", Georgia, serif; }
    .easel .f-hip { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; font-stretch: 125%; }
    .easel img { display: block; width: 100%; height: 100%; object-fit: cover; }
    .easel .pic { overflow: hidden; box-shadow: 0 0.2cqw 0.8cqw rgb(0 0 0 / 0.14); }
    .easel .lc { display: flex; overflow: hidden; background: #fff; box-shadow: 0 0 0 1px rgb(0 0 0 / 0.1), 0 0.2cqw 0.8cqw rgb(0 0 0 / 0.08);
      color: rgb(20 20 20); font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; text-decoration: none; }
    .easel .lc .ci { flex: none; height: 100%; width: auto; aspect-ratio: 1; object-fit: cover; }
    .easel .lc .cb { display: flex; flex-direction: column; justify-content: center; min-width: 0; }
    .easel .lc .ct { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .easel .lc .cd { opacity: 0.6; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
    .easel .lc .ch { opacity: 0.45; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .easel svg { display: block; width: 100%; height: 100%; overflow: visible; }
    """

    public static let exportNote = "An Easel exported from Airc. Links open in a new tab."
    /// What aircbrowser.com/e/<id> says above the board (the share sheet's preview).
    public static let sharedNote = "A snapshot shared from Airc: later changes don’t reach it. Links open in a new tab."

    /// A whole page that needs nothing else: the title, `note`, and the board.
    public static func page(_ e: EaselPublic, note: String = exportNote, asset: (String) -> String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="Airc">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src * file: data:">
        <meta name="referrer" content="no-referrer">
        <title>\(esc(e.displayTitle))</title>
        <style>
        body { margin: 0; padding: 32px 16px 48px; background: #ebe8e4; color: rgb(20 17 15 / 0.92);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
        main { max-width: 1200px; margin: 0 auto; }
        h1 { margin: 0; font-size: 28px; font-weight: 600; letter-spacing: -0.02em; overflow-wrap: anywhere; }
        .note { margin: 6px 0 0; font-size: 13px; color: rgb(20 17 15 / 0.5); }
        \(boardCSS)
        </style>
        </head>
        <body>
        <main>
        <h1>\(esc(e.displayTitle))</h1>
        <p class="note">\(esc(note))</p>
        \(board(e, asset: asset))
        </main>
        </body>
        </html>

        """
    }

    /// The board's box on the plane: every block's, with a margin.
    public static func bounds(_ e: EaselPublic) -> EaselRect {
        let b = e.blocks.map { $0.frame.rotatedBounds($0.rotation ?? 0) }.reduce(nil as EaselRect?) { $0?.union($1) ?? $1 }
            ?? EaselRect(x: 0, y: 0, width: 1, height: 1)
        return EaselRect(x: b.x - margin, y: b.y - margin, width: max(1, b.width + 2 * margin), height: max(1, b.height + 2 * margin))
    }

    /// The board's HTML; `asset(name)` is a picture's address.
    public static func board(_ e: EaselPublic, asset: (String) -> String) -> String {
        let B = bounds(e)
        func n(_ v: Double) -> String {
            let r = (v * 10000).rounded() / 10000
            return r == r.rounded() && abs(r) < 1e15 ? String(Int(r)) : String(r)
        }
        func cq(_ pt: Double) -> String { "\(n(pt / B.width * 100))cqw" }
        func place(_ f: EaselRect, _ rot: Double = 0) -> String {
            "left:\(n((f.x - B.x) / B.width * 100))%;top:\(n((f.y - B.y) / B.height * 100))%;width:\(n(f.width / B.width * 100))%;" +
                "height:\(n(f.height / B.height * 100))%" + (rot != 0 ? ";transform:rotate(\(n(rot))rad)" : "")
        }
        func link(_ url: String, _ inner: String, _ attrs: String = "") -> String {
            "<a href=\"\(esc(url))\" target=\"_blank\" rel=\"noopener noreferrer nofollow\"\(attrs)>\(inner)</a>"
        }
        var out: [String] = []
        for b in e.blocks {
            let c = b.content, f = b.frame, rot = b.rotation ?? 0
            switch c.type {
            case "text":
                out.append("<div class=\"b tx f-\((c.font ?? .clean).rawValue)\" style=\"\(place(f, rot));font-size:\(cq(c.size ?? 17));padding:\(cq(4));" +
                           "color:\(c.color ?? "#141414");text-align:\((c.alignment ?? .left).rawValue)\">\(paragraphs(c.paragraphs ?? []))</div>")
            case "image":
                out.append("<div class=\"b pic\" style=\"\(place(f, rot));border-radius:\(cq(6))\"><img src=\"\(esc(asset(c.asset ?? "")))\" alt=\"\(esc(c.alt ?? ""))\" loading=\"lazy\"></div>")
            case "capture":
                let img = "<img src=\"\(esc(asset(c.asset ?? "")))\" alt=\"\(esc(c.title ?? "A picture of a page"))\" loading=\"lazy\">"
                out.append("<div class=\"b pic\" style=\"\(place(f, rot));border-radius:\(cq(10))\">\(c.url.map { link($0, img) } ?? img)</div>")
            case "shape":
                let border = c.stroke.map { ";border:\(cq(c.strokeWidth ?? 0)) solid \($0)" } ?? ""
                let radius = c.kind == .ellipse ? "50%" : cq(min(c.cornerRadius ?? 0, f.width / 2, f.height / 2))
                out.append("<div class=\"b\" style=\"\(place(f, rot));background:\(c.fill ?? "transparent");border-radius:\(radius)\(border)\"></div>")
            case "line":
                guard let from = c.from, let to = c.to else { continue }
                let w = c.width ?? 3, color = c.color ?? "#000000", arrow = c.startHead == true || c.endHead == true
                let pad = w / 2 + (arrow ? w * 3 + 6 : 2)
                let box = EaselRect(x: f.x - pad, y: f.y - pad, width: f.width + 2 * pad, height: f.height + 2 * pad)
                func head(_ tip: EaselPoint, _ back: EaselPoint) -> String {
                    let a = atan2(tip.y - back.y, tip.x - back.x), l = w * 3 + 4, s = 0.5
                    let p = [tip, EaselPoint(tip.x - l * cos(a - s), tip.y - l * sin(a - s)), EaselPoint(tip.x - l * cos(a + s), tip.y - l * sin(a + s))]
                    return "<polygon points=\"\(p.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " "))\" fill=\"\(color)\"/>"
                }
                out.append("<div class=\"b\" style=\"\(place(box))\"><svg viewBox=\"\(n(box.x)) \(n(box.y)) \(n(box.width)) \(n(box.height))\" aria-hidden=\"true\">" +
                           "<line x1=\"\(n(from.x))\" y1=\"\(n(from.y))\" x2=\"\(n(to.x))\" y2=\"\(n(to.y))\" stroke=\"\(color)\" stroke-width=\"\(n(w))\" stroke-linecap=\"round\"/>" +
                           (c.endHead == true ? head(to, from) : "") + (c.startHead == true ? head(from, to) : "") + "</svg></div>")
            case "link":
                guard let url = c.url else { continue }
                var host = URL(string: url)?.host ?? url
                if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
                let inner = (c.image.map { "<img class=\"ci\" src=\"\(esc(asset($0)))\" alt=\"\" loading=\"lazy\">" } ?? "") +
                    "<span class=\"cb\" style=\"padding:0 \(cq(14));gap:\(cq(2))\"><span class=\"ct\" style=\"font-size:\(cq(14))\">\(esc(c.title ?? host))</span>" +
                    (c.detail.map { "<span class=\"cd\" style=\"font-size:\(cq(12))\">\(esc($0))</span>" } ?? "") +
                    "<span class=\"ch\" style=\"font-size:\(cq(11.5))\">\(esc(host))</span></span>"
                out.append("<div class=\"b\" style=\"\(place(f, rot))\">\(link(url, inner, " class=\"lc\" style=\"width:100%;height:100%;border-radius:\(cq(12))\""))</div>")
            default:
                continue
            }
        }
        return "<div class=\"easel\" style=\"aspect-ratio:\(n(B.width)) / \(n(B.height));max-width:\(Int(max(B.width, 320).rounded(.up)))px;background:\(e.background)\">\n" +
            out.joined(separator: "\n") + "\n</div>"
    }

    static func run(_ r: EaselPublic.Run) -> String {
        var s = esc(r.text).replacingOccurrences(of: "\n", with: "<br>")
        if r.code == true { s = "<code>\(s)</code>" }
        if r.italic == true { s = "<em>\(s)</em>" }
        if r.bold == true { s = "<strong>\(s)</strong>" }
        if r.underline == true { s = "<u>\(s)</u>" }
        if r.strike == true { s = "<s>\(s)</s>" }
        if let l = r.link { s = "<a href=\"\(esc(l))\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">\(s)</a>" }
        return s
    }

    static func paragraphs(_ ps: [EaselPublic.Paragraph]) -> String {
        var numbers: [Int] = []
        return ps.map { p -> String in
            let joined = p.runs.map(run).joined()
            let inner = joined.isEmpty ? "<br>" : joined
            let indent = p.indent ?? 0
            if p.kind != .numbered { numbers = Array(numbers.prefix(indent)) }
            switch p.kind {
            case .heading1: return "<h1>\(inner)</h1>"
            case .heading2: return "<h2>\(inner)</h2>"
            case .heading3: return "<h3>\(inner)</h3>"
            case .paragraph: return "<p>\(inner)</p>"
            default:
                var mark = "•"
                if p.kind == .numbered {
                    numbers = Array(numbers.prefix(indent + 1))
                    while numbers.count < indent + 1 { numbers.append(0) }
                    numbers[indent] += 1
                    mark = "\(numbers[indent])."
                } else if p.kind == .checkbox {
                    mark = p.checked == true ? "☑" : "☐"
                }
                let pad = (1.3 * Double(indent + 1) * 10000).rounded() / 10000
                return "<p style=\"padding-left:\(pad)em;text-indent:-1.3em\"\(p.checked == true ? " class=\"done\"" : "")>\(mark)&#8194;\(inner)</p>"
            }
        }.joined()
    }

    /// Text for an element or a quoted attribute.
    static func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(ch)
            }
        }
        return o
    }
}

// MARK: - ZIP

/// The headers of a ZIP of stored (uncompressed) entries, for an archive in memory (ZipWriter) or one written to a file
/// as it goes (ZipFileWriter). Pictures are compressed already, and every unzip tool and browser reads stored entries.
/// Names are UTF-8 (flag bit 11), relative, without "..". Past 65,535 entries or 4 GB the archive is ZIP64 (APPNOTE
/// 4.5.3: the offset in an extra field, then the ZIP64 end records); below that its bytes are plain ZIP, as before.
struct ZipLayout {
    private(set) var central = Data()
    private(set) var count = 0
    let time: UInt16, day: UInt16

    init(date: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    /// The local header for an entry at `offset`; its central record is kept for `end`.
    mutating func entry(_ name: String, _ data: Data, at offset: UInt64) -> Data {
        precondition(ZipWriter.isSafeName(name), "unsafe ZIP entry name")
        precondition(data.count < 0xFFFF_FFFF, "a ZIP entry of 4 GB or more")
        let n = Data(name.utf8), crc = CRC32.of(data), far = offset >= 0xFFFF_FFFF
        var h = Data()
        h.le32(0x04034B50); h.le16(far ? 45 : 20); h.le16(0x0800); h.le16(0); h.le16(time); h.le16(day)
        h.le32(crc); h.le32(UInt32(data.count)); h.le32(UInt32(data.count)); h.le16(UInt16(n.count)); h.le16(0)
        var c = Data()
        c.le32(0x02014B50); c.le16(0x031E); c.le16(far ? 45 : 20); c.le16(0x0800); c.le16(0); c.le16(time); c.le16(day)
        c.le32(crc); c.le32(UInt32(data.count)); c.le32(UInt32(data.count)); c.le16(UInt16(n.count)); c.le16(far ? 12 : 0); c.le16(0)
        c.le16(0); c.le16(0); c.le32(UInt32(0o100644) << 16); c.le32(far ? 0xFFFF_FFFF : UInt32(offset))
        c += n
        if far { c.le16(0x0001); c.le16(8); c.le64(offset) }
        central += c
        count += 1
        return h + n
    }

    /// The central directory and the end records, for a directory starting at `offset`.
    func end(at offset: UInt64) -> Data {
        var out = central
        let size = UInt64(central.count)
        let zip64 = count >= 0xFFFF || offset >= 0xFFFF_FFFF || size >= 0xFFFF_FFFF
        if zip64 {
            let record = offset + size
            out.le32(0x06064B50); out.le64(44); out.le16(0x032D); out.le16(45); out.le32(0); out.le32(0)
            out.le64(UInt64(count)); out.le64(UInt64(count)); out.le64(size); out.le64(offset)
            out.le32(0x07064B50); out.le32(0); out.le64(record); out.le32(1)
        }
        let n = UInt16(min(count, 0xFFFF))
        out.le32(0x06054B50); out.le16(0); out.le16(0); out.le16(n); out.le16(n)
        out.le32(UInt32(min(size, 0xFFFF_FFFF))); out.le32(UInt32(min(offset, 0xFFFF_FFFF))); out.le16(0)
        return out
    }
}

/// A ZIP archive of stored entries, in memory (one Easel's export).
public struct ZipWriter {
    private var body = Data()
    private var layout: ZipLayout

    public init(date: Date = Date()) { layout = ZipLayout(date: date) }

    public static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public mutating func add(_ name: String, _ data: Data) {
        body += layout.entry(name, data, at: UInt64(body.count))
        body += data
    }

    public func finish() -> Data { body + layout.end(at: UInt64(body.count)) }
}

/// A ZIP archive of stored entries written to a file as entries come (Export All Easels: only one entry is in memory
/// at a time, however many Easels and pictures there are).
public final class ZipFileWriter {
    private let handle: FileHandle
    private var layout: ZipLayout
    private var offset: UInt64 = 0
    public var entryCount: Int { layout.count }
    /// The bytes written so far.
    public var size: UInt64 { offset }

    /// A new, empty file at `url` (one already there is replaced).
    public init(url: URL, date: Date = Date()) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        layout = ZipLayout(date: date)
    }

    public func add(_ name: String, _ data: Data) throws {
        let h = layout.entry(name, data, at: offset)
        try handle.write(contentsOf: h)
        try handle.write(contentsOf: data)
        offset += UInt64(h.count + data.count)
    }

    /// Writes the directory and closes the file.
    public func finish() throws {
        try handle.write(contentsOf: layout.end(at: offset))
        try handle.close()
    }

    /// Closes the file without finishing it (the caller removes it).
    public func abandon() { try? handle.close() }
}

/// Reads a ZIP of stored entries (ZipWriter's and ZipFileWriter's, ZIP64 included), checking each entry's CRC; nil for
/// anything else.
public enum ZipReader {
    public static func entries(_ d: Data) -> [(name: String, data: Data)]? {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i >= 0 && i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : -1 }
        func u32(_ i: Int) -> Int { i >= 0 && i + 4 <= b.count ? u16(i) | u16(i + 2) << 16 : -1 }
        func u64(_ i: Int) -> Int { i >= 0 && i + 8 <= b.count ? u32(i) | u32(i + 4) << 32 : -1 }
        let eocd = b.count - 22
        guard b.count >= 22, u32(eocd) == 0x06054B50 else { return nil }
        var total = u16(eocd + 10)
        var at = u32(eocd + 16)
        // ZIP64: the locator just before the end record points at the ZIP64 end record.
        if u32(eocd - 20) == 0x07064B50 {
            let record = u64(eocd - 12)
            guard u32(record) == 0x06064B50 else { return nil }
            total = u64(record + 32)
            at = u64(record + 48)
        }
        var out: [(String, Data)] = []
        out.reserveCapacity(max(0, total))
        for _ in 0..<max(0, total) {
            guard u32(at) == 0x02014B50, u16(at + 10) == 0 else { return nil }
            let crc = u32(at + 16), size = u32(at + 20), nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32)
            var local = u32(at + 42)
            guard at + 46 + nameLength <= b.count, let name = String(bytes: b[(at + 46)..<(at + 46 + nameLength)], encoding: .utf8) else { return nil }
            if local == 0xFFFF_FFFF {
                var e = at + 46 + nameLength
                local = -1
                while e + 4 <= at + 46 + nameLength + extra {
                    if u16(e) == 0x0001, u16(e + 2) >= 8 { local = u64(e + 4); break }
                    e += 4 + u16(e + 2)
                }
            }
            guard u32(local) == 0x04034B50 else { return nil }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + size <= b.count else { return nil }
            let data = Data(b[start..<(start + size)])
            guard Int(CRC32.of(data)) == crc else { return nil }
            out.append((name, data))
            at += 46 + nameLength + extra + comment
        }
        return out
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func of(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { t in
            d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for byte in raw { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
    mutating func le64(_ v: UInt64) { le32(UInt32(v & 0xFFFF_FFFF)); le32(UInt32(v >> 32)) }
}
