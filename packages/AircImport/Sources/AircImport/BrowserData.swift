// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// One page from another browser's history, for the Command Bar's suggestions.
public struct ImportedVisit: Codable, Sendable, Equatable {
    public var url: String
    public var title: String
    public var visitCount: Int
    public var typedCount: Int
    public var lastVisit: Date
}

/// What one browser profile brings: counts only, never a title or address.
public struct BrowserProfileSummary: Sendable, Equatable, Identifiable {
    /// The profile's source key in the plan ("chrome-profile:Default").
    public var sourceKey: String
    /// `BrowserProfile.id`.
    public var profileID: String
    public var name: String
    public var color: String?
    public var isDefault: Bool
    public var bookmarks = 0
    /// Folders as the sidebar will show them, "Other bookmarks" included.
    public var folders = 0
    public var history = 0
    /// The parts that couldn't be read ("bookmarks", "history"). Never why in terms of a value.
    public var unreadable: [String] = []
    public var id: String { sourceKey }
}

/// A browser's bookmarks and history, read. `plan` is the Spaces-and-profiles part, in AircImport's own plan types:
/// one profile and one Space per browser profile; the Space's pinned tabs are the bookmarks bar, followed by one
/// folder per other root ("Other bookmarks", "Mobile bookmarks"). Favorites stay empty. Every ID is a full source key
/// (`BrowserImport.Keys`), stable across imports (Chromium's and Firefox's bookmark GUIDs), so importing again updates
/// in place.
public struct BrowserImport: Sendable {
    /// The browser; nil for a bookmarks file that doesn't say which browser wrote it.
    public var kind: BrowserKind?
    /// Read from a bookmarks file the user chose, not from the browser's own folder.
    public var fromFile = false
    public var installID: String
    public var plan: ImportPlan
    /// Profile source key → its history, newest first.
    public var history: [String: [ImportedVisit]]
    public var profiles: [BrowserProfileSummary]

    public var bookmarks: Int { profiles.reduce(0) { $0 + $1.bookmarks } }
    public var folders: Int { profiles.reduce(0) { $0 + $1.folders } }
    public var historyEntries: Int { profiles.reduce(0) { $0 + $1.history } }

    /// The source keys a browser import uses: "<install>-profile:<profile>", "<install>-space:<profile>" and
    /// "<install>-item:<profile>/<bookmark GUID>". The profile is part of an item's key because two profiles synced to
    /// one account share their bookmarks' GUIDs.
    public enum Keys {
        public static func profile(_ install: String, _ profile: String) -> String { "\(install)-profile:\(profile)" }
        public static func space(_ install: String, _ profile: String) -> String { "\(install)-space:\(profile)" }
        public static func item(_ install: String, _ profile: String) -> String { "\(install)-item:\(profile)/" }
    }
}

/// Builds the pinned tree from any bookmark source, with the limits and warnings every source shares.
struct BookmarkBuilder {
    static let maxDepth = 64
    let prefix: String
    let maxBookmarks: Int
    private(set) var bookmarks = 0
    private(set) var folders = 0
    private(set) var warnings: [ImportWarning] = []
    private var stopped = false
    /// The IDs given out so far, with how many times each was asked for: a file's own IDs (an HTML file's `ID`
    /// attributes, GUIDs) can repeat in a crafted or hand-edited file, and one ID for two entries would make the import
    /// merge them, or put a folder inside itself.
    private var given: [String: Int] = [:]

    init(prefix: String, maxBookmarks: Int) {
        self.prefix = prefix
        self.maxBookmarks = maxBookmarks
    }

    mutating func warn(_ code: ImportWarning.Code, _ message: String) { warnings.append(.init(code: code, message: message)) }

    /// A bookmark as a pinned tab, or nil (with a warning) when it can't be one.
    mutating func tab(id: String, url raw: String?, name: String?) -> ImportedItem? {
        guard let url = nonempty(raw) else { warn(.invalidTab, "Skipped a bookmark without an address."); return nil }
        let scheme = url.prefix(while: { $0 != ":" }).lowercased()
        if scheme == "javascript" { warn(.bookmarklet, "Skipped a bookmarklet."); return nil }
        if scheme == "place" { warn(.smartBookmark, "Skipped a smart folder."); return nil }
        if scheme == "data" || !url.contains(":") { warn(.invalidTab, "Skipped a bookmark without a usable address."); return nil }
        guard bookmarks < maxBookmarks else {
            if !stopped { stopped = true; warn(.tooManyBookmarks, "Stopped at the most bookmarks one import takes.") }
            return nil
        }
        bookmarks += 1
        return .tab(.init(id: prefix + unique(id), url: url, title: nonempty(name), pageTitle: nil, lastActiveAt: nil))
    }

    /// Called after its children were built: a folder whose ID repeats one inside it keeps the ID its first holder
    /// (in reading order, the deeper one) took, plus a suffix. The same file read again gives the same IDs.
    mutating func folder(id: String, title: String?, fallback: String = "Folder", children: [ImportedItem]) -> ImportedFolder {
        folders += 1
        return .init(id: prefix + unique(id), title: nonempty(title) ?? fallback, children: children)
    }

    /// `id`, or for a repeat `id#2`, `id#3`… (skipping any the file uses itself), so every entry of one import has its
    /// own ID.
    private mutating func unique(_ id: String) -> String {
        guard let n = given[id] else { given[id] = 1; return id }
        var k = n + 1
        while given["\(id)#\(k)"] != nil { k += 1 }
        given[id] = k
        let out = "\(id)#\(k)"
        given[out] = 1
        return out
    }

    func deep(_ depth: Int) -> Bool { depth > Self.maxDepth }
}

extension BrowserImporter {
    /// Bookmarks past this many in one profile are left out (with a warning): a sidebar is not a bookmark manager.
    public static let maxBookmarks = 10_000
    /// The newest this many pages of each profile's history come over (Airc keeps 20,000 per profile).
    public static let defaultHistoryLimit = 20_000
    /// Files past this size aren't read (Bookmarks JSON, bookmark HTML files, password CSV files).
    public static let maxFileSize = 128 << 20

    /// Reads `profiles` of `install` (all of them by default) off the caller's actor. `Bookmarks` is read in place
    /// (Chromium writes it whole, atomically); `History` and `places.sqlite` from private copies, because the browser
    /// may hold them open under SQLite's exclusive lock (`DatabaseCopy`, deleted when the read ends). A profile whose
    /// bookmarks or history can't be read still brings the other part; the plan's warnings say which. Throws only for
    /// cancellation.
    public static func read(_ install: BrowserInstall, profiles chosen: [String]? = nil, includeHistory: Bool = true,
                            historyLimit: Int = defaultHistoryLimit,
                            tempRoot: URL = FileManager.default.temporaryDirectory) async throws -> BrowserImport {
        try await Task.detached {
            var out = BrowserImport(kind: install.kind, installID: install.id,
                                    plan: ImportPlan(profiles: [], spaces: [], favorites: [:], warnings: []), history: [:], profiles: [])
            let profiles = install.profiles.filter { chosen?.contains($0.id) ?? true }
            var names: [String: Int] = [:]
            for p in profiles {
                try Task.checkCancellation()
                let key = BrowserImport.Keys.profile(install.id, p.id)
                var builder = BookmarkBuilder(prefix: BrowserImport.Keys.item(install.id, p.id), maxBookmarks: BrowserImporter.maxBookmarks)
                var summary = BrowserProfileSummary(sourceKey: key, profileID: p.id, name: p.name, color: p.color, isDefault: p.isDefault)
                var roots: (bar: [ImportedItem], folders: [ImportedFolder]) = ([], [])
                var visits: [ImportedVisit] = []
                if install.kind.family == .firefox {
                    do {
                        let db = try DatabaseCopy(p.folder.appendingPathComponent("places.sqlite"), tempRoot: tempRoot)
                        do { roots = try FirefoxPlaces.bookmarks(db, &builder) }
                        catch { summary.unreadable.append("bookmarks") }
                        if includeHistory {
                            do { visits = try FirefoxPlaces.history(db, limit: historyLimit) }
                            catch { summary.unreadable.append("history") }
                        }
                    } catch {
                        summary.unreadable += includeHistory ? ["bookmarks", "history"] : ["bookmarks"]
                    }
                } else {
                    let file = p.folder.appendingPathComponent("Bookmarks")
                    if BrowserImporter.isFile(file) {
                        do { roots = try ChromiumBookmarks.parse(try BrowserImporter.readLimited(file), &builder) }
                        catch { summary.unreadable.append("bookmarks") }
                    }
                    let history = p.folder.appendingPathComponent("History")
                    if includeHistory, BrowserImporter.isFile(history) {
                        do { visits = try ChromiumHistory.read(DatabaseCopy(history, tempRoot: tempRoot), limit: historyLimit) }
                        catch { summary.unreadable.append("history") }
                    }
                }
                try Task.checkCancellation()
                summary.bookmarks = builder.bookmarks
                summary.folders = builder.folders
                summary.history = visits.count
                out.plan.warnings += builder.warnings
                if summary.unreadable.contains("bookmarks") { out.plan.warnings.append(.init(code: .unreadableBookmarks, message: "A profile's bookmarks couldn't be read.")) }
                if summary.unreadable.contains("history") { out.plan.warnings.append(.init(code: .unreadableHistory, message: "A profile's history couldn't be read.")) }
                // Spaces are named after their profiles; two that would share a name get "Chrome", "Chrome 2".
                var name = p.name
                names[name.lowercased(), default: 0] += 1
                if let n = names[name.lowercased()], n > 1 { name += " \(n)" }
                summary.name = name
                out.plan.profiles.append(ImportedProfile(id: key, directory: p.id, name: name, avatar: nil,
                                                         color: p.chromiumColor.map { .number($0) }, isAvailable: true))
                let color = p.color ?? install.kind.color
                out.plan.spaces.append(ImportedSpace(id: BrowserImport.Keys.space(install.id, p.id), name: name, emoji: "•", icon: nil,
                                                     theme: ImportedTheme(color: color, colors: [color], raw: nil), profileID: key,
                                                     pinned: roots.bar + roots.folders.map { .folder($0) }, today: []))
                out.history[key] = visits
                out.profiles.append(summary)
            }
            return out
        }.value
    }

    /// A file whose size is checked before it's read whole.
    static func readLimited(_ url: URL, limit: Int = maxFileSize) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limit else { throw ImportError.fileTooLarge }
        return try readData(url, missing: .invalidBookmarks)
    }
}

/// Chromium's `Bookmarks` file: `roots.bookmark_bar`, `roots.other`, `roots.synced`, each a folder node with
/// `children`; a node is `{type: "url"|"folder", name, url, guid, id}`.
enum ChromiumBookmarks {
    static func parse(_ data: Data, _ b: inout BookmarkBuilder) throws -> (bar: [ImportedItem], folders: [ImportedFolder]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? Obj, let roots = root["roots"] as? Obj else {
            throw ImportError.invalidBookmarks
        }
        func children(_ node: Obj, depth: Int) -> [ImportedItem] {
            guard !b.deep(depth) else { b.warn(.depthLimit, "Stopped at a folder nested more than 64 levels deep."); return [] }
            var out: [ImportedItem] = []
            for case let child as Obj in node["children"] as? [Any] ?? [] {
                let id = nonempty(child["guid"]) ?? nonempty(child["id"]) ?? UUID().uuidString
                if child["type"] as? String == "folder" {
                    out.append(.folder(b.folder(id: id, title: child["name"] as? String, children: children(child, depth: depth + 1))))
                } else if let t = b.tab(id: id, url: child["url"] as? String, name: child["name"] as? String) {
                    out.append(t)
                }
            }
            return out
        }
        let bar = children(obj(roots["bookmark_bar"]), depth: 1)
        var folders: [ImportedFolder] = []
        for (key, fallback) in [("other", "Other bookmarks"), ("synced", "Mobile bookmarks")] {
            let node = obj(roots[key])
            let items = children(node, depth: 1)
            guard !items.isEmpty else { continue }
            folders.append(b.folder(id: "root:" + key, title: node["name"] as? String, fallback: fallback, children: items))
        }
        return (bar, folders)
    }
}

/// Chromium's `History` database: `urls(url, title, visit_count, typed_count, last_visit_time, hidden)`, times in
/// microseconds since 1601.
enum ChromiumHistory {
    static func read(_ db: DatabaseCopy, limit: Int, since: Date? = nil) throws -> [ImportedVisit] {
        let rows = try db.rows("""
            SELECT url, title, visit_count, typed_count, last_visit_time FROM urls
            WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
              AND last_visit_time >= \(since.map { Int64(($0.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) } ?? 0)
            ORDER BY last_visit_time DESC LIMIT \(max(0, limit))
            """)
        return rows.compactMap { r in
            visit(r, count: "visit_count", typed: "typed_count", time: "last_visit_time") { Date(timeIntervalSince1970: $0 / 1_000_000 - 11_644_473_600) }
        }
    }
}

/// Firefox's (and Zen's) `places.sqlite`: `moz_bookmarks` (type 1 a bookmark, 2 a folder, 3 a separator; the roots by
/// GUID) joined to `moz_places`, and `moz_places` for history, times in microseconds since 1970.
enum FirefoxPlaces {
    static func bookmarks(_ db: DatabaseCopy, _ b: inout BookmarkBuilder) throws -> (bar: [ImportedItem], folders: [ImportedFolder]) {
        let rows = try db.rows("""
            SELECT b.id AS id, b.type AS type, b.parent AS parent, b.title AS title, b.guid AS guid, p.url AS url
            FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
            """)
        func s(_ r: [String: Data], _ k: String) -> String? { r[k].flatMap { String(data: $0, encoding: .utf8) } }
        var kids: [String: [[String: Data]]] = [:]
        var roots: [String: String] = [:]
        for r in rows {
            guard let id = s(r, "id") else { continue }
            if let parent = s(r, "parent") { kids[parent, default: []].append(r) }
            if let guid = s(r, "guid"), guid.hasSuffix("_") { roots[guid] = id }
        }
        var seen = Set<String>()
        func children(_ parent: String, depth: Int) -> [ImportedItem] {
            guard !b.deep(depth) else { b.warn(.depthLimit, "Stopped at a folder nested more than 64 levels deep."); return [] }
            var out: [ImportedItem] = []
            for r in kids[parent] ?? [] {
                guard let id = s(r, "id"), seen.insert(id).inserted else { continue }
                let key = s(r, "guid") ?? id
                switch s(r, "type") {
                case "1": if let t = b.tab(id: key, url: s(r, "url"), name: s(r, "title")) { out.append(t) }
                case "2": out.append(.folder(b.folder(id: key, title: s(r, "title"), children: children(id, depth: depth + 1))))
                default: continue   // separators
                }
            }
            return out
        }
        let bar = roots["toolbar_____"].map { children($0, depth: 1) } ?? []
        var folders: [ImportedFolder] = []
        for (guid, title) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            guard let id = roots[guid] else { continue }
            let items = children(id, depth: 1)
            guard !items.isEmpty else { continue }
            folders.append(b.folder(id: "root:" + guid.trimmingCharacters(in: CharacterSet(charactersIn: "_")), title: title, children: items))
        }
        return (bar, folders)
    }

    static func history(_ db: DatabaseCopy, limit: Int) throws -> [ImportedVisit] {
        let rows = try db.rows("""
            SELECT url, title, visit_count, typed, last_visit_date FROM moz_places
            WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL AND (url LIKE 'http://%' OR url LIKE 'https://%')
            ORDER BY last_visit_date DESC LIMIT \(max(0, limit))
            """)
        return rows.compactMap { r in
            visit(r, count: "visit_count", typed: "typed", time: "last_visit_date") { Date(timeIntervalSince1970: $0 / 1_000_000) }
        }
    }
}

private func visit(_ r: [String: Data], count: String, typed: String, time: String, date: (Double) -> Date) -> ImportedVisit? {
    func s(_ k: String) -> String? { r[k].flatMap { String(data: $0, encoding: .utf8) } }
    guard let url = s("url"), !url.isEmpty, let t = s(time).flatMap(Double.init), t > 0 else { return nil }
    return ImportedVisit(url: url, title: s("title") ?? "", visitCount: max(1, Int(s(count) ?? "") ?? 1),
                         typedCount: max(0, Int(s(typed) ?? "") ?? 0), lastVisit: date(t))
}
