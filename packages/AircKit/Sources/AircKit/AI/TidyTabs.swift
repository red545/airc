// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

// Tidy Tabs (Arc Max's broom, docs/user/ai.md): one click puts a Space's Today tabs into folders by topic, named by a
// language model on this Mac, and one ⌘Z puts everything back. The app's model is Apple's on-device Foundation Models
// (apps/browser/Sources/Airc/AI/TidyTabsModel.swift); everything here works with any `TidyTabsModel`, so the tests use
// a fake. Nothing here sends anything anywhere.
//
// As in Arc, the folders go at the top of the Space's Today list (Today folders, TodayFolders.swift) and the grouped
// tabs stay Today tabs inside them: they still auto-archive, Clear still clears them, and a folder goes when its last
// tab does. Tabs already in a Today folder, pinned items and Favorites are never moved, renamed or read.

/// What the model is asked about one part of a Space's Today tabs: each page's title (counts and email addresses taken
/// out, `TidyTitleRules.prepare`) and host, numbered from 1. Never an address's path or query, never a private window's
/// page. `topics` are the folders named for the earlier parts of a long list, so the same topic keeps one name.
public struct TidyTabsRequest: Hashable, Sendable {
    public struct Tab: Hashable, Sendable {
        public var number: Int
        public var title: String
        public var host: String

        public init(number: Int, title: String, host: String) {
            self.number = number
            self.title = title
            self.host = host
        }
    }

    public var tabs: [Tab]
    public var topics: [String]

    public init(tabs: [Tab], topics: [String] = []) {
        self.tabs = tabs
        self.topics = topics
    }
}

/// One folder the model proposes: its name and the numbers of its tabs in the request.
public struct TidyTabsFolderAnswer: Hashable, Sendable {
    public var name: String
    public var tabs: [Int]

    public init(name: String, tabs: [Int]) {
        self.name = name
        self.tabs = tabs
    }
}

/// A language model that sorts tabs into folders. A call may take a while and may ignore cancellation: the planner keeps
/// its own timeout. Throw `AIRequestDeclined` for "won't" (a guardrail, a refusal, a language); anything else fails.
public protocol TidyTabsModel: Sendable {
    func folders(for request: TidyTabsRequest) async throws -> [TidyTabsFolderAnswer]
}

/// The instructions and the prompt. The app asks for guided generation: a list of folders, each a name and numbers.
public enum TidyTabsPrompt {
    public static let instructions = """
        You sort a person's open browser tabs into folders by topic. You get a numbered list of tabs, each with its \
        page title and its site. Put tabs about the same topic, task or project in one folder; a folder needs at least \
        two tabs. Name each folder in one to three words, in the tabs' language, the way a person would label it, like \
        "Lisbon Trip", "Kitchen Renovation" or "Swift Concurrency". Leave a tab out when it fits no folder. A tab goes \
        in at most one folder. Use the tabs' numbers exactly as listed.
        """

    public static func prompt(for request: TidyTabsRequest) -> String {
        var lines = ["Tabs:"]
        for t in request.tabs {
            lines.append(t.host.isEmpty ? "\(t.number). \(t.title)" : "\(t.number). \(t.title) (\(t.host))")
        }
        if !request.topics.isEmpty {
            lines.append("")
            lines.append("Folders made already (use one of these names when tabs fit it): " + request.topics.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// One Today tab the model may see: its tab, the page it shows, and what the prompt says about it.
public struct TidyTabsCandidate: Hashable, Sendable {
    public var tabID: String
    /// The page's address without its fragment: two tabs of one page are one line in the prompt and share a folder.
    public var page: String
    public var title: String
    public var host: String

    public init(tabID: String, page: String, title: String, host: String) {
        self.tabID = tabID
        self.page = page
        self.title = title
        self.host = host
    }
}

/// Which tabs are tidied, how a long list is cut into requests, and which answers are kept.
public enum TidyTabsRules {
    /// A folder needs this many different pages.
    public static let minPagesPerFolder = 2
    /// At most this many folders per tidy (the biggest kept).
    public static let maxFolders = 10
    /// A folder's name: at most this many words and characters.
    public static let maxNameWords = 4
    public static let maxNameLength = 32
    /// The model sees at most this much of a title.
    public static let titleLength = 90
    /// One request holds at most this many pages, and their lines at most this many tokens (`AITokens.estimate`), so
    /// instructions, list and answer fit Apple's on-device model's 4,096-token context.
    public static let pagesPerRequest = 24
    public static let tokensPerRequest = 1_500
    /// At most this many pages are sorted in one tidy (ten requests); the rest stay where they are.
    public static let maxPages = 240

    private static let email = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
                                                        options: [.caseInsensitive])

    /// The address a tab is grouped by: without its fragment ("#section"), so a page's tabs go together.
    public static func page(of url: String) -> String {
        guard var c = URLComponents(string: url) else { return url }
        c.fragment = nil
        return c.string ?? url
    }

    public static func host(of url: String) -> String {
        var h = URLComponents(string: url)?.host?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// Whether Tidy has something to do in these Today rows (the Today header's Tidy shows): at least two different web
    /// pages loose in Today. Tabs already in a Today folder don't count (Tidy never moves them, `tidyCandidates`). Reads
    /// only the rows given (the ones the sidebar built), stopping at the second page: no scan of its own.
    public static func hasEnoughPages<S: Sequence>(in rows: S) -> Bool where S.Element == SidebarEntry {
        var pages = Set<String>()
        for case .today(let t) in rows where t.isToday && t.folderID == nil && isSortable(url: t.url) {
            pages.insert(page(of: t.url))
            if pages.count >= minPagesPerFolder { return true }
        }
        return false
    }

    /// A tab worth sorting: a web page (http or https). New tabs, empty ones, notes, Easels, files and Airc's own pages
    /// stay where they are, and the model never sees them.
    public static func isSortable(url: String) -> Bool {
        guard !URLRules.isNewTab(url), let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The title the model sees: counts and email addresses out, at most `titleLength`, the host when there's none.
    public static func promptTitle(_ title: String, url: String) -> String {
        let t = AIText.collapse(TidyTitleRules.prepare(title))
        let clean = t.isEmpty ? URLRules.displayHost(url) : t
        return String(clean.prefix(titleLength))
    }

    /// The pages to ask about, each once, in Today order (the first tab of a page stands for its others), and the
    /// requests they make: at most `pagesPerRequest` pages and `tokensPerRequest` tokens of lines each.
    public static func chunks(_ candidates: [TidyTabsCandidate]) -> [[TidyTabsCandidate]] {
        var seen = Set<String>()
        let pages = candidates.filter { seen.insert($0.page).inserted }.prefix(maxPages)
        var out: [[TidyTabsCandidate]] = []
        var current: [TidyTabsCandidate] = []
        var tokens = 0
        for c in pages {
            let cost = AITokens.estimate("\(current.count + 1). \(c.title) (\(c.host))") + 1
            if !current.isEmpty, current.count >= pagesPerRequest || tokens + cost > tokensPerRequest {
                out.append(current)
                current = []
                tokens = 0
            }
            current.append(c)
            tokens += cost
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The model's folder name cleaned up, or nil: empty, too long, an email address, markup, or no letters.
    public static func folderName(_ answer: String) -> String? {
        var s = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["folder:", "topic:", "name:"] where s.lowercased().hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        let wrap = CharacterSet(charactersIn: "\"'“”‘’`«»*_#").union(.whitespaces)
        s = s.trimmingCharacters(in: wrap)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!-–—|·•/").union(.whitespaces))
        s = s.trimmingCharacters(in: wrap)
        s = AIText.collapse(s)
        guard !s.isEmpty, s.count <= maxNameLength, AIText.words(s).count <= maxNameWords, s.contains(where: \.isLetter) else { return nil }
        guard email.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil,
              !s.contains(where: { "<>{}[]\\@".contains($0) }) else { return nil }
        if let f = s.first, f.isLowercase { s = f.uppercased() + s.dropFirst() }
        return s
    }

    /// Folder names compared for merging: case, accents and widths folded.
    static func key(_ name: String) -> String { AIText.fold(name) }
}

/// What a tidy will do: folders (named, with their tabs in Today order), in the order they go in the sidebar (by their
/// first tab's place in Today). Tabs in no folder stay in Today.
public struct TidyTabsPlan: Equatable, Sendable {
    public struct Folder: Equatable, Sendable {
        public var name: String
        public var tabIDs: [String]

        public init(name: String, tabIDs: [String]) {
            self.name = name
            self.tabIDs = tabIDs
        }
    }

    public var spaceID: String
    public var folders: [Folder]

    public init(spaceID: String, folders: [Folder]) {
        self.spaceID = spaceID
        self.folders = folders
    }

    public var tabCount: Int { folders.reduce(0) { $0 + $1.tabIDs.count } }
}

/// How a tidy ended before anything changed.
public enum TidyTabsOutcome: Equatable, Sendable {
    case plan(TidyTabsPlan)
    /// Fewer than two pages to sort: nothing is asked.
    case tooFewTabs
    /// The model made no folder of two pages or more ("No tab groups found", as Arc says).
    case noFolders
    case declined(AIRequestDeclined.Reason)
    case failed
    case timeout
    /// Stopped by the person (or the window closed) while the model was working: nothing changed.
    case cancelled
}

/// Asks the model about a Space's Today tabs, a part at a time, and turns its answers into a plan. The same tabs and the
/// same answers make the same plan: pages are asked in Today order, unknown or repeated numbers are dropped (a tab goes
/// in the first folder that names it), folders with one name are merged, and folders go in Today order.
public enum TidyTabsPlanner {
    public struct Options: Sendable {
        /// One request's limit; a model that's slower is stopped and that part stays as it is.
        public var timeout: TimeInterval = 25
        public init() {}
    }

    public static func plan(spaceID: String, candidates: [TidyTabsCandidate], model: any TidyTabsModel,
                            options: Options = Options()) async -> TidyTabsOutcome {
        let chunks = TidyTabsRules.chunks(candidates)
        guard chunks.reduce(0, { $0 + $1.count }) >= TidyTabsRules.minPagesPerFolder else { return .tooFewTabs }
        // Folders by name key, in the order they were first named; each with its pages.
        var names: [String: String] = [:]
        var order: [String] = []
        var pagesByFolder: [String: [String]] = [:]
        var assigned = Set<String>()
        var problem: TidyTabsOutcome?
        for chunk in chunks {
            if Task.isCancelled { return .cancelled }
            let request = TidyTabsRequest(
                tabs: chunk.enumerated().map { TidyTabsRequest.Tab(number: $0.offset + 1, title: $0.element.title, host: $0.element.host) },
                topics: order.compactMap { names[$0] })
            let outcome = await AIDeadline.run(timeout: options.timeout) { try await model.folders(for: request) }
            let answers: [TidyTabsFolderAnswer]
            switch outcome {
            case .value(let v): answers = v
            case .cancelled: return .cancelled
            case .declined(let r): problem = problem ?? .declined(r); continue
            case .failed: problem = problem ?? .failed; continue
            case .timeout: problem = problem ?? .timeout; continue
            }
            if Task.isCancelled { return .cancelled }
            for a in answers {
                guard let name = TidyTabsRules.folderName(a.name) else { continue }
                let k = TidyTabsRules.key(name)
                for n in a.tabs where n >= 1 && n <= chunk.count {
                    let page = chunk[n - 1].page
                    guard assigned.insert(page).inserted else { continue }
                    if names[k] == nil { names[k] = name; order.append(k) }
                    pagesByFolder[k, default: []].append(page)
                }
            }
        }
        if Task.isCancelled { return .cancelled }
        // Every tab of a page goes with it, in Today order.
        var tabsByPage: [String: [String]] = [:]
        var position: [String: Int] = [:]
        for (i, c) in candidates.enumerated() {
            tabsByPage[c.page, default: []].append(c.tabID)
            if position[c.page] == nil { position[c.page] = i }
        }
        var folders: [(name: String, pages: [String], first: Int)] = order.compactMap { k in
            let pages = pagesByFolder[k] ?? []
            guard pages.count >= TidyTabsRules.minPagesPerFolder, let name = names[k] else { return nil }
            let sorted = pages.sorted { position[$0] ?? 0 < position[$1] ?? 0 }
            return (name, sorted, position[sorted[0]] ?? 0)
        }
        if folders.count > TidyTabsRules.maxFolders {
            folders = Array(folders.sorted { ($1.pages.count, $0.first) < ($0.pages.count, $1.first) }.prefix(TidyTabsRules.maxFolders))
        }
        folders.sort { $0.first < $1.first }
        guard !folders.isEmpty else { return problem ?? .noFolders }
        return .plan(TidyTabsPlan(spaceID: spaceID, folders: folders.map { f in
            TidyTabsPlan.Folder(name: f.name, tabIDs: f.pages.flatMap { tabsByPage[$0] ?? [] })
        }))
    }
}

/// What one ⌘Z needs to put a tidy back, also after a relaunch (the store's own undo lives only as long as the app):
/// the Space, the folders the tidy made, and each moved tab as it was in Today with the Today folder it went into. Kept
/// in the store's device-local values (never synced or exported), one per Space, until it's undone or out of date.
public struct TidyTabsUndoRecord: Codable, Equatable, Sendable {
    public struct Moved: Codable, Equatable, Sendable {
        /// The Today tab as it was before the tidy.
        public var before: LiveTab
        /// The Today folder it went into.
        public var folderID: String?
        /// A record from before Today folders (a733c880): the pinned item it became in a pinned folder.
        public var itemID: String?

        public init(before: LiveTab, folderID: String? = nil, itemID: String? = nil) {
            self.before = before
            self.folderID = folderID
            self.itemID = itemID
        }
    }

    public var spaceID: String
    public var folderIDs: [String]
    public var moved: [Moved]
    public var at: Date

    static func key(_ spaceID: String) -> String { "tidyTabs.undo." + spaceID }
}

extension SpacesStore {
    /// The undo step's name: the Edit menu's "Undo Tidy Tabs".
    public static let tidyTabsLabel = "Tidy Tabs"

    /// The Today tabs a tidy may sort, in Today order: pages (not new tabs) loose in Today, outside splits and Today
    /// folders. Pinned tabs, Favorites, splits and tabs already in a folder are never read. Private windows keep their
    /// pages out of the store, so none of theirs is ever here.
    public func tidyCandidates(inSpace spaceID: String) -> [TidyTabsCandidate] {
        todayRootRows(ofSpace: spaceID).compactMap { e -> TidyTabsCandidate? in
            guard case .today(let t) = e, t.isToday, TidyTabsRules.isSortable(url: t.url) else { return nil }
            return TidyTabsCandidate(tabID: t.id, page: TidyTabsRules.page(of: t.url),
                                     title: TidyTabsRules.promptTitle(t.title, url: t.url), host: TidyTabsRules.host(of: t.url))
        }
    }

    /// Makes the plan's folders at the top of the Space's Today list, in the plan's order, and moves their tabs in, in
    /// one undoable step ("Tidy Tabs"). Tabs that changed while the model worked (closed, pinned, moved to another Space,
    /// put in a split or a folder) are left out, and a folder left with fewer than two pages isn't made. Returns the
    /// record ⌘Z needs (also kept for after a relaunch), or nil when nothing changed.
    @discardableResult
    public func applyTidyTabs(_ plan: TidyTabsPlan) throws -> TidyTabsUndoRecord? {
        let sid = plan.spaceID
        guard space(sid) != nil else { throw StoreError.notFound }
        let current = Dictionary(tidyCandidates(inSpace: sid).map { ($0.tabID, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<String>()
        let folders = plan.folders.compactMap { f -> TidyTabsPlan.Folder? in
            let ids = f.tabIDs.filter { current[$0] != nil && used.insert($0).inserted }
            guard Set(ids.compactMap { current[$0]?.page }).count >= TidyTabsRules.minPagesPerFolder else { return nil }
            return TidyTabsPlan.Folder(name: f.name, tabIDs: ids)
        }
        guard !folders.isEmpty else { return nil }
        let before = Dictionary(uniqueKeysWithValues: folders.flatMap(\.tabIDs).compactMap { id in tab(id).map { (id, $0) } })
        var folderIDs: [String] = []
        try perform(Self.tidyTabsLabel, undoable: true) {
            for (n, f) in folders.enumerated() {
                let folder = try createTodayFolder(named: f.name, inSpace: sid, index: n, containing: f.tabIDs.map { .tab($0) })
                folderIDs.append(folder.id)
            }
        }
        let moved = folders.flatMap(\.tabIDs).compactMap { id -> TidyTabsUndoRecord.Moved? in
            guard let b = before[id], let folder = tab(id)?.folderID else { return nil }
            return TidyTabsUndoRecord.Moved(before: b, folderID: folder)
        }
        let record = TidyTabsUndoRecord(spaceID: sid, folderIDs: folderIDs, moved: moved, at: now())
        saveTidyUndo(record)
        return record
    }

    /// The Space's last tidy that can still be put back by `undoTidyTabs` (one of its folders still holds one of its
    /// tabs); an out-of-date record is forgotten.
    public func tidyUndo(inSpace spaceID: String) -> TidyTabsUndoRecord? {
        let key = TidyTabsUndoRecord.key(spaceID)
        guard let raw = localValue(key), let data = raw.data(using: .utf8) else { return nil }
        guard let r = try? JSONDecoder().decode(TidyTabsUndoRecord.self, from: data), isCurrent(r) else {
            setLocalValue(key, nil)
            return nil
        }
        return r
    }

    func saveTidyUndo(_ r: TidyTabsUndoRecord) {
        // Dates as Foundation's own numbers, so a tab comes back with exactly the dates it had.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(r) else { return }
        setLocalValue(TidyTabsUndoRecord.key(r.spaceID), String(decoding: data, as: UTF8.self))
    }

    private func isCurrent(_ r: TidyTabsUndoRecord) -> Bool {
        let folders = Set(r.folderIDs)
        return space(r.spaceID) != nil && r.moved.contains { m in
            if let f = m.folderID { return folders.contains(f) && tab(m.before.id)?.folderID == f }
            return item(m.itemID).map { $0.parentID.map(folders.contains) ?? false } ?? false
        }
    }

    /// ⌘Z for a tidy whose step isn't on the undo stack any more (after a relaunch): each moved tab still in one of the
    /// tidy's folders goes back to Today, where it was, with its page as it is now; the folders it left empty go. A
    /// tab that loads in another profile than the Space's now stays where it is (H3). Not itself undoable, as an undo
    /// isn't. Returns the tabs put back; the record is forgotten.
    @discardableResult
    public func undoTidyTabs(_ r: TidyTabsUndoRecord) throws -> [String] {
        guard let sp = space(r.spaceID) else { throw StoreError.notFound }
        let folders = Set(r.folderIDs)
        var restored: [String] = []
        try perform(nil) {
            for m in r.moved {
                // A Today folder's tab goes back where it was in Today; the folders it leaves empty go with the
                // transaction (TodayFolders.swift).
                if let f = m.folderID {
                    guard folders.contains(f), var t = tab(m.before.id), t.folderID == f, t.isToday,
                          t.spaceID == r.spaceID else { continue }
                    t.folderID = nil
                    t.order = m.before.order
                    put(t)
                    restored.append(t.id)
                    continue
                }
                guard let item = item(m.itemID), item.kind == .tab, let parent = item.parentID, folders.contains(parent),
                      m.before.profileID == sp.profileID else { continue }
                var t = m.before
                if let live = liveTab(forItem: item.id) {
                    // The page as it is now (it may have moved on since the tidy).
                    t.url = live.url
                    t.title = live.title
                    t.faviconURL = live.faviconURL
                    t.isMuted = live.isMuted
                    t.lastActiveAt = live.lastActiveAt
                    if live.id != t.id { remove(LiveTab.self, live.id) }
                } else if let saved = item.savedURL {
                    t.url = saved
                    t.title = item.pageTitle ?? t.title
                }
                t.itemID = nil
                t.spaceID = r.spaceID
                put(t)
                remove(Item.self, item.id)
                restored.append(t.id)
            }
            for f in r.folderIDs where item(f)?.kind == .folder && item(f)?.isTodayFolder == false
                && !state.items.values.contains(where: { $0.parentID == f }) {
                remove(Item.self, f)
            }
        }
        setLocalValue(TidyTabsUndoRecord.key(r.spaceID), nil)
        return restored
    }
}
