// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation

/// P04 (S14): what files, folders, links and text dropped on the sidebar (or chosen with Add Files) become, planned in
/// full before a single row is made. Arc's rules (2021–2023 release notes): a Finder file opens as a tab, a folder is
/// imported as a sidebar folder, text becomes a search. Airc adds that a link (or lines that are all links) opens as
/// tabs, and that longer text, more than a line or a search, becomes a note.
public enum SidebarDropItem: Equatable, Sendable {
    /// A file or folder on disk.
    case file(URL)
    /// A link, with the title the drag carried (Safari's and Chrome's links have one).
    case link(String, title: String?)
    /// Plain text.
    case text(String)
}

public struct SidebarFilePlan: Equatable, Sendable {
    public indirect enum Node: Equatable, Sendable {
        /// A file (its file URL) or a link.
        case tab(title: String, url: String)
        /// A Finder folder, its contents in Finder's name order.
        case folder(title: String, children: [Node])
        /// Text for the profile's search engine.
        case search(query: String)
        /// Text too long for a search: a note with it.
        case note(text: String)
    }

    /// What the plan left out, and why.
    public struct Skipped: Equatable, Sendable {
        /// Hidden files (.DS_Store, dot files).
        public var hidden = 0
        /// Folder links that lead back into a folder already being read (a cycle).
        public var cycles = 0
        /// Files that couldn't be read (a broken link, no permission).
        public var unreadable = 0
        /// Folders deeper than `Limits.maxDepth`, kept empty.
        public var tooDeep = 0
        public init() {}
        public var total: Int { hidden + cycles + unreadable + tooDeep }
    }

    public struct Limits: Equatable, Sendable {
        /// Folders inside folders, at most.
        public var maxDepth: Int
        /// Tabs one drop makes, at most; the rest are left out (`truncated`).
        public var maxTabs: Int
        /// Directory entries read, at most (a guard against a huge tree).
        public var maxEntries: Int
        /// Text longer than this, or on more than one line, becomes a note rather than a search.
        public var maxSearchLength: Int

        public init(maxDepth: Int = 8, maxTabs: Int = 300, maxEntries: Int = 5_000, maxSearchLength: Int = 200) {
            self.maxDepth = maxDepth
            self.maxTabs = maxTabs
            self.maxEntries = maxEntries
            self.maxSearchLength = maxSearchLength
        }
        public static let standard = Limits()
    }

    public var nodes: [Node]
    public var skipped = Skipped()
    /// More files than `Limits.maxTabs` (or entries than `maxEntries`): only the first were planned.
    public var truncated = false
    /// The planning was cancelled: nothing may be made from it.
    public var cancelled = false

    public init(nodes: [Node] = [], skipped: Skipped = Skipped(), truncated: Bool = false, cancelled: Bool = false) {
        self.nodes = nodes
        self.skipped = skipped
        self.truncated = truncated
        self.cancelled = cancelled
    }

    public var isEmpty: Bool { nodes.isEmpty }
    /// Every tab the plan makes (files, links, searches and notes), folders' contents included.
    public var tabCount: Int { Self.count(nodes) { if case .folder = $0 { false } else { true } } }
    public var folderCount: Int { Self.count(nodes) { if case .folder = $0 { true } else { false } } }

    static func count(_ nodes: [Node], _ counts: (Node) -> Bool) -> Int {
        nodes.reduce(0) { n, node in
            var c = n + (counts(node) ? 1 : 0)
            if case .folder(_, let kids) = node { c += count(kids, counts) }
            return c
        }
    }
}

/// Builds a `SidebarFilePlan`. Reading folders happens here (call it off the main thread for big trees): Finder's name
/// order, hidden files skipped, links followed once (a link back into a folder being read is a cycle and is skipped),
/// packages (apps, bundles) taken as files, at most `Limits` of everything. `isCancelled` is asked between entries.
public enum SidebarFilePlanner {
    public static func plan(_ items: [SidebarDropItem], limits: SidebarFilePlan.Limits = .standard,
                            fileManager: FileManager = .default, isCancelled: () -> Bool = { false }) -> SidebarFilePlan {
        withoutActuallyEscaping(isCancelled) { plan(items, limits: limits, fm: fileManager, isCancelled: $0) }
    }

    private static func plan(_ items: [SidebarDropItem], limits: SidebarFilePlan.Limits, fm: FileManager,
                             isCancelled: @escaping () -> Bool) -> SidebarFilePlan {
        var walk = Walk(limits: limits, fm: fm, isCancelled: isCancelled)
        var nodes: [SidebarFilePlan.Node] = []
        for item in items {
            if walk.stopped { break }
            switch item {
            case .file(let url):
                if let n = walk.node(for: url, depth: 0, ancestors: []) { nodes.append(n) }
            case .link(let url, let title):
                guard walk.takeTab() else { break }
                nodes.append(.tab(title: title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", url: url))
            case .text(let text):
                for n in textNodes(text, limits: limits) where walk.takeTab() { nodes.append(n) }
            }
        }
        return SidebarFilePlan(nodes: nodes, skipped: walk.skipped, truncated: walk.truncated, cancelled: walk.cancelled)
    }

    /// Text as Arc takes it: a link opens (several lines that are all links open one tab each); a word or phrase is a
    /// search; anything longer (more than one line, or over `maxSearchLength`) becomes a note.
    public static func textNodes(_ text: String, limits: SidebarFilePlan.Limits = .standard) -> [SidebarFilePlan.Node] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let links = lines.compactMap { line -> String? in
            guard !line.contains(" "), let u = URLRules.normalizeInput(line) else { return nil }
            return u
        }
        if !lines.isEmpty, links.count == lines.count { return links.map { .tab(title: "", url: $0) } }
        if lines.count == 1, trimmed.count <= limits.maxSearchLength { return [.search(query: trimmed)] }
        return [.note(text: trimmed)]
    }

    /// The things a Finder drop holds, in order, deduplicated: file URLs, then links (with their titles), then text
    /// that isn't one of the links. `titles` lines up with `links` where the drag had them.
    public static func items(files: [URL], links: [String], titles: [String] = [], text: String?) -> [SidebarDropItem] {
        var out: [SidebarDropItem] = []
        var seen = Set<String>()
        for f in files where f.isFileURL && seen.insert(f.standardizedFileURL.path).inserted { out.append(.file(f.standardizedFileURL)) }
        for (i, l) in links.enumerated() where !l.isEmpty && !(URL(string: l)?.isFileURL ?? false) && seen.insert(l).inserted {
            out.append(.link(l, title: i < titles.count ? titles[i] : nil))
        }
        // A dragged link or file usually carries its address as text too: text counts only when there's nothing else.
        if out.isEmpty, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(text)) }
        return out
    }

    private struct Walk {
        let limits: SidebarFilePlan.Limits
        let fm: FileManager
        let isCancelled: () -> Bool
        var skipped = SidebarFilePlan.Skipped()
        var truncated = false
        var cancelled = false
        var tabs = 0
        var entries = 0
        var stopped: Bool { truncated || cancelled }

        init(limits: SidebarFilePlan.Limits, fm: FileManager, isCancelled: @escaping () -> Bool) {
            self.limits = limits
            self.fm = fm
            self.isCancelled = isCancelled
        }

        mutating func takeTab() -> Bool {
            guard !stopped else { return false }
            guard tabs < limits.maxTabs else { truncated = true; return false }
            tabs += 1
            return true
        }

        /// `ancestors`: the real paths of the folders being read above this one (a link back to one is a cycle).
        mutating func node(for url: URL, depth: Int, ancestors: Set<String>) -> SidebarFilePlan.Node? {
            if isCancelled() { cancelled = true }
            guard !stopped else { return nil }
            entries += 1
            if entries > limits.maxEntries { truncated = true; return nil }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]
            guard let link = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { skipped.unreadable += 1; return nil }
            let real = link.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
            guard let v = try? real.resourceValues(forKeys: keys), fm.fileExists(atPath: real.path) else {
                skipped.unreadable += 1
                return nil
            }
            let name = url.lastPathComponent
            guard v.isDirectory == true, v.isPackage != true else {
                guard takeTab() else { return nil }
                return .tab(title: name, url: real.standardizedFileURL.absoluteString)
            }
            // The folder's real path, links resolved all the way (/var is /private/var), so a link back is recognised.
            let path = real.resolvingSymlinksInPath().standardizedFileURL.path
            if ancestors.contains(path) { skipped.cycles += 1; return nil }
            if depth >= limits.maxDepth { skipped.tooDeep += 1; return .folder(title: name, children: []) }
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(at: real, includingPropertiesForKeys: Array(keys), options: [])
            } catch {
                skipped.unreadable += 1
                return .folder(title: name, children: [])
            }
            var kids: [SidebarFilePlan.Node] = []
            let inside = ancestors.union([path])
            for c in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if stopped { break }
                if c.lastPathComponent.hasPrefix(".") || (try? c.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true {
                    skipped.hidden += 1
                    continue
                }
                if let n = node(for: c, depth: depth + 1, ancestors: inside) { kids.append(n) }
            }
            return .folder(title: name, children: kids)
        }
    }
}

/// Where a plan's rows go: the top of a Space's Today list (or a place in it), or a place in its pinned section (inside
/// a folder or not). Folders always go to the pinned section (Arc's folders live there): at the end of it when the
/// rest goes to Today.
public struct SidebarFileDestination: Equatable, Sendable {
    public enum Section: Equatable, Sendable {
        case today(index: Int?)
        case pinned(parentID: String?, index: Int?)
    }
    public var spaceID: String
    public var section: Section

    public init(spaceID: String, section: Section = .today(index: nil)) {
        self.spaceID = spaceID
        self.section = section
    }
}

/// What applying a plan made.
public struct SidebarFileResult: Equatable, Sendable {
    /// Today tabs made, in the plan's order (the first is shown).
    public var todayTabIDs: [String] = []
    /// Pinned items made at the destination's level (folders and tabs), in order.
    public var pinnedItemIDs: [String] = []
    public var tabs = 0
    public var folders = 0
    public init() {}
}

extension SpacesStore {
    /// Makes a plan's rows in one undoable step ("Add Files": one ⌘Z takes all of them back). Files and links become
    /// tabs; searches use `engine`; notes are notes. Nothing is made for a cancelled or empty plan.
    @discardableResult
    public func applySidebarFilePlan(_ plan: SidebarFilePlan, to dest: SidebarFileDestination,
                                     engine: SearchEngine) throws -> SidebarFileResult {
        guard let s = space(dest.spaceID) else { throw StoreError.notFound }
        guard !plan.cancelled, !plan.isEmpty else { return SidebarFileResult() }
        if case .pinned(let parentID?, _) = dest.section {
            guard let f = item(parentID), f.kind == .folder, f.container == .pinned(spaceID: s.id) else { throw StoreError.invalidMove }
        }
        var result = SidebarFileResult()
        let pinned = ItemContainer.pinned(spaceID: s.id)
        func url(of node: SidebarFilePlan.Node) -> (url: String, title: String)? {
            switch node {
            case .tab(let title, let u): return (u, title)
            case .search(let q): return (engine.searchURL(for: q).absoluteString, q)
            case .folder, .note: return nil
            }
        }
        /// Pinned rows for `nodes` under `parentID`, from `index` (the end when nil).
        func pin(_ nodes: [SidebarFilePlan.Node], parentID: String?, index: Int?, top: Bool) throws {
            let siblings = children(of: pinned, parent: parentID).map(\.order)
            var lo = index.map { $0 > 0 && $0 <= siblings.count ? siblings[$0 - 1] : nil } ?? siblings.last
            let hi = index.flatMap { $0 < siblings.count ? siblings[$0] : nil }
            for node in nodes {
                let order = Ordering.between(lo, hi)
                lo = order
                switch node {
                case .folder(let title, let kids):
                    let f = Item(kind: .folder, container: pinned, parentID: parentID, order: order, title: title, createdAt: now())
                    put(f)
                    result.folders += 1
                    if top { result.pinnedItemIDs.append(f.id) }
                    try pin(kids, parentID: f.id, index: nil, top: false)
                case .note(let text):
                    let tab = try createNote(inSpace: s.id, pinned: true, parentID: parentID, document: NoteDocument(lines: text.components(separatedBy: .newlines)))
                    if var i = item(tab.itemID) {
                        i.order = order
                        put(i)
                        if top { result.pinnedItemIDs.append(i.id) }
                    }
                    result.tabs += 1
                default:
                    guard let (u, title) = url(of: node) else { continue }
                    let i = Item(kind: .tab, container: pinned, parentID: parentID, order: order, savedURL: u,
                                 pageTitle: title.isEmpty ? nil : title, createdAt: now())
                    put(i)
                    if top { result.pinnedItemIDs.append(i.id) }
                    result.tabs += 1
                }
            }
        }
        try perform("Add Files", undoable: true) {
            switch dest.section {
            case .pinned(let parentID, let index):
                try pin(plan.nodes, parentID: parentID, index: index, top: true)
            case .today(let index):
                // Folders go to the end of the pinned section; the rest, in order, into Today.
                let folders = plan.nodes.filter { if case .folder = $0 { true } else { false } }
                try pin(folders, parentID: nil, index: nil, top: true)
                let rows = todayRows(ofSpace: s.id).map(rowOrder)
                let at = min(max(index ?? 0, 0), rows.count)
                var lo = at > 0 ? rows[at - 1] : nil
                let hi = at < rows.count ? rows[at] : nil
                for node in plan.nodes {
                    if case .folder = node { continue }
                    let order = Ordering.between(lo, hi)
                    lo = order
                    var tab: LiveTab
                    if case .note(let text) = node {
                        tab = try createNote(inSpace: s.id, pinned: false, document: NoteDocument(lines: text.components(separatedBy: .newlines)))
                        tab.order = order
                    } else {
                        guard let (u, title) = url(of: node) else { continue }
                        tab = LiveTab(profileID: s.profileID, spaceID: s.id, url: u, title: title, order: order, createdAt: now())
                    }
                    put(tab)
                    result.todayTabIDs.append(tab.id)
                    result.tabs += 1
                }
                if let first = result.todayTabIDs.first { markActive(first, inSpace: s.id) }
            }
        }
        return result
    }
}
