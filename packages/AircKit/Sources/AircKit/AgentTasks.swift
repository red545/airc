// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// A task's title: its first prompt, cut to about 48 characters at a word boundary (docs/design/agent-ux.md §1). No
/// model call.
public enum AgentTaskTitle {
    public static let limit = 48

    public static func make(_ prompt: String) -> String {
        // The first line only; the page Airc attaches to the prompt never becomes the title.
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard t.count > limit else { return t.isEmpty ? "New task" : t }
        let cut = t.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            return String(cut[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:–—-")) + "…"
        }
        return String(cut) + "…"
    }
}

/// One task as the All tasks page lists it (docs/design/agent-ux.md §1, §7). Metadata and text only: never screenshots,
/// page text, keys or anything typed into a page. The answer is kept only as its first line.
public struct AgentTaskRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case running, waiting, takenOver, done, stopped, failed
        /// agentparallel: past the person's limit of tasks at once; starts when one ends.
        case queued

        public var label: String {
            switch self {
            case .running: return "Running"
            case .waiting: return "Waiting for your OK"
            case .takenOver: return "You have the page"
            case .done: return "Done"
            case .stopped: return "Stopped"
            case .failed: return "Failed"
            case .queued: return "Queued"
            }
        }

        /// The All tasks page's status chips.
        public var chip: String {
            switch self {
            case .running, .takenOver, .queued: return "Running"
            case .waiting: return "Waiting"
            case .done: return "Done"
            case .stopped, .failed: return "Stopped"
            }
        }

        /// Rows by state: waiting for you first, then running, then the rest by time.
        public var rank: Int {
            switch self {
            case .waiting: return 0
            case .running, .takenOver: return 1
            case .queued: return 2
            default: return 3
            }
        }
    }

    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var spaceID: String
    public var profileID: String
    /// "Anthropic API key", "Claude Code", …
    public var provider: String
    public var status: Status
    public var unread: Bool
    /// The first line of the last answer, ≤ 80 characters.
    public var answer: String?
    public var steps: Int
    /// Sites the task used (hosts only).
    public var sites: [String]
    /// asidepass: the task view's timeline (prompts, step captions, the agent's text), so a finished task still reads
    /// as it ran. Only what the pane showed: redacted step captions (never typed values or page text), capped.
    public var entries: [Entry]?
    /// The start of the last answer (≤ 280 characters, plain), for the Recent tasks cards.
    public var answerHead: String?
    /// When the last run stopped being active ("Working for 3m 48s" runs from `createdAt` until then).
    public var endedAt: Date?

    /// One line of the task's timeline.
    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case prompt, step, text, answer, note, approval }
        public var kind: Kind
        public var text: String
        /// The step's site (host only).
        public var host: String?
        public var detail: String?
        /// agentrecall: the step's picture key (AgentTaskPictureStore; the live step's id), so its picture comes back
        /// after a relaunch. Nil for older records and lines without one.
        public var key: String?
        /// agentrecall: what a "Searched your history" step found (title, cleaned address, where), ≤ `foundLimit`.
        public var found: [Found]?

        /// One result row of a history search.
        public struct Found: Codable, Equatable, Sendable {
            public var title: String
            public var url: String
            public var place: AgentRecall.Place
            public init(title: String, url: String, place: AgentRecall.Place) {
                self.title = title.count > AgentTaskRecord.captionLimit ? String(title.prefix(AgentTaskRecord.captionLimit - 1)) + "…" : title
                self.url = url.count > 2048 ? String(url.prefix(2048)) : url
                self.place = place
            }
        }

        public init(kind: Kind, text: String, host: String? = nil, detail: String? = nil, key: String? = nil, found: [Found]? = nil) {
            self.kind = kind
            self.host = host
            self.key = key
            self.found = found.map { Array($0.prefix(AgentTaskRecord.foundLimit)) }
            let cap = kind == .answer || kind == .text || kind == .prompt ? AgentTaskRecord.textLimit : AgentTaskRecord.captionLimit
            self.text = text.count > cap ? String(text.prefix(cap - 1)) + "…" : text
            self.detail = detail.map { $0.count > AgentTaskRecord.captionLimit ? String($0.prefix(AgentTaskRecord.captionLimit - 1)) + "…" : $0 }
        }
    }

    public static let entryLimit = 160
    public static let textLimit = 4000
    public static let captionLimit = 200
    public static let foundLimit = 8

    /// Keeps the newest `entryLimit` lines, but always the first prompt (the task's start).
    public static func capped(_ entries: [Entry]) -> [Entry] {
        guard entries.count > entryLimit else { return entries }
        let first = entries.first { $0.kind == .prompt }
        var tail = Array(entries.suffix(entryLimit - (first == nil ? 0 : 1)))
        if let first { tail.insert(first, at: 0) }
        return tail
    }

    /// The answer's start as the cards show it: Markdown marks out, lines joined, ≤ 280 characters.
    public static func answerHead(_ text: String) -> String {
        var plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        plain = plain.split(whereSeparator: \.isNewline).map { line in
            var l = line.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "* ", "• ", "# ", "## ", "### "] where l.hasPrefix(p) { l = String(l.dropFirst(p.count)) }
            return l
        }.filter { !$0.isEmpty }.joined(separator: " ")
        return plain.count > 280 ? String(plain.prefix(279)) + "…" : plain
    }

    /// The last `n` step captions ("Opening shop.example.com"), oldest first.
    public func lastSteps(_ n: Int) -> [Entry] { Array((entries ?? []).filter { $0.kind == .step }.suffix(n)) }

    public init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), spaceID: String, profileID: String,
                provider: String, status: Status = .running) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.spaceID = spaceID
        self.profileID = profileID
        self.provider = provider
        self.status = status
        unread = false
        steps = 0
        sites = []
    }

    /// The answer as the record keeps it: first line, cut to 80 characters.
    public static func answerLine(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let plain = first.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        return plain.count > 80 ? String(plain.prefix(79)) + "…" : plain
    }

    /// Waiting first, then running, then newest.
    public static func ordered(_ tasks: [AgentTaskRecord]) -> [AgentTaskRecord] {
        tasks.sorted { a, b in a.status.rank != b.status.rank ? a.status.rank < b.status.rank : a.updatedAt > b.updatedAt }
    }

    /// Matches the All tasks page's search (title, answer, sites, provider).
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ([title, answer ?? "", provider] + sites).contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

/// `<data folder>/Agent/Tasks/<id>.json`, one file per task, folder 0700 and files 0600.
public struct AgentTaskStore: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }()

    private func file(_ id: String) -> URL? {
        // Ids are UUIDs: nothing else becomes a path.
        guard UUID(uuidString: id) != nil else { return nil }
        return folder.appendingPathComponent(id + ".json")
    }

    public func save(_ t: AgentTaskRecord) throws {
        guard let url = file(t.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(t)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ id: String) -> AgentTaskRecord? {
        guard let url = file(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(AgentTaskRecord.self, from: data)
    }

    public func all() -> [AgentTaskRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { load(String($0.dropLast(5))) }
    }

    public func delete(_ id: String) {
        guard let url = file(id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The All tasks tab (`airc://agents`): a native page in the card, like What's New.
public enum AgentTasksURL {
    public static let prefix = "airc://agents"
    public static let title = "Agent tasks"

    public static func isPage(_ url: String?) -> Bool {
        guard let url else { return false }
        return url == prefix || url.hasPrefix(prefix + "?") || url.hasPrefix(prefix + "/")
    }

    /// asidepass: one task's view, `airc://agents/<id>`.
    public static func task(_ id: String) -> String { prefix + "/" + id }

    /// The task a tab's address names (nil: the list).
    public static func taskID(_ url: String?) -> String? {
        guard let url, url.hasPrefix(prefix + "/") else { return nil }
        let id = url.dropFirst(prefix.count + 1).prefix { $0 != "?" && $0 != "#" && $0 != "/" }
        return UUID(uuidString: String(id)) != nil ? String(id) : nil
    }
}
