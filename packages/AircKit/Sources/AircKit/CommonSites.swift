// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Well-known sites the Command Bar offers before you have ever been there (CB-1): with no history, "spot" offers
// Spotify, "gma" Gmail, "yt" YouTube, "derst" Der Standard. The list is built in (CommonSitesData.swift). It is parsed
// and indexed once, off the main thread, the first time the Command Bar opens; after that a keystroke is a binary
// search in sorted keys, cheap enough for the main thread (the same frame as the other local results, §2.12).
// Your own open tabs, pinned items, Favorites and history always rank above it (`CommandSearch.blend`).

public enum CommonSites {
    public struct Site: Sendable, Hashable {
        /// The site's proper name ("Spotify", "Der Standard").
        public var name: String
        /// Its most useful entry page ("https://open.spotify.com").
        public var url: String
        /// Hosts that are this site, lowercased, without "www.": the entry page's, then other domains it goes by
        /// ("open.spotify.com", "spotify.com"). A page of yours on one of them stands in for this site.
        public var hosts: [String]
        /// Short and other names ("yt", "gcal", "google mail"), folded.
        public var aliases: [String]
        /// 1 a household name, 2 well known, 3 known.
        public var tier: Int
        /// The regions it is for ("at", "de"), lowercased ISO codes ("uk" for Great Britain); empty for everywhere.
        public var regions: [String]

        /// The entry page's path ("/maps" for Google Maps), "" when it is the host's home page.
        public var path: String {
            guard let p = URLComponents(string: url)?.path, p != "/" else { return "" }
            return p
        }

        /// `covers(host:path:)` for a URL.
        public func covers(url: String) -> Bool {
            guard let c = URLComponents(string: url), var h = c.host?.lowercased() else { return false }
            if h.hasPrefix("www.") { h.removeFirst(4) }
            return covers(host: h, path: c.path)
        }

        /// The hosts the list completes and finds this site by: its own domains, and its entry page's host unless the
        /// site is a part of that host (Google Maps is not google.com).
        public var keyHosts: [String] { path.isEmpty ? hosts : Array(hosts.dropFirst()) }

        /// A page of yours (host without "www.", path) stands in for this site: it is on one of the site's hosts, and
        /// under the entry page's path when the site is a part of its host (Sheets in docs.google.com/spreadsheets).
        public func covers(host: String, path: String) -> Bool {
            guard let i = hosts.firstIndex(of: host) else { return false }
            let own = self.path
            return i > 0 || own.isEmpty || path == own || path.hasPrefix(own + "/")
        }
    }

    public struct Match: Sendable, Equatable {
        public var site: Site
        /// How well the query matches, on CommandSearch.score's scale (100: a prefix of the name).
        public var score: Double
        /// `score` plus the site's tier and region, for ordering sites among themselves.
        public var rank: Double
        /// Matched character offsets in the name, for highlighting.
        public var matches: [Int]
        /// The query is the site's name, an alias, a host or a host's name part ("youtube", "yt", "youtube.com"):
        /// clearly this site.
        public var isExact: Bool
    }

    /// A built-in completion: the text and URL (as InlineCompletion's) and the site it is.
    public struct Completion: Sendable, Equatable {
        public var match: InlineCompletion.Match
        public var site: Site
    }

    /// Regions an "eu" site is for (the EU, EFTA and the UK).
    static let europe: Set<String> = ["at", "be", "bg", "hr", "cy", "cz", "dk", "ee", "fi", "fr", "de", "gr", "hu", "ie",
                                      "it", "lv", "lt", "lu", "mt", "nl", "pl", "pt", "ro", "sk", "si", "es", "se", "ch",
                                      "no", "is", "li", "uk"]

    /// The fewest characters before the list offers anything: one letter matches too much to mean a site.
    public static let minimumQuery = 2

    /// The lowercased host of `url` without "www.", the key a page of yours is compared on.
    public static func hostKey(_ url: String) -> String? {
        guard var h = URLComponents(string: url)?.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// This Mac's region, as the list writes it ("at"; "uk" for GB).
    public static var currentRegion: String? {
        guard let r = Locale.current.region?.identifier.lowercased() else { return nil }
        return r == "gb" ? "uk" : r
    }

    /// Parses the list: one site per line, `tier|Name|entry URL without https://|aliases and other domains|regions`
    /// (lists comma-separated). Blank lines and `#` comments are skipped, as are lines that don't parse.
    public static func parse(_ text: String) -> [Site] {
        var out: [Site] = []
        out.reserveCapacity(2_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            let f = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let tier = Int(f[0]), !f[1].isEmpty, !f[2].isEmpty else { continue }
            let url = "https://" + f[2]
            guard let host = hostKey(url) else { continue }
            var hosts = [host]
            var aliases: [String] = []
            if f.count > 3 {
                for a in f[3].split(separator: ",") {
                    let alias = a.trimmingCharacters(in: .whitespaces).lowercased()
                    guard !alias.isEmpty else { continue }
                    if alias.contains("."), !alias.contains(" ") {
                        let h = alias.hasPrefix("www.") ? String(alias.dropFirst(4)) : alias
                        if !hosts.contains(h) { hosts.append(h) }
                    } else {
                        aliases.append(CommandSearch.fold(alias))
                    }
                }
            }
            let regions = f.count > 4 ? f[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } : []
            out.append(Site(name: f[1], url: url, hosts: hosts, aliases: aliases, tier: tier, regions: regions))
        }
        return out
    }
}

/// The list, indexed for prefix search. Immutable and Sendable: built once off the main thread, then read from any.
public struct CommonSitesSnapshot: Sendable {
    public let sites: [CommonSites.Site]

    struct Key: Sendable {
        let bytes: [UInt8]
        let site: Int32
    }

    /// Folded names, every later word of a name ("standard" for Der Standard), aliases and hosts, sorted bytewise.
    let keys: [Key]
    /// Hosts only (inline completion: the field shows an address).
    let hostKeys: [Key]
    /// Folded name, its letters without spaces, aliases, hosts and hosts' first labels: what makes a query exact.
    let exact: [Set<String>]

    public init(sites: [CommonSites.Site]) {
        self.sites = sites
        var keys: [Key] = [], hostKeys: [Key] = []
        var exact: [Set<String>] = []
        keys.reserveCapacity(sites.count * 5)
        exact.reserveCapacity(sites.count)
        for (i, s) in sites.enumerated() {
            let id = Int32(i)
            var seen = Set<[UInt8]>()
            func add(_ text: String) {
                let b = HistoryIndex.fold(text)
                if !b.isEmpty, seen.insert(b).inserted { keys.append(Key(bytes: b, site: id)) }
            }
            let name = CommandSearch.fold(s.name)
            add(name)
            let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for w in words.indices.dropFirst() { add(words[w...].joined(separator: " ")) }
            s.aliases.forEach(add)
            var ex: Set<String> = [name, name.filter { $0.isLetter || $0.isNumber }]
            for a in s.aliases { ex.insert(a) }
            // A site that is a part of its host (Google Maps at google.com/maps) is found by its name and its own
            // domains, not its host's: "google.com" is Google, and completes to Google.
            for h in s.keyHosts {
                add(h)
                hostKeys.append(Key(bytes: Array(h.utf8), site: id))
                ex.insert(h)
                if let label = Self.nameLabel(h) { ex.insert(label) }
            }
            exact.append(ex)
        }
        keys.sort { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        hostKeys.sort { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        self.keys = keys
        self.hostKeys = hostKeys
        self.exact = exact
    }

    public var count: Int { sites.count }

    /// Second-level suffixes under which the name comes one label earlier ("bbc" in bbc.co.uk).
    static let secondLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "co.at", "or.at", "gv.at", "ac.at",
                                           "com.au", "co.jp", "co.nz", "co.za", "com.br", "co.in", "com.mx", "com.tr"]

    /// The name part of a registrable host ("youtube" in youtube.com, "bbc" in bbc.co.uk); nil for subdomains.
    static func nameLabel(_ host: String) -> String? {
        let labels = host.split(separator: ".")
        if labels.count == 2 { return String(labels[0]) }
        if labels.count == 3, secondLevel.contains(labels[1...].joined(separator: ".")) { return String(labels[0]) }
        return nil
    }

    /// The site whose hosts include `host` (lowercased, without "www."), if any.
    public func site(forHost host: String) -> CommonSites.Site? {
        let b = Array(host.utf8)
        let i = Self.firstKey(atLeast: b, in: hostKeys)
        guard i < hostKeys.count, hostKeys[i].bytes == b else { return nil }
        return sites[Int(hostKeys[i].site)]
    }

    /// What a query looks like to the keys: folded, without a scheme or "www.".
    static func body(_ query: String) -> [UInt8] {
        var q = HistoryIndex.fold(query)
        for p in ["https://", "http://", "www."] where q.starts(with: Array(p.utf8)) { q.removeFirst(p.utf8.count) }
        return q
    }

    /// Sites whose name, a later word of the name, an alias or a host starts with `query`, best first. `region` lifts
    /// sites for that region and lowers sites for others.
    public func search(_ query: String, region: String? = CommonSites.currentRegion, limit: Int = 4) -> [CommonSites.Match] {
        let q = Self.body(query.trimmingCharacters(in: .whitespaces))
        guard q.count >= CommonSites.minimumQuery, limit > 0 else { return [] }
        var found: [Int32] = []
        var i = Self.firstKey(atLeast: q, in: keys)
        // Two letters can start a few hundred keys; the best sites are among the first scored anyway (tier breaks ties).
        while i < keys.count, keys[i].bytes.starts(with: q), found.count < 400 {
            if !found.contains(keys[i].site) { found.append(keys[i].site) }
            i += 1
        }
        let text = String(decoding: q, as: UTF8.self)
        var out: [CommonSites.Match] = []
        for id in found {
            let s = sites[Int(id)]
            var best: (score: Double, matches: [Int]) = (0, [])
            if let m = CommandSearch.score(text, in: s.name) { best = m }
            for a in s.aliases {
                if let m = CommandSearch.score(text, in: a), m.score * 0.95 > best.score { best = (m.score * 0.95, []) }
            }
            for h in s.hosts {
                if let m = CommandSearch.score(text, in: h), m.score * 0.9 > best.score { best = (m.score * 0.9, []) }
            }
            guard best.score > 0 else { continue }
            let isExact = exact[Int(id)].contains(text)
            let rank = best.score + Self.bonus(s, region: region) + (isExact ? 10 : 0)
            out.append(.init(site: s, score: isExact ? max(best.score, 100) : best.score, rank: rank, matches: best.matches,
                             isExact: isExact))
        }
        out.sort { ($0.rank, $1.site.name) > ($1.rank, $0.site.name) }
        return Array(out.prefix(limit))
    }

    /// Inline completion from the list: "spot" → "spotify.com" (opening Spotify's entry page). Only while the typing
    /// is still in the host; the best-known site wins, then the shorter host.
    public func inlineCompletion(for typed: String, region: String? = CommonSites.currentRegion) -> CommonSites.Completion? {
        guard !typed.isEmpty, typed.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        let lower = typed.lowercased()
        var body = lower
        for p in ["https://", "http://"] where body.hasPrefix(p) { body.removeFirst(p.count) }
        if body.hasPrefix("www.") { body.removeFirst(4) }
        guard body.count >= CommonSites.minimumQuery, !body.contains("/") else { return nil }
        let b = Array(body.utf8)
        var best: (key: Key, rank: Double)?
        var i = Self.firstKey(atLeast: b, in: hostKeys)
        while i < hostKeys.count, hostKeys[i].bytes.starts(with: b) {
            let k = hostKeys[i]
            i += 1
            guard k.bytes.count > b.count else { continue }
            let r = Self.bonus(sites[Int(k.site)], region: region)
            if let cur = best, r < cur.rank || (r == cur.rank && k.bytes.count >= cur.key.bytes.count) { continue }
            best = (k, r)
        }
        guard let best else { return nil }
        let site = sites[Int(best.key.site)]
        let host = String(decoding: best.key.bytes, as: UTF8.self)
        let text = typed + host.dropFirst(body.count)
        return .init(match: InlineCompletion.Match(text: text, url: site.url, typedCount: typed.count), site: site)
    }

    /// Tier and region: a household name gets 4, a well-known one 2; the Mac's region 3, another region's site −3.
    /// "eu" in a site's regions means any European region.
    static func bonus(_ s: CommonSites.Site, region: String?) -> Double {
        let tier: Double = s.tier <= 1 ? 4 : s.tier == 2 ? 2 : 0
        guard !s.regions.isEmpty else { return tier }
        if let region, s.regions.contains(region) || (s.regions.contains("eu") && CommonSites.europe.contains(region)) {
            return tier + 3
        }
        return tier - 3
    }

    static func firstKey(atLeast bytes: [UInt8], in keys: [Key]) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].bytes.lexicographicallyPrecedes(bytes) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Builds the built-in list's index once, off the main thread, and hands it out.
public final class CommonSitesIndex: @unchecked Sendable {
    public static let shared = CommonSitesIndex { CommonSites.parse(CommonSitesData.list) }

    private let source: @Sendable () -> [CommonSites.Site]
    private let lock = NSLock()
    private var built: CommonSitesSnapshot?
    private var started = false
    /// How long the last build took (parse, fold, sort), in milliseconds.
    public private(set) var buildMilliseconds: Double = 0

    public init(source: @escaping @Sendable () -> [CommonSites.Site]) {
        self.source = source
    }

    /// Starts the build on a background queue (the Command Bar's first opening); later calls do nothing.
    public func prepare() {
        let start = lock.withLock { () -> Bool in
            if started { return false }
            started = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = self.build() }
    }

    /// The index, or nil while it is still being built (the Command Bar then shows no built-in sites yet).
    public var snapshot: CommonSitesSnapshot? { lock.withLock { built } }

    /// The index, built here and now if needed (tests and measurements).
    public func snapshotNow() -> CommonSitesSnapshot {
        if let s = snapshot { return s }
        lock.withLock { started = true }
        return build()
    }

    private func build() -> CommonSitesSnapshot {
        let t0 = Date()
        let s = CommonSitesSnapshot(sites: source())
        let ms = Date().timeIntervalSince(t0) * 1000
        return lock.withLock {
            if let b = built { return b }
            built = s
            buildMilliseconds = ms
            return s
        }
    }
}
