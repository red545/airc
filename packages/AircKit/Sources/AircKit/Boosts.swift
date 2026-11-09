// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Boosts (BST-1, Arc's "Boosts: customise any website"): one per site, the site being a registrable domain by the
// public suffix list ("nytimes.com", and every subdomain of it; "alice.github.io", but not "bob.github.io"). A Boost
// tints and dims the page, swaps its font, hides elements the person zapped, and adds their own CSS and JavaScript (the
// JavaScript on one host of the site unless they pick all of it). Boosts are global, like Arc's: every Space and profile shows the same
// one. They live in one local JSON file and are never synced or sent anywhere (Arc kept them in Firebase, which is how
// CVE-2024-45489 let strangers run code in other people's browsers; docs/research/t3code_and_accounts.md).

/// One site's Boost. Every field decodes with a default, so files from older and newer builds still load.
public struct Boost: Codable, Equatable, Sendable {
    /// The registrable domain it applies to (BoostDomain.key), lowercased.
    public var name: String? = nil
    public var domain: String
    public var enabled: Bool
    public var colors: BoostColors
    public var font: BoostFont
    /// Elements hidden with Zap, oldest first.
    public var zaps: [BoostZap]
    /// The person's own CSS and JavaScript (the Code section). JavaScript runs only from here: Airc never downloads it.
    public var css: String
    public var js: String
    /// The one host the JavaScript runs on ("www.nytimes.com"), or nil for every page of the site. New code gets the
    /// host it was saved on; Boosts from before hosts existed keep the whole site.
    public var scriptHost: String?
    /// Made by a build that didn't have the whole public suffix list, for a "site" that is really shared by different
    /// owners ("duckdns.org", "github.io"): it applies nowhere and its code never runs until the person picks, in the
    /// editor, the site it belongs to (BoostStore's migration, BoostDomain.isSharedLegacyKey).
    public var needsSite: Bool
    /// Where a shared Boost came from (installed from a file, a link or the gallery) or, for one the person shared
    /// themselves, the identity its files and links carry: what lets a newer version update it (BoostOrigin).
    public var origin: BoostOrigin?
    public var created: Date
    public var modified: Date

    public init(domain: String, enabled: Bool = true, colors: BoostColors = BoostColors(), font: BoostFont = BoostFont(),
                zaps: [BoostZap] = [], css: String = "", js: String = "", scriptHost: String? = nil, needsSite: Bool = false,
                origin: BoostOrigin? = nil, created: Date = Date(), modified: Date? = nil) {
        self.domain = domain
        self.enabled = enabled
        self.colors = colors
        self.font = font
        self.zaps = zaps
        self.css = css
        self.js = js
        self.scriptHost = scriptHost
        self.needsSite = needsSite
        self.origin = origin
        self.created = created
        self.modified = modified ?? created
    }

    /// Nothing set: an empty Boost changes nothing (the editor keeps it until it's deleted, as Arc does).
    public var isEmpty: Bool {
        colors.isDefault && font.isDefault && zaps.isEmpty && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasScript
    }

    public var hasScript: Bool { !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// It changes pages now: on, and not waiting for its site.
    public var isLive: Bool { enabled && !needsSite }

    /// The code runs on a page of `host` (a host of this Boost's site).
    public func scriptRuns(onHost host: String) -> Bool {
        guard isLive, hasScript else { return false }
        return scriptHost.map { $0 == host.lowercased() } ?? true
    }

    /// What it does to pages, as a short fingerprint: the same settings, zaps and code give the same digest (its name,
    /// switch and dates don't count). An installed Boost whose digest is no longer its origin's was edited since.
    public var contentDigest: String { BoostOrigin.digest(of: self) }

    enum CodingKeys: String, CodingKey { case name, domain, enabled, colors, font, zaps, css, js, scriptHost, needsSite, origin, created, modified }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        domain = try c.decode(String.self, forKey: .domain)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        colors = (try? c.decodeIfPresent(BoostColors.self, forKey: .colors)) ?? BoostColors()
        font = (try? c.decodeIfPresent(BoostFont.self, forKey: .font)) ?? BoostFont()
        zaps = (try? c.decodeIfPresent([BoostZap].self, forKey: .zaps)) ?? []
        css = try c.decodeIfPresent(String.self, forKey: .css) ?? ""
        js = try c.decodeIfPresent(String.self, forKey: .js) ?? ""
        scriptHost = try c.decodeIfPresent(String.self, forKey: .scriptHost)
        needsSite = try c.decodeIfPresent(Bool.self, forKey: .needsSite) ?? false
        origin = try? c.decodeIfPresent(BoostOrigin.self, forKey: .origin)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
    }
}

/// The Colours section: a tint over the page, brightness, contrast, how much of the page's own colour stays (Arc's
/// "Original Saturation"), and invert for an instant dark mode.
public struct BoostColors: Codable, Equatable, Sendable {
    /// The tint's hue, 0…1 (red at 0, as HSL).
    public var hue: Double
    /// How strong the tint is, 0 (none) … 1.
    public var tint: Double
    /// 1 is the page as it is; 0.5…1.5.
    public var brightness: Double
    public var contrast: Double
    /// How much of the page's own colour stays: 1 is all of it, 0 a grey page (under the tint, if one is on).
    public var saturation: Double
    /// Inverts the page's colours (pictures and video are inverted back).
    public var invert: Bool

    public static let range: ClosedRange<Double> = 0.5...1.5
    public static let saturationRange: ClosedRange<Double> = 0...1

    public init(hue: Double = 0.6, tint: Double = 0, brightness: Double = 1, contrast: Double = 1, saturation: Double = 1,
                invert: Bool = false) {
        self.hue = hue
        self.tint = tint
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.invert = invert
    }

    public var isDefault: Bool { !hasTint && !hasFilter }
    var hasTint: Bool { tint > 0.005 }
    var hasFilter: Bool { invert || hasLightFilter }
    /// Brightness, contrast or saturation: the filters an iframe already gets from its page's.
    var hasLightFilter: Bool { abs(brightness - 1) > 0.005 || abs(contrast - 1) > 0.005 || saturation < 0.995 }

    enum CodingKeys: String, CodingKey { case hue, tint, brightness, contrast, saturation, invert }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0.6
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 1
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
    }
}

/// The Font section: one of a few system fonts for the page's text, a size step, and a letter case (Arc's "Change text
/// case").
public struct BoostFont: Codable, Equatable, Sendable {
    /// A `BoostFontFamily` raw value; nil (or a family this build doesn't know) keeps the site's own.
    public var family: String?
    /// A step in `BoostFont.sizes` around 0 (100 %).
    public var size: Int
    /// A `BoostTextCase` raw value; nil (or one this build doesn't know) keeps the site's own.
    public var textCase: String?

    /// Step → scale. The page is zoomed as a whole, as ⌘+ zooms it (BoostZoom: the engine's page zoom, not CSS zoom,
    /// which made every 100vh layout taller than the window), so its layout reflows to fit.
    public static let sizes: [Int: Double] = [-2: 0.8, -1: 0.9, 0: 1, 1: 1.1, 2: 1.25, 3: 1.5]
    public static let sizeSteps: ClosedRange<Int> = -2...3

    public init(family: BoostFontFamily? = nil, size: Int = 0, textCase: BoostTextCase? = nil) {
        self.family = family?.rawValue
        self.size = size
        self.textCase = textCase?.rawValue
    }

    public var knownFamily: BoostFontFamily? { family.flatMap(BoostFontFamily.init(rawValue:)) }
    public var knownCase: BoostTextCase? { textCase.flatMap(BoostTextCase.init(rawValue:)) }
    public var step: Int { min(max(size, Self.sizeSteps.lowerBound), Self.sizeSteps.upperBound) }
    public var scale: Double { Self.sizes[step] ?? 1 }
    public var isDefault: Bool { knownFamily == nil && size == 0 && knownCase == nil }

    enum CodingKeys: String, CodingKey { case family, size, textCase = "case" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        textCase = try c.decodeIfPresent(String.self, forKey: .textCase)
    }
}

/// Arc's text case choices: every word capitalised, all capitals, all small letters.
public enum BoostTextCase: String, CaseIterable, Sendable {
    case capitalize, uppercase, lowercase

    public var title: String {
        switch self {
        case .capitalize: "Title Case"
        case .uppercase: "Capitals"
        case .lowercase: "Lowercase"
        }
    }

    /// The editor's sample of it.
    public var sample: String {
        switch self {
        case .capitalize: "Aa"
        case .uppercase: "AA"
        case .lowercase: "aa"
        }
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
    /// Zapped inside a frame of the page's own site (boosts3): its selector was made in the frame's document, so it
    /// hides elements in the site's frame documents only, never in the page itself. Saved only when true.
    public var frame: Bool

    public init(id: String = UUID().uuidString, selector: String, label: String, created: Date = Date(), frame: Bool = false) {
        self.id = id
        self.selector = selector
        self.label = label
        self.created = created
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey { case id, selector, label, created, frame }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        selector = try c.decode(String.self, forKey: .selector)
        label = try c.decode(String.self, forKey: .label)
        created = try c.decode(Date.self, forKey: .created)
        frame = try c.decodeIfPresent(Bool.self, forKey: .frame) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(selector, forKey: .selector)
        try c.encode(label, forKey: .label)
        try c.encode(created, forKey: .created)
        if frame { try c.encode(true, forKey: .frame) }
    }

    /// A selector the page sent: one selector, nothing that could end the rule it goes in or start another.
    public static func isValidSelector(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 600 && !s.contains(where: { "{};@\n\r".contains($0) }) && !s.contains("/*")
    }
}

// MARK: - Sites

/// What a Boost is keyed by: the registrable domain of a page's host by the complete public suffix list
/// (PublicSuffixList: ICANN and private suffixes, wildcards and exceptions), the rule Chromium's site isolation uses.
/// "nytimes.com" for "www.nytimes.com" and "cooking.nytimes.com"; "alice.duckdns.org", never "duckdns.org", for
/// "alice.duckdns.org". A host that is itself a public suffix ("github.io", "localhost"), an IP address, or any host when
/// the app has no list, is its own site: that exact host only. The page script gets what it needs to agree from
/// BoostPageScript (the exact flag and the rules under each site), never its own copy of the list.
public enum BoostDomain {
    /// The site of `host`, or nil for an empty host.
    public static func key(forHost host: String, suffixes: PublicSuffixList = .shared) -> String? {
        guard let h = normalize(host) else { return nil }
        if isAddress(h) { return h }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty), !suffixes.isEmpty else { return h }
        return suffixes.registrableDomain(labels) ?? h
    }

    /// The site of a web page; nil for pages that aren't http(s) (Boosts are for websites).
    public static func key(for url: URL?, suffixes: PublicSuffixList = .shared) -> String? {
        guard let host = webHost(of: url) else { return nil }
        return key(forHost: host, suffixes: suffixes)
    }

    /// The lowercased ASCII host of an http(s) page.
    public static func webHost(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return normalize(host)
    }

    /// A site that is one exact host, not that host and its subdomains: an address, a lone label, a public suffix
    /// itself ("github.io": "alice.github.io" is someone else's), or every site while there's no list.
    public static func isExactHost(_ site: String, suffixes: PublicSuffixList = .shared) -> Bool {
        if isAddress(site) || suffixes.isEmpty { return true }
        let labels = site.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count < 2 || labels.contains(where: \.isEmpty) || suffixes.isPublicSuffix(site)
    }

    /// The list's rules under a site that make some of its subdomains other sites ("s3.amazonaws.com" under
    /// "amazonaws.com"); empty for nearly every site.
    public static func otherSitesBeneath(_ site: String, suffixes: PublicSuffixList = .shared) -> [String] {
        isExactHost(site, suffixes: suffixes) ? [] : suffixes.rules(beneath: site)
    }

    /// A key a build before the whole list may have given to hosts of different owners: it is a public suffix of two or
    /// more labels ("duckdns.org", "uk.com", "github.io", "b.ck" under "*.ck"), or the list has sites under it
    /// ("amazonaws.com"). Such a Boost is held (`Boost.needsSite`) until the person picks its site.
    public static func isSharedLegacyKey(_ key: String, suffixes: PublicSuffixList = .shared) -> Bool {
        guard !isAddress(key), !suffixes.isEmpty else { return false }
        let labels = key.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
        return suffixes.isPublicSuffix(key) || !suffixes.rules(beneath: key).isEmpty
    }

    /// Lowercased, without brackets or trailing dots, international labels as punycode; nil when nothing is left.
    static func normalize(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        if h.contains(":") { return h }
        return PublicSuffixList.ascii(h) ?? h
    }

    static func isAddress(_ h: String) -> Bool { h.contains(":") || isIPv4(h) }

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

    /// Text keeps its own case in fields, code and the like.
    static let caseExclusions = ":not(pre, pre *, code, code *, kbd, kbd *, samp, samp *, input, textarea, select, "
        + "[contenteditable], [contenteditable] *)"

    /// The CSS for a page of the site, or (`frame`) for a document in one of its frames whose page is on the same site.
    /// A frame is drawn inside its page, under the page's filter and tint: it adds neither again, only the invert its
    /// page took back for frames ("pictures and frames are inverted back"), with the font, the letter case and the zaps.
    public static func generated(for boost: Boost, frame: Bool = false) -> String {
        var css: [String] = []
        let c = boost.colors
        if c.invert || (!frame && c.hasLightFilter) {
            var f: [String] = []
            if c.invert { f.append("invert(1) hue-rotate(180deg)") }
            if !frame {
                if abs(c.brightness - 1) > 0.005 { f.append("brightness(\(fmt(clamp(c.brightness, BoostColors.range))))") }
                if abs(c.contrast - 1) > 0.005 { f.append("contrast(\(fmt(clamp(c.contrast, BoostColors.range))))") }
                if c.saturation < 0.995 { f.append("saturate(\(fmt(clamp(c.saturation, BoostColors.saturationRange))))") }
            }
            css.append("html { filter: \(f.joined(separator: " ")) !important; }")
            // A filter on the root covers the root's background but not the page's backdrop: a page with no
            // background of its own needs one (white) so that it is filtered too. The page's own wins (lower
            // specificity than any `html` rule). A frame shows its page through where it has none.
            if !frame { css.append(":where(html) { background-color: #fff; }") }
            if c.invert { css.append("\(uninverted) { filter: invert(1) hue-rotate(180deg) !important; }") }
        }
        if c.hasTint, !frame {
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
        if let textCase = boost.font.knownCase {
            css.append("body, body \(caseExclusions) { text-transform: \(textCase.rawValue) !important; }")
        }
        // The size is the engine's page zoom (BoostZoom), never CSS.
        // One rule per zap: a selector this engine can't parse drops only its own rule. A zap made in a frame is the
        // frames' only.
        for z in boost.zaps where BoostZap.isValidSelector(z.selector) && (frame || !z.frame) {
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

/// The Boosts file (`Boosts.json` in the data folder): `{"version": 2, "boosts": [...]}`. Changes are kept in memory
/// and written with `flush()` (the app batches slider drags); a file this build can't read is kept beside it as
/// `Boosts.unreadable-<time>.json` instead of being overwritten.
///
/// Version 1 files came from builds with a short list of public suffixes, which gave every "alice.duckdns.org" and
/// "bob.duckdns.org" the one key "duckdns.org". Reading one, a Boost whose key may be shared that way is held
/// (`needsSite`) until the person picks its site in the editor; every other Boost keeps its whole site, code included.
public final class BoostStore {
    public static let version = 2
    public let url: URL?
    public private(set) var boosts: [String: Boost] = [:]
    public private(set) var isDirty = false
    /// Called after every change, with the domain that changed.
    public var onChange: ((String) -> Void)?

    /// The zoom the app gave each host for a Boost's size (BoostZoom), so that it can take it back when the size or
    /// the Boost goes, without touching a zoom the person chose themselves. Chromium keeps a host's zoom in its profile,
    /// so this outlives the pages.
    public private(set) var zoomedHosts: [String: Double] = [:]

    struct File: Codable {
        var version: Int
        var boosts: [Boost]
        var zoomedHosts: [String: Double]?
    }

    /// `url` nil keeps everything in memory.
    /// `suffixes`: the list a version 1 file's keys are checked against (the app's when nil, loaded only then).
    public init(url: URL?, suffixes: PublicSuffixList? = nil) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        do {
            let file = try JSONDecoder.boosts.decode(File.self, from: data)
            for var b in file.boosts {
                if file.version < 2, !b.needsSite, BoostDomain.isSharedLegacyKey(b.domain, suffixes: suffixes ?? .shared) {
                    b.needsSite = true
                    isDirty = true
                }
                boosts[b.domain] = b
            }
            zoomedHosts = (file.zoomedHosts ?? [:]).filter { $0.value > 0 && $0.value < 10 }
            if file.version < Self.version { isDirty = true }
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

    /// A held Boost (`needsSite`) that a page of `host` may be what it was made for: its key is the host or ends it.
    /// The longest such key.
    public func heldBoost(coveringHost host: String) -> Boost? {
        guard let h = BoostDomain.normalize(host) else { return nil }
        return boosts.values.filter { $0.needsSite && (h == $0.domain || h.hasSuffix("." + $0.domain)) }
            .max { $0.domain.count < $1.domain.count }
    }

    /// The person picked the site a held Boost is for: it moves there (replacing an empty Boost there) and applies
    /// again, its code on `host` only, until they choose all of the site. False if the site has a Boost of its own.
    @discardableResult
    public func adopt(held domain: String, to site: String, host: String) -> Bool {
        guard var b = boosts[domain], b.needsSite else { return false }
        if site != domain, let there = boosts[site], !there.isEmpty { return false }
        b.needsSite = false
        b.domain = site
        if b.hasScript { b.scriptHost = BoostDomain.isExactHost(site) ? nil : BoostDomain.normalize(host) }
        b.modified = Date()
        if site != domain { boosts.removeValue(forKey: domain) }
        boosts[site] = b
        isDirty = true
        if site != domain { onChange?(domain) }
        onChange?(site)
        return true
    }

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

    /// Notes (or, with nil, forgets) the zoom the app set on `host` for a Boost. Not a Boost change: no `onChange`.
    public func noteZoom(_ scale: Double?, host: String) {
        guard zoomedHosts[host] != scale else { return }
        zoomedHosts[host] = scale
        isDirty = true
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
            let data = try JSONEncoder.boosts.encode(File(version: Self.version, boosts: all,
                                                          zoomedHosts: zoomedHosts.isEmpty ? nil : zoomedHosts))
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

// MARK: - The size

/// A Boost's size is the page's zoom, the one ⌘+ and ⌘− change (BST-3: the CSS `zoom` it used before scaled every
/// `100vh` box with the text, so full-height layouts grew taller than the window). The app sets it when a page of the
/// site is shown, and takes it back when the size or the Boost goes, but never fights the person: a page they zoomed
/// themselves keeps their zoom. `ledger` is the zoom the app last set for this host (BoostStore.zoomedHosts) or, on an
/// engine whose zoom belongs to the tab rather than the site, for this tab.
public enum BoostZoom {
    /// Chromium's and WebKit's preset zoom steps include every size, so ⌘0 then ⌘+/⌘− steps reach it exactly.
    public static func steps(to scale: Double) -> Int? {
        let order = BoostFont.sizes.sorted { $0.key < $1.key }
        guard let i = order.firstIndex(where: { near($0.value, scale) }) else { return nil }
        return order[i].key
    }

    /// The zoom to set now, or nil to leave the page as it is.
    public static func plan(current: Double, target: Double?, ledger: [Double]) -> Double? {
        if let target {
            if near(current, target) { return nil }
            return near(current, 1) || ledger.contains(where: { near(current, $0) }) ? target : nil
        }
        return !near(current, 1) && ledger.contains(where: { near(current, $0) }) ? 1 : nil
    }

    public static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.005 }
}
