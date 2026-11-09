// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Ranking for the Command Bar (CB-1): open tabs, pinned items, Favorites, Spaces and commands,
/// plus a "search or open" row for what was typed.
public enum CommandSearch {
    public enum Kind: String, Sendable {
        case openTab, pinned, favorite, space, action, history
    }

    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var subtitle: String
        /// Extra words that match (aliases for actions, e.g. "bookmark" for Pin).
        public var keywords: [String]
        /// Higher wins ties; recently used tabs get more.
        public var boost: Double

        public init(id: String, kind: Kind, title: String, subtitle: String = "", keywords: [String] = [],
                    boost: Double = 0) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.keywords = keywords
            self.boost = boost
        }
    }

    public struct Result: Equatable, Sendable {
        public var candidate: Candidate
        public var score: Double
        /// Matched character offsets in the title, for highlighting.
        public var titleMatches: [Int]
        /// How well the query matched, before the kind's weight and the boost (`score`'s scale).
        public var match: Double = 0
    }

    /// Scores `text` against `query`: whole-word prefix > word prefix > substring > in-order
    /// characters. Returns nil when the query doesn't match. Case- and diacritic-insensitive.
    public static func score(_ query: String, in text: String) -> (score: Double, matches: [Int])? {
        score(folded(query), in: folded(text))
    }

    /// The identical scorer for callers that own bounded, off-main prepared text.
    static func score(_ q: Folded, in t: Folded) -> (score: Double, matches: [Int])? {
        guard q.count > 0 else { return (0, []) }
        guard t.count > 0 else { return nil }
        if let qu = q.units, let tu = t.units { return match(qu, in: tu, wordStart: t.wordStart) }
        return match(q.chars, in: t.chars, wordStart: t.wordStart)
    }

    /// The four rules on folded characters (or their scalars, when every character is one). Offsets are characters.
    private static func match<C: Equatable>(_ qc: [C], in tc: [C], wordStart: [Bool]) -> (score: Double, matches: [Int])? {
        let n = tc.count, m = qc.count
        func equal(at i: Int) -> Bool {
            guard i + m <= n else { return false }
            for k in 0..<m where tc[i + k] != qc[k] { return false }
            return true
        }
        if equal(at: 0) { return (100 - Double(n - m) * 0.05, Array(0..<m)) }
        // Word-start prefix.
        if n >= m {
            for i in 0...(n - m) where wordStart[i] && equal(at: i) { return (80 - Double(i) * 0.1, Array(i..<(i + m))) }
            for i in 0...(n - m) where equal(at: i) { return (55 - Double(i) * 0.1, Array(i..<(i + m))) }
        }
        // Subsequence, rewarding runs and word starts.
        var matches: [Int] = []
        var qi = 0
        var s = 0.0
        var last = -2
        for ti in 0..<n where qi < m && tc[ti] == qc[qi] {
            s += (ti == last + 1 ? 3 : 1) + (wordStart[ti] ? 2 : 0)
            matches.append(ti)
            last = ti
            qi += 1
        }
        guard qi == m, m >= 2 else { return nil }
        return (min(40, 10 + s * 20 / Double(m * 5)), matches)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A folded string ready to match: its characters, their scalars when every character is a single one (nearly
    /// always), and where words start. The Command Bar scores the same titles, URLs and keywords on every keystroke;
    /// folding and splitting them again each time was most of a keystroke's main-thread work (§2.12).
    struct Folded: Sendable {
        let chars: [Character]
        let units: [UInt32]?
        let wordStart: [Bool]
        var count: Int { chars.count }

        init(_ text: String) {
            chars = Array(CommandSearch.fold(text))
            var u: [UInt32] = []
            u.reserveCapacity(chars.count)
            for c in chars {
                guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else { u = []; break }
                u.append(scalar.value)
            }
            units = u.count == chars.count ? u : nil
            var starts = [Bool](repeating: false, count: chars.count)
            for i in chars.indices {
                starts[i] = i == 0 || !chars[i - 1].isLetter && !chars[i - 1].isNumber
            }
            wordStart = starts
        }
    }

    private static let cache = FoldCache()

    static func folded(_ text: String) -> Folded { cache.get(text) }

    final class FoldCache: @unchecked Sendable {
        private var entries: [String: Folded] = [:]
        private let lock = NSLock()

        func get(_ text: String) -> Folded {
            lock.lock()
            if let hit = entries[text] { lock.unlock(); return hit }
            lock.unlock()
            let made = Folded(text)
            lock.lock()
            // Bounded: titles, URLs and keywords of one profile's tabs and history hits come to a few hundred.
            if entries.count >= 4_000 { entries.removeAll(keepingCapacity: true) }
            entries[text] = made
            lock.unlock()
            return made
        }
    }

    static let kindWeight: [Kind: Double] = [
        .openTab: 6, .favorite: 5, .pinned: 5, .space: 4, .action: 3, .history: 1,
    ]

    /// Ranked results. An empty query lists candidates by kind and boost (recent tabs first).
    public static func rank(_ query: String, _ candidates: [Candidate], limit: Int = 8) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var results: [Result] = []
        for c in candidates {
            if q.isEmpty {
                results.append(Result(candidate: c, score: (kindWeight[c.kind] ?? 0) + c.boost, titleMatches: []))
                continue
            }
            var best: (Double, [Int])? = nil
            if let m = score(q, in: c.title) { best = (m.score, m.matches) }
            if let m = score(q, in: c.subtitle), m.score * 0.8 > (best?.0 ?? -1) { best = (m.score * 0.8, []) }
            for k in c.keywords {
                if let m = score(q, in: k), m.score * 0.9 > (best?.0 ?? -1) { best = (m.score * 0.9, []) }
            }
            guard let b = best else { continue }
            results.append(Result(candidate: c, score: b.0 + (kindWeight[c.kind] ?? 0) + c.boost, titleMatches: b.1, match: b.0))
        }
        results.sort { ($0.score, $1.candidate.title) > ($1.score, $0.candidate.title) }
        return Array(results.prefix(limit))
    }

    /// One row of `blend`: a result of yours, or a built-in site.
    public enum Blended: Equatable, Sendable {
        case personal(Result)
        case site(CommonSites.Match)
    }

    /// How much better a built-in site must match to go above a result of yours: a site's name prefix (100) stays
    /// under your word-start match (80), and goes over a match in the middle of a word (55) or scattered letters.
    public static let siteMargin: Double = 25
    /// Built-in rows at most, and when the query is clearly a site's name ("google": Google, Calendar, Docs…).
    public static let maxSites = 2
    public static let maxSitesForName = 4

    /// Your results (`personal`, ranked: open tabs, pinned items, Favorites, history, Spaces, commands) and built-in
    /// sites in one list. Yours keep their order. A site goes after every result of yours that matches as well (within
    /// `siteMargin`), so it never pushes down one you would have picked; a site you have open, pinned or in history
    /// (`personalURLs`, see `Site.covers`) isn't repeated; at most `maxSites` sites, `maxSitesForName` when the query is
    /// exactly a site's name or alias.
    public static func blend(_ personal: [Result], sites: [CommonSites.Match], personalURLs: [String],
                             limit: Int = 8) -> [Blended] {
        guard !sites.isEmpty else { return personal.prefix(limit).map { .personal($0) } }
        var pages: [String: [String]] = [:]
        for u in personalURLs {
            guard let c = URLComponents(string: u), var h = c.host?.lowercased() else { continue }
            if h.hasPrefix("www.") { h.removeFirst(4) }
            pages[h, default: []].append(c.path)
        }
        let fresh = sites.filter { s in
            !s.site.hosts.contains { h in pages[h]?.contains { s.site.covers(host: h, path: $0) } ?? false }
        }
        let cap = fresh.contains(where: \.isExact) ? maxSitesForName : maxSites
        var slots: [[CommonSites.Match]] = Array(repeating: [], count: personal.count + 1)
        for s in fresh.prefix(cap) {
            // After the last result of yours that matches as well.
            let at = (personal.lastIndex { $0.match + siteMargin >= s.score }).map { $0 + 1 } ?? 0
            slots[at].append(s)
        }
        var out: [Blended] = slots[0].map { .site($0) }
        for (i, p) in personal.enumerated() {
            out.append(.personal(p))
            out += slots[i + 1].map { .site($0) }
        }
        return Array(out.prefix(limit))
    }
}
