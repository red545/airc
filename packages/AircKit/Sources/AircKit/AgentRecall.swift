// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// The Airc Agent's `search_history` tool (agentrecall): the person's history and tabs in ONE profile, on the Command
/// Bar's own index (HistoryStore.recall), so the agent can find "that article about X I read last week" or "the tab
/// with the flight booking". Read only, on this Mac: no new storage; what leaves it is only the tool's answer the model
/// reads (titles, cleaned addresses, when). Private windows: never (`unavailable`).
public enum AgentRecall {
    /// Where a result is.
    public enum Place: String, Codable, Sendable {
        case openTab = "open tab", pinnedTab = "pinned tab", favorite, history

        /// Tabs rank above a history entry with the same match: the person has them now.
        var bonus: Double {
            switch self {
            case .openTab: return 8
            case .pinnedTab, .favorite: return 6
            case .history: return 0
            }
        }
    }

    /// An open tab, pinned tab or Favorite of the profile.
    public struct Tab: Sendable, Equatable {
        public var title: String
        public var url: String
        public var place: Place
        public var lastUsed: Date?

        public init(title: String, url: String, place: Place, lastUsed: Date? = nil) {
            self.title = title
            self.url = url
            self.place = place
            self.lastUsed = lastUsed
        }
    }

    /// One result, as the model reads it and the task view lists it.
    public struct Hit: Codable, Sendable, Equatable {
        public var title: String
        /// Cleaned (`clean`): no sign-in parts, fragment or token-like query values.
        public var url: String
        public var site: String
        public var place: Place
        public var lastVisit: Date?
        public var visits: Int?
        public var score: Double

        public init(title: String, url: String, site: String, place: Place, lastVisit: Date? = nil, visits: Int? = nil, score: Double = 0) {
            self.title = title
            self.url = url
            self.site = site
            self.place = place
            self.lastVisit = lastVisit
            self.visits = visits
            self.score = score
        }
    }

    public static let defaultLimit = 8
    public static let maxLimit = 20
    public static let maxWords = 8
    public static let titleLimit = 140
    public static let unavailablePrivate = "History search isn't available in private windows: Airc never shows the agent a private window's pages or history."

    /// Words that only glue a sentence ("the article about kyoto" → kyoto), in the languages the model writes queries in
    /// most. A query of nothing but these keeps them.
    static let stopWords: Set<String> = ["the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "with", "about", "from",
                                         "my", "i", "that", "this", "der", "die", "das", "und", "le", "la", "les", "de"]

    /// The query's words, folded the way the index folds (case, accents, widths), at most `maxWords`.
    public static func words(_ query: String) -> [String] {
        let all = CommandSearch.fold(query)
            .split { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "'" || $0 == "’") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-'’")) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0).inserted }
        let kept = unique.filter { !stopWords.contains($0) && ($0.count >= 2 || $0.first?.isNumber == true) }
        return Array((kept.isEmpty ? unique : kept).prefix(maxWords))
    }

    /// How well a tab matches the words (nil: fewer than half of them), on the Command Bar's scorer. A word counts only
    /// from a substring match up, as in the history recall.
    public static func score(_ words: [String], title: String, url: String) -> (found: Int, score: Double)? {
        guard !words.isEmpty else { return nil }
        let display = URLRules.displayURL(url)
        var found = 0, total = 0.0
        for w in words {
            let u = CommandSearch.score(w, in: display)?.score ?? 0
            let t = title.isEmpty ? 0 : (CommandSearch.score(w, in: title)?.score ?? 0)
            let best = max(u >= 55 ? u : 0, t >= 55 ? t : 0)
            if best > 0 { found += 1; total += best }
        }
        guard found >= (words.count + 1) / 2 else { return nil }
        return (found, total / Double(words.count))
    }

    /// History matches (HistoryStore.recall, already ranked and frecency-weighted) and the profile's tabs, merged: one
    /// row per page (a tab wins, keeping history's last visit and count), more of the words first, then score.
    public static func rank(_ words: [String], history: [HistoryMatch], tabs: [Tab], limit: Int = defaultLimit,
                            now: Date = Date()) -> [Hit] {
        guard !words.isEmpty else { return [] }
        var byURL: [String: (hit: Hit, found: Int)] = [:]
        var order: [String] = []
        func add(_ h: Hit, found: Int) {
            guard isWebURL(h.url) else { return }
            let key = h.url
            if let old = byURL[key] {
                var merged = old.hit.place == .history ? h : old.hit
                let other = old.hit.place == .history ? old.hit : h
                merged.lastVisit = [merged.lastVisit, other.lastVisit].compactMap { $0 }.max()
                merged.visits = merged.visits ?? other.visits
                merged.score = max(old.hit.score, h.score)
                if merged.title.isEmpty { merged.title = other.title }
                byURL[key] = (merged, max(old.found, found))
            } else {
                byURL[key] = (h, found)
                order.append(key)
            }
        }
        for m in history {
            let s = score(words, title: m.entry.title, url: m.entry.url)
            let found = s?.found ?? (words.count + 1) / 2
            let url = clean(m.entry.url)
            add(Hit(title: cut(m.entry.title), url: url, site: site(url), place: .history, lastVisit: m.entry.lastVisit,
                    visits: m.entry.visitCount, score: m.score), found: found)
        }
        for t in tabs {
            guard let s = score(words, title: t.title, url: t.url) else { continue }
            // Recently used tabs a little higher (up to 4 points over a week).
            let age = t.lastUsed.map { max(0, now.timeIntervalSince($0)) / 86_400 } ?? 7
            let url = clean(t.url)
            add(Hit(title: cut(t.title), url: url, site: site(url), place: t.place, lastVisit: t.lastUsed,
                    score: s.score + t.place.bonus + max(0, 4 - age * 4 / 7)), found: s.found)
        }
        let ranked = order.compactMap { byURL[$0] }.sorted { a, b in
            a.found != b.found ? a.found > b.found : (a.hit.score, a.hit.lastVisit ?? .distantPast) > (b.hit.score, b.hit.lastVisit ?? .distantPast)
        }
        return ranked.prefix(max(0, min(limit, maxLimit))).map { $0.hit }
    }

    /// "Searched your history: ‘kyoto ryokan’ · 4 results". The query shows only when it's a safe label (no codes,
    /// addresses: AgentRedaction.label).
    public static func caption(query: String, count: Int) -> String {
        let n = count == 0 ? "no results" : count == 1 ? "1 result" : "\(count) results"
        guard let q = AgentRedaction.label(query) else { return "Searched your history · \(n)" }
        return "Searched your history: ‘\(q)’ · \(n)"
    }

    public static let runningCaption = "Searching your history"

    // MARK: Addresses

    /// Query names whose values are secrets or sign-in state: dropped from what the model reads.
    static let secretParams: [String] = ["token", "key", "code", "secret", "password", "passwd", "pwd", "auth", "session",
                                         "sid", "sig", "signature", "otp", "ticket", "credential", "jwt", "state", "nonce"]

    /// An address for the model and the task view: no user name or password, no fragment, and no query value that may be
    /// a secret (a name containing token, key, code, session, auth…, or a long opaque value).
    public static func clean(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw }
        c.user = nil
        c.password = nil
        c.fragment = nil
        if let items = c.queryItems {
            let kept = items.filter { item in
                let n = item.name.lowercased()
                if secretParams.contains(where: { n == $0 || n.hasSuffix("_" + $0) || n.hasSuffix("-" + $0) || n.hasPrefix($0 + "_") }) { return false }
                let v = item.value ?? ""
                // A long run of letters and digits without spaces: an opaque id or token.
                if v.count >= 32, v.allSatisfy({ $0.isLetter || $0.isNumber || "-_.=%".contains($0) }) { return false }
                return true
            }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        return c.string ?? raw
    }

    static func isWebURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("https://") || l.hasPrefix("http://")
    }

    static func site(_ url: String) -> String {
        AgentRedaction.site(URL(string: url)) ?? URLRules.displayHost(url)
    }

    static func cut(_ title: String) -> String {
        let one = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return one.count > titleLimit ? String(one.prefix(titleLimit - 1)) + "…" : one
    }

    /// `days` from the tool's arguments: the start of that window (nil: all of history).
    public static func since(days: Int?, now: Date = Date()) -> Date? {
        guard let days, days > 0 else { return nil }
        return now.addingTimeInterval(-Double(min(days, 3650)) * 86_400)
    }
}

// MARK: - Task pictures

/// Small JPEG pictures of a task's pages (agentrecall): the Recent tasks card's (`card`) and the "Opened …" steps'
/// (their step's key), so a finished task still shows them after a relaunch. `<data folder>/Agent/Tasks/Pictures/<task
/// id>/<key>.jpg`, folders 0700, files 0600. Capped: one picture ≤ `maxPictureBytes`, ≤ `maxPerTask` per task (the
/// oldest steps' go first; the card stays), ≤ `maxTotalBytes` in all (the least recently written tasks go first).
/// Deleting a task deletes its folder. Callers never save a private window's (AgentTaskThumbs).
public struct AgentTaskPictureStore: Sendable {
    public let folder: URL
    public var maxPictureBytes = 96 * 1024
    public var maxPerTask = 24
    public var maxTotalBytes = 24 * 1024 * 1024
    public static let card = "card"

    public init(folder: URL) { self.folder = folder }

    /// Task ids are UUIDs, keys a UUID or `card`: nothing else becomes a path.
    static func valid(_ key: String) -> Bool { key == card || UUID(uuidString: key) != nil }

    func taskFolder(_ task: String) -> URL? {
        guard UUID(uuidString: task) != nil else { return nil }
        return folder.appendingPathComponent(task, isDirectory: true)
    }

    public func file(task: String, key: String) -> URL? {
        guard Self.valid(key), let dir = taskFolder(task) else { return nil }
        return dir.appendingPathComponent(key + ".jpg")
    }

    /// Writes one picture, then applies the caps. False: refused (bad id, too big, not a JPEG) or not written.
    @discardableResult
    public func save(_ jpeg: Data, task: String, key: String) -> Bool {
        guard jpeg.count <= maxPictureBytes, jpeg.count > 3, jpeg.prefix(3) == Data([0xFF, 0xD8, 0xFF]),
              let dir = taskFolder(task), let url = file(task: task, key: key) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try jpeg.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { return false }
        capTask(task)
        capTotal(keeping: task)
        return true
    }

    public func load(task: String, key: String) -> Data? {
        file(task: task, key: key).flatMap { try? Data(contentsOf: $0) }
    }

    /// The keys a task has pictures for.
    public func keys(task: String) -> [String] {
        guard let dir = taskFolder(task) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.filter(Self.valid)
    }

    public func delete(task: String) {
        guard let dir = taskFolder(task) else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Removes the folders of tasks that no longer exist (a task deleted while Airc wasn't running, a crash).
    public func prune(keeping tasks: Set<String>) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where UUID(uuidString: name) != nil && !tasks.contains(name) {
            delete(task: name)
        }
    }

    public func totalBytes() -> Int {
        tasksOnDisk().reduce(0) { $0 + $1.files.reduce(0) { $0 + $1.size } }
    }

    private struct Entry { let url: URL; let key: String; let size: Int; let date: Date }

    private func files(_ task: String) -> [Entry] {
        guard let dir = taskFolder(task) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension == "jpg" }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Entry(url: u, key: u.deletingPathExtension().lastPathComponent, size: v?.fileSize ?? 0, date: v?.contentModificationDate ?? .distantPast)
        }
    }

    private func tasksOnDisk() -> [(task: String, files: [Entry])] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { UUID(uuidString: $0) != nil }.map { ($0, files($0)) }
    }

    private func capTask(_ task: String) {
        let steps = files(task).filter { $0.key != Self.card }.sorted { ($0.date, $0.key) < ($1.date, $1.key) }
        let card = files(task).contains { $0.key == Self.card } ? 1 : 0
        let over = steps.count + card - maxPerTask
        guard over > 0 else { return }
        for e in steps.prefix(over) { try? FileManager.default.removeItem(at: e.url) }
    }

    private func capTotal(keeping current: String) {
        var all = tasksOnDisk().map { t in (t.task, t.files, t.files.map(\.date).max() ?? .distantPast) }
        var total = all.reduce(0) { $0 + $1.1.reduce(0) { $0 + $1.size } }
        guard total > maxTotalBytes else { return }
        // Least recently written tasks first; the task just written goes last, and only its oldest steps.
        all.sort { a, b in (a.0 == current ? 1 : 0, a.2) < (b.0 == current ? 1 : 0, b.2) }
        for (task, files, _) in all where total > maxTotalBytes {
            if task == current {
                for e in files.filter({ $0.key != Self.card }).sorted(by: { $0.date < $1.date }) where total > maxTotalBytes {
                    try? FileManager.default.removeItem(at: e.url)
                    total -= e.size
                }
            } else {
                delete(task: task)
                total -= files.reduce(0) { $0 + $1.size }
            }
        }
    }
}
