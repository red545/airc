// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Browsing history for the Command Bar (CB-1, SP-24). History is per profile, like Chromium's: a page visited in the
// Work profile never shows up in Personal. The Chromium engine keeps its own history database per profile; until
// the app reads that, the app records visits here. This is local data only and never goes in the sync op log.

/// One page in a profile's history.
public struct HistoryEntry: Hashable, Sendable {
    public var profileID: String
    public var url: String
    public var title: String
    public var visitCount: Int
    /// Visits that started from typing the address (or picking it in the Command Bar).
    public var typedCount: Int
    public var lastVisit: Date

    public init(profileID: String, url: String, title: String = "", visitCount: Int = 1, typedCount: Int = 0, lastVisit: Date) {
        self.profileID = profileID
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }

    /// Chromium-style frecency: visits (typed ones count more) decayed by age. 1 visit today ≈ 1.
    public func frecency(now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastVisit) / 86400)
        let recency: Double = switch days {
        case ..<1: 1
        case ..<4: 0.7
        case ..<14: 0.5
        case ..<31: 0.3
        case ..<90: 0.15
        default: 0.05
        }
        return (Double(visitCount) + 2 * Double(typedCount)) * recency
    }
}

public final class HistoryStore {
    public static let maxEntriesPerProfile = 20_000
    private let db: Database
    private var entries: [String: [String: HistoryEntry]] = [:]   // profile → url → entry
    private let indexer = HistoryIndexer()
    public var now: () -> Date = Date.init

    /// Opens (or creates) the history database at `path`; nil keeps it in memory (tests).
    public init(path: String?) throws {
        if let path {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        db = try Database(path: path)
        try db.exec("""
            CREATE TABLE IF NOT EXISTS visits(
              profile TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, visits INTEGER NOT NULL,
              typed INTEGER NOT NULL, last REAL NOT NULL, PRIMARY KEY(profile, url));
            """)
        for row in try db.query("SELECT profile, url, title, visits, typed, last FROM visits") {
            guard let p = row[0] as? String, let u = row[1] as? String else { continue }
            let e = HistoryEntry(profileID: p, url: u, title: row[2] as? String ?? "", visitCount: Int(row[3] as? Int64 ?? 1),
                                 typedCount: Int(row[4] as? Int64 ?? 0),
                                 lastVisit: Date(timeIntervalSince1970: row[5] as? Double ?? 0))
            entries[p, default: [:]][u] = e
        }
        indexer.load(entries)
    }

    /// Only web pages are history.
    public static func records(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Records a main-frame navigation.
    public func recordVisit(profileID: String, url: String, title: String = "", typed: Bool = false) {
        guard Self.records(url) else { return }
        var e = entries[profileID]?[url] ?? HistoryEntry(profileID: profileID, url: url, visitCount: 0, lastVisit: now())
        e.visitCount += 1
        if typed { e.typedCount += 1 }
        if !title.isEmpty { e.title = title }
        e.lastVisit = now()
        entries[profileID, default: [:]][url] = e
        write(e)
        indexer.update(e, now: now())
        if (entries[profileID]?.count ?? 0) > Self.maxEntriesPerProfile { prune(profileID) }
    }

    /// Another browser's history (IM-4), merged in one transaction: a page Airc already has keeps the higher visit and
    /// typed counts and the later visit, and takes the imported title if it had none. Counts are never added up, so
    /// importing the same history again changes nothing. Only web pages; a profile past the limit is pruned as usual.
    @discardableResult
    public func importVisits(_ visits: [HistoryEntry]) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        var changed: [HistoryEntry] = []
        for v in visits where Self.records(v.url) {
            if let old = entries[v.profileID]?[v.url] {
                var e = old
                e.visitCount = max(old.visitCount, v.visitCount)
                e.typedCount = max(old.typedCount, v.typedCount)
                if v.lastVisit > old.lastVisit { e.lastVisit = v.lastVisit }
                if old.title.isEmpty, !v.title.isEmpty { e.title = v.title }
                guard e != old else { continue }
                entries[v.profileID]?[v.url] = e
                changed.append(e)
                updated += 1
            } else {
                entries[v.profileID, default: [:]][v.url] = v
                changed.append(v)
                added += 1
            }
        }
        guard !changed.isEmpty else { return (0, 0) }
        try? db.transaction { for e in changed { write(e) } }
        let t = now()
        for e in changed { indexer.update(e, now: t) }
        for p in Set(changed.map(\.profileID)) where (entries[p]?.count ?? 0) > Self.maxEntriesPerProfile { prune(p) }
        return (added, updated)
    }

    /// The page's title arrived after the visit.
    public func updateTitle(profileID: String, url: String, title: String) {
        guard !title.isEmpty, var e = entries[profileID]?[url], e.title != title else { return }
        e.title = title
        entries[profileID]?[url] = e
        write(e)
        indexer.update(e, now: now())
    }

    public func entries(ofProfile id: String) -> [HistoryEntry] {
        Array(entries[id]?.values ?? [:].values)
    }

    public func entry(profileID: String, url: String) -> HistoryEntry? { entries[profileID]?[url] }

    /// Deletes a profile's history (profile deleted, or "clear this profile's data").
    public func clear(profileID: String) {
        entries[profileID] = nil
        indexer.clear(profileID: profileID)
        try? db.run("DELETE FROM visits WHERE profile=?", [.text(profileID)])
    }

    /// Builds the profile's search index off the main thread (call when the Command Bar opens).
    public func prepareIndex(profileID: String) { indexer.prepare(profileID: profileID, now: now()) }

    /// Searches off the main thread (H5). A newer search cancels this one; `completion` runs on the main queue, and not
    /// at all when cancelled.
    public func search(_ query: String, profileID: String, limit: Int = 8,
                       completion: @escaping @Sendable ([HistoryMatch]) -> Void) {
        indexer.search(query, profileID: profileID, limit: limit, now: now(), completion: completion)
    }

    /// The latest built index, for inline completion on the main thread: a binary search, no scan. nil until the
    /// first build finishes.
    public func indexSnapshot(profileID: String) -> HistorySnapshot? { indexer.publishedSnapshot(profileID) }

    /// The index, built now if needed (tests and measurements; blocks until the index queue is done).
    public func indexSnapshotNow(profileID: String) -> HistorySnapshot { indexer.snapshotNow(profileID, now: now()) }

    /// The best matches for what was typed, ranked by match quality and frecency. Synchronous: it waits for the index
    /// queue (tests); the Command Bar uses `search(_:profileID:limit:completion:)`.
    public func search(_ query: String, profileID: String, limit: Int = 6) -> [(entry: HistoryEntry, score: Double, matches: [Int])] {
        indexer.searchNow(query, profileID: profileID, limit: limit, now: now()).map { ($0.entry, $0.score, $0.matches) }
    }

    /// Inline autocompletion from this profile's history (see `InlineCompletion`).
    public func inlineCompletion(for typed: String, profileID: String) -> InlineCompletion.Match? {
        indexSnapshotNow(profileID: profileID).inlineCompletion(for: typed)
    }

    private func write(_ e: HistoryEntry) {
        try? db.run("""
            INSERT INTO visits(profile, url, title, visits, typed, last) VALUES(?,?,?,?,?,?)
            ON CONFLICT(profile, url) DO UPDATE SET title=excluded.title, visits=excluded.visits, typed=excluded.typed, last=excluded.last
            """, [.text(e.profileID), .text(e.url), .text(e.title), .int(Int64(e.visitCount)), .int(Int64(e.typedCount)),
                  .real(e.lastVisit.timeIntervalSince1970)])
    }

    private func prune(_ profileID: String) {
        guard let all = entries[profileID] else { return }
        let t = now()
        let keep = all.values.sorted { $0.frecency(now: t) > $1.frecency(now: t) }.prefix(Self.maxEntriesPerProfile * 9 / 10)
        let kept = Set(keep.map(\.url))
        for url in all.keys where !kept.contains(url) {
            entries[profileID]?[url] = nil
            indexer.remove(profileID: profileID, url: url)
            try? db.run("DELETE FROM visits WHERE profile=? AND url=?", [.text(profileID), .text(url)])
        }
    }
}

/// Inline autocompletion for the Command Bar (Chrome's and Arc's): typing "gi" shows "github.com" with "thub.com"
/// selected after the caret. Only completes when what was typed is a prefix of a known address, ignoring the
/// scheme and "www.". Completes to the host while the typing is still in the host, and to the full address once it
/// reaches the path.
public enum InlineCompletion {
    public struct Match: Equatable, Sendable {
        /// The full text to show: what was typed plus the completion.
        public var text: String
        /// The URL to open if the user accepts it.
        public var url: String
        /// The part after what was typed (shown selected).
        public var suffix: String { String(text.dropFirst(typedCount)) }
        public var typedCount: Int
    }

    /// A completion target ("github.com", or "github.com/apple/swift" once the typing reaches the path) with the summed
    /// weight of its pages. The history index keeps them sorted, for a binary search per keystroke.
    public struct Key: Sendable {
        public var text: String
        public var url: String
        public var weight: Double
        let bytes: [UInt8]

        init(text: String, url: String, weight: Double) {
            self.text = text
            self.url = url
            self.weight = weight
            bytes = Array(text.utf8)
        }
    }

    /// A URL's host target (lowercased, no "www.", with the port), the URL that completing to the host opens, and its
    /// address target. nil for anything but http(s).
    static func targets(_ url: String) -> (host: String, hostURL: String, address: String)? {
        guard let u = URLComponents(string: url), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = u.host?.lowercased() else { return nil }
        var host = rawHost
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let port = u.port { host += ":\(port)" }
        return (host, "\(scheme)://\(rawHost)\(u.port.map { ":\($0)" } ?? "")/", URLRules.displayURL(url).lowercased())
    }

    /// `candidates` are (url, weight); higher weight wins among prefix matches.
    public static func complete(_ typed: String, candidates: [(url: String, weight: Double)]) -> Match? {
        complete(typed, hostKeys: [], addressKeys: [], extra: candidates)
    }

    /// The same, with most candidates already in sorted keys (the history index) and a few `extra` ones.
    static func complete(_ typed: String, hostKeys: [Key], addressKeys: [Key], extra: [(url: String, weight: Double)]) -> Match? {
        let raw = typed
        guard !raw.isEmpty, raw.rangeOfCharacter(from: .whitespaces) == nil else { return nil }
        let lower = raw.lowercased()
        // Typing a scheme or "www." means the user is spelling it out; match without it, keep it in the text.
        var body = lower
        for p in ["https://", "http://"] where body.hasPrefix(p) { body.removeFirst(p.count) }
        if body.hasPrefix("www.") { body.removeFirst(4) }
        guard !body.isEmpty else { return nil }
        let inHost = !body.contains("/")
        // The heaviest target wins (the shorter one on a tie). The index's keys are unique and sorted, already summed
        // per target, so the walk over them allocates nothing: this runs on the main thread on every keystroke, and
        // one letter matches thousands of hosts in a full history.
        let keys = inHost ? hostKeys : addressKeys
        var best: (text: String, url: String, weight: Double)?
        func consider(_ text: String, _ url: String, _ weight: Double) {
            guard let b = best else { best = (text, url, weight); return }
            if weight > b.weight || (weight == b.weight && text.count < b.text.count) { best = (text, url, weight) }
        }
        let b = Array(body.utf8)
        var i = firstKey(atLeast: b, in: keys)
        while i < keys.count, keys[i].bytes.starts(with: b) {
            let k = keys[i]
            if k.bytes.count > b.count, best.map({ k.weight >= $0.weight }) ?? true { consider(k.text, k.url, k.weight) }
            i += 1
        }
        // Open tabs and pinned items (a handful) add their weight to the history's for the same target.
        var extras: [String: (url: String, weight: Double)] = [:]
        for c in extra {
            guard let t = targets(c.url) else { continue }
            let target = inHost ? t.host : t.address
            guard target.hasPrefix(body), target.count > body.count else { continue }
            let url = inHost ? t.hostURL : c.url
            extras[target] = (extras[target]?.url ?? url, (extras[target]?.weight ?? 0) + c.weight)
        }
        for (target, e) in extras {
            let tb = Array(target.utf8)
            let j = firstKey(atLeast: tb, in: keys)
            if j < keys.count, keys[j].bytes == tb {
                consider(target, keys[j].url, keys[j].weight + e.weight)
            } else {
                consider(target, e.url, e.weight)
            }
        }
        guard let best, best.text.count > body.count else { return nil }
        // Keep exactly what was typed (its case), then the completion.
        let text = raw + best.text.dropFirst(body.count)
        return Match(text: text, url: best.url, typedCount: raw.count)
    }

    /// The index of the first key not ordered before `bytes` (keys are sorted by their bytes).
    private static func firstKey(atLeast bytes: [UInt8], in keys: [Key]) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if keys[mid].bytes.lexicographicallyPrecedes(bytes) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Search suggestions from the profile's search engine (CB-1). The app fetches them; parsing lives here so it can
/// be tested.
public enum SearchSuggestions {
    /// The endpoint for an engine's suggestions (OpenSearch "suggestions" JSON), or nil if it has none.
    public static func url(for query: String, engine: SearchEngine) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let q = query.addingPercentEncoding(withAllowedCharacters: allowed), !q.isEmpty else { return nil }
        switch engine {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/ac/?type=list&q=\(q)")
        case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=\(q)")
        case .ecosia: return URL(string: "https://ac.ecosia.org/autocomplete?type=list&q=\(q)")
        case .kagi: return nil
        }
    }

    /// Parses OpenSearch suggestions: `["query", ["s1", "s2", …], …]`. Drops the query itself and blanks.
    public static func parse(_ data: Data, query: String, limit: Int = 4) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2,
              let list = root[1] as? [Any] else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        var out: [String] = []
        for case let s as String in list {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, t.lowercased() != q, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count == limit { break }
        }
        return out
    }
}

/// One signed-in Google account from ListAccounts. It stays on this Mac: never logged, never in telemetry.
public struct GoogleAccount: Equatable, Sendable {
    public var name: String?
    public var email: String
    /// The account picture, on Google's image host.
    public var photoURL: String?

    public init(name: String? = nil, email: String, photoURL: String? = nil) {
        self.name = name
        self.email = email
        self.photoURL = photoURL
    }
}

/// The Google accounts signed in to a profile (SB-22), read from Google's ListAccounts response, which Chromium also
/// uses: `["gaia.l.a.r",[["gaia.l.a",1,"Name","user@example.com","https://…/photo",…],…]]`.
public enum GoogleAccounts {
    public static func emails(fromListAccounts text: String) -> [String] {
        (accounts(fromListAccounts: text) ?? []).map(\.email)
    }

    /// The signed-in accounts, primary first; `[]` when the answer says nobody is signed in, nil when `text` isn't a
    /// ListAccounts answer at all (an error page, a sign-in page). The JSON may sit inside a page's text (a browser's
    /// JSON viewer adds its own words around it).
    public static func accounts(fromListAccounts text: String) -> [GoogleAccount]? {
        guard let start = text.range(of: "[\"gaia.l.a.r\"")?.lowerBound, let end = text.range(of: "]", options: .backwards)?.upperBound,
              start < end, let data = String(text[start..<end]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2 else { return nil }
        guard let list = root[1] as? [Any] else { return nil }
        var out: [GoogleAccount] = []
        for case let a as [Any] in list {
            // Field 3 is the email; skip signed-out entries (field 9 is 0 for those when present).
            guard a.count > 3, let email = a[3] as? String, email.contains("@") else { continue }
            if a.count > 9, let valid = a[9] as? Int, valid == 0 { continue }
            let name = (a[2] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let photo = a.count > 4 ? (a[4] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
            out.append(GoogleAccount(name: name, email: email, photoURL: photo))
        }
        return out
    }
}
