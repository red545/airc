// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Boosts (BST-1, Arc's "Boosts: customise any website"): one per site, the site being a registrable domain
// ("nytimes.com", and every subdomain of it). A Boost tints and dims the page, swaps its font, hides elements the person
// zapped, and adds their own CSS and JavaScript. Boosts are global, like Arc's: every Space and profile shows the same
// one. They live in one local JSON file and are never synced or sent anywhere (Arc kept them in Firebase, which is how
// CVE-2024-45489 let strangers run code in other people's browsers; docs/research/t3code_and_accounts.md).

/// One site's Boost. Every field decodes with a default, so files from older and newer builds still load.
public struct Boost: Codable, Equatable, Sendable {
    /// The registrable domain it applies to (BoostDomain.key), lowercased.
    public var domain: String
    public var enabled: Bool
    public var colors: BoostColors
    public var font: BoostFont
    /// Elements hidden with Zap, oldest first.
    public var zaps: [BoostZap]
    /// The person's own CSS and JavaScript (the Code section). JavaScript runs only from here: Airc never downloads it.
    public var css: String
    public var js: String
    public var created: Date
    public var modified: Date

    public init(domain: String, enabled: Bool = true, colors: BoostColors = BoostColors(), font: BoostFont = BoostFont(),
                zaps: [BoostZap] = [], css: String = "", js: String = "", created: Date = Date(), modified: Date? = nil) {
        self.domain = domain
        self.enabled = enabled
        self.colors = colors
        self.font = font
        self.zaps = zaps
        self.css = css
        self.js = js
        self.created = created
        self.modified = modified ?? created
    }

    /// Nothing set: an empty Boost changes nothing (the editor keeps it until it's deleted, as Arc does).
    public var isEmpty: Bool {
        colors.isDefault && font.isDefault && zaps.isEmpty && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasScript
    }

    public var hasScript: Bool { !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    enum CodingKeys: String, CodingKey { case domain, enabled, colors, font, zaps, css, js, created, modified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = try c.decode(String.self, forKey: .domain)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        colors = (try? c.decodeIfPresent(BoostColors.self, forKey: .colors)) ?? BoostColors()
        font = (try? c.decodeIfPresent(BoostFont.self, forKey: .font)) ?? BoostFont()
        zaps = (try? c.decodeIfPresent([BoostZap].self, forKey: .zaps)) ?? []
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        js = try c.decodeIfPresent(String.self, forKey: .js) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
    }
}

/// The Colours section: a tint over the page, brightness, contrast, and invert for an instant dark mode.
public struct BoostColors: Codable, Equatable, Sendable {
    /// The tint's hue, 0…1 (red at 0, as HSL).
    public var hue: Double
    /// How strong the tint is, 0 (none) … 1.
    public var tint: Double
    /// 1 is the page as it is; 0.5…1.5.
    public var brightness: Double
    public var contrast: Double
    /// Inverts the page's colours (pictures and video are inverted back).
    public var invert: Bool

    public static let range: ClosedRange<Double> = 0.5...1.5

    public init(hue: Double = 0.6, tint: Double = 0, brightness: Double = 1, contrast: Double = 1, invert: Bool = false) {
        self.hue = hue
        self.tint = tint
        self.brightness = brightness
        self.contrast = contrast
        self.invert = invert
    }

    public var isDefault: Bool { !hasTint && !hasFilter }
    var hasTint: Bool { tint > 0.005 }
    var hasFilter: Bool { invert || abs(brightness - 1) > 0.005 || abs(contrast - 1) > 0.005 }

    enum CodingKeys: String, CodingKey { case hue, tint, brightness, contrast, invert }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0.6
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// The Font section: one of a few system fonts for the page's text, and a size step.
public struct BoostFont: Codable, Equatable, Sendable {
    /// A `BoostFontFamily` raw value; nil (or a family this build doesn't know) keeps the site's own.
    public var family: String?
    /// A step in `BoostFont.sizes` around 0 (100 %).
    public var size: Int

    /// Step → scale. The page grows or shrinks as a whole (CSS zoom on the body), so its layout keeps its proportions.
    public static let sizes: [Int: Double] = [-2: 0.8, -1: 0.9, 0: 1, 1: 1.1, 2: 1.25, 3: 1.5]
    public static let sizeSteps: ClosedRange<Int> = -2...3

    public init(family: BoostFontFamily? = nil, size: Int = 0) {
        self.family = family?.rawValue
        self.size = size
    }

    public var knownFamily: BoostFontFamily? { family.flatMap(BoostFontFamily.init(rawValue:)) }
    public var scale: Double { Self.sizes[min(max(size, Self.sizeSteps.lowerBound), Self.sizeSteps.upperBound)] ?? 1 }
    public var isDefault: Bool { knownFamily == nil && size == 0 }

    enum CodingKeys: String, CodingKey { case family, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }
}

/// Fonts that ship with macOS, so a Boost never downloads one.
public enum BoostFontFamily: String, CaseIterable, Sendable {
    case system, helvetica, avenir, georgia, charter, menlo

    public var title: String {
        switch self {
        case .system: "System"
        case .helvetica: "Helvetica Neue"
        case .avenir: "Avenir Next"
        case .georgia: "Georgia"
        case .charter: "Charter"
        case .menlo: "Menlo"
        }
    }

    /// The CSS font-family list (Chromium has no `ui-serif` and friends, so the faces are named).
    public var stack: String {
        switch self {
        case .system: "-apple-system, BlinkMacSystemFont, system-ui, sans-serif"
        case .helvetica: "\"Helvetica Neue\", Helvetica, Arial, sans-serif"
        case .avenir: "\"Avenir Next\", Avenir, \"Helvetica Neue\", sans-serif"
        case .georgia: "Georgia, \"Times New Roman\", serif"
        case .charter: "Charter, \"Iowan Old Style\", Georgia, serif"
        case .menlo: "Menlo, Monaco, monospace"
        }
    }
}

/// An element hidden with Zap: a CSS selector that finds it again on the next visit, and how the list names it.
public struct BoostZap: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var selector: String
    public var label: String
    public var created: Date

    public init(id: String = UUID().uuidString, selector: String, label: String, created: Date = Date()) {
        self.id = id
        self.selector = selector
        self.label = label
        self.created = created
    }

    /// A selector the page sent: one selector, nothing that could end the rule it goes in or start another.
    public static func isValidSelector(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 600 && !s.contains(where: { "{};@\n\r".contains($0) }) && !s.contains("/*")
    }
}

// MARK: - Sites

/// What a Boost is keyed by: the registrable domain of a page's host ("nytimes.com" for "www.nytimes.com" and
/// "cooking.nytimes.com"). Without the whole public suffix list, the multi-label suffixes people actually meet are
/// listed here; anything else is its last two labels. IP addresses and single-label hosts (localhost) are their own
/// site. The page script (BoostPageScript) uses the same list, so the page and the app always agree.
public enum BoostDomain {
    /// Public suffixes of more than one label: country second levels and shared hosting where every customer is
    /// their own site (one user's github.io pages never get another's Boost).
    public static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk",
        "co.at", "or.at", "gv.at", "ac.at",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ad.jp", "ed.jp", "gr.jp", "lg.jp",
        "co.kr", "or.kr", "ac.kr", "go.kr", "ne.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.sg", "org.sg", "net.sg", "edu.sg", "gov.sg",
        "co.in", "net.in", "org.in", "gov.in", "ac.in", "firm.in", "gen.in", "ind.in",
        "co.za", "org.za", "net.za", "gov.za", "ac.za",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "co.id", "or.id", "ac.id", "go.id", "web.id",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.mx", "org.mx", "net.mx", "gob.mx", "edu.mx",
        "com.ar", "org.ar", "net.ar", "gob.ar",
        "com.co", "org.co", "net.co", "gov.co",
        "com.pe", "org.pe", "gob.pe", "com.ve", "com.uy", "com.ec", "com.bo", "com.py",
        "com.tr", "org.tr", "net.tr", "gov.tr", "edu.tr",
        "com.my", "org.my", "net.my", "gov.my", "com.ph", "org.ph", "gov.ph", "com.vn", "net.vn", "gov.vn",
        "com.pk", "org.pk", "com.bd", "com.np", "com.lk", "com.sa", "org.sa", "gov.sa", "com.eg", "gov.eg",
        "com.ng", "org.ng", "co.ke", "or.ke", "co.tz", "co.ug",
        "com.ua", "org.ua", "net.ua", "gov.ua", "com.ru", "org.ru", "net.ru", "com.pl", "net.pl", "org.pl",
        "com.es", "org.es", "nom.es", "com.pt", "org.pt", "com.gr", "com.cy", "com.mt", "co.hu", "com.ro",
        "co.th", "or.th", "ac.th", "go.th", "in.th",
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app",
        "firebaseapp.com", "herokuapp.com", "appspot.com", "blogspot.com", "azurewebsites.net", "cloudfront.net",
        "s3.amazonaws.com", "fly.dev", "onrender.com", "glitch.me", "ngrok.io", "ngrok-free.app", "myshopify.com",
        "repl.co", "deno.dev", "surge.sh", "readthedocs.io", "neocities.org",
    ]

    /// The site of `host`, or nil for an empty host.
    public static func key(forHost host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        if h.contains(":") || isIPv4(h) { return h }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return h }
        // The longest listed suffix the host ends with (the host itself, when it is one).
        for n in stride(from: min(labels.count, 3), through: 2, by: -1) {
            let suffix = labels.suffix(n).joined(separator: ".")
            guard multiLabelSuffixes.contains(suffix) else { continue }
            return labels.count == n ? suffix : labels.suffix(n + 1).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// The site of a web page; nil for pages that aren't http(s) (Boosts are for websites).
    public static func key(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return key(forHost: host)
    }

    static func isIPv4(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

// MARK: - The style a Boost adds

/// The CSS a Boost puts on its pages, in two parts: what the editor's controls generate, and the person's own CSS
/// (its own sheet, so a typo in it can't break the rest).
public enum BoostStyle {
    /// Icon fonts and code keep their own face when the font changes.
    static let fontExclusions = ":not(pre, pre *, code, code *, kbd, kbd *, samp, samp *, tt, var, i:empty, "
        + "[class*=\"icon\" i], [class*=\"glyph\" i], [class*=\"symbol\" i], [class^=\"fa-\"], [class*=\" fa-\"], "
        + "[class=\"fa\"], [class^=\"fa \"], .material-icons, [class*=\"material-symbols\"], [aria-hidden=\"true\"], "
        + "[aria-hidden=\"true\"] *)"

    /// Pictures, video and frames are inverted back, so photos keep their colours in an inverted page.
    static let uninverted = "img, video, picture, canvas, svg image, embed, object, iframe, [style*=\"background-image\"]"

    public static func generated(for boost: Boost) -> String {
        var css: [String] = []
        let c = boost.colors
        if c.hasFilter {
            var f: [String] = []
            if c.invert { f.append("invert(1) hue-rotate(180deg)") }
            if abs(c.brightness - 1) > 0.005 { f.append("brightness(\(fmt(clamp(c.brightness, BoostColors.range))))") }
            if abs(c.contrast - 1) > 0.005 { f.append("contrast(\(fmt(clamp(c.contrast, BoostColors.range))))") }
            css.append("html { filter: \(f.joined(separator: " ")) !important; }")
            // A filter on the root covers the root's background but not the page's backdrop: a page with no
            // background of its own needs one (white) so that it is filtered too. The page's own wins (lower
            // specificity than any `html` rule).
            css.append(":where(html) { background-color: #fff; }")
            if c.invert { css.append("\(uninverted) { filter: invert(1) hue-rotate(180deg) !important; }") }
        }
        if c.hasTint {
            // A light wash of the hue multiplied over the page: whites take the colour, text stays dark.
            let hue = Int((c.hue.truncatingRemainder(dividingBy: 1) + (c.hue < 0 ? 1 : 0)) * 360) % 360
            let t = clamp(c.tint, 0...1)
            css.append("html::after { content: \"\" !important; position: fixed !important; inset: 0 !important; "
                       + "display: block !important; pointer-events: none !important; z-index: 2147483647 !important; "
                       + "background: hsl(\(hue) 75% \(fmt(97 - 30 * t))%) !important; mix-blend-mode: multiply !important; }")
        }
        if let family = boost.font.knownFamily {
            css.append("body, body \(fontExclusions) { font-family: \(family.stack) !important; }")
        }
        if boost.font.size != 0 {
            css.append("body { zoom: \(fmt(boost.font.scale)) !important; }")
        }
        // One rule per zap: a selector this engine can't parse drops only its own rule.
        for z in boost.zaps where BoostZap.isValidSelector(z.selector) {
            css.append("\(z.selector) { display: none !important; }")
        }
        return css.joined(separator: "\n")
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }

    /// Up to three decimals, no trailing zeros: "0.9", "1.25".
    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

// MARK: - The store

/// The Boosts file (`Boosts.json` in the data folder): `{"version": 1, "boosts": [...]}`. Changes are kept in memory
/// and written with `flush()` (the app batches slider drags); a file this build can't read is kept beside it as
/// `Boosts.unreadable-<time>.json` instead of being overwritten.
public final class BoostStore {
    public static let version = 1
    public let url: URL?
    public private(set) var boosts: [String: Boost] = [:]
    public private(set) var isDirty = false
    /// Called after every change, with the domain that changed.
    public var onChange: ((String) -> Void)?

    struct File: Codable {
        var version: Int
        var boosts: [Boost]
    }

    /// `url` nil keeps everything in memory.
    public init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            let file = try JSONDecoder.boosts.decode(File.self, from: data)
            for b in file.boosts { boosts[b.domain] = b }
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("Boosts.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
        }
    }

    /// Every Boost, by domain.
    public var all: [Boost] { boosts.values.sorted { $0.domain < $1.domain } }

    public func boost(domain: String) -> Boost? { boosts[domain] }

    /// The Boost for a page's host, if any (on or off).
    public func boost(forHost host: String) -> Boost? { BoostDomain.key(forHost: host).flatMap { boosts[$0] } }

    /// Changes (or creates) the Boost of `domain`.
    @discardableResult
    public func update(domain: String, _ change: (inout Boost) -> Void) -> Boost {
        var b = boosts[domain] ?? Boost(domain: domain)
        let before = b
        change(&b)
        b.domain = domain
        guard b != before || boosts[domain] == nil else { return b }
        b.modified = Date()
        boosts[domain] = b
        isDirty = true
        onChange?(domain)
        return b
    }

    public func remove(domain: String) {
        guard boosts.removeValue(forKey: domain) != nil else { return }
        isDirty = true
        onChange?(domain)
    }

    /// Writes the file if anything changed. Owner-only permissions: it can hold the person's own scripts.
    @discardableResult
    public func flush() -> Bool {
        guard isDirty else { return true }
        guard let url else { isDirty = false; return true }
        do {
            let data = try JSONEncoder.boosts.encode(File(version: Self.version, boosts: all))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            isDirty = false
            return true
        } catch {
            return false
        }
    }
}

extension JSONEncoder {
    static var boosts: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var boosts: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
