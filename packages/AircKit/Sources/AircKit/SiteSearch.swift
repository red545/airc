// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// Arc's Site Search (docs/user/command-bar.md): a site searched straight from the Command Bar. Type its shortcut or
/// name, press Tab (or Space, when the profile allows it), type the query, press Return. The address is the site's
/// search page with `%s` where the query goes ("https://www.amazon.com/s?k=%s", Arc's help), as in Arc's and Chrome's
/// search engine settings.
public struct SiteSearch: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The shortcut typed before Tab ("yt"). Compared ignoring case.
    public var keyword: String
    /// The search page with `%s` in place of the query.
    public var template: String

    public init(id: String = UUID().uuidString, name: String, keyword: String, template: String) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.template = template
    }

    /// The page that searches for `query` (trimmed), encoded as Chromium does for its search engines; nil for an empty
    /// query or a template that isn't a web address.
    public func url(for query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return SiteSearchTemplate.expand(template, with: q).flatMap(URL.init(string:))
    }

    /// "youtube.com" for "https://www.youtube.com/results?search_query=%s": the host, lowercased, without "www.".
    public var host: String? { SiteSearchTemplate.host(of: template) }

    /// Whether `url` is a page of this site: its host or a subdomain ("en.wikipedia.org" for wikipedia.org), and, for a
    /// site that is one part of a shared host (Google Maps at www.google.com/maps), that part ("google.com/maps/…", never
    /// docs.google.com or google.com's front page).
    public func covers(_ url: String) -> Bool {
        guard let host else { return false }
        return SiteSearchIndex.covers(url, host: host, section: SiteSearchIndex.section(of: template))
    }

    /// The site's front page ("https://www.youtube.com/"), for its icon.
    public var homeURL: String? {
        guard let u = URLComponents(string: template.replacingOccurrences(of: SiteSearchTemplate.placeholder, with: "x")),
              let scheme = u.scheme, let host = u.host, !host.isEmpty else { return nil }
        return "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")/"
    }

    /// Lowercased letters and digits, for matching what's typed against a name ("Google Maps" → "googlemaps").
    static func fold(_ s: String) -> String {
        String(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Templates: validation, and the query's percent-encoding.
public enum SiteSearchTemplate {
    public static let placeholder = "%s"
    public static let maxLength = 2048

    public enum Problem: String, Error, Equatable, Sendable {
        case empty, noPlaceholder, spaces, tooLong, notWeb, noHost, placeholderInHost, invalid

        public var message: String {
            switch self {
            case .empty: "Enter the site's search address."
            case .noPlaceholder: "Put %s where the search words go, like https://www.amazon.com/s?k=%s."
            case .spaces: "A web address has no spaces."
            case .tooLong: "That address is too long."
            case .notWeb: "Only http and https addresses can be searched."
            case .noHost: "That address has no site in it."
            case .placeholderInHost: "%s goes in the address after the site's name, not in it."
            case .invalid: "That isn't a web address."
            }
        }
    }

    /// The template as it will be kept: trimmed, Chrome's `{searchTerms}` written as `%s`, and "https://" in front of a
    /// bare address ("amazon.com/s?k=%s"). Refuses what can't search a web site: no `%s`, a non-web scheme
    /// (javascript:, data:, file:), no host, `%s` in the host, spaces or control characters.
    public static func normalize(_ input: String) -> Result<String, Problem> {
        var t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.empty) }
        guard t.count <= maxLength else { return .failure(.tooLong) }
        t = t.replacingOccurrences(of: "{searchTerms}", with: placeholder)
        guard t.contains(placeholder) else { return .failure(.noPlaceholder) }
        guard !t.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.spaces) }
        if let scheme = scheme(of: t) {
            guard scheme == "http" || scheme == "https" else { return .failure(.notWeb) }
            // The scheme lowercased, the rest as written.
            t = scheme + t[t.firstIndex(of: ":")!...]
            guard t.hasPrefix(scheme + "://") else { return .failure(.noHost) }
        } else {
            t = "https://" + t
        }
        // The address must hold up with a query in it, and the query must go after the host.
        let sample = t.replacingOccurrences(of: placeholder, with: "x")
        guard let parts = URLComponents(string: sample), URL(string: sample) != nil else { return .failure(.invalid) }
        guard let host = parts.host, !host.isEmpty else { return .failure(.noHost) }
        let authority = t[t.range(of: "://")!.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if authority.contains(placeholder) { return .failure(.placeholderInHost) }
        guard host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-.[]:".unicodeScalars.contains($0) }),
              !host.hasPrefix("."), !host.contains("..") else { return .failure(.invalid) }
        return .success(t)
    }

    /// "https" for "https://…"; nil for a bare address, "example.com:8443/…" and "localhost:8080" included (a port, not
    /// a scheme).
    private static func scheme(of t: String) -> String? {
        guard let colon = t.firstIndex(of: ":") else { return nil }
        let s = t[..<colon]
        guard let f = s.first, f.isASCII, f.isLetter,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        if t[t.index(after: colon)...].first?.isNumber == true { return nil }
        return s.lowercased()
    }

    public static func isValid(_ template: String) -> Bool {
        if case .success(let t) = normalize(template) { return t == template }
        return false
    }

    /// The template with every `%s` replaced by `query`, escaped as Chromium's TemplateURLRef escapes search terms: after
    /// a "?" as a query value (space as "+", everything but letters, digits and !'()*-._~ as %XX), before it (path or
    /// fragment, Spotify's /search/%s, Gmail's #apps/%s) as a path (space as %20; "/", "&", "+" and the like kept).
    /// UTF-8, uppercase hex.
    public static func expand(_ template: String, with query: String) -> String? {
        guard let first = template.range(of: placeholder) else { return nil }
        let inQuery = template[..<first.lowerBound].contains("?")
        return template.replacingOccurrences(of: placeholder, with: escape(query, inQuery: inQuery))
    }

    public static func escape(_ text: String, inQuery: Bool) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count * 3)
        for b in text.utf8 {
            if inQuery && b == 0x20 {
                out.append("+")
            } else if inQuery ? queryEscapes(b) : pathEscapes(b) {
                out.append("%")
                out.append(hex[Int(b >> 4)])
                out.append(hex[Int(b & 0xF)])
            } else {
                out.unicodeScalars.append(Unicode.Scalar(b))
            }
        }
        return out
    }

    private static let hex = Array("0123456789ABCDEF")

    /// base::EscapeQueryParamValue's set: everything except alphanumerics and !'()*-._~.
    private static func queryEscapes(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: false
        case UInt8(ascii: "!"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"),
             UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"): false
        default: true
        }
    }

    /// base::EscapePath's set: control characters, non-ASCII, space and "#%:<>?[\]^`{|}.
    private static func pathEscapes(_ b: UInt8) -> Bool {
        if b < 0x20 || b >= 0x7F { return true }
        return " \"#%:<>?[\\]^`{|}".utf8.contains(b)
    }

    static func host(of template: String) -> String? {
        guard let h = URLComponents(string: template.replacingOccurrences(of: placeholder, with: "x"))?.host?.lowercased(),
              !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

/// A problem with one field of a site search being added or edited.
public struct SiteSearchProblem: Error, Equatable, Sendable {
    public enum Field: String, Sendable { case name, keyword, template }
    public let field: Field
    public let message: String
}

/// Every profile's site searches (Settings → Site Search), kept in the app settings. Profiles are separate, as Arc's
/// (each Arc profile has its own Chromium search engines): a profile nobody has changed has Arc's seeded sites; once
/// its list is changed, its own list is kept. Each profile also says whether Space starts a site search (Chromium's
/// "Space or Tab"; Arc moved everyone to Tab only, so that's the default).
public struct SiteSearchSettings: Codable, Equatable, Sendable {
    public struct ProfileSearches: Codable, Equatable, Sendable {
        public var searches: [SiteSearch]
        public var spaceTriggers: Bool
        /// The site this profile searches when what's typed isn't an address (P07d, Chrome's "Make default"); nil: the
        /// profile's built-in engine. Kept by id, so an edited site stays the default and a removed one hands back.
        public var defaultID: String?

        public init(searches: [SiteSearch], spaceTriggers: Bool = false, defaultID: String? = nil) {
            self.searches = searches
            self.spaceTriggers = spaceTriggers
            self.defaultID = defaultID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // An entry a newer build (or a hand edit) left malformed is dropped, not the whole list.
            let raw = (try? c.decodeIfPresent([Lenient].self, forKey: .searches)) ?? []
            searches = raw.compactMap(\.value).filter { SiteSearchTemplate.isValid($0.template) }
            spaceTriggers = (try? c.decodeIfPresent(Bool.self, forKey: .spaceTriggers)) ?? false
            // Only a site still in the list: a hand edit or an older build's removal can't leave a dangling default.
            let d = (try? c.decodeIfPresent(String.self, forKey: .defaultID)) ?? nil
            defaultID = d.flatMap { id in searches.contains { $0.id == id } ? id : nil }
        }

        private struct Lenient: Decodable {
            let value: SiteSearch?
            init(from decoder: Decoder) throws { value = try? SiteSearch(from: decoder) }
        }
    }

    /// Profile ID → its list, for the profiles whose list or setting was changed.
    public private(set) var profiles: [String: ProfileSearches] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One profile's record that doesn't read (a newer build's, a hand edit) is dropped, not every profile's.
        let raw = (try? c.decodeIfPresent([String: LenientProfile].self, forKey: .profiles)) ?? [:]
        profiles = raw.compactMapValues(\.value)
    }

    private struct LenientProfile: Decodable {
        let value: ProfileSearches?
        init(from decoder: Decoder) throws { value = try? ProfileSearches(from: decoder) }
    }

    /// Arc's seeded popular site searches (Arc 1.170's `seededPopularSiteSearches`, its search addresses as Arc has them;
    /// the old twitter.com entry is X's). The shortcuts are Airc's; a site also matches its name ("you", "google m").
    public static let defaults: [SiteSearch] = [
        ("drive", "Google Drive", "drive", "https://drive.google.com/drive/search?q=%s"),
        ("gmail", "Gmail", "gmail", "https://mail.google.com/mail/ca/u/0/#apps/%s"),
        ("maps", "Google Maps", "maps", "https://www.google.com/maps/search/%s"),
        ("calendar", "Google Calendar", "gcal", "https://calendar.google.com/calendar/u/0/r/search?q=%s"),
        ("docs", "Google Docs", "gdocs", "https://docs.google.com/document/u/0/?q=%s"),
        ("dropbox", "Dropbox", "dropbox", "https://www.dropbox.com/search/personal?&query=%s"),
        ("amazon", "Amazon", "amazon", "https://www.amazon.com/s?k=%s"),
        ("github", "GitHub", "gh", "https://github.com/search?q=%s"),
        ("figma", "Figma", "figma", "https://www.figma.com/files/search?q=%s"),
        ("x", "X", "x", "https://x.com/search?q=%s"),
        ("youtube", "YouTube", "yt", "https://www.youtube.com/results?search_query=%s"),
        ("wikipedia", "Wikipedia", "wiki", "https://wikipedia.org/w/index.php?search=%s"),
        ("reddit", "Reddit", "reddit", "https://www.reddit.com/search/?q=%s"),
        ("soundcloud", "SoundCloud", "soundcloud", "https://soundcloud.com/search?q=%s"),
        ("asana", "Asana", "asana", "https://app.asana.com/0/search?q=%s"),
        ("linkedin", "LinkedIn", "linkedin", "https://linkedin.com/search/results/all/?keywords=%s"),
        ("applemusic", "Apple Music", "music", "https://music.apple.com/us/search?term=%s"),
        ("spotify", "Spotify", "sp", "https://open.spotify.com/search/%s"),
    ].map { SiteSearch(id: "default." + $0.0, name: $0.1, keyword: $0.2, template: $0.3) }

    public func searches(for profileID: String) -> [SiteSearch] { profiles[profileID]?.searches ?? Self.defaults }

    public func spaceTriggers(for profileID: String) -> Bool { profiles[profileID]?.spaceTriggers ?? false }

    public mutating func setSpaceTriggers(_ on: Bool, for profileID: String) {
        var p = profiles[profileID] ?? ProfileSearches(searches: Self.defaults)
        p.spaceTriggers = on
        profiles[profileID] = p
    }

    /// The entry these fields make, or what's wrong with them: a name, a shortcut without spaces (and not "/", which
    /// lists actions) that no other site of this profile has, and a template that `SiteSearchTemplate` accepts.
    public func check(name: String, keyword: String, template: String, for profileID: String,
                      editing id: String? = nil) -> Result<SiteSearch, SiteSearchProblem> {
        let n = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !n.isEmpty else { return .failure(.init(field: .name, message: "Give the site a name.")) }
        guard n.count <= 80 else { return .failure(.init(field: .name, message: "That name is too long.")) }
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return .failure(.init(field: .keyword, message: "Choose a shortcut, like yt.")) }
        guard !k.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return .failure(.init(field: .keyword, message: "A shortcut has no spaces.")) }
        guard !k.hasPrefix("/") else { return .failure(.init(field: .keyword, message: "A shortcut can't start with /: that lists actions.")) }
        guard k.count <= 40 else { return .failure(.init(field: .keyword, message: "That shortcut is too long.")) }
        if let other = searches(for: profileID).first(where: { $0.id != id && $0.keyword.lowercased() == k.lowercased() }) {
            return .failure(.init(field: .keyword, message: "\(other.name) already uses \(k)."))
        }
        switch SiteSearchTemplate.normalize(template) {
        case .failure(let p): return .failure(.init(field: .template, message: p.message))
        case .success(let t): return .success(SiteSearch(id: id ?? UUID().uuidString, name: n, keyword: k, template: t))
        }
    }

    @discardableResult
    public mutating func add(name: String, keyword: String, template: String, to profileID: String) -> Result<SiteSearch, SiteSearchProblem> {
        let r = check(name: name, keyword: keyword, template: template, for: profileID)
        if case .success(let s) = r { change(profileID) { $0.append(s) } }
        return r
    }

    @discardableResult
    public mutating func update(_ id: String, name: String, keyword: String, template: String,
                                in profileID: String) -> Result<SiteSearch, SiteSearchProblem> {
        guard searches(for: profileID).contains(where: { $0.id == id }) else {
            return .failure(.init(field: .name, message: "That site was removed."))
        }
        let r = check(name: name, keyword: keyword, template: template, for: profileID, editing: id)
        if case .success(let s) = r { change(profileID) { list in list = list.map { $0.id == id ? s : $0 } } }
        return r
    }

    public mutating func remove(_ id: String, from profileID: String) {
        change(profileID) { $0.removeAll { $0.id == id } }
        // The default goes with its site: the profile searches its built-in engine again.
        if profiles[profileID]?.defaultID == id { profiles[profileID]?.defaultID = nil }
    }

    // MARK: A site search as the default engine (P07d)

    /// The site this profile searches by default, if one of its sites is the default; nil: its built-in engine.
    public func defaultSite(for profileID: String) -> SiteSearch? {
        guard let id = profiles[profileID]?.defaultID else { return nil }
        return searches(for: profileID).first { $0.id == id }
    }

    /// What this profile searches when what's typed isn't an address: its default site, else `engine` (the profile's
    /// built-in engine, Settings → Profiles → Search engine).
    public func defaultSearch(for profileID: String, engine: SearchEngine) -> DefaultSearch {
        defaultSite(for: profileID).map(DefaultSearch.site) ?? .engine(engine)
    }

    /// Makes site `id` this profile's default search (nil: back to the built-in engine). False, and nothing changed,
    /// for a site the profile doesn't have.
    @discardableResult
    public mutating func setDefault(_ id: String?, for profileID: String) -> Bool {
        if let id, !searches(for: profileID).contains(where: { $0.id == id }) { return false }
        if id == nil, profiles[profileID]?.defaultID == nil { return true }
        var p = profiles[profileID] ?? ProfileSearches(searches: Self.defaults)
        p.defaultID = id
        profiles[profileID] = p
        return true
    }

    /// Puts back the seeded sites this profile removed (not one whose shortcut another site now has); keeps its own.
    public mutating func restoreDefaults(for profileID: String) {
        change(profileID) { list in
            for d in Self.defaults where !list.contains(where: { $0.id == d.id || $0.keyword.lowercased() == d.keyword.lowercased() }) {
                list.append(d)
            }
        }
    }

    /// A deleted profile's list goes with it.
    public mutating func forget(profileID: String) { profiles[profileID] = nil }

    /// Drops the lists of profiles that no longer exist.
    public mutating func prune(keeping profileIDs: Set<String>) {
        profiles = profiles.filter { profileIDs.contains($0.key) }
    }

    private mutating func change(_ profileID: String, _ edit: (inout [SiteSearch]) -> Void) {
        var p = profiles[profileID] ?? ProfileSearches(searches: Self.defaults)
        edit(&p.searches)
        profiles[profileID] = p
    }
}

/// What a profile searches when what's typed isn't an address (P07d): its built-in engine (Google, DuckDuckGo…), or one
/// of its site searches made the default in Settings → Site Search, as Chrome's search engine page makes any site search
/// the default. The site's query is encoded as its site search encodes it (`SiteSearchTemplate.expand`).
public enum DefaultSearch: Equatable, Sendable {
    case engine(SearchEngine)
    case site(SiteSearch)

    /// "Google", "Amazon": for "Search Amazon" and the like.
    public var name: String {
        switch self {
        case .engine(let e): e.name
        case .site(let s): s.name
        }
    }

    public var site: SiteSearch? {
        if case .site(let s) = self { return s }
        return nil
    }

    /// The page that searches for `query`; nil for an empty query (or a site whose address can't hold it).
    public func url(for query: String) -> URL? {
        switch self {
        case .engine(let e):
            return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : e.searchURL(for: query)
        case .site(let s):
            return s.url(for: query)
        }
    }
}

extension URLRules {
    /// What Return does with typed text: open it if it's an address, else search for it with `search` (the profile's
    /// default, a site search included).
    public static func resolve(_ input: String, search: DefaultSearch) -> URL? {
        switch search {
        case .engine(let e): return resolve(input, engine: e)
        case .site(let s):
            let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            if let u = normalizeInput(t), let url = URL(string: u) { return url }
            return s.url(for: t)
        }
    }
}

/// One profile's site searches, ready for matching on every keystroke: shortcuts, hosts and names are folded once.
public struct SiteSearchIndex: Equatable, Sendable {
    public let searches: [SiteSearch]
    private let keywords: [String]
    private let hosts: [String?]
    /// The first path segment of each template ("maps" for Google Maps' www.google.com/maps/search/%s).
    private let sections: [String]
    private let names: [String]

    public init(_ searches: [SiteSearch]) {
        self.searches = searches
        keywords = searches.map { $0.keyword.lowercased() }
        hosts = searches.map(\.host)
        sections = searches.map { Self.section(of: $0.template) }
        names = searches.map { SiteSearch.fold($0.name) }
    }

    /// Paths that search a whole site; any other first segment ("maps", "drive") is one part of a shared host.
    private static let siteWide: Set<String> = ["", "search", "results", "s", "w", "find", "query"]

    private static func firstSegment(_ path: String?) -> String {
        (path ?? "").split(separator: "/").first.map { $0.lowercased() } ?? ""
    }

    static func section(of template: String) -> String {
        firstSegment(URLComponents(string: template.replacingOccurrences(of: SiteSearchTemplate.placeholder, with: "x"))?.path)
    }

    /// `url`'s host (without "www.") and its first path segment; a bare host ("youtube.com") is read as https.
    private static func parts(_ url: String) -> (host: String, section: String)? {
        let c = URLComponents(string: url).flatMap { $0.host == nil ? nil : $0 } ?? URLComponents(string: "https://" + url)
        guard var host = c?.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return (host, firstSegment(c?.path))
    }

    /// A page of the site at `host` whose template starts with `section`: the host or a subdomain, and the same part of
    /// a shared host unless the template searches the whole site.
    static func covers(_ url: String, host: String, section: String, subdomains: Bool = true) -> Bool {
        guard let p = parts(url) else { return false }
        let sameHost = p.host == host || (subdomains && p.host.hasSuffix("." + host))
        return sameHost && (siteWide.contains(section) || p.section == section)
    }

    /// The site of the address `url` (typed, or completed inline): its own host first, then a site it's a subdomain of;
    /// google.com isn't Google Maps (www.google.com/maps/…) but google.com/maps is.
    private func site(at url: String) -> Int? {
        let own = hosts.indices.first { i in hosts[i].map { Self.covers(url, host: $0, section: sections[i], subdomains: false) } ?? false }
        return own ?? hosts.indices.first { i in hosts[i].map { Self.covers(url, host: $0, section: sections[i]) } ?? false }
    }

    /// The site Tab would search for `typed`: a site whose shortcut it is ("yt"); else the site of `host`, the address
    /// typed or completed inline ("you" completing to youtube.com, as Chrome's "Press Tab to search YouTube"); else the
    /// one site whose name starts with it ("google m", "spot"; at least two letters unless it's the whole name).
    /// Never for "/…" (actions). A few string compares per site.
    public func match(_ typed: String, host: String? = nil) -> SiteSearch? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("/"), !searches.isEmpty else { return nil }
        let lower = t.lowercased()
        if let i = keywords.firstIndex(of: lower) { return searches[i] }
        if let host, let i = site(at: host) { return searches[i] }
        let folded = SiteSearch.fold(t)
        guard !folded.isEmpty else { return nil }
        let named = names.indices.filter { names[$0].hasPrefix(folded) }
        if let exact = named.first(where: { names[$0] == folded }) { return searches[exact] }
        guard folded.count >= 2, named.count == 1 else { return nil }
        return searches[named[0]]
    }

    /// Space as the trigger ("Space or Tab"): only right after a whole shortcut ("yt "), never after a name, so a
    /// search like "you know" stays a search.
    public func spaceMatch(_ text: String) -> SiteSearch? {
        guard text.hasSuffix(" "), !text.hasSuffix("  ") else { return nil }
        let k = text.dropLast().lowercased()
        guard !k.isEmpty, !k.contains(" "), let i = keywords.firstIndex(of: k) else { return nil }
        return searches[i]
    }

    public func contains(_ id: String) -> Bool { searches.contains { $0.id == id } }
}
