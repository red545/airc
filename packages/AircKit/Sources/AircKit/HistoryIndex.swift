// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// The Command Bar's history index (code review H5). Full-history preparation/search stays off-main;
// the main thread can search a bounded, prebuilt hot tier:
// - Each entry is folded once (case, accents and widths removed) into UTF-8 bytes, on the index's own queue.
// - Full search runs there on an immutable snapshot, with a generation counter: a newer keystroke cancels an older search.
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
    private let localScores: [(url: CommandSearch.Folded, title: CommandSearch.Folded)]?

    static let empty = HistorySnapshot(rows: [], now: Date())

    init(rows: [HistoryRow], now: Date, completionKeys: Bool = true) {
        self.rows = rows
        self.now = now
        localScores = completionKeys ? nil : rows.map { (CommandSearch.Folded($0.displayURL), CommandSearch.Folded($0.entry.title)) }
        guard completionKeys else { hostKeys = []; addressKeys = []; return }
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
        let preparedQuery = localScores == nil ? nil : CommandSearch.Folded(query)
        var out: [HistoryMatch] = []
        for c in candidates {
            let r = rows[c.row]
            var best: (Double, [Int])?
            let urlMatch: (score: Double, matches: [Int])?
            let titleMatch: (score: Double, matches: [Int])?
            if let preparedQuery, let localScores {
                urlMatch = CommandSearch.score(preparedQuery, in: localScores[c.row].url)
                titleMatch = CommandSearch.score(preparedQuery, in: localScores[c.row].title)
            } else {
                urlMatch = CommandSearch.score(query, in: r.displayURL)
                titleMatch = r.entry.title.isEmpty ? nil : CommandSearch.score(query, in: r.entry.title)
            }
            if let m = urlMatch { best = (m.score, []) }
            if let m = titleMatch, m.score > (best?.0 ?? -1) {
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

// The same matcher as the full snapshot, over a bounded hot tier. No new search semantics:
// fuzzy, accent, URL and title matching/highlights stay identical for entries in the tier.
extension HistorySnapshot {
    public static let localEntryLimit = 128
    public static let localTextByteLimit = 512

    static func local<S: Sequence>(rows: S, now: Date) -> HistorySnapshot where S.Element == HistoryRow {
        var recent: [HistoryRow] = [], frequent: [HistoryRow] = []
        func insert(_ row: HistoryRow, into list: inout [HistoryRow], limit: Int,
                    before: (HistoryRow, HistoryRow) -> Bool) {
            if list.count == limit, !before(row, list[list.count - 1]) { return }
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(row, list[mid]) { hi = mid } else { lo = mid + 1 }
            }
            list.insert(row, at: lo)
            if list.count > limit { list.removeLast() }
        }
        // Bound both source bytes and folded bytes (including Unicode expansion), hence also
        // the prepared character/scalar arrays. Oversized pages stay in async full search.
        for r in rows where r.entry.url.utf8.count + r.entry.title.utf8.count <= localTextByteLimit
            && r.display.count + r.title.count <= localTextByteLimit {
            insert(r, into: &recent, limit: localEntryLimit / 2) {
                ($0.entry.lastVisit, $0.entry.url) > ($1.entry.lastVisit, $1.entry.url)
            }
            insert(r, into: &frequent, limit: localEntryLimit) {
                ($0.weight, $0.entry.url) > ($1.weight, $1.entry.url)
            }
        }
        var seen = Set<String>()
        var selected: [HistoryRow] = []
        for r in recent + frequent where seen.insert(r.entry.url).inserted {
            selected.append(r)
            if selected.count == localEntryLimit { break }
        }
        return HistorySnapshot(rows: selected, now: now, completionKeys: false)
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
    private var local: [String: HistorySnapshot] = [:]
    // A deletion invalidates publication immediately, including a build already in flight.
    private var revisions: [String: Int] = [:]
    private var queueRevisions: [String: Int] = [:] // owned by queue
    private var localPending: Set<String> = [] // owned by queue
    private var localPrepared: Set<String> = [] // owned by queue
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
            if self.localPrepared.contains(e.profileID) { self.scheduleLocal(e.profileID, now: now) }
        }
    }

    private func invalidate(_ profileID: String) -> Int {
        lock.withLock {
            generation += 1
            published[profileID] = nil
            local[profileID] = nil
            revisions[profileID, default: 0] += 1
            return revisions[profileID]!
        }
    }

    func remove(profileID: String, url: String) {
        let revision = invalidate(profileID)
        queue.async {
            self.queueRevisions[profileID] = revision
            self.rows[profileID]?[url] = nil
            self.source[profileID]?[url] = nil
            self.dirty.insert(profileID)
            if self.built.contains(profileID) { _ = self.snapshot(profileID, now: Date()) }
            else if self.localPrepared.contains(profileID) { self.publishLocal(profileID, now: Date()) }
        }
    }

    func clear(profileID: String) {
        let revision = invalidate(profileID)
        queue.async {
            self.queueRevisions[profileID] = revision
            self.rows[profileID] = nil
            self.source[profileID] = nil
            self.snapshots[profileID] = nil
            self.built.remove(profileID)
            self.localPrepared.remove(profileID)
            self.dirty.remove(profileID)
        }
    }

    /// Only a pointer copy under the lock; no queue wait, disk read or build on the caller.
    func localSnapshot(_ profileID: String) -> HistorySnapshot? {
        lock.withLock { local[profileID] }
    }

    private func scheduleLocal(_ profileID: String, now: Date) {
        guard localPending.insert(profileID).inserted else { return }
        queue.async {
            self.localPending.remove(profileID)
            guard self.localPrepared.contains(profileID) else { return }
            self.publishLocal(profileID, now: now)
        }
    }

    private static let localEnabled: Bool = {
        #if AIRC_TESTING
        return ProcessInfo.processInfo.environment["AIRC_LOCAL_HISTORY"] != "0"
        #else
        return true
        #endif
    }()

    private func publishLocal(_ profileID: String, now: Date) {
        guard Self.localEnabled else { return }
        localPrepared.insert(profileID)
        let s: HistorySnapshot
        if built.contains(profileID) {
            s = HistorySnapshot.local(rows: (rows[profileID] ?? [:]).values, now: now)
        } else {
            // Keep the full index lazy. The bounded selector retains only its top-k rows;
            // folding the persisted source here never materializes a full row array or completion keys.
            let entries = (source[profileID] ?? [:]).values.lazy.filter {
                $0.url.utf8.count + $0.title.utf8.count <= HistorySnapshot.localTextByteLimit
            }
            s = HistorySnapshot.local(rows: entries.map { HistoryRow($0, now: now) }, now: now)
        }
        let retired = lock.withLock { () -> HistorySnapshot? in
            guard revisions[profileID, default: 0] == queueRevisions[profileID, default: 0] else { return nil }
            return local.updateValue(s, forKey: profileID)
        }
        // Release the old snapshot outside the lock; readers never wait for its array destruction.
        withExtendedLifetime(retired) {}
    }

    /// Idle preparation adds only the bounded tier, leaving full-history storage lazy until opening.
    func prepareLocal(profileID: String, now: Date) {
        queue.async {
            guard !self.localPrepared.contains(profileID) else { return }
            self.publishLocal(profileID, now: now)
        }
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
        publishLocal(profileID, now: t)
        let retired = lock.withLock { () -> HistorySnapshot? in
            guard revisions[profileID, default: 0] == queueRevisions[profileID, default: 0] else { return nil }
            return published.updateValue(s, forKey: profileID)
        }
        withExtendedLifetime(retired) {}
        return s
    }
}
