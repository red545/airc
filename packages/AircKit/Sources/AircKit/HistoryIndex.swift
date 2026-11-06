// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// The Command Bar's history index (code review H5). A keystroke never parses URLs, folds strings or scans history on
// the main thread:
// - Each entry is folded once (case, accents and widths removed) into UTF-8 bytes, on the index's own queue.
// - Search runs there on an immutable snapshot, with a generation counter: a newer keystroke cancels an older search.
//   A byte scan picks candidates with a cheap pre-score; only the best few hundred get the full CommandSearch score.
// - Inline completion is a binary search in sorted host and address keys, cheap enough for the main thread.

/// A history match for the Command Bar.
public struct HistoryMatch: Sendable, Equatable {
    public var entry: HistoryEntry
    public var score: Double
    /// Matched character offsets in the title, for highlighting.
    public var matches: [Int]
}

/// One entry, folded for matching.
struct HistoryRow: Sendable {
    let entry: HistoryEntry
    let displayURL: String
    let display: [UInt8]
    let title: [UInt8]
    let weight: Double

    init(_ e: HistoryEntry, now: Date) {
        entry = e
        displayURL = URLRules.displayURL(e.url)
        display = HistoryIndex.fold(displayURL)
        title = e.title.isEmpty ? [] : HistoryIndex.fold(e.title)
        weight = e.frecency(now: now) + Double(e.typedCount)
    }
}

/// An immutable, searchable picture of one profile's history.
public struct HistorySnapshot: Sendable {
    let rows: [HistoryRow]
    /// Inline completion keys (InlineCompletion's targets), sorted bytewise, weights summed per key.
    let hostKeys: [InlineCompletion.Key]
    let addressKeys: [InlineCompletion.Key]
    let now: Date

    static let empty = HistorySnapshot(rows: [], now: Date())

    init(rows: [HistoryRow], now: Date) {
        self.rows = rows
        self.now = now
        var hosts: [String: InlineCompletion.Key] = [:]
        var addresses: [String: InlineCompletion.Key] = [:]
        for r in rows {
            guard let t = InlineCompletion.targets(r.entry.url) else { continue }
            hosts[t.host, default: .init(text: t.host, url: t.hostURL, weight: 0)].weight += r.weight
            addresses[t.address, default: .init(text: t.address, url: r.entry.url, weight: 0)].weight += r.weight
        }
        hostKeys = hosts.values.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        addressKeys = addresses.values.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }

    public var count: Int { rows.count }

    /// The best `limit` matches for `query`. `cancelled` is polled during the scan.
    public func search(_ query: String, limit: Int = 8, cancelled: () -> Bool = { false }) -> [HistoryMatch] {
        let q = HistoryIndex.fold(query)
        guard !q.isEmpty, !rows.isEmpty else { return [] }
        // Pre-score: prefix 4, word start 3, substring 2, in-order characters 1. Ties go to the most-used page.
        var candidates: [(row: Int, key: Double)] = []
        candidates.reserveCapacity(min(rows.count, 4096))
        for (i, r) in rows.enumerated() {
            if i & 2047 == 0, cancelled() { return [] }
            let p = max(HistoryIndex.preScore(q, r.display), HistoryIndex.preScore(q, r.title))
            if p > 0 { candidates.append((i, Double(p) * 1_000_000 + r.weight)) }
        }
        if candidates.count > HistoryIndex.scoredCandidates {
            candidates.sort { $0.key > $1.key }
            candidates.removeLast(candidates.count - HistoryIndex.scoredCandidates)
        }
        var out: [HistoryMatch] = []
        for c in candidates {
            let r = rows[c.row]
            var best: (Double, [Int])?
            if let m = CommandSearch.score(query, in: r.displayURL) { best = (m.score, []) }
            if !r.entry.title.isEmpty, let m = CommandSearch.score(query, in: r.entry.title), m.score > (best?.0 ?? -1) {
                best = (m.score, m.matches)
            }
            guard let b = best else { continue }
            // Frecency adds up to ~12 points: a page you live on beats a one-off with a slightly better match.
            out.append(HistoryMatch(entry: r.entry, score: b.0 + min(12, 4 * log2(1 + r.entry.frecency(now: now))), matches: b.1))
        }
        out.sort { ($0.score, $0.entry.lastVisit) > ($1.score, $1.entry.lastVisit) }
        return Array(out.prefix(limit))
    }

    /// Whether any page of this history is on `host` (lowercased, without "www."): a binary search, for the main thread.
    public func hasHost(_ host: String) -> Bool {
        let b = Array(host.utf8)
        var lo = 0, hi = hostKeys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hostKeys[mid].bytes.lexicographicallyPrecedes(b) { lo = mid + 1 } else { hi = mid }
        }
        return lo < hostKeys.count && hostKeys[lo].bytes == b
    }

    /// Inline completion from this history plus `extra` candidates (open tabs, pinned items: a handful).
    public func inlineCompletion(for typed: String, extra: [(url: String, weight: Double)] = []) -> InlineCompletion.Match? {
        InlineCompletion.complete(typed, hostKeys: hostKeys, addressKeys: addressKeys, extra: extra)
    }
}

enum HistoryIndex {
    /// How many pre-scored candidates get the full score.
    static let scoredCandidates = 300

    static func fold(_ s: String) -> [UInt8] {
        // ASCII (most URLs and many titles): lowercase the bytes. Anything else: CommandSearch's fold.
        if s.utf8.allSatisfy({ $0 < 0x80 }) {
            var b = Array(s.utf8)
            for i in b.indices where b[i] >= 65 && b[i] <= 90 { b[i] += 32 }
            var lo = 0, hi = b.count
            while lo < hi, b[lo] == 32 { lo += 1 }
            while hi > lo, b[hi - 1] == 32 { hi -= 1 }
            return Array(b[lo..<hi])
        }
        return Array(CommandSearch.fold(s).utf8)
    }

    @inline(__always) static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b >= 0x80
    }

    /// 4 prefix, 3 word start, 2 substring, 1 characters in order (two or more), 0 no match.
    static func preScore(_ q: [UInt8], _ t: [UInt8]) -> Int {
        let n = q.count, m = t.count
        guard n > 0, m >= n else { return n >= 2 && m > 0 ? (isSubsequence(q, t) ? 1 : 0) : 0 }
        let first = q[0]
        var found = 0
        var i = 0
        while i <= m - n {
            if t[i] == first {
                var j = 1
                while j < n && t[i + j] == q[j] { j += 1 }
                if j == n {
                    if i == 0 { return 4 }
                    if !isWordByte(t[i - 1]) { return 3 }
                    found = 2
                }
            }
            i += 1
        }
        if found > 0 { return found }
        return n >= 2 && isSubsequence(q, t) ? 1 : 0
    }

    static func isSubsequence(_ q: [UInt8], _ t: [UInt8]) -> Bool {
        var qi = 0
        for b in t where qi < q.count && b == q[qi] { qi += 1 }
        return qi == q.count
    }
}

/// Owns the folded rows and snapshots, on its own queue. HistoryStore feeds it every change.
final class HistoryIndexer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.airc.history-index", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`: read from any thread.
    private var generation = 0
    private var published: [String: HistorySnapshot] = [:]
    // Owned by `queue`.
    private var rows: [String: [String: HistoryRow]] = [:]
    private var built: Set<String> = []
    private var source: [String: [String: HistoryEntry]] = [:]
    private var dirty: Set<String> = []
    private var snapshots: [String: HistorySnapshot] = [:]

    /// The entries loaded at launch. Rows are folded lazily, per profile, the first time it's searched or prepared.
    func load(_ entries: [String: [String: HistoryEntry]]) {
        queue.async { self.source = entries; self.dirty = Set(entries.keys) }
    }

    func update(_ e: HistoryEntry, now: Date) {
        queue.async {
            if self.built.contains(e.profileID) { self.rows[e.profileID, default: [:]][e.url] = HistoryRow(e, now: now) }
            else { self.source[e.profileID, default: [:]][e.url] = e }
            self.dirty.insert(e.profileID)
        }
    }

    func remove(profileID: String, url: String) {
        queue.async {
            self.rows[profileID]?[url] = nil
            self.source[profileID]?[url] = nil
            self.dirty.insert(profileID)
        }
    }

    func clear(profileID: String) {
        queue.async {
            self.rows[profileID] = nil
            self.source[profileID] = nil
            self.built.remove(profileID)
            self.dirty.insert(profileID)
        }
        lock.withLock { published[profileID] = nil }
    }

    /// Builds the profile's snapshot ahead of the first keystroke (the Command Bar opening).
    func prepare(profileID: String, now: Date) {
        queue.async { _ = self.snapshot(profileID, now: now) }
    }

    /// The latest built snapshot, for inline completion on the main thread (nil until the first build).
    func publishedSnapshot(_ profileID: String) -> HistorySnapshot? {
        lock.withLock { published[profileID] }
    }

    /// Searches off the main thread. A newer call cancels this one; `completion` runs on the main queue, and not at all
    /// when cancelled.
    func search(_ query: String, profileID: String, limit: Int, now: Date,
                completion: @escaping @Sendable ([HistoryMatch]) -> Void) {
        let gen = lock.withLock { generation += 1; return generation }
        let current: @Sendable () -> Bool = { [weak self] in self?.lock.withLock { self?.generation != gen } ?? true }
        queue.async {
            guard !current() else { return }
            let hits = self.snapshot(profileID, now: now).search(query, limit: limit, cancelled: current)
            guard !current() else { return }
            DispatchQueue.main.async { if !current() { completion(hits) } }
        }
    }

    /// Synchronous search (tests and the old API).
    func searchNow(_ query: String, profileID: String, limit: Int, now: Date) -> [HistoryMatch] {
        queue.sync { snapshot(profileID, now: now).search(query, limit: limit) }
    }

    func snapshotNow(_ profileID: String, now: Date) -> HistorySnapshot { queue.sync { snapshot(profileID, now: now) } }

    /// On `queue`.
    private func snapshot(_ profileID: String, now t: Date) -> HistorySnapshot {
        if !dirty.contains(profileID), let s = snapshots[profileID] { return s }
        if !built.contains(profileID) {
            var r: [String: HistoryRow] = [:]
            for (url, e) in source[profileID] ?? [:] { r[url] = HistoryRow(e, now: t) }
            rows[profileID] = r
            source[profileID] = nil
            built.insert(profileID)
        }
        let s = HistorySnapshot(rows: Array((rows[profileID] ?? [:]).values), now: t)
        snapshots[profileID] = s
        dirty.remove(profileID)
        lock.withLock { published[profileID] = s }
        return s
    }
}
