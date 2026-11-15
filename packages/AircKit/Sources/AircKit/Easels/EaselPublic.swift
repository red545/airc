// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

// P19c (parity N08): what leaves this Mac when an Easel is exported as HTML or shared as a link. One form for both,
// the schema aircbrowser.com checks (apps/marketing/src/lib/easel-core.js) and renders (/e/<id>):
//   - blocks back to front, each a frame (points on the plane, y down), an optional turn and one kind of content;
//   - colours resolved to hex in the Easel's light look; text as paragraphs of runs (a note's marks);
//   - pictures named by the SHA-256 of the bytes that go out (PNG, JPEG, GIF or WebP; the app converts the rest).
// Nothing else: no block ids, groups, undo history or viewport; a live Capture is its last picture and its page's
// address (never its profile, region, scroll, zoom or refresh state); a picture's source page is not included;
// addresses are web addresses only, without user names, passwords, or query and fragment parts that carry sign-in or
// session secrets (`webAddress`). So an export or a link holds no cookie, token or profile of any kind.

public struct EaselPublic: Codable, Equatable, Sendable {
    public static let version = 1
    /// The service's limits (easel-core.js), checked here before anything is sent.
    public static let maxBlocks = 2_000
    public static let maxAssets = 200
    public static let maxAssetBytes = 4_000_000
    public static let maxTotalAssetBytes = 20_000_000
    public static let maxJSON = 1_048_576
    static let coordinateLimit = 1_000_000.0, sideLimit = 100_000.0, titleLimit = 120, labelLimit = 500, textLimit = 20_000

    public var kind = "easel"
    public var version = EaselPublic.version
    public var title: String
    public var background: String
    public var blocks: [Block]
    public var assets: [Asset]

    public struct Asset: Codable, Equatable, Sendable {
        public var name: String
        public var size: Int
        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    public struct Block: Codable, Equatable, Sendable {
        public var frame: EaselRect
        public var rotation: Double?
        public var content: Content
    }

    public struct Run: Codable, Equatable, Sendable {
        public var text: String
        public var bold, italic, underline, strike, code: Bool?
        public var link: String?
    }

    public struct Paragraph: Codable, Equatable, Sendable {
        public var kind: NoteBlock.Kind
        public var indent: Int?
        public var checked: Bool?
        public var runs: [Run]
    }

    /// One block's content, tagged by `type`; only the keys of its kind are set (nil keys aren't written).
    public struct Content: Codable, Equatable, Sendable {
        public var type: String
        // text
        public var paragraphs: [Paragraph]?
        public var font: EaselFont?
        public var size: Double?
        public var color: String?
        public var alignment: EaselAlignment?
        // image, capture
        public var asset: String?
        public var alt: String?
        // shape
        public var kind: EaselShape.Kind?
        public var fill: String?
        public var stroke: String?
        public var strokeWidth: Double?
        public var cornerRadius: Double?
        // line
        public var from: EaselPoint?
        public var to: EaselPoint?
        public var startHead: Bool?
        public var endHead: Bool?
        public var width: Double?
        // link, capture
        public var url: String?
        public var title: String?
        public var detail: String?
        public var image: String?

        init(type: String) { self.type = type }

        /// The pictures it shows.
        public var pictures: [String] { [asset, image].compactMap { $0 } }
    }

    /// What making it left out or changed, for the preview before anything is published or written.
    public struct Report: Equatable, Sendable {
        /// Blocks of a kind this build can't share (a newer build's), or too far out on the plane.
        public var leftOut = 0
        /// Live Captures that went as their last picture.
        public var liveCaptures = 0
        /// Addresses that lost a user name, password or a sign-in/session part.
        public var addressesCleaned = 0
        /// Links that aren't web addresses (and blocks whose only content was one), left out.
        public var linksDropped = 0
        /// Pictures that couldn't be read or are too large, and their blocks.
        public var picturesMissing = 0
        public init() {}
    }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? EaselURL.untitled : t
    }

    /// The picture names its blocks show, in first-use order.
    public var pictureNames: [String] {
        var seen = Set<String>()
        return blocks.flatMap(\.content.pictures).filter { seen.insert($0).inserted }
    }

    // MARK: Making it

    /// The public form of `doc` (only blocks `ids`, when given). Pictures keep their Easel asset names until
    /// `settingPictures` names them by the bytes that go out.
    public static func make(_ doc: EaselDocument, only ids: Set<String>? = nil) -> (EaselPublic, Report) {
        var report = Report()
        let palette = doc.palette
        func hex(_ c: EaselColor, stroke: Bool = false) -> String { c.hex(palette, dark: false, stroke: stroke).uppercased() }
        func address(_ s: String?) -> String? {
            guard let s else { return nil }
            guard let clean = webAddress(s) else { report.linksDropped += 1; return nil }
            if clean != s { report.addressesCleaned += 1 }
            return clean
        }
        var blocks: [Block] = []
        for b in doc.stacked where ids?.contains(b.id) ?? true {
            let f = b.frame
            guard f.isFinite, abs(f.x) <= coordinateLimit, abs(f.y) <= coordinateLimit, f.width <= sideLimit, f.height <= sideLimit,
                  blocks.count < maxBlocks else { report.leftOut += 1; continue }
            var c: Content
            switch b.content {
            case .text(let t):
                c = Content(type: "text")
                var budget = textLimit, runBudget = 4_000
                c.paragraphs = t.text.blocks.prefix(2_000).map { p in
                    let runs: [Run] = p.runs.compactMap { r in
                        guard r.image == nil, budget > 0, runBudget > 0 else { return nil }
                        runBudget -= 1
                        let text = String(clean(r.text, lines: true).prefix(budget))
                        budget -= text.count
                        guard !text.isEmpty else { return nil }
                        let m = r.marks
                        return Run(text: text, bold: m.contains(.bold) ? true : nil, italic: m.contains(.italic) ? true : nil,
                                   underline: m.contains(.underline) ? true : nil, strike: m.contains(.strikethrough) ? true : nil,
                                   code: m.contains(.code) ? true : nil, link: address(r.link))
                    }
                    let indent = max(0, min(8, p.indent))
                    return Paragraph(kind: p.kind, indent: indent == 0 ? nil : indent, checked: p.kind == .checkbox && p.checked ? true : nil, runs: runs)
                }
                c.font = t.font
                c.size = t.size
                c.color = t.color.map { hex($0) } ?? "#141414"
                c.alignment = t.alignment
            case .image(let i):
                c = Content(type: "image")
                c.asset = i.asset
                c.alt = label(i.altText)
            case .shape(let s):
                c = Content(type: "shape")
                c.kind = s.kind
                c.fill = s.fill.map { hex($0) }
                c.stroke = s.stroke.map { hex($0, stroke: true) }
                c.strokeWidth = max(0, min(200, s.strokeWidth.isFinite ? s.strokeWidth : 0))
                c.cornerRadius = max(0, min(sideLimit, s.cornerRadius.isFinite ? s.cornerRadius : 0))
            case .line(let l):
                c = Content(type: "line")
                c.from = l.from
                c.to = l.to
                c.startHead = l.startHead
                c.endHead = l.endHead
                c.color = hex(l.color)
                c.width = max(0.25, min(200, l.width.isFinite ? l.width : 3))
            case .link(let l):
                guard let url = address(l.url) else { continue }
                c = Content(type: "link")
                c.url = url
                c.title = label(l.title)
                c.detail = l.detail.map { String(clean($0, lines: true).prefix(2 * labelLimit)) }.flatMap { $0.isEmpty ? nil : $0 }
                c.image = l.image
            case .capture(let cap):
                c = Content(type: "capture")
                c.asset = cap.asset
                c.url = address(cap.url)
                c.title = label(cap.title)
                if cap.live != nil { report.liveCaptures += 1 }
            case .unknown:
                report.leftOut += 1
                continue
            }
            blocks.append(Block(frame: f, rotation: b.rotation == 0 || !b.rotation.isFinite ? nil : b.rotation, content: c))
        }
        let title = String(clean(doc.title, lines: false).prefix(titleLimit))
        return (EaselPublic(title: title, background: EaselBackground.light, blocks: blocks, assets: []), report)
    }

    /// The pictures as they go out: `map` gives each Easel asset name the name and size of its bytes (by their SHA-256).
    /// A block whose picture isn't in `map` goes (a link card loses its picture and stays).
    public func settingPictures(_ map: [String: Asset], report: inout Report) -> EaselPublic {
        var out = self
        out.blocks = blocks.compactMap { b in
            var b = b
            if let a = b.content.asset {
                guard let m = map[a] else { report.picturesMissing += 1; return nil }
                b.content.asset = m.name
            }
            if let i = b.content.image { b.content.image = map[i]?.name }
            return b
        }
        var seen = Set<String>()
        let byName = Dictionary(map.values.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        out.assets = out.blocks.flatMap(\.content.pictures).filter { seen.insert($0).inserted }.compactMap { byName[$0] }
        return out
    }

    /// The JSON the service takes (keys sorted, so the same Easel is the same bytes).
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case empty, tooLarge
        public var errorDescription: String? {
            switch self {
            case .empty: "There’s nothing on this Easel to share."
            case .tooLarge: "This Easel is too large to share. Share a selection, or fewer pictures."
            }
        }
    }

    /// What the service would refuse, found before anything is sent.
    public func check() throws {
        guard !blocks.isEmpty else { throw Problem.empty }
        guard blocks.count <= Self.maxBlocks, assets.count <= Self.maxAssets, assets.allSatisfy({ $0.size <= Self.maxAssetBytes }),
              assets.reduce(0, { $0 + $1.size }) <= Self.maxTotalAssetBytes, try encoded().count <= Self.maxJSON else { throw Problem.tooLarge }
    }

    /// A picture's name for the bytes that go out: their SHA-256 and their type, or nil for a type that isn't PNG,
    /// JPEG, GIF or WebP (by the bytes themselves).
    public static func pictureName(_ data: Data) -> String? {
        guard let ext = pictureType(data) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "." + ext
    }

    /// png, jpg, gif or webp, by the bytes' first bytes (easel-core.js's `sniff`).
    public static func pictureType(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        func at(_ sig: [UInt8], _ o: Int = 0) -> Bool { b.count >= o + sig.count && Array(b[o..<o + sig.count]) == sig }
        if at([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if at([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if at([0x47, 0x49, 0x46, 0x38]), b.count >= 6, b[4] == 0x37 || b[4] == 0x39, b[5] == 0x61 { return "gif" }
        if at([0x52, 0x49, 0x46, 0x46]), at([0x57, 0x45, 0x42, 0x50], 8) { return "webp" }
        return nil
    }

    // MARK: Text and addresses

    /// Text without control or direction-override characters (newlines and tabs stay in `lines`; CR LF become LF).
    static func clean(_ s: String, lines: Bool) -> String {
        let t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        return String(String.UnicodeScalarView(t.unicodeScalars.compactMap { u -> Unicode.Scalar? in
            let v = u.value
            if v == 0x0A || v == 0x09 { return lines ? u : " " }
            if v < 0x20 || (0x7F...0x9F).contains(v) || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return nil }
            return u
        }))
    }

    /// A label (a title, a picture's description): cleaned, at most 500 characters, nil when nothing's left.
    static func label(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = String(clean(s, lines: false).prefix(labelLimit))
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? nil : t
    }

    /// Query names that carry sign-in or session secrets (exactly, or as part of a longer name for the long ones).
    static let secretNames: Set<String> = ["token", "access_token", "id_token", "refresh_token", "auth", "authorization", "session",
                                          "sessionid", "session_id", "sid", "ssid", "phpsessid", "jsessionid", "aspsessionid", "key",
                                          "api_key", "apikey", "code", "state", "password", "pass", "passwd", "pwd", "secret",
                                          "client_secret", "signature", "sig", "ticket", "otp", "nonce", "jwt", "csrf", "xsrf",
                                          "_csrf", "authenticity_token", "oauth_token", "oauth_verifier", "x-amz-signature",
                                          "x-amz-credential", "x-amz-security-token", "x-goog-signature", "x-goog-credential", "sharedkey",
                                          "magic", "login_token", "reset_token", "invite", "invite_token"]
    static let secretParts = ["token", "session", "secret", "password", "passwd", "signature", "credential", "apikey", "api_key"]

    static func isSecretName(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretNames.contains(n) || secretParts.contains { n.contains($0) }
    }

    /// `s` as an address an export or a link may carry, or nil: an absolute http(s) address with a host, without a user
    /// name or password, query items whose names carry secrets, or a fragment with parameters (OAuth puts tokens there);
    /// at most 4,096 characters with no spaces, backslashes or control characters (what the service accepts).
    public static func webAddress(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: t), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.user = nil
        c.password = nil
        if let items = c.percentEncodedQueryItems {
            let kept = items.filter { !isSecretName($0.name.removingPercentEncoding ?? $0.name) }
            c.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        if let f = c.percentEncodedFragment, f.contains("=") || isSecretName(f) { c.percentEncodedFragment = nil }
        guard let out = c.string, out.count <= 4096,
              !out.unicodeScalars.contains(where: { $0.value <= 0x20 || $0 == "\\" || (0x7F...0x9F).contains($0.value) }),
              URL(string: out)?.host != nil else { return nil }
        return out
    }
}
