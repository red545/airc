// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Compression
import CryptoKit
import Foundation

/// Untrusted interchange, deliberately separate from the forgiving local Boosts.json decoder.
///
/// Version 2 (BST-3) adds what sharing needs, all optional: `id` and `revision` (the shared Boost's identity and how
/// many times its author has shared a change: a file or link with the same id and a higher revision updates an
/// installed copy), `author` (a name the author typed, never verified), `about` (a line of description), `preview` (a
/// screenshot, JPEG or PNG), and the settings Airc added since (`colors.saturation`, `font.case`). Version 1 files
/// still open, with exactly version 1's keys.
public struct BoostFile: Codable, Equatable, Sendable {
    public static let maximumBytes = 512 * 1024
    /// A preview picture, decoded.
    public static let maximumPreviewBytes = 300 * 1024
    public static let version = 2
    public var version: Int = BoostFile.version
    public var name: String
    public var site: String
    public var createdAt: Date
    public var colors: BoostColors
    public var font: BoostFont
    public struct Zap: Codable, Equatable, Sendable {
        public var selector: String
        public var label: String
        /// Zapped inside a frame (BoostZap.frame): `true`, or absent. Version 2 files only.
        public var frame: Bool? = nil
    }
    public var zaps: [Zap]
    public var css: String
    public var js: String
    public var scriptHost: String?
    /// The shared Boost's identity (a UUID), the same in every revision its author shares.
    public var id: String?
    /// 1 for the first share; one more each time the author shares a change.
    public var revision: Int?
    /// The name the author gave, if any. Nobody checks it.
    public var author: String?
    public var about: String?
    /// A screenshot of the Boost on its site: a JPEG or PNG, base64.
    public var preview: String?

    public init(boost: Boost, name: String? = nil) {
        self.name = name ?? boost.name ?? boost.domain
        site = boost.domain; createdAt = boost.created
        colors = boost.colors; font = boost.font
        zaps = boost.zaps.map { Zap(selector: $0.selector, label: $0.label, frame: $0.frame ? true : nil) }
        css = boost.css; js = boost.js; scriptHost = boost.scriptHost
    }

    public enum Invalid: String, Error, LocalizedError {
        case size = "This Boost is too large. Files may be at most 512 KB; CSS and JavaScript at most 128 KB each."
        case format = "This is not a valid Airc Boost file. Check its fields and settings."
        case version = "This Boost was made by a newer version of Airc. Update Airc to open it."
        case domain = "This Boost must name a registrable site, not an address, public suffix or subdomain."
        case exists = "A Boost for this site already exists. Review it and choose Replace to continue."
        case link = "This isn't a Boost link Airc can read. Ask for the file instead."
        case linkSize = "This Boost is too big for a link. Share it as a file instead."
        public var errorDescription: String? { rawValue }
    }

    public static func validSite(_ site: String) -> Bool {
        validHost(site) && !BoostDomain.isExactHost(site) && BoostDomain.key(forHost: site) == site
    }
    private static func validHost(_ host: String) -> Bool {
        host.utf8.count <= 253 && host == host.lowercased() && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.utf8.allSatisfy {
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45
            }
        }
    }
    /// Text the review can't show as it is: bidirectional overrides, embeddings, isolates and marks, which make code
    /// read differently from how it runs ("Trojan Source"), and control characters (tab and line breaks only in
    /// `multiline` text, the CSS and JavaScript).
    static func hidesText(_ s: String, multiline: Bool) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x09, 0x0A, 0x0D: !multiline
            case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
            default: false
            }
        }
    }
    /// One line of text a review can show as it is: not empty, at most `max` characters, nothing hidden.
    public static func plainLine(_ s: String, max: Int) -> Bool {
        !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.unicodeScalars.count <= max && !hidesText(s, multiline: false)
            && !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func validID(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id) != nil && id == id.lowercased()
    }
    public func validated() throws -> BoostFile {
        guard (1...Self.version).contains(version) else { throw Invalid.version }
        guard Self.validSite(site), scriptHost.map({ Self.validHost($0) && BoostDomain.key(forHost: $0) == site }) ?? true else { throw Invalid.domain }
        guard css.utf8.count <= 128 * 1024, js.utf8.count <= 128 * 1024, zaps.count <= 200 else { throw Invalid.size }
        guard !Self.hidesText(css, multiline: true), !Self.hidesText(js, multiline: true), !Self.hidesText(name, multiline: false),
              zaps.allSatisfy({ !Self.hidesText($0.selector, multiline: false) && !Self.hidesText($0.label, multiline: false) })
        else { throw Invalid.format }
        guard Self.plainLine(name, max: 120),
              (0...1).contains(colors.hue), (0...1).contains(colors.tint),
              BoostColors.range.contains(colors.brightness), BoostColors.range.contains(colors.contrast),
              BoostColors.saturationRange.contains(colors.saturation),
              BoostFont.sizeSteps.contains(font.size), font.family == nil || font.knownFamily != nil,
              font.textCase == nil || font.knownCase != nil,
              zaps.allSatisfy({ BoostZap.isValidSelector($0.selector) && $0.label.unicodeScalars.count <= 80 }),
              Set(zaps.map(\.selector)).count == zaps.count else { throw Invalid.format }
        guard id.map(Self.validID) ?? true, revision.map({ (1...1_000_000).contains($0) }) ?? true, (id == nil) == (revision == nil),
              author.map({ Self.plainLine($0, max: 60) }) ?? true, about.map({ Self.plainLine($0, max: 280) }) ?? true,
              preview.map({ Self.previewImage($0) != nil }) ?? true else { throw Invalid.format }
        return self
    }
    /// The preview's bytes, if it's a JPEG or a PNG of at most 300 KB.
    public static func previewImage(_ base64: String) -> Data? {
        guard base64.utf8.count <= (maximumPreviewBytes / 3 + 1) * 4, let data = Data(base64Encoded: base64),
              data.count <= maximumPreviewBytes else { return nil }
        let jpeg = data.starts(with: [0xFF, 0xD8, 0xFF]), png = data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return jpeg || png ? data : nil
    }
    public var previewData: Data? { preview.flatMap(Self.previewImage) }

    public func encoded() throws -> Data {
        var f = try validated()
        f.version = Self.version
        let data = try JSONEncoder.boosts.encode(f)
        guard data.count <= Self.maximumBytes else { throw Invalid.size }
        return data
    }
    public static func read(_ url: URL) throws -> BoostFile {
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true else { throw Invalid.format }
        guard (metadata.fileSize ?? 0) <= maximumBytes else { throw Invalid.size }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bounded read, including when file size metadata lies or changes after it was checked.
        return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
    }
    public static func decode(_ data: Data) throws -> BoostFile {
        guard data.count <= maximumBytes else { throw Invalid.size }
        do {
            func keys(_ value: Any?, required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
                guard let object = value as? [String: Any], required.isSubset(of: Set(object.keys)),
                      Set(object.keys).isSubset(of: required.union(optional)),
                      required.allSatisfy({ !(object[$0] is NSNull) }) else { throw Invalid.format }
                return object
            }
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Invalid.format }
            guard let version = top["version"] as? Int else { throw Invalid.format }
            guard (1...Self.version).contains(version) else { throw Invalid.version }
            let two = version >= 2
            let root = try keys(top, required: ["version", "name", "site", "createdAt", "colors", "font", "zaps", "css", "js"],
                                optional: Set(["scriptHost"]).union(two ? ["id", "revision", "author", "about", "preview"] : []))
            _ = try keys(root["colors"], required: ["hue", "tint", "brightness", "contrast", "invert"], optional: two ? ["saturation"] : [])
            _ = try keys(root["font"], required: ["size"], optional: two ? ["family", "case"] : ["family"])
            guard let zaps = root["zaps"] as? [Any] else { throw Invalid.format }
            for zap in zaps {
                let z = try keys(zap, required: ["selector", "label"], optional: two ? ["frame"] : [])
                if let f = z["frame"], (f as? Bool) != true { throw Invalid.format }
            }
            return try JSONDecoder.boosts.decode(Self.self, from: data).validated()
        } catch let error as Invalid { throw error }
        catch { throw Invalid.format }
    }
    public var boost: Boost {
        var b = Boost(domain: site, colors: colors, font: font,
                      zaps: zaps.map { BoostZap(selector: $0.selector, label: $0.label, created: createdAt, frame: $0.frame == true) },
                      css: css, js: js, scriptHost: scriptHost, created: createdAt)
        b.name = name
        return b
    }
    /// The file without its picture, for a link.
    public var withoutPreview: BoostFile { var f = self; f.preview = nil; return f }

    public var summary: String {
        var parts: [String] = []
        let c = colors
        if c.tint > 0.005 { parts.append("tint \(Int((c.tint * 100).rounded())) % (hue \(Int((c.hue * 360).rounded()))°)") }
        if abs(c.brightness - 1) > 0.005 { parts.append("brightness \(Int((c.brightness * 100).rounded())) %") }
        if abs(c.contrast - 1) > 0.005 { parts.append("contrast \(Int((c.contrast * 100).rounded())) %") }
        if c.saturation < 0.995 { parts.append("saturation \(Int((c.saturation * 100).rounded())) %") }
        if c.invert { parts.append("inverted (dark)") }
        if let f = font.knownFamily { parts.append("the font \(f.title)") }
        if font.size != 0 { parts.append("size \(Int((font.scale * 100).rounded())) %") }
        if let t = font.knownCase { parts.append(t.title.lowercased()) }
        if !zaps.isEmpty { parts.append(zaps.count == 1 ? "1 hidden element" : "\(zaps.count) hidden elements") }
        if parts.isEmpty { return css.isEmpty && js.isEmpty ? "No changes." : "No settings; only its code." }
        return parts.joined(separator: ", ").prefix(1).uppercased() + String(parts.joined(separator: ", ").dropFirst()) + "."
    }
}

// MARK: - Where a Boost came from

/// A shared Boost's identity in a person's own copy (`Boost.origin`): the one they shared themselves (`shared`), or the
/// one they installed from someone (`installed`) or from Airc's gallery.
public struct BoostOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case shared, installed }
    public var id: String
    public var revision: Int
    public var kind: Kind
    public var author: String?
    /// `Boost.contentDigest` when it was installed or last shared: a different digest now means it was changed since.
    public var digest: String
    public var date: Date
    /// Installed from Airc's own gallery.
    public var gallery: Bool

    public init(id: String, revision: Int, kind: Kind, author: String? = nil, digest: String, date: Date = Date(), gallery: Bool = false) {
        self.id = id
        self.revision = revision
        self.kind = kind
        self.author = author
        self.digest = digest
        self.date = date
        self.gallery = gallery
    }

    enum CodingKeys: String, CodingKey { case id, revision, kind, author, digest, date, gallery }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .installed
        author = try c.decodeIfPresent(String.self, forKey: .author)
        digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
        gallery = try c.decodeIfPresent(Bool.self, forKey: .gallery) ?? false
    }

    /// What a Boost does to pages, in a stable form: its settings, zaps (selectors and labels, in order) and code.
    static func digest(of b: Boost) -> String {
        let c = b.colors, f = b.font
        let parts: [Any] = [
            [c.hue, c.tint, c.brightness, c.contrast, c.saturation, c.invert ? 1 : 0].map { String(format: "%.4f", Double($0)) },
            [f.family ?? "", String(f.size), f.textCase ?? ""],
            // A frame's zap adds a mark; every other zap is as before, so existing digests don't change.
            b.zaps.map { $0.frame ? [$0.selector, $0.label, "frame"] : [$0.selector, $0.label] },
            b.css, b.js, b.scriptHost ?? "",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The person changed it after installing or sharing it.
    public func edited(_ b: Boost) -> Bool { b.contentDigest != digest }
}

/// How a file relates to the Boost already on its site: what the review offers.
public enum BoostInstall: Equatable, Sendable {
    /// No Boost there yet.
    case new
    /// A Boost of the person's own, or from somewhere else: installing replaces it.
    case replace
    /// An earlier revision of the same shared Boost: installing updates it.
    case update(from: Int, to: Int)
    /// The same revision (`reinstall`) or an older one (`older`) of the same shared Boost.
    case reinstall(Int)
    case older(have: Int, file: Int)
    /// The person's own shared Boost, opened again.
    case own

    public static func relation(of file: BoostFile, to existing: Boost?) -> BoostInstall {
        guard let existing else { return .new }
        guard let id = file.id, let have = existing.origin, have.id == id else { return .replace }
        if have.kind == .shared { return .own }
        let get = file.revision ?? 1
        if get > have.revision { return .update(from: have.revision, to: get) }
        if get == have.revision { return .reinstall(get) }
        return .older(have: have.revision, file: get)
    }
}

extension BoostStore {
    /// Called only after review. A replacement is explicit and atomic, with one change notification. A file with an id
    /// keeps it (and its revision) as the installed Boost's origin, so a later revision updates it.
    public func install(_ file: BoostFile, replacing: Bool = false, gallery: Bool = false, now: Date = Date()) throws {
        let file = try file.validated()
        guard replacing || boost(domain: file.site) == nil else { throw BoostFile.Invalid.exists }
        update(domain: file.site) {
            $0 = file.boost
            if let id = file.id {
                $0.origin = BoostOrigin(id: id, revision: file.revision ?? 1, kind: .installed, author: file.author,
                                        digest: $0.contentDigest, date: now, gallery: gallery)
            }
        }
    }

    /// The file to share `domain`'s Boost as, with the name and author the person gave. Its origin decides the id: the
    /// person's own shared Boost keeps its id and gets a new revision when it changed since it was last shared; any other
    /// (never shared, or installed from someone) becomes a new shared Boost of theirs. Nothing is stored until
    /// `noteShared` (the file was saved, or the link copied).
    /// `newID`: the id a Boost that isn't shared yet gets (the share sheet makes one and keeps it, so its link and
    /// file name the same Boost).
    public func shareFile(domain: String, name: String, author: String?, about: String? = nil, preview: Data? = nil,
                          newID: String? = nil) -> BoostFile? {
        guard let b = boost(domain: domain) else { return nil }
        var f = BoostFile(boost: b, name: name)
        if let o = b.origin, o.kind == .shared {
            f.id = o.id
            f.revision = o.edited(b) ? o.revision + 1 : o.revision
        } else {
            f.id = newID ?? UUID().uuidString.lowercased()
            f.revision = 1
        }
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        f.author = trimmed?.isEmpty == false ? trimmed : nil
        f.about = about?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        f.preview = preview.map { $0.base64EncodedString() }
        return f
    }

    /// The person shared `file` (saved it or copied its link): their Boost remembers its id and revision.
    public func noteShared(_ file: BoostFile, now: Date = Date()) {
        guard let id = file.id else { return }
        update(domain: file.site) {
            $0.name = file.name
            $0.origin = BoostOrigin(id: id, revision: file.revision ?? 1, kind: .shared, author: file.author, digest: $0.contentDigest,
                                    date: now)
        }
    }

    /// Renames a Boost (Arc's "Rename this Boost…"); an empty name goes back to the site's.
    public func rename(domain: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(domain: domain) { $0.name = n.isEmpty || n == domain ? nil : String(n.prefix(120)) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Links

/// A Boost as a link (BST-3): `https://aircbrowser.com/boost#1.<data>`, the whole file (without its picture) deflated
/// and base64url-encoded in the fragment. The fragment never leaves the browser, so opening a link sends the Boost
/// nowhere: Airc reads it from the address (a link from another app, or a page that navigated to it) and shows the
/// same review as a file. Links are for small Boosts; a bigger one is shared as a file.
public enum BoostLink {
    public static let host = "aircbrowser.com"
    public static let path = "/boost"
    /// Characters of a link, at most: messages and chats keep it whole.
    public static let maximumLength = 8000

    public static func url(for file: BoostFile) throws -> URL {
        var f = try file.withoutPreview.validated()
        f.version = BoostFile.version
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let json = try enc.encode(f)
        guard let packed = deflate(json) else { throw BoostFile.Invalid.linkSize }
        let s = "https://\(host)\(path)#1." + base64url(packed)
        guard s.count <= maximumLength, let url = URL(string: s) else { throw BoostFile.Invalid.linkSize }
        return url
    }

    /// A Boost link (the scheme, host and path exactly; `www.` too).
    public static func isLink(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let h = url.host?.lowercased(),
              h == host || h == "www." + host, url.path == path || url.path == path + "/" else { return false }
        return url.fragment?.hasPrefix("1.") == true
    }

    public static func file(from url: URL) throws -> BoostFile {
        guard isLink(url), let fragment = url.fragment, fragment.count <= maximumLength * 2 else { throw BoostFile.Invalid.link }
        guard let packed = unbase64url(String(fragment.dropFirst(2))),
              let json = inflate(packed, limit: BoostFile.maximumBytes) else { throw BoostFile.Invalid.link }
        let f = try BoostFile.decode(json)
        guard f.preview == nil else { throw BoostFile.Invalid.link }
        return f
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unbase64url(_ s: String) -> Data? {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    /// Raw DEFLATE (RFC 1951), Apple's zlib encoder.
    static func deflate(_ d: Data) -> Data? {
        guard !d.isEmpty else { return nil }
        var out = Data(count: d.count + 1024)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return out.prefix(n)
    }

    /// Inflates into a buffer of `limit` + 1 bytes: more than `limit` is refused, so a small link can't unpack into a
    /// big allocation.
    static func inflate(_ d: Data, limit: Int) -> Data? {
        guard !d.isEmpty else { return nil }
        var out = Data(count: limit + 1)
        let n = out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                          src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n <= limit else { return nil }
        return out.prefix(n)
    }
}
