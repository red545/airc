// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

// Live Folders (Arc parity S15, docs/user/live-folders.md): a sidebar folder that keeps itself filled from a source.
// The only provider is GitHub pull requests.
//
// - The folder is an ordinary folder `Item`. What makes it live is its definition (`LiveFolderDefinition`), kept per
//   device in the store's local values (`SpacesStore.localValue`): never in the op log and never synced. On another Mac
//   the folder and its current rows sync as an ordinary folder; only the Mac that holds the definition updates them.
// - Its pull requests are ordinary pinned tab rows inside it, told apart by `Item.sourceID` = "live:<key>". Only those
//   rows are ever added, renamed or removed by a refresh: the person's own tabs in the folder are never touched.
// - A live row the person removes, keeps (Keep in Folder) or drags out is "dismissed": it isn't added again while its
//   pull request stays open.
// - Deleting the folder is the normal undoable Delete; the definition stays until the next launch's `prune()`, so ⌘Z
//   brings back a live folder, not a plain one.

/// The prefix of a live row's `Item.sourceID`.
public let liveRowSourcePrefix = "live:"

/// Which pull requests a GitHub live folder lists (Arc's filters: Created by Me, Review Requests, Drafts, a repository).
public struct GitHubPullQuery: Codable, Hashable, Sendable {
    /// "owner/name", or nil for every repository the account can see (needs sign-in).
    public var repository: String?
    /// Pull requests the signed-in account opened (needs sign-in).
    public var createdByMe: Bool
    /// Pull requests waiting for the signed-in account's review (needs sign-in).
    public var reviewRequested: Bool
    /// Only this author's pull requests (a GitHub login).
    public var author: String?
    /// Only pull requests with every one of these labels.
    public var labels: [String]
    public var includeDrafts: Bool

    public init(repository: String? = nil, createdByMe: Bool = false, reviewRequested: Bool = false, author: String? = nil,
                labels: [String] = [], includeDrafts: Bool = true) {
        self.repository = Self.normalizedRepository(repository)
        self.createdByMe = createdByMe
        self.reviewRequested = reviewRequested
        self.author = author.flatMap { Self.normalizedLogin($0) }
        self.labels = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        self.includeDrafts = includeDrafts
    }

    /// Arc's automatic folder: your pull requests and the ones waiting for your review.
    public static let yours = GitHubPullQuery(createdByMe: true, reviewRequested: true)

    /// A query that only GitHub's signed-in search can answer.
    public var needsSignIn: Bool { createdByMe || reviewRequested || repository == nil }

    /// "owner/name" from "owner/name", "github.com/owner/name" or a full URL; nil if it isn't one.
    public static func normalizedRepository(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        for p in ["https://", "http://", "www.", "github.com/"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map(String.init)
        guard parts.count == 2, parts.allSatisfy(isNamePart) else { return nil }
        return parts.joined(separator: "/")
    }

    static func normalizedLogin(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@") { s.removeFirst() }
        return !s.isEmpty && isNamePart(s) ? s : nil
    }

    private static func isNamePart(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 100 && s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0)
        } && s != "." && s != ".."
    }

    /// Whether a pull request passes the filters GitHub's list endpoint can't apply (author, review, labels, drafts).
    public func admits(_ p: GitHubPull, viewer: String?) -> Bool {
        guard p.isOpen else { return false }
        if !includeDrafts, p.isDraft { return false }
        if let author, p.author?.lowercased() != author.lowercased() { return false }
        if let repository, p.repository.lowercased() != repository.lowercased() { return false }
        let have = Set(p.labels.map { $0.lowercased() })
        if !labels.allSatisfy({ have.contains($0.lowercased()) }) { return false }
        // From search these hold by construction (GitHub matched them); a repository listing checks them here.
        if let viewer, p.fromSearch == false {
            let mine = createdByMe && p.author?.lowercased() == viewer.lowercased()
            let review = reviewRequested && p.requestedReviewers.contains { $0.lowercased() == viewer.lowercased() }
            if (createdByMe || reviewRequested) && !(mine || review) { return false }
        }
        return true
    }

    /// The folder's name for this query, as Arc names its automatic folder ("Pull Requests").
    public var suggestedTitle: String {
        if let repository, !createdByMe, !reviewRequested { return repository.split(separator: "/").last.map(String.init) ?? repository }
        if reviewRequested && !createdByMe { return "Review Requests" }
        return "Pull Requests"
    }
}

/// One pull request as a live folder keeps it (its offline cache too).
public struct GitHubPull: Codable, Hashable, Sendable {
    /// "owner/name".
    public var repository: String
    public var number: Int
    public var title: String
    /// The pull request's page on github.com.
    public var url: String
    public var author: String?
    public var isDraft: Bool
    public var labels: [String]
    public var requestedReviewers: [String]
    /// "open" or "closed".
    public var state: String
    public var merged: Bool
    public var updatedAt: Date?
    /// Came from GitHub's search (which applied the query) rather than a repository's list.
    public var fromSearch: Bool

    public init(repository: String, number: Int, title: String, url: String, author: String? = nil, isDraft: Bool = false,
                labels: [String] = [], requestedReviewers: [String] = [], state: String = "open", merged: Bool = false,
                updatedAt: Date? = nil, fromSearch: Bool = false) {
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.isDraft = isDraft
        self.labels = labels
        self.requestedReviewers = requestedReviewers
        self.state = state
        self.merged = merged
        self.updatedAt = updatedAt
        self.fromSearch = fromSearch
    }

    public var isOpen: Bool { state == "open" && !merged }
    /// The live row's identity: "github:owner/name#12".
    public var key: String { "github:\(repository.lowercased())#\(number)" }
}

/// Why a live folder isn't up to date. Arc's words are in `message`.
public enum LiveFolderStatus: Codable, Hashable, Sendable {
    case ok
    /// No GitHub account for the folder's profile, or GitHub refused its token (expired or revoked).
    case signedOut
    case rateLimited(until: Date?)
    case offline
    case notFound
    case failed(String)

    public var isError: Bool { self != .ok }

    /// The status line in the folder's menu and the row's tooltip.
    public var message: String {
        switch self {
        case .ok: "Up to date"
        case .signedOut: "Not signed in to GitHub"
        case .rateLimited: "GitHub rate limit exceeded"
        case .offline: "Offline. Showing the last list"
        case .notFound: "Repository not found"
        case .failed(let why): why.isEmpty ? "Failed to update" : "Failed to update: \(why)"
        }
    }

    /// The short word on the folder's row.
    public var badge: String {
        switch self {
        case .ok: ""
        case .signedOut: "Sign In"
        case .rateLimited: "Rate Limited"
        case .offline: "Offline"
        case .notFound: "Not Found"
        case .failed: "Failed"
        }
    }
}

/// A status is also the error of a request that didn't list (`GitHubClient.viewer`).
extension LiveFolderStatus: Error {}

/// A page of a listing as GitHub last sent it, for If-None-Match (a 304 reuses it) and offline use.
public struct LiveCachedPage: Codable, Hashable, Sendable {
    public var etag: String?
    public var pulls: [GitHubPull]
    /// The next page's URL (GitHub's Link header), if any.
    public var next: String?

    public init(etag: String?, pulls: [GitHubPull], next: String?) {
        self.etag = etag
        self.pulls = pulls
        self.next = next
    }
}

/// What makes a folder live. Saved per device (see the top of this file).
public struct LiveFolderDefinition: Codable, Hashable, Sendable {
    public var folderID: String
    public var provider: String
    public var query: GitHubPullQuery
    public var createdAt: Date
    public var status: LiveFolderStatus
    public var lastRefreshed: Date?
    public var lastAttempt: Date?
    /// No automatic refresh before this (backoff after failures, GitHub's rate-limit reset).
    public var nextAllowed: Date?
    public var failures: Int
    /// Live rows this folder made, by key, with the title it gave each (a title the person changed is theirs).
    public var known: [String: String]
    /// Keys of live rows the person removed, kept or moved out: not added again while their pull request is open.
    public var dismissed: Set<String>
    /// The last full listing (the offline cache).
    public var cache: [GitHubPull]
    /// Listing pages by URL, for If-None-Match.
    public var pages: [String: LiveCachedPage]

    public init(folderID: String, query: GitHubPullQuery, createdAt: Date) {
        self.folderID = folderID
        provider = "github"
        self.query = query
        self.createdAt = createdAt
        status = .ok
        failures = 0
        known = [:]
        dismissed = []
        cache = []
        pages = [:]
    }
}

/// The result of one fetch, applied by `LiveFolderBook.apply`.
public enum LiveFetchResult: Sendable, Equatable {
    /// Every page was read. `viewer` is the signed-in login, if known.
    case success(pulls: [GitHubPull], pages: [String: LiveCachedPage], viewer: String?)
    case failure(LiveFolderStatus, retryAt: Date?)
    case cancelled
}

/// What applying a result changed.
public struct LiveApplyOutcome: Equatable, Sendable {
    public var added: [String] = []
    public var updated: [String] = []
    public var retired: [String] = []
    /// Tabs of retired rows: their pages should close.
    public var retiredTabIDs: [String] = []
    /// Rows that would retire but are on screen: they go at a later refresh.
    public var deferred: [String] = []
    /// The folder or its definition went while the request was out: nothing was applied.
    public var discarded = false
    public init() {}
}

/// The live folders of one store: their definitions, and what a refresh does to their rows. Main thread, like the store.
public final class LiveFolderBook {
    public let store: SpacesStore
    public private(set) var definitions: [String: LiveFolderDefinition] = [:]
    public var now: () -> Date

    static let localKey = "liveFolders.v1"

    public init(store: SpacesStore) {
        self.store = store
        now = { store.now() }
        if let raw = store.localValue(Self.localKey), let data = raw.data(using: .utf8),
           let saved = try? Self.decoder.decode([String: LiveFolderDefinition].self, from: data) {
            definitions = saved
        }
    }

    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }()
    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    func save() {
        let body = (try? Self.encoder.encode(definitions)).flatMap { String(data: $0, encoding: .utf8) }
        store.setLocalValue(Self.localKey, definitions.isEmpty ? nil : body)
    }

    /// The folder's definition while the folder exists (a deleted folder's waits for ⌘Z or the next `prune`).
    public func definition(_ folderID: String) -> LiveFolderDefinition? {
        guard let d = definitions[folderID], store.item(folderID)?.kind == .folder else { return nil }
        return d
    }

    public func isLive(_ folderID: String?) -> Bool { folderID.map { definition($0) != nil } ?? false }

    /// The live folders that exist now.
    public var activeFolderIDs: [String] {
        definitions.keys.filter { store.item($0)?.kind == .folder }.sorted()
    }

    /// The profile whose GitHub account a folder uses: its Space's.
    public func profileID(ofFolder folderID: String) -> String? {
        guard let space = store.item(folderID)?.spaceID else { return nil }
        return store.space(space)?.profileID
    }

    /// The key of a live row (a pull request's row inside its live folder), nil for every other row.
    public func liveKey(ofItem id: String) -> String? {
        guard let i = store.item(id), let s = i.sourceID, s.hasPrefix(liveRowSourcePrefix),
              let parent = i.parentID, definitions[parent] != nil else { return nil }
        return String(s.dropFirst(liveRowSourcePrefix.count))
    }

    /// New Live Folder: a folder in the Space's pinned section (at the top, as Arc puts its automatic folder) that
    /// fills itself at the first refresh.
    @discardableResult
    public func create(query: GitHubPullQuery, title: String? = nil, inSpace spaceID: String, parentID: String? = nil,
                       index: Int = 0) throws -> Item {
        let folder = try store.createFolder(named: title ?? query.suggestedTitle, inSpace: spaceID, parentID: parentID, index: index)
        definitions[folder.id] = LiveFolderDefinition(folderID: folder.id, query: query, createdAt: now())
        save()
        return folder
    }

    /// New filters: the next refresh lists again from scratch (no cached pages), and rows that no longer match retire.
    public func setQuery(_ query: GitHubPullQuery, ofFolder folderID: String) {
        guard var d = definitions[folderID], d.query != query else { return }
        d.query = query
        d.pages = [:]
        d.dismissed = []
        d.status = .ok
        d.failures = 0
        d.nextAllowed = nil
        definitions[folderID] = d
        save()
    }

    /// Stop Updating: the folder stays with its rows, now ordinary tabs, and nothing refreshes it again.
    public func stopUpdating(_ folderID: String) throws {
        guard definitions[folderID] != nil else { return }
        let rows = store.state.items.values.filter {
            $0.parentID == folderID && ($0.sourceID?.hasPrefix(liveRowSourcePrefix) ?? false)
        }
        try store.perform("Stop Updating") {
            for var r in rows {
                r.sourceID = nil
                store.put(r)
            }
        }
        definitions[folderID] = nil
        save()
    }

    /// Keep in Folder: a pull request's row becomes the person's own tab, so it stays after the pull request closes.
    public func keep(_ itemID: String) throws {
        guard liveKey(ofItem: itemID) != nil, var i = store.item(itemID) else { return }
        i.sourceID = nil
        try store.perform("Keep in Folder") { store.put(i) }
    }

    /// Forgets the definitions of folders that are gone. Called once at launch, so an undone delete in the session
    /// before still finds its definition.
    @discardableResult
    public func prune() -> [String] {
        let gone = definitions.keys.filter { store.item($0)?.kind != .folder }
        for id in gone { definitions[id] = nil }
        if !gone.isEmpty { save() }
        return gone.sorted()
    }

    /// Records that a refresh is starting (for the schedule).
    public func noteAttempt(_ folderID: String) {
        guard definitions[folderID] != nil else { return }
        definitions[folderID]?.lastAttempt = now()
        save()
    }

    /// Applies a fetch to the folder's rows. A result for a folder that's gone (deleted while the request was out) or
    /// that stopped updating is dropped. `protected`: tabs on screen, whose rows don't retire under the person.
    @discardableResult
    public func apply(_ result: LiveFetchResult, to folderID: String, protected: Set<String> = []) -> LiveApplyOutcome {
        var out = LiveApplyOutcome()
        guard var d = definitions[folderID], let folder = store.item(folderID), folder.kind == .folder else {
            out.discarded = true
            return out
        }
        let t = now()
        switch result {
        case .cancelled:
            out.discarded = true
            return out
        case .failure(let status, let retryAt):
            d.status = status
            d.failures += 1
            d.nextAllowed = LiveFolderSchedule.nextAttempt(after: status, failures: d.failures, retryAt: retryAt, now: t)
            definitions[folderID] = d
            save()
            return out
        case .success(let fetched, let pages, let viewer):
            var pulls: [GitHubPull] = []
            var seen = Set<String>()
            for p in fetched where d.query.admits(p, viewer: viewer) && seen.insert(p.key).inserted { pulls.append(p) }
            pulls.sort { ($0.updatedAt ?? .distantPast, $1.key) > ($1.updatedAt ?? .distantPast, $0.key) }
            let open = Set(pulls.map(\.key))

            var rows: [String: Item] = [:]
            for i in store.state.items.values where i.parentID == folderID {
                if let s = i.sourceID, s.hasPrefix(liveRowSourcePrefix) { rows[String(s.dropFirst(liveRowSourcePrefix.count))] = i }
            }
            // A row this folder made that isn't a live row in it any more was removed, kept or moved by the person.
            for key in d.known.keys where rows[key] == nil { d.dismissed.insert(key) }
            d.dismissed.formIntersection(open)
            d.dismissed.subtract(rows.keys)   // a dismissed row brought back by ⌘Z is live again

            let siblings = store.children(of: folder.container, parent: folderID)
            var top = siblings.map(\.order).min() ?? 0
            var given: [String: String] = [:]   // titles this refresh gave rows
            do {
                try store.perform(nil) {
                    for (key, row) in rows where !open.contains(key) {
                        if let tab = store.liveTab(forItem: row.id) {
                            if protected.contains(tab.id) { out.deferred.append(row.id); continue }
                            out.retiredTabIDs.append(tab.id)
                        }
                        store.removeItemTree(row.id)
                        out.retired.append(row.id)
                    }
                    for p in pulls {
                        // A title the person gave the row stays theirs.
                        guard var row = rows[p.key], row.title != p.title,
                              row.title == d.known[p.key] || row.title == nil else { continue }
                        row.title = p.title
                        store.put(row)
                        rows[p.key] = row
                        given[p.key] = p.title
                        out.updated.append(row.id)
                    }
                    // New pull requests go to the top, most recently updated first.
                    for p in pulls.reversed() where rows[p.key] == nil && !d.dismissed.contains(p.key) {
                        top -= 1
                        let row = Item(kind: .tab, container: folder.container, parentID: folderID, order: top,
                                       savedURL: p.url, title: p.title, faviconURL: Self.favicon(forPull: p.url), createdAt: t,
                                       sourceID: liveRowSourcePrefix + p.key)
                        store.put(row)
                        out.added.append(row.id)
                        rows[p.key] = row
                        given[p.key] = p.title
                    }
                }
            } catch {
                d.status = .failed("Couldn't save")
                definitions[folderID] = d
                save()
                return LiveApplyOutcome()
            }
            var known: [String: String] = [:]
            for (key, row) in rows where store.item(row.id) != nil {
                known[key] = given[key] ?? d.known[key] ?? row.title ?? ""
            }
            d.known = known
            d.cache = pulls
            d.pages = pages
            d.status = .ok
            d.failures = 0
            d.lastRefreshed = t
            d.nextAllowed = nil
            definitions[folderID] = d
            save()
            out.added.reverse()
            return out
        }
    }

    /// The icon a live row shows before its page loads: its site's (github.com's, or a GitHub Enterprise or test host's).
    public static func favicon(forPull url: String) -> String? {
        guard let u = URLComponents(string: url), let scheme = u.scheme, let host = u.host else { return nil }
        return "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")/favicon.ico"
    }
}
