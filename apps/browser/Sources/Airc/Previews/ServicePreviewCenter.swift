// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// Where a service card's content comes from (S04, PreviewService). A provider serves one or more services; the
/// center asks it for an account's state and keeps the answer in memory (PreviewCache).
///
/// - Notion, Confluence, Figma and Linear: the pages recently visited there, from the profile's own history
///   (HistoryRecentsProvider), as Arc listed them. Nothing is fetched; private windows keep no history.
/// - Mail and calendars need an account (Arc signed in to each). Airc has no real provider yet (packages P11b/c, with
///   the owner): their pinned tabs and Favorites keep the page-picture card. Scripted runs register a fake provider
///   on loopback fixtures (Debug/ParityP11aCheck.swift) to exercise every state.
protocol ServicePreviewProvider: AnyObject {
    var services: Set<PreviewService> { get }
    /// Whether answering means asking the network (an account). The center never asks such a provider about an
    /// account whose site wasn't opened in its profile.
    var fetchesRemotely: Bool { get }
    /// The account's state now; `completion` on the main queue.
    func fetch(_ account: PreviewAccount, completion: @escaping (PreviewState) -> Void)
    /// The card's sign-in button (signed out, or signed out by the service); `completion` on the main queue.
    func signIn(_ account: PreviewAccount, completion: @escaping () -> Void)
    /// "Remove" on a card whose sign-in ran out: the account is forgotten.
    func remove(_ account: PreviewAccount)
}

final class ServicePreviewCenter {
    static let shared = ServicePreviewCenter()
    /// Posted (main queue) when an account's state changed; `object` is the PreviewAccount.
    static let changed = Notification.Name("AircServicePreviewChanged")
    /// A card being shown asks again when what it has is older than this (Arc had a minimum fetch interval). Nothing
    /// polls: only a card on screen, or Live Calendar for its Favorite's account, asks.
    static let refreshAfter: TimeInterval = 60

    private var providers: [PreviewService: ServicePreviewProvider] = [:]
    private let history = HistoryRecentsProvider()
    private(set) var cache = PreviewCache()
    private var inFlight: Set<PreviewAccount> = []
    /// Bumped when a profile is forgotten: answers still on their way for it are dropped.
    private var generation: [String: Int] = [:]
    /// Bumped when a provider comes or goes: answers asked of the one before are dropped.
    private var registration = 0
    /// Accounts whose site the profile has opened (from its history), once found.
    private var opened: Set<PreviewAccount> = []
    /// Accounts found not opened, and until when that answer stands (history isn't read again on every row's render).
    private var notOpened: [PreviewAccount: Date] = [:]
    /// The one wake-up for a calendar row's line ("Event in 9m") changing.
    private var statusTick: Timer?
    var now: () -> Date = Date.init

    #if AIRC_TESTING
    struct Stats {
        /// Every account asked of a provider that fetches, in order.
        var remoteFetches: [PreviewAccount] = []
        /// Accounts a card asked about that were never opened in their profile (and so weren't fetched).
        var refusedUnopened: [PreviewAccount] = []
        var opened: [(URL, String)] = []
    }
    var stats = Stats()
    /// Scripted runs: what a card's row or "+" would open in a pinned tab or Favorite, instead of loading it.
    var openedForTesting: ((URL, String) -> Void)?
    /// Scripted runs: what Peek Email would open in Peek (a sign-in link, the inbox), instead of loading it.
    var peekForTesting: ((URL) -> Void)?
    /// The accounts known to be opened (the checks: a forgotten profile's are gone).
    var openedAccountsForTesting: Set<PreviewAccount> { opened }
    #endif

    private init() {
        for s in history.services { providers[s] = history }
    }

    func register(_ p: ServicePreviewProvider) {
        registration += 1
        inFlight = inFlight.filter { !p.services.contains($0.service) }
        for s in p.services { providers[s] = p }
        for a in cache.accounts where p.services.contains(a.service) { cache.forget(a) }
        if p.services.contains(where: { $0.family == .calendar }) { CalendarCenter.shared.accounts = PreviewCalendarAccounts.shared }
    }

    /// Back to Airc's own providers for `services` (the recents from history; nothing for mail and calendars).
    func unregister(_ services: Set<PreviewService>) {
        registration += 1
        inFlight = inFlight.filter { !services.contains($0.service) }
        for s in services { providers[s] = history.services.contains(s) ? (history as ServicePreviewProvider) : nil }
        for a in cache.accounts where services.contains(a.service) { cache.forget(a) }
        opened = opened.filter { !services.contains($0.service) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func provider(for s: PreviewService) -> ServicePreviewProvider? { providers[s] }

    /// The card for a pinned tab or Favorite showing `url` in `profileID`: its account, when the service has a
    /// provider. An account provider's card needs the site to have been opened in the profile; until then the row
    /// keeps the page-picture card (a hover never tells a service about a page you haven't opened).
    func account(for url: String, profileID: String) -> PreviewAccount? {
        guard let a = PreviewAccount(url: url, profileID: profileID), let p = providers[a.service] else { return nil }
        if p.fetchesRemotely, !hasOpened(a) {
            #if AIRC_TESTING
            stats.refusedUnopened.append(a)
            #endif
            return nil
        }
        return a
    }

    func state(_ a: PreviewAccount) -> PreviewState? { cache.entry(a)?.state }

    /// Whether the profile has opened `a`'s site (its history has a page of that service under that account). Private
    /// windows keep no history, so they never open one.
    func hasOpened(_ a: PreviewAccount) -> Bool {
        if opened.contains(a) { return true }
        if let until = notOpened[a], Date() < until { return false }
        guard let h = (NSApp.delegate as? AppDelegate)?.history else { return false }
        let found = h.entries(ofProfile: a.profileID).contains {
            PreviewService.detect($0.url) == a.service && PreviewService.accountKey($0.url) == a.key
        }
        if found { opened.insert(a); notOpened[a] = nil } else { notOpened[a] = Date().addingTimeInterval(30) }
        return found
    }

    // MARK: The line under a pinned row

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// What a pinned mail or calendar row says under its title (Arc: "1 Recent", "Event in 9m"), from its account's
    /// card (PreviewStatus); nil for anything else. Seeing the row asks the account again when its answer is a minute
    /// old, never for a site the profile hasn't opened.
    func statusLine(for entry: SidebarEntry, in c: WindowController?) -> String? {
        guard let c, case .pinned = entry, let item = entry.item, item.kind == .tab else { return nil }
        let url = TabPreviewController.url(of: entry, in: c)
        guard let s = PreviewService.detect(url), s.family != .recents, providers[s] != nil,
              let a = account(for: url, profileID: TabPreviewController.profileID(of: entry, in: c)) else { return nil }
        // After the row's configure, never inside it (an answer refreshes the rows).
        DispatchQueue.main.async { self.refresh(a) }
        switch state(a)?.content {
        case .mail(let m)?: return PreviewStatus.mail(m.count)
        case .calendar(let events)?:
            scheduleStatusTick(PreviewStatus.nextChange(events, now: now()))
            return PreviewStatus.calendar(events, now: now(), time: Self.timeFormat.string(from:))
        default: return nil
        }
    }

    /// One one-shot wake-up at the next change of a calendar row's line; the rows read it again then.
    private func scheduleStatusTick(_ at: Date?) {
        guard let at else { return }
        if let t = statusTick, t.isValid, t.fireDate <= at { return }
        statusTick?.invalidate()
        let t = Timer(fire: Date().addingTimeInterval(max(0.05, at.timeIntervalSince(now()) + 0.05)), interval: 0, repeats: false) { [weak self] _ in
            self?.statusTick = nil
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        statusTick = t
    }

    /// A card for `a` is up (or Live Calendar wants its meetings): the cache answers at once, and the provider is asked
    /// again if the answer is older than `refreshAfter` (or `force`). Never for an account that wasn't opened.
    func refresh(_ a: PreviewAccount, force: Bool = false) {
        guard let p = providers[a.service] else { return }
        if p.fetchesRemotely, !hasOpened(a) { return }
        // The profile's history is read each time (it's in memory); an account at most once a minute.
        let interval = p.fetchesRemotely ? Self.refreshAfter : 0
        guard force || cache.isStale(a, now: now(), interval: interval), !inFlight.contains(a) else { return }
        inFlight.insert(a)
        if cache.entry(a) == nil {
            cache.store(.loading, for: a, at: now())
            notify(a)
        }
        #if AIRC_TESTING
        if p.fetchesRemotely { stats.remoteFetches.append(a) }
        #endif
        let gen = generation[a.profileID, default: 0], reg = registration
        p.fetch(a) { [weak self] state in
            guard let self else { return }
            self.inFlight.remove(a)
            guard self.registration == reg, self.generation[a.profileID, default: 0] == gen, self.providers[a.service] === p else { return }
            self.cache.store(state, for: a, at: self.now())
            self.notify(a)
        }
    }

    /// An answer for `a` that came outside `refresh` (Peek Email asks at once).
    func storeAnswer(_ state: PreviewState, for a: PreviewAccount) {
        cache.store(state, for: a, at: now())
        notify(a)
    }

    func signIn(_ a: PreviewAccount) {
        guard let p = providers[a.service] else { return }
        cache.store(.loading, for: a, at: .distantPast)
        notify(a)
        p.signIn(a) { [weak self] in self?.refresh(a, force: true) }
    }

    func remove(_ a: PreviewAccount) {
        providers[a.service]?.remove(a)
        cache.store(.signedOut, for: a, at: now())
        notify(a)
    }

    /// A profile deleted, or its browsing data cleared: its cards' content, what's known of its accounts, and its tab
    /// pictures (TabPreviewCache) go. Answers still on their way for it are dropped.
    func forget(profileID: String) {
        generation[profileID, default: 0] += 1
        cache.forget(profileID: profileID)
        opened = opened.filter { $0.profileID != profileID }
        notOpened = notOpened.filter { $0.key.profileID != profileID }
        inFlight = inFlight.filter { $0.profileID != profileID }
        TabPreviewCache.shared.forget(profileID: profileID)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func notify(_ a: PreviewAccount) {
        NotificationCenter.default.post(name: Self.changed, object: a)
    }

    // MARK: Opening

    /// A row or "+" of a card: `url` in the pinned tab or Favorite `itemID` (its own site), in `spaceID`. The item goes
    /// back to its own page later, as pinned tabs and Favorites do.
    func open(_ url: URL, inItem itemID: String, spaceID: String?, controller c: WindowController) {
        c.tabPreview.hide()
        #if AIRC_TESTING
        stats.opened.append((url, itemID))
        if let hook = openedForTesting { return hook(url, itemID) }
        #endif
        let space = spaceID.flatMap { c.store.space($0) }?.id ?? c.currentSpaceID
        if space != c.currentSpaceID { c.switchToSpace(space, animated: false) }
        guard let t = try? c.store.openItem(itemID, inSpace: space) else { return }
        c.show(t.id)
        if let page = c.engineTab(for: t.id) { c.engineWindow.load(url, in: page) }
    }

    /// A recent page (Arc: "open it as a new tab"), or a documents service's "+": a new Today tab in `spaceID`.
    func openNewTab(_ url: URL, spaceID: String?, controller c: WindowController) {
        c.tabPreview.hide()
        #if AIRC_TESTING
        stats.opened.append((url, ""))
        if let hook = openedForTesting { return hook(url, "") }
        #endif
        c.openExternal(url, inSpace: spaceID.flatMap { c.store.space($0) }?.id ?? c.currentSpaceID)
    }
}

/// Notion, Confluence, Figma and Linear (Arc: "view and open recently visited … pages"): the profile's own history of
/// the site, newest first. Local: nothing is fetched, and a private window's pages are never in it.
final class HistoryRecentsProvider: ServicePreviewProvider {
    static let limit = 20
    let services: Set<PreviewService> = [.notion, .confluence, .figma, .linear]
    var fetchesRemotely: Bool { false }

    func fetch(_ a: PreviewAccount, completion: @escaping (PreviewState) -> Void) {
        guard let h = (NSApp.delegate as? AppDelegate)?.history else { return completion(.failed(stale: nil)) }
        let pages = h.entries(ofProfile: a.profileID)
            .filter { PreviewService.detect($0.url) == a.service && (a.service != .confluence || PreviewService.accountKey($0.url) == a.key) }
            .sorted { $0.lastVisit > $1.lastVisit }
            .prefix(Self.limit)
            .map { PreviewPage(url: $0.url, title: $0.title.isEmpty ? URLRules.displayHost($0.url) : $0.title, date: $0.lastVisit) }
        completion(.ready(.recents(Array(pages))))
    }

    func signIn(_ a: PreviewAccount, completion: @escaping () -> Void) { completion() }
    func remove(_ a: PreviewAccount) {}
}

/// The calendar card's gear menu (the card hides while a menu is open, so the menu's target can't be the card).
final class ServicePreviewMenuTarget: NSObject {
    static let shared = ServicePreviewMenuTarget()

    @objc func signOut(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? PreviewAccount else { return }
        ServicePreviewCenter.shared.remove(a)
    }
}
