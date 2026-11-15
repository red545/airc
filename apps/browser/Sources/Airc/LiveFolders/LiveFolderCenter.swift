// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// Keeps the app's live folders current (AircKit's LiveFolders.swift, docs/user/live-folders.md): every three minutes,
/// when a window comes to the front with a list older than a minute, and on Refresh. One request per folder at a time;
/// a folder deleted while its request is out cancels it, and a late answer is dropped. Starts the first time the sidebar
/// shows a live folder or one is made, so a profile without one never touches the network.
final class LiveFolderCenter {
    static let shared = LiveFolderCenter()
    /// Posted (object: the folder's ID, or nil for all) when a folder's state or rows change: rows and menus redraw.
    static let didChange = Notification.Name("AircLiveFolderDidChange")

    private(set) var book: LiveFolderBook?
    private weak var store: SpacesStore?
    private var storeToken: Int?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// The request each folder's answer must match: an answer from before a cancel or a newer request is dropped.
    private var tickets: [String: UUID] = [:]
    /// Folders with a request out.
    private(set) var refreshing: Set<String> = []
    let accounts = GitHubAccounts.shared

    /// Where GitHub is. A scripted check points it at its local fake (ParityP12Check); never changed otherwise.
    var endpoint = GitHubEndpoint.github
    var http: any LiveHTTPClient = URLSessionLiveHTTP()
    var client: GitHubClient { GitHubClient(http: http, endpoint: endpoint) }

    private init() {
        #if AIRC_TESTING
        // Scripted runs never reach GitHub: a check points `http` at its loopback fake before any refresh it counts.
        if LaunchOptions.current.isAutomated { http = RefusingLiveHTTP() }
        #endif
    }

    // MARK: Setup

    /// Starts with the app's store. A private window's store gets none: its folders never go live. Safe to call often.
    @discardableResult
    func attach(_ store: SpacesStore) -> LiveFolderBook? {
        if let book, book.store === store { return book }
        if let main = (NSApp.delegate as? AppDelegate)?.store, main !== store { return nil }
        detach()
        let b = LiveFolderBook(store: store)
        b.prune()   // folders deleted in an earlier session (their ⌘Z is gone)
        book = b
        self.store = store
        storeToken = store.observe { [weak self] change in
            guard change.touches(.item) else { return }
            self?.storeChanged()
        }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refreshDue(.timer) }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.refreshDue(.focus) }
        DispatchQueue.main.async { [weak self] in self?.refreshDue(.focus) }
        return b
    }

    /// Stops everything (tests and a store swap).
    func detach() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        tickets = [:]
        refreshing = []
        timer?.invalidate()
        timer = nil
        if let storeToken { store?.removeObserver(storeToken) }
        storeToken = nil
        activeObserver.map(NotificationCenter.default.removeObserver)
        activeObserver = nil
        book = nil
        store = nil
    }


    /// A folder that went (deleted, its Space deleted) cancels its request.
    private func storeChanged() {
        guard let book else { return }
        for id in Array(tasks.keys) where !book.isLive(id) {
            cancel(id)
            post(id)
        }
    }

    // MARK: State

    struct Display: Equatable {
        var isRefreshing: Bool
        var status: LiveFolderStatus
        var lastRefreshed: Date?
        var query: GitHubPullQuery
        var account: String?
    }

    func display(_ folderID: String) -> Display? {
        guard let book, let d = book.definition(folderID) else { return nil }
        let account = book.profileID(ofFolder: folderID).flatMap { accounts.login(forProfile: $0) }
        return Display(isRefreshing: refreshing.contains(folderID), status: d.status, lastRefreshed: d.lastRefreshed,
                       query: d.query, account: account)
    }

    func isLive(_ folderID: String) -> Bool { book?.isLive(folderID) ?? false }

    private func post(_ folderID: String?) {
        NotificationCenter.default.post(name: Self.didChange, object: folderID)
    }

    // MARK: Refresh

    func refreshDue(_ trigger: LiveFolderSchedule.Trigger) {
        guard let book else { return }
        let now = book.now()
        for id in book.activeFolderIDs {
            guard let d = book.definition(id), LiveFolderSchedule.isDue(d, trigger: trigger, now: now) else { continue }
            refresh(id, trigger: trigger)
        }
    }

    /// Refreshes one folder unless a request for it is already out (Refresh in its menu, a sign-in, the timer).
    func refresh(_ folderID: String, trigger: LiveFolderSchedule.Trigger = .manual) {
        guard let book, let d = book.definition(folderID), tasks[folderID] == nil else { return }
        if trigger == .manual, !LiveFolderSchedule.isDue(d, trigger: .manual, now: book.now()) {
            post(folderID)   // rate limited: the row and menu say until when
            return
        }
        let token = book.profileID(ofFolder: folderID).flatMap { accounts.token(forProfile: $0) }
        let client = client
        book.noteAttempt(folderID)
        refreshing.insert(folderID)
        post(folderID)
        let ticket = UUID()
        tickets[folderID] = ticket
        tasks[folderID] = Task { [weak self] in
            let result = await client.fetch(d.query, token: token, pages: d.pages)
            await MainActor.run { self?.finish(folderID, ticket, result) }
        }
    }

    private func finish(_ folderID: String, _ ticket: UUID, _ result: LiveFetchResult) {
        guard tickets[folderID] == ticket else { return }   // cancelled, or a newer request is out
        tickets[folderID] = nil
        tasks[folderID] = nil
        refreshing.remove(folderID)
        guard let book else { return }
        // A folder deleted meanwhile, or one that stopped updating: `apply` drops the answer.
        let out = book.apply(result, to: folderID, protected: protectedTabs())
        for tab in out.retiredTabIDs {
            for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { c.dropPage(tab) }
        }
        post(folderID)
        #if AIRC_TESTING
        lastOutcome[folderID] = out
        #endif
    }

    /// Pages on screen in any window: their rows don't retire under the person (they go at a later refresh).
    private func protectedTabs() -> Set<String> {
        var ids = Set<String>()
        for c in (NSApp.delegate as? AppDelegate)?.controllers ?? [] { ids.formUnion(c.visibleTabIDs) }
        return ids
    }

    private func cancel(_ folderID: String) {
        tasks[folderID]?.cancel()
        tasks[folderID] = nil
        tickets[folderID] = nil
        refreshing.remove(folderID)
    }

    // MARK: Actions

    @discardableResult
    func create(query: GitHubPullQuery, title: String?, inSpace spaceID: String, store: SpacesStore) -> Item? {
        guard let book = attach(store), let folder = try? book.create(query: query, title: title, inSpace: spaceID) else { return nil }
        post(folder.id)
        refresh(folder.id)
        return folder
    }

    func setQuery(_ query: GitHubPullQuery, ofFolder folderID: String) {
        cancel(folderID)
        book?.setQuery(query, ofFolder: folderID)
        post(folderID)
        refresh(folderID)
    }

    func stopUpdating(_ folderID: String) {
        cancel(folderID)
        try? book?.stopUpdating(folderID)
        post(folderID)
    }

    func keep(_ itemID: String) {
        try? book?.keep(itemID)
        post(store?.item(itemID)?.parentID)
    }

    /// After a sign-in or sign-out: the profile's folders refresh (or show that they need a sign-in).
    func accountChanged(profileID: String) {
        guard let book else { return }
        for id in book.activeFolderIDs where book.profileID(ofFolder: id) == profileID { refresh(id) }
        post(nil)
    }

    #if AIRC_TESTING
    /// The last refresh's outcome per folder (ParityP12Check).
    var lastOutcome: [String: LiveApplyOutcome] = [:]
    var inFlight: Set<String> { Set(tasks.keys) }
    #endif
}

#if AIRC_TESTING
/// A scripted run's GitHub until its check sets one: every request fails as if offline.
struct RefusingLiveHTTP: LiveHTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
#endif
