// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The S04 fixtures: a loopback server whose 127.0.0.1 pages mimic Gmail (the inbox list's markup, its Atom feed at
/// /mail/u/N/feed/atom, a strict CSP with Trusted Types) and whose localhost pages mimic Outlook's message list. No
/// real account or service. Every request is logged with the page session it came from (a cookie the inbox sets).
final class S04MailFixtures: @unchecked Sendable {
    struct Message {
        var id: String
        var sender: String
        var address: String
        var subject: String
        var snippet: String
        var minutesAgo: Double
        var unread = true
    }

    private let lock = NSLock()
    private var gmail: [Message] = []
    private var outlook: [Message] = []
    /// "ok", "401" (signed out), "404" (no feed: the page's list is read).
    private var feedMode = "ok"
    /// Seconds the feed's answer is held (a read on its way).
    private var feedDelay: TimeInterval = 0
    private var sessions = 0
    private(set) var log: [(path: String, host: String, session: String)] = []
    var port: UInt16 = 0

    func set(gmail: [Message]? = nil, outlook: [Message]? = nil, feed: String? = nil, feedDelay: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let gmail { self.gmail = gmail }
        if let outlook { self.outlook = outlook }
        if let feed { feedMode = feed }
        if let feedDelay { self.feedDelay = feedDelay }
    }

    var requests: [(path: String, host: String, session: String)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func feedReads(session: String? = nil) -> Int {
        requests.filter { $0.path.contains("/feed/atom") && (session == nil || $0.session == session) }.count
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func iso(_ m: Message, _ now: Date) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-m.minutesAgo * 60))
    }

    func answer(_ r: LocalPageServer.Request) -> LocalPageServer.Page? {
        lock.lock(); defer { lock.unlock() }
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        let session = (r.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("sid=") }.map { String($0.dropFirst(4)) } ?? "-"
        log.append((r.path, host, session))
        let now = Date()
        // Gmail's CSP: script nonces and Trusted Types (Chromium's evaluate falls back to DevTools there, as on Gmail).
        let csp = ["Content-Security-Policy": "script-src 'nonce-s04'; require-trusted-types-for 'script'"]
        func newSession() -> [String: String] {
            sessions += 1
            // A page load without a session gets one: the log says which, so later requests can be told apart.
            if session == "-" { log[log.count - 1].session = "new:s\(sessions)" }
            return ["Set-Cookie": "sid=s\(sessions); Path=/; SameSite=Lax"]
        }
        let parts = r.path.split(separator: "/").map(String.init)
        if host == "127.0.0.1", parts.count == 5, parts[0] == "mail", parts[1] == "u", parts[3] == "feed", parts[4] == "atom" {
            switch feedMode {
            case "401": return .init(status: "401 Unauthorized", body: "<HTML><TITLE>Unauthorized</TITLE></HTML>")
            case "404": return .init(status: "404 Not Found", body: "not found")
            default: break
            }
            let n = parts[2]
            let unread = n == "0" ? gmail.filter(\.unread) : []
            // Not in date order: the card orders them.
            let entries = unread.reversed().map { g in """
                <entry><title>\(Self.esc(g.subject))</title><summary>\(Self.esc(g.snippet))</summary>
                <link rel="alternate" href="http://127.0.0.1:\(port)/mail/u/\(n)/#inbox/\(g.id)" type="text/html" />
                <modified>\(Self.iso(g, now))</modified><issued>\(Self.iso(g, now))</issued><id>tag:gmail.google.com,2004:\(g.id)</id>
                <author><name>\(Self.esc(g.sender))</name><email>\(g.address)</email></author></entry>
                """ }.joined(separator: "\n")
            let xml = """
                <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
                <title>Gmail - Inbox for fixture@example.com</title><fullcount>\(unread.count)</fullcount>
                \(entries)</feed>
                """
            return .init(headers: ["Content-Type": "application/atom+xml; charset=UTF-8"], body: xml, delay: feedDelay)
        }
        if host == "127.0.0.1", r.path.hasPrefix("/mail/u/") {
            let rows = gmail.map { g in """
                <tr class="zA \(g.unread ? "zE" : "yO")"><td><span class="yP" email="\(g.address)" name="\(Self.esc(g.sender))">\(Self.esc(g.sender))</span></td>
                <td><span class="bog"><span data-legacy-thread-id="\(g.id)">\(Self.esc(g.subject))</span></span><span class="y2"> - \(Self.esc(g.snippet))</span></td>
                <td class="xW"><span title="\(Self.iso(g, now))">\(Int(g.minutesAgo))m</span></td></tr>
                """ }.joined(separator: "\n")
            let byID = Dictionary(gmail.map { ($0.id, $0.subject) }, uniquingKeysWith: { a, _ in a })
            let json = (try? String(data: JSONSerialization.data(withJSONObject: byID), encoding: .utf8)) ?? "{}"
            let body = """
                <!doctype html><title>Inbox (\(gmail.filter(\.unread).count)) - fixture@example.com - Gmail</title>
                <table><tbody>\(rows)</tbody></table><h1 id=msg></h1>
                <script nonce="s04">var s=\(json);function show(){var m=location.hash.match(/#inbox\\/(.+)$/);
                if(m&&s[m[1]]){document.title=s[m[1]];document.getElementById('msg').textContent=s[m[1]]}}
                addEventListener('hashchange',show);show();</script>
                """
            return .init(headers: csp.merging(newSession()) { a, _ in a }, body: body)
        }
        if host == "localhost", r.path.hasPrefix("/mail/0/inbox/id/") {
            let raw = String(r.path.dropFirst("/mail/0/inbox/id/".count))
            let id = raw.removingPercentEncoding ?? raw
            let s = outlook.first { $0.id == id }?.subject ?? "Unknown message"
            return .init(body: "<!doctype html><title>\(Self.esc(s))</title><h1>\(Self.esc(s))</h1>")
        }
        if host == "localhost", r.path.hasPrefix("/mail/0/") {
            let rows = outlook.map { o in """
                <div role="option" data-convid="\(o.id)" aria-label="\(o.unread ? "Unread " : "")\(Self.esc(o.sender)) \(Self.esc(o.subject))">
                <div><span title="\(o.address)">\(Self.esc(o.sender))</span><time datetime="\(Self.iso(o, now))">\(Int(o.minutesAgo))m</time></div>
                <div><span>\(Self.esc(o.subject))</span></div><div><span>\(Self.esc(o.snippet))</span></div>
                <button title="\(o.unread ? "Mark as read" : "Mark as unread")"><span>•</span></button></div>
                """ }.joined(separator: "\n")
            return .init(headers: newSession(), body: "<!doctype html><title>Mail - Fixture - Outlook</title><div role=listbox>\(rows)</div>")
        }
        if r.path == "/plain.html" { return .init(body: "<!doctype html><title>Plain</title><h1>Plain</h1>") }
        return nil
    }
}

/// `--script s04` (both engines): S04, Gmail's and Outlook's previews read from the account's own page, on loopback
/// fixtures only (S04MailFixtures; PreviewService.loopbackFixtures makes 127.0.0.1 "Gmail" and localhost "Outlook").
///   - before the page is loaded, the card says to open it; its Open button loads the item and the card fills;
///   - the card lists the unread mail (sender, subject, snippet), newest first, from Gmail's Atom feed in the page's
///     own session (its cookie), through the page's strict CSP; the row's line counts it ("3 Recent");
///   - a new message shows on the row without a hover (refreshed while the page is loaded);
///   - a click on a message opens it in Peek, the right message (its title), in the account's profile;
///   - no feed: the inbox list in the page is read (unread rows only); signed out (401): the signed-out card;
///   - Outlook: the unread rows of its message list, newest first; a message opens in Peek;
///   - a second account (/u/1/) never opened is never read; Settings → Site Previews off: no card, no line, no reads;
///   - a private window's page of the account is never read, and a private visit never opens an account.
/// With AIRC_REAL_KEYS=1 in a dedicated session, hovers are real pointer moves and card clicks real clicks from the
/// stable UI driver; otherwise posted events. The log says which.
extension SnapshotRunner {
    func parityS04Scenario() {
        let tp = { self.c.tabPreview }
        let center = ServicePreviewCenter.shared
        let fx = S04MailFixtures()
        var server: LocalPageServer?
        var home = "", profile = "", gmailItem = "", gmail2Item = "", outlookItem = ""
        var gmailURL = "", gmail2URL = "", outlookURL = ""
        var lastHovered: NSView?
        var realClicks = 0, postedClicks = 0, realHovers = 0, postedHovers = 0
        let page = { self.c.pageView(for: self.c.currentSpaceID) }
        let t: (String, String, String, String, String, Double) -> S04MailFixtures.Message = {
            .init(id: $0, sender: $1, address: $2, subject: $3, snippet: $4, minutesAgo: $5)
        }
        let ada = t("18c1a", "Ada Lovelace", "ada@example.com", "Notes on the engine", "I've gone through the diagrams.", 12)
        let grace = t("18c1b", "Grace Hopper", "grace@example.com", "Compiler review", "Friday works for me.", 60 * 5)
        let weekly = t("18c1c", "Example Weekly", "news@example.org", "This week in browsers", "Tabs, spaces and more.", 60 * 30)
        var oldRead = t("18c1d", "Read Already", "read@example.com", "Already read", "Not unread.", 3)
        oldRead.unread = false

        func row(_ itemID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.entry?.item?.id == itemID }
        }
        func rowLines(_ r: TabRowView?) -> [String] {
            MainActor.assumeIsolated {
                r?.subviews.compactMap { v -> String? in
                    guard let l = v as? AircFadingLabel, !l.isHidden, !l.stringValue.isEmpty else { return nil }
                    return l.stringValue
                } ?? []
            }
        }
        func centre(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        func movePointer(over target: NSView?) {
            let p = target.map(centre) ?? centre(c.card)
            if lastHovered !== target {
                func ev(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
                }
                if let prev = lastHovered, let e = ev(.mouseExited) { prev.mouseExited(with: e) }
                if let target, let e = ev(.mouseEntered) { target.mouseEntered(with: e) }
            }
            lastHovered = target
        }
        /// The pointer comes to `v` from the page: a real HID move from the stable UI driver when allowed (the row's own
        /// tracking area sees it), else posted enter and exit events. The log counts each.
        func realPointer() -> Bool {
            UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                && NSApp.isActive && c.window.isKeyWindow
        }
        func hoverFresh(_ v: @escaping () -> NSView?, settle: Double = 0.9) {
            step { [self] done in
                tp().hide()
                TestAnchors.frames = TestAnchors.frames.filter { !$0.key.hasPrefix("svc.") }
                guard realPointer() else { movePointer(over: nil); return done() }
                UIDriverClient.move(centre(c.card), in: c.window) { _, _ in done() }
            }
            wait(0.45)
            step { [self] done in
                guard realPointer(), let target = v() else { movePointer(over: v()); postedHovers += 1; return done() }
                UIDriverClient.move(centre(target), in: c.window) { [self] ok, out in
                    if ok { realHovers += 1 } else { note("s04: driver move failed (\(out)); posted hover"); movePointer(over: target); postedHovers += 1 }
                    done()
                }
            }
            wait(settle)
        }
        var card: ServicePreviewCardView? { tp().serviceCard?.superview != nil ? tp().serviceCard : nil }
        var model: ServicePreviewModel? { card?.model }
        func mail() -> [PreviewMail] {
            if case .mail(let m)? = model?.state.content { return m }
            return []
        }
        func account(_ url: String) -> PreviewAccount { PreviewAccount(url: url, profileID: profile)! }
        func stored(_ url: String) -> [PreviewMail] {
            if case .mail(let m)? = center.state(account(url))?.content { return m }
            return []
        }
        /// A click on the card: a real driver click when allowed, else posted through the app's queue.
        func clickCard(_ anchor: String, until ok: @escaping () -> Bool) {
            step { [self] done in
                guard let h = card?.hostingView, let p = anchorPoint(anchor, in: h) else {
                    check(false, "s04: click \(anchor): not on the card")
                    return done()
                }
                let real = UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                    && NSApp.isActive && c.window.isKeyWindow
                if real {
                    let g = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                    UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { [self] okay, out in
                        if okay { realClicks += 1 } else { note("s04: driver click on \(anchor) failed: \(out)") }
                        waitUntil(ok, timeout: 3) { done() }
                    }
                } else {
                    postedClicks += 1
                    clickAnchor(anchor, in: h) { self.waitUntil(ok, timeout: 3) { done() } }
                }
            }
        }

        // MARK: Fixtures

        step { [self] done in
            fx.set(gmail: [ada, grace, weekly, oldRead], outlook: [], feed: "ok")
            server = LocalPageServer(responses: [:])
            server?.requestHandler = { fx.answer($0) }
            server?.start { port in
                fx.port = port ?? 0
                done()
            }
        }
        run { [self] in
            guard fx.port != 0 else { return check(false, "s04: a loopback server") }
            PreviewService.loopbackFixtures = ["127.0.0.1": .gmail, "localhost": .outlookMail]
            ServicePreviewCenter.refreshAfter = 2
            PageMailProvider.tick = 1
            center.pageMail.stop()
            center.pageMail.start()
            home = c.currentSpaceID
            profile = c.store.profile(ofSpace: home).id
            gmailURL = "http://127.0.0.1:\(fx.port)/mail/u/0/#inbox"
            gmail2URL = "http://127.0.0.1:\(fx.port)/mail/u/1/#inbox"
            outlookURL = "http://localhost:\(fx.port)/mail/0/inbox"
            do {
                try pin(gmailURL, title: "Gmail", icon: nil, space: home)
                gmailItem = c.store.pinnedRoots(ofSpace: home).last { $0.savedURL == gmailURL }?.id ?? ""
                try pin(gmail2URL, title: "Gmail (second account)", icon: nil, space: home)
                gmail2Item = c.store.pinnedRoots(ofSpace: home).last { $0.savedURL == gmail2URL }?.id ?? ""
                try pin(outlookURL, title: "Outlook", icon: nil, space: home)
                outlookItem = c.store.pinnedRoots(ofSpace: home).last { $0.savedURL == outlookURL }?.id ?? ""
            } catch { check(false, "s04: fixtures (\(error))") }
            check(PreviewService.detect(gmailURL) == .gmail && PreviewService.detect("http://127.0.0.2:\(fx.port)/mail/u/0/") == nil,
                  "s04: only the fixture's loopback host stands for Gmail")
            // Gmail was opened in this profile before (history), but no page of it is loaded now.
            app?.history.recordVisit(profileID: profile, url: gmailURL, title: "Inbox - Gmail")
            _ = try? c.store.openTab(url: "http://127.0.0.1:\(fx.port)/plain.html", inSpace: home, title: "Plain")
            c.reloadAll(animated: false)
            check(row(gmailItem) != nil && row(outlookItem) != nil, "s04: the pinned Gmail and Outlook rows are in the sidebar")
        }

        // MARK: No page yet: the card says to open it, and Open fills it.

        hoverFresh({ row(gmailItem) }, settle: 0.8)
        run { [self] in
            check(tp().thumbnail == .service && model?.state == .needsPage && TestAnchors.frames["svc.openPage"] != nil,
                  "s04: before Gmail's page is loaded, the card says to open it (\(String(describing: model?.state)))")
            check(fx.feedReads() == 0, "s04: nothing is read without the account's page (\(fx.feedReads()) feed reads)")
        }
        capture("s04-needs-page")
        clickCard("svc.openPage") { stored(gmailURL).count == 3 }
        hoverFresh({ row(gmailItem) }, settle: 0.5)
        run { [self] in
            check(c.store.tab(c.shownTabID)?.itemID == gmailItem, "s04: Open loads the pinned Gmail itself")
            check(mail().map(\.id) == [ada.id, grace.id, weekly.id],
                  "s04: the card fills from the page: the unread mail, newest first (\(mail().map(\.id)))")
            let first = mail().first
            check(first?.sender == "Ada Lovelace" && first?.subject == "Notes on the engine" && first?.snippet == "I've gone through the diagrams."
                  && first?.senderAddress == "ada@example.com", "s04: sender, subject and snippet (\(String(describing: first)))")
            let reads = fx.requests.filter { $0.path.hasSuffix("/feed/atom") }
            check(!reads.isEmpty && reads.allSatisfy { $0.path == "/mail/u/0/feed/atom" && $0.host == "127.0.0.1" && $0.session != "-" },
                  "s04: read from the account's own feed, in the page's own session (\(reads.map { "\($0.path)@\($0.session)" }))")
            check(!fx.requests.contains { !["127.0.0.1", "localhost"].contains($0.host) }, "s04: no other host asked")
            check(rowLines(row(gmailItem)).contains("3 Recent"), "s04: the row says \"3 Recent\" (\(rowLines(row(gmailItem))))")
        }
        capture("s04-gmail-card")

        // MARK: Peek Email: a message opens in Peek, the right one.

        clickCard("svc.mail.\(grace.id)") { self.c.peek != nil }
        step { [self] done in waitUntil({ self.c.peek?.page.title == grace.subject }, timeout: 6) { done() } }
        run { [self] in
            let p = c.peek?.page
            check(p?.url?.absoluteString.hasSuffix("#inbox/\(grace.id)") == true && p?.title == grace.subject,
                  "s04: Peek Email: the message opens in Peek, the right one (\(p?.url?.absoluteString ?? "no Peek"), \"\(p?.title ?? "")\")")
            check(c.store.tab(c.shownTabID)?.itemID == gmailItem, "s04: the Gmail tab stays where it was under the Peek")
        }
        capture("s04-peek-email")
        run { [self] in c.closePeek() }
        wait(0.8)

        // MARK: Refresh while loaded: a new message reaches the row with no hover.

        run { [self] in
            movePointer(over: nil)
            tp().hide()
            var new = t("18c1e", "Linus Example", "linus@example.com", "Fresh mail", "Just arrived.", 1)
            new.minutesAgo = 0.5
            fx.set(gmail: [new, ada, grace, weekly, oldRead])
        }
        step { [self] done in waitUntil({ rowLines(row(gmailItem)).contains("4 Recent") }, timeout: 8) { done() } }
        run { [self] in
            check(rowLines(row(gmailItem)).contains("4 Recent"), "s04: refreshed while the page is loaded: \"4 Recent\" without a hover (\(rowLines(row(gmailItem))))")
        }
        hoverFresh({ row(gmailItem) }, settle: 0.5)
        run { [self] in check(mail().first?.id == "18c1e", "s04: the new message is first on the card (\(mail().map(\.id)))") }

        // MARK: No feed: the page's list; signed out.

        run { [self] in
            fx.set(feed: "404")
            c.engineTab(for: c.shownTabID ?? "")?.reload()
        }
        wait(1.5)
        run { center.refresh(account(gmailURL), force: true) }
        step { [self] done in waitUntil({ center.state(account(gmailURL))?.content.map { if case .mail(let m) = $0 { m.count == 4 } else { false } } ?? false }, timeout: 4) { done() } }
        run { [self] in
            guard case .mail(let m)? = center.state(account(gmailURL))?.content else { return check(false, "s04: list fallback: no mail") }
            check(m.map(\.id) == ["18c1e", ada.id, grace.id, weekly.id] && !m.contains { $0.id == oldRead.id },
                  "s04: with no feed, the inbox list in the page: unread rows only, newest first (\(m.map(\.id)))")
            check(m.first?.url?.hasSuffix("/mail/u/0/#inbox/18c1e") == true, "s04: a list row opens its thread (\(m.first?.url ?? "-"))")
        }
        run { [self] in
            fx.set(feed: "401")
            center.refresh(account(gmailURL), force: true)
        }
        step { [self] done in waitUntil({ center.state(account(gmailURL)) == .signedOut }, timeout: 4) { done() } }
        hoverFresh({ row(gmailItem) }, settle: 0.5)
        run { [self] in
            check(model?.state == .signedOut && TestAnchors.frames["svc.signIn"] != nil, "s04: signed out (401): the signed-out card with Sign In")
            check(!rowLines(row(gmailItem)).contains { $0.hasSuffix("Recent") }, "s04: signed out: no count on the row")
            fx.set(feed: "ok")
            center.refresh(account(gmailURL), force: true)
        }
        step { [self] done in waitUntil({ rowLines(row(gmailItem)).contains("4 Recent") }, timeout: 4) { done() } }

        // MARK: A second account never opened is never read.

        hoverFresh({ row(gmail2Item) }, settle: 0.8)
        run { [self] in
            check(tp().thumbnail != .service, "s04: a second Gmail account (/u/1/) never opened keeps the picture card")
            check(!fx.requests.contains { $0.path.hasPrefix("/mail/u/1/") }, "s04: and is never read")
        }

        // MARK: Outlook

        run { [self] in
            let o1 = t("AQk1", "Margaret Example", "margaret@example.com", "Launch checklist", "Three items left before Friday.", 40)
            let o2 = t("AQk2", "Alan Example", "alan@example.com", "Lunch?", "Thai or ramen today.", 4)
            var o3 = t("AQk3", "Read Person", "read@example.com", "Read already", "Seen.", 2)
            o3.unread = false
            // The list in the page's order; the card orders by time.
            fx.set(outlook: [o1, o3, o2])
            guard let t = try? c.store.openItem(outlookItem, inSpace: home) else { return check(false, "s04: open Outlook") }
            c.show(t.id)
        }
        step { [self] done in waitUntil({ rowLines(row(outlookItem)).contains("2 Recent") }, timeout: 8) { done() } }
        hoverFresh({ row(outlookItem) }, settle: 0.6)
        run { [self] in
            check(model?.account?.service == .outlookMail && mail().map(\.id) == ["AQk2", "AQk1"],
                  "s04: Outlook: the unread rows of its list, newest first (\(mail().map(\.id)))")
            check(mail().first?.sender == "Alan Example" && mail().first?.subject == "Lunch?" && mail().first?.snippet == "Thai or ramen today.",
                  "s04: Outlook: sender, subject and snippet (\(String(describing: mail().first)))")
            check(rowLines(row(outlookItem)).contains("2 Recent"), "s04: Outlook's row says \"2 Recent\"")
        }
        capture("s04-outlook-card")
        clickCard("svc.mail.AQk1") { self.c.peek != nil }
        step { [self] done in waitUntil({ self.c.peek?.page.title == "Launch checklist" }, timeout: 6) { done() } }
        run { [self] in
            check(c.peek?.page.title == "Launch checklist" && c.peek?.page.url?.path.hasSuffix("/inbox/id/AQk1") == true,
                  "s04: Outlook: the message opens in Peek, the right one (\(c.peek?.page.url?.absoluteString ?? "no Peek"))")
            c.closePeek()
        }
        wait(0.8)

        // MARK: Off switch, with a read on its way
        //
        // The feed answers 2 s late, so a read is provably in flight (its request has reached the server) when Gmail's
        // previews go off. That read is stopped in the page and its answer, when it comes, is dropped: nothing stored,
        // shown or counted. No read starts after the switch, neither in Airc nor at the server.

        var serverAtOff = 0, readsAtOff = 0, cancelledAtOff = 0, droppedAtOff = 0, feedsBefore = 0
        var offAt = Date.distantFuture
        run { [self] in
            fx.set(feedDelay: 2)
            feedsBefore = fx.feedReads()
            center.refresh(account(gmailURL), force: true)
        }
        step { [self] done in waitUntil({ fx.feedReads() > feedsBefore }, timeout: 5) { done() } }
        run { [self] in
            guard let s = app?.settings else { return check(false, "s04: settings") }
            check(fx.feedReads() > feedsBefore, "s04: a Gmail read is on its way (its feed request reached the server, answer held 2 s)")
            serverAtOff = fx.requests.count
            readsAtOff = center.pageMail.readsForTesting.count
            cancelledAtOff = center.pageMail.cancelledForTesting
            droppedAtOff = center.pageMail.droppedForTesting
            offAt = Date()
            SitePreviewsSettingsSection.set(.gmail, on: false, in: s)
        }
        wait(3)   // past the held answer
        hoverFresh({ row(gmailItem) }, settle: 0.8)
        wait(2.5)   // more than two refresh intervals and timer ticks
        run { [self] in
            let p = center.pageMail
            let startedAfter = p.readsForTesting.dropFirst(readsAtOff).filter { $0.0.service == .gmail && $0.2 >= offAt }
            let serverAfter = fx.requests.dropFirst(serverAtOff).filter { $0.path.hasSuffix("/feed/atom") && $0.host == "127.0.0.1" }
            check(app?.settings.values.servicePreviewsOff == ["gmail"], "s04: Settings › Site Previews › Gmail off is saved")
            check(p.cancelledForTesting - cancelledAtOff >= 1, "s04: Gmail off: the read on its way is cancelled in its page (\(p.cancelledForTesting - cancelledAtOff))")
            check(p.droppedForTesting - droppedAtOff >= 1, "s04: Gmail off: its late answer came back and was dropped (\(p.droppedForTesting - droppedAtOff))")
            check(startedAfter.isEmpty, "s04: Gmail off: no read starts in Airc after the switch (\(startedAfter.count))")
            check(serverAfter.isEmpty, "s04: Gmail off: no feed request reaches the server after the switch (\(serverAfter.count))")
            check(center.state(account(gmailURL)) == nil && !center.cache.accounts.contains { $0.service == .gmail },
                  "s04: Gmail off: nothing of it is stored, also after the late answer (\(String(describing: center.state(account(gmailURL)))))")
            check(tp().thumbnail != .service, "s04: Gmail previews off: its pinned tab shows the page picture, not mail")
            check(!rowLines(row(gmailItem)).contains { $0.hasSuffix("Recent") }, "s04: Gmail previews off: no count on the row")
            check(center.state(account(outlookURL)) != nil, "s04: Outlook's previews stay on")
            fx.set(feedDelay: 0)
            if let s = app?.settings { SitePreviewsSettingsSection.set(.gmail, on: true, in: s) }
        }
        step { [self] done in waitUntil({ rowLines(row(gmailItem)).contains("4 Recent") }, timeout: 6) { done() } }
        run { [self] in check(rowLines(row(gmailItem)).contains("4 Recent"), "s04: back on, Gmail's row counts again") }

        // MARK: Private windows

        var privateWindow: PrivateWindowController?
        var privateSession = ""
        step { [self] done in
            guard let app else { return done() }
            // No normal page of the account any more: the Gmail tab goes elsewhere.
            if let gid = c.store.liveTab(forItem: gmailItem)?.id, let p = c.engineTab(for: gid) {
                p.load(URL(string: "http://127.0.0.1:\(fx.port)/plain.html")!)
            }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: gmailURL))
                done()
            }
        }
        wait(2)
        run { [self] in
            let load = fx.requests.last { $0.path.hasPrefix("/mail/u/0/") && !$0.path.hasSuffix("/feed/atom") }?.session ?? ""
            privateSession = load.hasPrefix("new:") ? String(load.dropFirst(4)) : load
            check(load.hasPrefix("new:"), "s04: the private window loaded the account's page in a session of its own (\(load))")
            center.register(center.pageMail)   // forget what was read: only a page can answer now
            center.refresh(account(gmailURL), force: true)
        }
        wait(2.5)
        run { [self] in
            check(privateWindow != nil, "s04: a private window opened")
            check(fx.feedReads(session: privateSession) == 0,
                  "s04: a private window's page of the account is never read (session \(privateSession): \(fx.feedReads(session: privateSession)) feed reads)")
            check(center.state(account(gmailURL)) == .needsPage, "s04: with only a private page, the card waits for a normal one (\(String(describing: center.state(account(gmailURL)))))")
            privateWindow?.closeWindow()
        }
        wait(0.5)
        run { [self] in
            note("s04: hovers: \(realHovers) real driver pointer moves, \(postedHovers) posted enter events; card clicks: \(realClicks) real driver clicks, \(postedClicks) posted")
            check(!UIDriverClient.available || (postedHovers == 0 && postedClicks == 0),
                  "s04: with the UI driver, every hover and card click was real input (\(postedHovers) posted hovers, \(postedClicks) posted clicks)")
            PreviewService.loopbackFixtures = [:]
            ServicePreviewCenter.refreshAfter = 60
            PageMailProvider.tick = 15
            center.pageMail.stop()
            center.pageMail.start()
            server?.stop()
        }
    }
}
#endif
