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
        // Every rule needs each of the query's characters somewhere in the text: one missing (by `mask`) is no match.
        // Only where both compare by scalars: equal Characters can have different scalars (Å, Å).
        if prefilters, q.units != nil, t.units != nil, q.mask & ~t.mask != 0 { return nil }
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
        /// Which scalars occur (bit: the value mod 64). When both texts are compared by scalars (`units`), a text whose
        /// mask lacks a bit of the query's can't contain the query's characters, in any order (keyframe2).
        let mask: UInt64
        var count: Int { chars.count }

        init(_ text: String) {
            chars = Array(CommandSearch.fold(text))
            var u: [UInt32] = []
            u.reserveCapacity(chars.count)
            var bits: UInt64 = 0
            for c in chars {
                if let first = c.unicodeScalars.first { bits |= 1 << UInt64(first.value & 63) }
            }
            mask = bits
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

    /// The character-mask prefilters (keyframe2). Results are the same either way; test builds turn them off to time
    /// the old ranking in the same binary. Set once, at launch, before any ranking.
    nonisolated(unsafe) public static var prefilters = true

    static func folded(_ text: String) -> Folded { cache.get(text) }

    /// Folds `texts` now (call it off the main thread) and keeps them apart from the bounded cache, replacing the
    /// previous set: the Command Bar's command titles and words, so its first keystroke folds none of them.
    public static func prepare(_ texts: [String]) {
        var made: [String: Folded] = [:]
        made.reserveCapacity(texts.count)
        for t in texts where made[t] == nil { made[t] = cache.peek(t) ?? Folded(t) }
        cache.setPrepared(made)
    }

    final class FoldCache: @unchecked Sendable {
        private var entries: [String: Folded] = [:]
        private var prepared: [String: Folded] = [:]
        private let lock = NSLock()

        func peek(_ text: String) -> Folded? {
            lock.lock(); defer { lock.unlock() }
            return prepared[text] ?? entries[text]
        }

        func setPrepared(_ p: [String: Folded]) {
            lock.lock(); prepared = p; lock.unlock()
        }

        func get(_ text: String) -> Folded {
            lock.lock()
            if let hit = prepared[text] ?? entries[text] { lock.unlock(); return hit }
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
        var none: Narrowing?
        return rank(query, candidates, limit: limit, stable: 0..<0, narrowing: &none)
    }

    /// What a query matched in a stable run of candidates (the Command Bar's commands, the same list from key to key),
    /// so the next query that extends it scores only those (cbrows). Matching is monotonic: every rule (prefix, word
    /// prefix, substring, in-order characters) that a longer query meets, the query it extends meets too, so a candidate
    /// the shorter query missed can never match the longer one. The order of what's scored is unchanged, so results are
    /// identical to scoring every candidate.
    public struct Narrowing: Sendable {
        fileprivate let query: [UInt32]
        fileprivate let matched: [Int]
        /// Candidates of the stable run the last query matched (cbperf reports it).
        public var count: Int { matched.count }
    }

    /// The stable run's texts folded once, with each candidate's characters (keyframe2): its title, subtitle and
    /// keywords as `folded` gives them, so scoring them gives the same results without a cache lookup per text, and a
    /// candidate none of whose texts has every character of the query is skipped without scoring.
    public struct PreparedRun: Sendable {
        fileprivate struct Item: Sendable {
            let title: Folded
            let subtitle: Folded?
            let keywords: [Folded]
            /// The union of the texts' masks; nil when one of them isn't compared by scalars (no prefilter then).
            let mask: UInt64?
        }
        fileprivate let items: [Item]
        public var count: Int { items.count }

        public init(_ candidates: [Candidate]) {
            items = candidates.map { c in
                let title = CommandSearch.folded(c.title)
                let subtitle = c.subtitle.isEmpty ? nil : CommandSearch.folded(c.subtitle)
                let keywords = c.keywords.map { CommandSearch.folded($0) }
                let texts = [title] + (subtitle.map { [$0] } ?? []) + keywords
                let mask = texts.allSatisfy { $0.units != nil } ? texts.reduce(UInt64(0)) { $0 | $1.mask } : nil
                return Item(title: title, subtitle: subtitle, keywords: keywords, mask: mask)
            }
        }
    }

    /// `rank`, scoring only what `narrowing` allows of `candidates[stable]` when `query` extends its query, and
    /// leaving in `narrowing` what this query matched there. The caller resets `narrowing` to nil whenever that run
    /// changes. Results are the same as `rank(query, candidates, limit:)`'s. `prepared`, when given, must be made from
    /// `candidates[stable]` (the same candidates in the same order); one of another length is ignored.
    public static func rank(_ query: String, _ candidates: [Candidate], limit: Int = 8, stable: Range<Int>,
                            narrowing: inout Narrowing?, prepared: PreparedRun? = nil) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var results: [Result] = []
        if q.isEmpty {
            for c in candidates {
                results.append(Result(candidate: c, score: (kindWeight[c.kind] ?? 0) + c.boost, titleMatches: []))
            }
            narrowing = nil
        } else {
            // The query folded once (scoring it against each text used to fold it again, through the cache, each time).
            let fq = folded(q)
            func scored(_ c: Candidate) -> Result? {
                var best: (Double, [Int])? = nil
                if let m = score(fq, in: folded(c.title)) { best = (m.score, m.matches) }
                if !c.subtitle.isEmpty, let m = score(fq, in: folded(c.subtitle)), m.score * 0.8 > (best?.0 ?? -1) { best = (m.score * 0.8, []) }
                for k in c.keywords {
                    if let m = score(fq, in: folded(k)), m.score * 0.9 > (best?.0 ?? -1) { best = (m.score * 0.9, []) }
                }
                guard let b = best else { return nil }
                return Result(candidate: c, score: b.0 + (kindWeight[c.kind] ?? 0) + c.boost, titleMatches: b.1, match: b.0)
            }
            let run = stable.clamped(to: candidates.indices)
            let prep = prepared.flatMap { $0.count == run.count ? $0.items : nil }
            // The same as `scored`, from the run's prepared texts (`k`: the index in the run).
            func scoredInRun(_ k: Int) -> Result? {
                guard let prep else { return scored(candidates[run.lowerBound + k]) }
                let p = prep[k]
                if prefilters, fq.units != nil, let mask = p.mask, fq.mask & ~mask != 0 { return nil }
                let c = candidates[run.lowerBound + k]
                var best: (Double, [Int])? = nil
                if let m = score(fq, in: p.title) { best = (m.score, m.matches) }
                if let sub = p.subtitle, let m = score(fq, in: sub), m.score * 0.8 > (best?.0 ?? -1) { best = (m.score * 0.8, []) }
                for k in p.keywords {
                    if let m = score(fq, in: k), m.score * 0.9 > (best?.0 ?? -1) { best = (m.score * 0.9, []) }
                }
                guard let b = best else { return nil }
                return Result(candidate: c, score: b.0 + (kindWeight[c.kind] ?? 0) + c.boost, titleMatches: b.1, match: b.0)
            }
            // Narrow only when both queries are single scalars per character, so both take the same comparison
            // (`match` on scalars) against every text, and the new one starts with the old one.
            var only: [Int]?
            if let n = narrowing, let units = fq.units, !n.query.isEmpty, units.count >= n.query.count,
               Array(units.prefix(n.query.count)) == n.query { only = n.matched }
            var matched: [Int] = []
            for i in candidates.startIndex..<run.lowerBound { if let r = scored(candidates[i]) { results.append(r) } }
            if let only {
                for k in only where run.lowerBound + k < run.upperBound {
                    if let r = scoredInRun(k) { results.append(r); matched.append(k) }
                }
            } else {
                for k in 0..<run.count { if let r = scoredInRun(k) { results.append(r); matched.append(k) } }
            }
            for i in run.upperBound..<candidates.endIndex { if let r = scored(candidates[i]) { results.append(r) } }
            narrowing = fq.units.map { Narrowing(query: $0, matched: matched) }
        }
        results.sort { ($0.score, $1.candidate.title) > ($1.score, $0.candidate.title) }
        return Array(results.prefix(limit))
    }

    /// A page's host (lowercased, no "www.") and path, as `blend` compares them with built-in sites.
    static func page(_ url: String) -> (host: String, path: String)? {
        guard let c = URLComponents(string: url), var h = c.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return (h, c.path)
    }

    /// `page` remembered per address (keyframe2): `blend` parsed every open tab's and history row's address on every
    /// keystroke that matched a built-in site. Test builds turn it off to time the old path in the same binary.
    nonisolated(unsafe) public static var memoizesPages = true
    private static let pageMemo = PageMemo()

    private final class PageMemo: @unchecked Sendable {
        private var entries: [String: (host: String, path: String)?] = [:]
        private let lock = NSLock()

        func get(_ url: String) -> (host: String, path: String)? {
            lock.lock()
            if let hit = entries[url] { lock.unlock(); return hit }
            lock.unlock()
            let made = CommandSearch.page(url)
            lock.lock()
            if entries.count >= 4_000 { entries.removeAll(keepingCapacity: true) }
            entries[url] = .some(made)
            lock.unlock()
            return made
        }
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
            guard let p = memoizesPages ? pageMemo.get(u) : page(u) else { continue }
            pages[p.host, default: []].append(p.path)
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
