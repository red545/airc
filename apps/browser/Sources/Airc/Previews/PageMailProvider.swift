// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import OSLog
import WebKit

/// S04: Gmail's and Outlook's cards, from the account's own page, as Arc did it. A loaded page of the account (its
/// pinned tab or Favorite, or any tab of it in a normal window of the same profile) is asked for its unread mail with
/// a read-only script (AircKit's PageMail): Gmail's own Atom feed, same origin with the page's own cookies, or the
/// inbox list in the page; Outlook's message list. No account of Airc's, no sign-in, no request to anywhere else.
///
/// - Private windows are never read (their pages aren't the windows' pages here), and their pages are never history,
///   so a private window never opens an account (ServicePreviewCenter.hasOpened).
/// - Answers are cached by the center (one minute); while such a page is loaded, a light timer asks again when the
///   answer is stale, so the card and the row's "3 Recent" are ready before a hover. Nothing is read with no page.
/// - A site whose previews are off in Settings is never read (ServicePreviewCenter.isEnabled).
///
/// calprev: Google Calendar's and Outlook's calendar cards come the same way, from the calendar page's own markup
/// (AircKit's PageCalendar): no request at all, only what the page shows. The days the page doesn't show keep what
/// was last read of them. A pinned calendar whose page went to its sign-in page is signed out.
final class PageMailProvider: ServicePreviewProvider {
    let services: Set<PreviewService> = [.gmail, .outlookMail, .googleCalendar, .outlookCalendar]
    /// The account's site must have been opened in its profile before its card asks anything.
    var fetchesRemotely: Bool { true }
    /// How often loaded pages are looked at (an account is read only when its answer is stale).
    static var tick: TimeInterval = 15
    private var timer: Timer?
    weak var center: ServicePreviewCenter?

    /// Reads on their way: each one's page, so it can be stopped there.
    private struct Read { let account: PreviewAccount; weak var page: EngineTab? }
    private var reads: [Int: Read] = [:]
    private var nextToken = 1

    #if AIRC_TESTING
    /// Each read: the account, the address of the page it was read from, and when it started.
    var readsForTesting: [(PreviewAccount, String, Date)] = []
    /// Reads stopped by a site's previews going off, and their answers that came anyway (dropped).
    var cancelledForTesting = 0
    var droppedForTesting = 0
    #endif

    init() {}

    /// The page to read `a` from: a loaded page of the account in a normal window of its profile (the shown one
    /// first, then one that has finished loading).
    func page(for a: PreviewAccount) -> EngineTab? {
        guard let app = NSApp.delegate as? AppDelegate else { return nil }
        var best: (EngineTab, Int)?
        for c in app.controllers {
            for (tabID, page) in c.pages where !page.isClosed {
                guard let u = page.url?.absoluteString, c.store.tab(tabID)?.profileID == a.profileID,
                      PreviewAccount(url: u, profileID: a.profileID) == a else { continue }
                let score = (page.isLoading ? 0 : 2) + (c.shownTabID == tabID ? 1 : 0)
                if best.map({ score > $0.1 }) ?? true { best = (page, score) }
            }
        }
        return best?.0
    }

    private static let log = Logger(subsystem: "org.airc.Airc", category: "SitePreviews")
    /// The last diagnostic line per account (each is logged once, when it changes).
    private var lastNote: [PreviewAccount: String] = [:]

    /// pageread (owner, 2026-11-15): why `a` has no page to read, or why a read gave nothing. Privacy: the service,
    /// the account's key ("u/0") and, per loaded page of that service, whether its profile and account match and
    /// whether it's closed, loading or shown; never an address, a title or any mail or event. `log show --predicate
    /// 'subsystem == "org.airc.Airc" AND category == "SitePreviews"'` on the Mac shows them.
    private func diagnose(_ a: PreviewAccount, _ what: String) {
        var pages: [String] = []
        if let app = NSApp.delegate as? AppDelegate {
            for c in app.controllers {
                for (tabID, page) in c.pages {
                    guard let u = page.url?.absoluteString, PreviewService.detect(u) == a.service else { continue }
                    let tab = c.store.tab(tabID)
                    pages.append("key \(PreviewService.accountKey(u))\(tab == nil ? " no-tab" : tab?.profileID == a.profileID ? "" : " other-profile")"
                                 + "\(page.isClosed ? " closed" : "")\(page.isLoading ? " loading" : "")\(c.shownTabID == tabID ? " shown" : "")")
                }
            }
        }
        let line = "\(a.service.rawValue) \(a.key): \(what); \(pages.count) page(s) of the service [\(pages.joined(separator: ", "))]"
        guard lastNote[a] != line else { return }
        lastNote[a] = line
        Self.log.notice("\(line, privacy: .public)")
    }

    /// The read-only script for `a`'s service: mail (PageMail) or a calendar (PageCalendar).
    static func script(for s: PreviewService, token: Int = 0) -> String? {
        PageMail.script(for: s, token: token) ?? PageCalendar.script(for: s, token: token)
    }

    /// A tab of an item of `a` (its pinned tab or Favorite) in a normal window of its profile that is on its service's
    /// sign-in page now: the account is signed out there.
    func signInPage(for a: PreviewAccount) -> Bool {
        guard let app = NSApp.delegate as? AppDelegate else { return false }
        for c in app.controllers {
            for (tabID, page) in c.pages where !page.isClosed && !page.isLoading {
                guard let u = page.url?.absoluteString, PreviewService.isSignInPage(u), let tab = c.store.tab(tabID),
                      tab.profileID == a.profileID, let saved = tab.itemID.flatMap({ c.store.item($0)?.savedURL }),
                      PreviewAccount(url: saved, profileID: a.profileID) == a else { continue }
                return true
            }
        }
        return false
    }

    func fetch(_ a: PreviewAccount, completion: @escaping (PreviewState) -> Void) {
        let previous = center?.state(a)?.content
        guard Self.script(for: a.service) != nil, let page = page(for: a) else {
            if signInPage(for: a) { return completion(.signedOut) }
            diagnose(a, "no page to read")
            // No page to read: what the card had stays; with nothing, it says to open the site.
            return completion(previous.map { .ready($0) } ?? .needsPage)
        }
        let token = nextToken
        nextToken += 1
        guard let script = Self.script(for: a.service, token: token) else { return completion(.failed(stale: nil)) }
        reads[token] = Read(account: a, page: page)
        #if AIRC_TESTING
        readsForTesting.append((a, page.url?.absoluteString ?? "", Date()))
        #endif
        Self.run(script, in: page) { [weak self] answer in
            guard let self else { return }
            // A read stopped by its site going off: whatever came back is dropped, never stored, shown or counted.
            guard self.reads.removeValue(forKey: token) != nil, !PageMail.wasCancelled(answer) else {
                #if AIRC_TESTING
                self.droppedForTesting += 1
                #endif
                return
            }
            let now = self.center?.now() ?? Date()
            let state: PreviewState?
            if a.service.family == .calendar {
                // The calendar page on another view (an event's page, settings): nothing to read, the card keeps its events.
                var before: [CalendarEvent]?
                if case .calendar(let e)? = previous { before = e }
                state = answer.flatMap { PageCalendar.state(from: $0, service: a.service, now: now, previous: before) }
                    ?? previous.map { .ready($0) } ?? .needsPage
            } else {
                state = answer.flatMap { PageMail.state(from: $0, service: a.service, now: now) }
            }
            if state == nil || state == .needsPage {
                self.diagnose(a, answer == nil ? "the read gave no answer" : "the page's answer had nothing to read (\(answer?.count ?? 0) chars)")
            }
            completion(state ?? .failed(stale: nil))
        }
    }

    /// Runs `expression` (a promise of a string) in `page`: on WebKit in Airc's own script world (the page's scripts
    /// can't see it; same origin and cookies), on Chromium through the engine's evaluate (which awaits it).
    static func run(_ expression: String, in page: EngineTab, _ done: @escaping (String?) -> Void) {
        if let w = (page as? WebKitTab)?.webView {
            w.callAsyncJavaScript("return await " + expression, arguments: [:], in: nil, in: .defaultClient) { r in
                DispatchQueue.main.async { done(try? r.get() as? String) }
            }
            return
        }
        page.evaluate(expression) { r in DispatchQueue.main.async { done(r as? String) } }
    }

    /// A site's previews went off: its reads on their way are stopped in their pages (the feed request aborted, a read
    /// not yet begun never begins) and forgotten, so their answers are dropped when they come.
    func cancel(_ service: PreviewService) {
        for (token, r) in reads where r.account.service == service {
            reads[token] = nil
            #if AIRC_TESTING
            cancelledForTesting += 1
            #endif
            guard let page = r.page, !page.isClosed else { continue }
            Self.run(PageMail.cancelScript(token: token), in: page) { _ in }
        }
    }

    /// The card's button (Sign In, or Open with no page): the item's own page, by the card (TabPreview opens it).
    func signIn(_ a: PreviewAccount, completion: @escaping () -> Void) { completion() }
    func remove(_ a: PreviewAccount) {}

    // MARK: Refresh while loaded

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.look() }
        t.tolerance = Self.tick / 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Each account with a loaded page that the profile has opened and whose previews are on: asked again when its
    /// answer is stale, or at once when the card was waiting for a page.
    func look() {
        guard let center, let app = NSApp.delegate as? AppDelegate else { return }
        var seen: Set<PreviewAccount> = []
        for c in app.controllers {
            for (tabID, page) in c.pages where !page.isClosed && !page.isLoading {
                guard let u = page.url?.absoluteString, let profile = c.store.tab(tabID)?.profileID,
                      let a = PreviewAccount(url: u, profileID: profile), services.contains(a.service),
                      !seen.contains(a), center.provider(for: a.service) === self else { continue }
                center.recheckOpened(a)
                guard center.account(for: u, profileID: profile) != nil else { continue }
                seen.insert(a)
                let waiting = center.state(a) == .needsPage
                center.refresh(a, force: waiting)
            }
        }
    }
}
