// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import Network
import WebKit

/// The calprev fixtures: look-alike Google Calendar and Outlook calendar pages with synthetic events only, served for
/// fixture hosts under calprev.co.uk by one loopback listener (Chromium maps them with
/// `--host-resolver-rules=MAP *.calprev.co.uk 127.0.0.1`, WebKit through the test profile's own CONNECT proxy).
/// PreviewService.fixtureHosts makes calendar.google.calprev.co.uk stand for calendar.google.com and
/// outlook.live.calprev.co.uk for outlook.live.com. Every request is logged with its host and page session.
///
/// Markup, from the public structure of both sites (not a real account):
/// - Google: day columns `[data-datekey]` (Google's packed date), event chips `[data-eventid]` with the screen-reader
///   text in `.XuJrye` ("10am to 10:30am, Standup, Accepted, No location, November 14, 2026");
/// - Outlook: day columns `[data-date]`, event buttons `[data-calitemid]` with an aria-label ("Standup, 10:00 AM to
///   10:30 AM, Friday, November 14, 2026, Busy").
final class CalPrevFixtures: @unchecked Sendable {
    struct Event {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var allDay = false
        var declined = false
        var meet = false
    }

    static let googleHost = "calendar.google.calprev.co.uk"
    static let outlookHost = "outlook.live.calprev.co.uk"
    static let accountsHost = "accounts.google.calprev.co.uk"
    /// pageread: a Gmail look-alike (the inbox list's markup and its Atom feed, as S04MailFixtures), for mail.google.com.
    static let gmailHost = "mail.google.calprev.co.uk"
    /// Google's pages refuse eval (script nonces and Trusted Types): Chromium's evaluate falls back to DevTools there.
    static let googleCSP = ["Content-Security-Policy": "script-src 'nonce-calprev'; require-trusted-types-for 'script'; object-src 'none'"]

    struct Mail {
        var id: String
        var sender: String
        var address: String
        var subject: String
        var snippet: String
        var minutesAgo: Double
        var unread = true
    }
    private var gmail: [Mail] = []

    private let lock = NSLock()
    private var google: [Event] = []
    private var outlook: [Event] = []
    private var googleSignedOut = false
    private var sessions = 0
    private(set) var log: [(host: String, path: String, session: String)] = []
    var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "airc.calprev.fixture")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters)
    }

    func set(google: [Event]? = nil, outlook: [Event]? = nil, googleSignedOut: Bool? = nil, gmail: [Mail]? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let gmail { self.gmail = gmail }
        if let google { self.google = google }
        if let outlook { self.outlook = outlook }
        if let googleSignedOut { self.googleSignedOut = googleSignedOut }
    }

    var requests: [(host: String, path: String, session: String)] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    // MARK: Pages

    private static let en: Locale = Locale(identifier: "en_US_POSIX")
    private static func format(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = en
        d.dateFormat = f
        return d
    }
    private static let longDate = format("MMMM d, yyyy")
    private static let weekday = format("EEEE")
    private static let ymd = format("yyyy-MM-dd")

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Google's chip time: "10am", "10:30pm".
    static func google12(_ d: Date) -> String {
        let m = minutes(d), h = m / 60, mm = m % 60
        return "\(h % 12 == 0 ? 12 : h % 12)" + (mm > 0 ? String(format: ":%02d", mm) : "") + (h < 12 ? "am" : "pm")
    }

    /// Outlook's: "10:00 AM".
    static func outlook12(_ d: Date) -> String {
        let m = minutes(d), h = m / 60
        return "\(h % 12 == 0 ? 12 : h % 12)" + String(format: ":%02d", m % 60) + (h < 12 ? " AM" : " PM")
    }

    /// Google's packed day: ((year - 1970) << 9) | (month << 5) | day.
    static func dateKey(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return ((c.year! - 1970) << 9) | (c.month! << 5) | c.day!
    }

    /// The days a page shows: a week around today, or today alone (the day view).
    private static func days(dayView: Bool) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (dayView ? [0] : [-1, 0, 1, 2]).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private func googlePage(dayView: Bool) -> String {
        var cols = ""
        for day in Self.days(dayView: dayView) {
            var chips = ""
            for e in google where Calendar.current.isDate(e.start, inSameDayAs: day) {
                let when = e.allDay ? "All day" : "\(Self.google12(e.start)) to \(Self.google12(e.end))"
                var parts = [when, e.title, "Fixture Organizer", e.declined ? "Declined" : "Accepted"]
                if e.meet { parts.append("https://meet.google.com/abc-defg-hij") }
                parts += ["No location", Self.longDate.string(from: e.start)]
                chips += """
                    <div role="button" tabindex="0" data-eventchip="" data-eventid="\(e.id)" class="chip">\
                    <div class="XuJrye">\(Self.esc(parts.joined(separator: ", ")))</div><span aria-hidden="true">\(Self.esc(e.title))</span></div>
                    """
            }
            cols += "<div role=\"gridcell\" data-datekey=\"\(Self.dateKey(day))\"><h2>\(Self.weekday.string(from: day))</h2>\(chips)</div>"
        }
        return """
            <!doctype html><title>Google Calendar - Fixture</title>
            <style>body{font:13px -apple-system;margin:0}[role=grid]{display:flex}[role=gridcell]{flex:1;padding:6px;border-left:1px solid #ddd}
            .chip{background:#039be5;color:#fff;border-radius:4px;margin:4px 0;padding:4px}.XuJrye{position:absolute;left:-9999px}</style>
            <div role="main"><div role="grid">\(cols)</div></div>
            """
    }

    private func outlookPage() -> String {
        var cols = ""
        for day in Self.days(dayView: false) {
            var items = ""
            for e in outlook where Calendar.current.isDate(e.start, inSameDayAs: day) {
                let when = e.allDay ? "All day" : "\(Self.outlook12(e.start)) to \(Self.outlook12(e.end))"
                let label = [e.title, when, Self.weekday.string(from: e.start), Self.longDate.string(from: e.start),
                             e.declined ? "Declined" : "Busy"].joined(separator: ", ")
                items += "<div role=\"button\" data-calitemid=\"\(e.id)\" aria-label=\"\(Self.esc(label))\" class=\"ev\"><span>\(Self.esc(e.title))</span></div>"
            }
            cols += "<div data-date=\"\(Self.ymd.string(from: day))T00:00:00\"><h2>\(Self.weekday.string(from: day))</h2>\(items)</div>"
        }
        return """
            <!doctype html><title>Calendar - Fixture - Outlook</title>
            <style>body{font:13px -apple-system;margin:0}[role=grid]{display:flex}[data-date]{flex:1;padding:6px}.ev{background:#0f6cbd;color:#fff;margin:4px 0;padding:4px}</style>
            <div role="main"><div role="grid">\(cols)</div></div>
            """
    }

    private static func iso(_ minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
    }

    /// Gmail: `/mail/u/N/feed/atom` (the unread messages) and the inbox (`tr.zA`, unread `zE`), under Google's CSP.
    private func gmailAnswer(path: String, headers: [String: String]) -> Answer {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 5, parts[0] == "mail", parts[1] == "u", parts[3] == "feed", parts[4] == "atom" {
            let entries = gmail.filter(\.unread).reversed().map { g in """
                <entry><title>\(Self.esc(g.subject))</title><summary>\(Self.esc(g.snippet))</summary>
                <link rel="alternate" href="http://\(Self.gmailHost):\(port)/mail/u/\(parts[2])/#inbox/\(g.id)" type="text/html" />
                <modified>\(Self.iso(g.minutesAgo))</modified><issued>\(Self.iso(g.minutesAgo))</issued><id>tag:gmail.google.com,2004:\(g.id)</id>
                <author><name>\(Self.esc(g.sender))</name><email>\(g.address)</email></author></entry>
                """ }.joined(separator: "\n")
            return Answer(headers: ["Content-Type": "application/atom+xml; charset=UTF-8"], body: """
                <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#">
                <title>Gmail - Inbox for fixture@example.com</title><fullcount>\(gmail.filter(\.unread).count)</fullcount>
                \(entries)</feed>
                """)
        }
        guard path.hasPrefix("/mail/") else { return Answer(status: "404 Not Found", body: "not found") }
        let rows = gmail.map { g in """
            <tr class="zA \(g.unread ? "zE" : "yO")"><td><span class="yP" email="\(g.address)" name="\(Self.esc(g.sender))">\(Self.esc(g.sender))</span></td>
            <td><span class="bog"><span data-legacy-thread-id="\(g.id)">\(Self.esc(g.subject))</span></span><span class="y2"> - \(Self.esc(g.snippet))</span></td>
            <td class="xW"><span title="\(Self.iso(g.minutesAgo))">\(Int(g.minutesAgo))m</span></td></tr>
            """ }.joined(separator: "\n")
        return Answer(headers: headers.merging(Self.googleCSP) { a, _ in a }, body: """
            <!doctype html><title>Inbox (\(gmail.filter(\.unread).count)) - fixture@example.com - Gmail</title>
            <table><tbody>\(rows)</tbody></table>
            """)
    }

    struct Answer {
        var status = "200 OK"
        var headers: [String: String] = [:]
        var body: String
    }

    private func answer(host: String, path: String, cookie: String) -> Answer {
        lock.lock(); defer { lock.unlock() }
        let session = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("sid=") }.map { String($0.dropFirst(4)) } ?? "-"
        log.append((host, path, session))
        func newSession() -> [String: String] {
            sessions += 1
            if session == "-" { log[log.count - 1].session = "new:s\(sessions)" }
            return ["Set-Cookie": "sid=s\(sessions); Path=/; SameSite=Lax"]
        }
        func title(_ id: String, in list: [Event]) -> String { list.first { $0.id == id }?.title ?? "Unknown event" }
        switch host {
        case Self.googleHost:
            if let r = path.range(of: "/r/eventedit/") {
                let raw = String(path[r.upperBound...])
                let id = raw.removingPercentEncoding ?? raw
                let t = title(id, in: google)
                return Answer(body: "<!doctype html><title>\(Self.esc(t)) - Google Calendar</title><h1>\(Self.esc(t))</h1>")
            }
            if path.hasPrefix("/calendar/") {
                if googleSignedOut {
                    return Answer(status: "302 Found", headers: ["Location": "http://\(Self.accountsHost):\(port)/ServiceLogin?service=cl"], body: "")
                }
                return Answer(headers: newSession().merging(Self.googleCSP) { a, _ in a }, body: googlePage(dayView: path.contains("/r/day")))
            }
        case Self.accountsHost:
            return Answer(body: "<!doctype html><title>Sign in - Google Accounts</title><h1>Sign in</h1>")
        case Self.gmailHost:
            return gmailAnswer(path: path, headers: newSession())
        case Self.outlookHost:
            if let r = path.range(of: "/calendar/0/item/") {
                let raw = String(path[r.upperBound...])
                let t = title(raw.removingPercentEncoding ?? raw, in: outlook)
                return Answer(body: "<!doctype html><title>\(Self.esc(t)) - Outlook</title><h1>\(Self.esc(t))</h1>")
            }
            if path.hasPrefix("/calendar/") { return Answer(headers: newSession(), body: outlookPage()) }
        default: break
        }
        if path == "/plain.html" { return Answer(body: "<!doctype html><title>Plain</title><h1>Plain</h1>") }
        return Answer(status: "404 Not Found", body: "not found")
    }

    // MARK: Serving

    func start(_ ready: @escaping (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { DispatchQueue.main.async { ready(port.rawValue) } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, _ prefix: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var bytes = prefix
            bytes.append(data ?? Data())
            guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil || bytes.count > 65536 { connection.cancel() } else { self.receive(connection, bytes) }
                return
            }
            let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
            if head.hasPrefix("CONNECT ") {
                connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self.receive(connection, Data(bytes[end.upperBound...]))
                })
                return
            }
            var headers: [String: String] = [:]
            for line in head.components(separatedBy: "\r\n").dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
            }
            // WebKit's proxy asks with an absolute URI; Chromium with a path and a Host header.
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let absolute = URL(string: target).flatMap { $0.host != nil ? $0 : nil }
            let host = absolute?.host ?? (headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
            let path = absolute.map { $0.path.isEmpty ? "/" : $0.path } ?? String(target.split(separator: "?").first ?? "/")
            let a = self.answer(host: host.lowercased(), path: path, cookie: headers["cookie"] ?? "")
            let payload = Data(a.body.utf8)
            var extra = a.headers
            extra["Content-Type"] = "text/html; charset=utf-8"
            extra["Cache-Control"] = "no-store"
            let response = "HTTP/1.1 \(a.status)\r\n" + extra.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
                + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

/// `--script paritycalprev` (both engines): calendar hover cards read from the account's own calendar page (calprev),
/// on fixture hosts only (CalPrevFixtures), with real UI-driver hovers and clicks:
///   - before the page is loaded: "Open Google Calendar…" over the item's last page picture, nothing read; Open loads
///     the pinned calendar and the card fills;
///   - the card shows today as Arc's hour grid (calgrid): opened a quarter hour before now, today's events as blocks at
///     their times (an ended one above, scrolled away), the all-day event in the strip above, no declined event; under
///     it, tomorrow in one line (all-day first, "+1"); read from the page's markup with no request of its own;
///     the row says "Event in 20m";
///   - calcard, the full card: a big Join, three all-day events, overlapping meetings, one in the sixth hour and
///     tomorrow: Arc's six hours still show without scrolling; a click on tomorrow's chip opens it;
///   - a click on an event opens that event's own page in the pinned tab;
///   - the page reloaded with a new event: the row's line follows without a hover; the page on its day view: today is
///     read again (a removed event goes), tomorrow keeps what was read;
///   - the page went to its sign-in page: the signed-out card; its Open loads the calendar again and the card fills;
///   - an Outlook calendar Favorite: its events, and a click opens the event in the Favorite;
///   - pageread (the owner's setup): Gmail and Google Calendar Favorites (Google's address forms, Google's CSP), Live
///     Calendar on with an Apple Calendar meeting: not loaded, "Open Google Calendar" / "Open Gmail"; loaded with Gmail
///     active, the unread mail and the page's day, never Live Calendar's card or the Mac's meeting; Gmail closed, "Open
///     Gmail" again;
///   - a second Google account (/u/1/) never opened is never read; Settings › Site Previews › Google Calendar off: the
///     picture card, no line, no read; a private window's page is never read.
/// Needs AIRC_REAL_KEYS=1 in a dedicated session (AIRC_UI_DEDICATED_SESSION=1, AIRC_LA_AS_OWNER=1) for real input;
/// otherwise hovers and clicks are posted and the last check fails.
extension SnapshotRunner {
    /// calcard: the hour height the shown calendar card fits Arc's six hours with (PreviewTimeline.CardLayout).
    func cardLayout(_ m: ServicePreviewModel?) -> PreviewTimeline.CardLayout? {
        guard let m, case .calendar(let e)? = m.state.content else { return nil }
        return PreviewTimeline.CardLayout(e, now: m.now, cardHeight: Double(m.cardHeight))
    }
    func hourHeight(_ m: ServicePreviewModel?) -> CGFloat { CGFloat(cardLayout(m)?.hourHeight ?? 0) }

    func parityCalPrevScenario() {
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "calprev \(engine): " + s }
        let tp = { self.c.tabPreview }
        let center = ServicePreviewCenter.shared
        var fx: CalPrevFixtures?
        var home = "", profile = "", gcalItem = "", gcal2Item = "", outItem = ""
        var gcalURL = "", gcal2URL = "", outURL = ""
        var realClicks = 0, postedClicks = 0, realHovers = 0, postedHovers = 0
        var lastHovered: NSView?
        let page = { self.c.pageView(for: self.c.currentSpaceID) }
        let cal = Calendar.current
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60)
        func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
        let today = cal.startOfDay(for: t0)
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today)!
        func tomorrowAt(_ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: tomorrow)! }
        typealias E = CalPrevFixtures.Event
        let standup = E(id: "ZXZzdGFuZHVw", title: "Standup", start: at(20), end: at(35))
        let lunch = E(id: "ZXZsdW5jaA", title: "Lunch with Sam", start: at(90), end: at(150))
        let holiday = E(id: "ZXZob2xpZGF5", title: "Company holiday", start: today, end: tomorrow, allDay: true)
        let declined = E(id: "ZXZkZWNsaW5lZA", title: "Declined sync", start: at(45), end: at(75), declined: true)
        let past = E(id: "ZXZwYXN0", title: "Earlier review", start: at(-120), end: at(-90))
        let planning = E(id: "ZXZwbGFubmluZw", title: "Planning", start: tomorrowAt(9), end: tomorrowAt(9, 30), meet: true)
        let offsite = E(id: "ZXZvZmZzaXRl", title: "Offsite", start: tomorrow, end: cal.date(byAdding: .day, value: 1, to: tomorrow)!, allDay: true)
        let monday = E(id: "ZXZsYXRlcg", title: "Day after tomorrow", start: cal.date(byAdding: .day, value: 1, to: tomorrowAt(10))!,
                       end: cal.date(byAdding: .day, value: 1, to: tomorrowAt(11))!)
        let coffee = E(id: "ZXZjb2ZmZWU", title: "Coffee chat", start: at(10), end: at(25))
        let googleEvents = [standup, lunch, holiday, declined, past, planning, offsite, monday]

        /// What a card should list of `events` (Arc's rules, M08's day list), by title.
        func expected(_ events: [E]) -> [String] {
            PageCalendar.upcoming(events.map {
                CalendarEvent(id: $0.id, title: $0.title, start: $0.start, end: $0.end, isAllDay: $0.allDay,
                              response: $0.declined ? .declined : .none)
            }, now: Date()).map(\.title)
        }

        func row(_ itemID: String) -> TabRowView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? TabRowView }.first { $0.entry?.item?.id == itemID }
        }
        func tile(_ itemID: String) -> FavoriteTileView? {
            guard let p = page() else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == itemID }
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
        func realInput() -> Bool {
            UIDriverClient.available && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                && NSApp.isActive && c.window.isKeyWindow
        }
        func postedHover(_ target: NSView?) {
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
        /// The pointer comes to `v` from the page: a real HID move when allowed, else posted enter and exit events.
        func hoverFresh(_ v: @escaping () -> NSView?, settle: Double = 0.9) {
            step { [self] done in
                tp().hide()
                CalendarCard.shared.hide()
                TestAnchors.frames = TestAnchors.frames.filter { !$0.key.hasPrefix("svc.") }
                guard realInput() else { postedHover(nil); return done() }
                UIDriverClient.move(centre(c.card), in: c.window) { _, _ in done() }
            }
            wait(0.45)
            step { [self] done in
                guard realInput(), let target = v() else { postedHover(v()); postedHovers += 1; return done() }
                UIDriverClient.move(centre(target), in: c.window) { [self] ok, out in
                    if ok { realHovers += 1 } else { note(label("driver move failed (\(out)); posted hover")); postedHover(target); postedHovers += 1 }
                    done()
                }
            }
            wait(settle)
        }
        var card: ServicePreviewCardView? { tp().serviceCard?.superview != nil ? tp().serviceCard : nil }
        var model: ServicePreviewModel? { card?.model }
        func shown() -> [CalendarEvent] {
            if case .calendar(let e)? = model?.state.content { return PageCalendar.upcoming(e, now: Date()) }
            return []
        }
        func account(_ url: String) -> PreviewAccount { PreviewAccount(url: url, profileID: profile)! }
        func stored(_ url: String) -> [CalendarEvent] {
            if case .calendar(let e)? = center.state(account(url))?.content { return PageCalendar.upcoming(e, now: Date()) }
            return []
        }
        /// The row's line for the next event `e` now ("Event in 20m"), a minute either way.
        func lines(_ e: E) -> [String] {
            let m = Int((e.start.timeIntervalSinceNow / 60).rounded(.up))
            return [m - 1, m, m + 1].filter { $0 >= 1 }.map { "Event in \($0)m" }
        }
        func pageRequests() -> Int { fx?.requests.filter { !$0.path.hasSuffix("favicon.ico") }.count ?? 0 }
        func readsOf(_ url: String) -> Int { center.pageMail.readsForTesting.filter { $0.0 == account(url) }.count }
        func clickCard(_ anchor: @escaping () -> String, until ok: @escaping () -> Bool) {
            step { [self] done in
                let name = anchor()
                guard let h = card?.hostingView, let p = anchorPoint(name, in: h) else {
                    check(false, label("click \(name): not on the card"))
                    return done()
                }
                if realInput() {
                    let g = c.window.convertPoint(toScreen: p), top = NSScreen.screens.first?.frame.maxY ?? 0
                    UIDriverClient.run(["--click", String(Double(g.x)), String(Double(top - g.y))]) { [self] okay, out in
                        if okay { realClicks += 1 } else { note(label("driver click on \(name) failed: \(out)")) }
                        waitUntil(ok, timeout: 4) { done() }
                    }
                } else {
                    postedClicks += 1
                    clickAnchor(name, in: h) { self.waitUntil(ok, timeout: 4) { done() } }
                }
            }
        }
        func shownTab() -> (url: String, title: String, item: String?) {
            let id = c.shownTabID ?? ""
            return (c.engineTab(for: id)?.url?.absoluteString ?? "", c.engineTab(for: id)?.title ?? "", c.store.tab(id)?.itemID)
        }
        func load(_ itemID: String, _ url: String) {
            guard let t = c.store.liveTab(forItem: itemID), let p = c.engineTab(for: t.id), let u = URL(string: url) else { return }
            p.load(u)
        }
        func restore() {
            if let wk = c.profiles.engineProfile(for: c.store.selectedSpace.profileID) as? WebKitProfile { wk.dataStore.proxyConfigurations = [] }
            PreviewService.fixtureHosts = [:]
            ServicePreviewCenter.refreshAfter = 60
            PageMailProvider.tick = 15
            center.pageMail.stop()
            center.pageMail.start()
            fx?.stop()
        }

        // MARK: Fixtures

        step { [self] done in
            if engine == "Chromium", !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--host-resolver-rules=") && $0.contains("calprev.co.uk") }) {
                check(false, label("Chromium needs --host-resolver-rules=MAP *.calprev.co.uk 127.0.0.1 (launch argument)"))
            }
            fx = try? CalPrevFixtures()
            guard let fx else { check(false, label("fixture server starts")); return done() }
            fx.set(google: googleEvents, outlook: [], googleSignedOut: false)
            fx.start { port in
                fx.port = port
                self.c.profiles.whenLoaded(self.c.store.selectedSpace.profileID, { loaded in
                    if let wk = loaded as? WebKitProfile, let p = NWEndpoint.Port(rawValue: port) {
                        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: p))
                        proxy.matchDomains = ["calprev.co.uk"]
                        proxy.allowFailover = false
                        wk.dataStore.proxyConfigurations = [proxy]
                    }
                    done()
                }, failed: { self.check(false, label("profile loads")); done() })
            }
        }
        run { [self] in
            guard let fx, fx.port != 0 else { return check(false, label("a loopback fixture")) }
            PreviewService.fixtureHosts = [CalPrevFixtures.googleHost: "calendar.google.com", CalPrevFixtures.outlookHost: "outlook.live.com",
                                           CalPrevFixtures.accountsHost: "accounts.google.com"]
            ServicePreviewCenter.refreshAfter = 2
            PageMailProvider.tick = 1
            center.pageMail.stop()
            center.pageMail.start()
            center.register(center.pageMail)
            home = c.currentSpaceID
            profile = c.store.profile(ofSpace: home).id
            gcalURL = "http://\(CalPrevFixtures.googleHost):\(fx.port)/calendar/u/0/r/week"
            gcal2URL = "http://\(CalPrevFixtures.googleHost):\(fx.port)/calendar/u/1/r/week"
            outURL = "http://\(CalPrevFixtures.outlookHost):\(fx.port)/calendar/0/view/week"
            do {
                try pin(gcalURL, title: "Google Calendar", icon: nil, space: home)
                gcalItem = c.store.pinnedRoots(ofSpace: home).last { $0.savedURL == gcalURL }?.id ?? ""
                try pin(gcal2URL, title: "Google Calendar (second account)", icon: nil, space: home)
                gcal2Item = c.store.pinnedRoots(ofSpace: home).last { $0.savedURL == gcal2URL }?.id ?? ""
                try favorite(outURL, title: "Outlook Calendar", icon: nil, profile: profile, space: home)
                outItem = c.store.favorites(ofProfile: profile).first { $0.savedURL == outURL }?.id ?? ""
            } catch { check(false, label("fixtures (\(error))")) }
            check(PreviewService.detect(gcalURL) == .googleCalendar && PreviewService.detect(outURL) == .outlookCalendar
                  && PreviewService.detect("http://calendar.other.co.uk/calendar/u/0/r") == nil,
                  label("only the fixture hosts stand for Google Calendar and Outlook"))
            check(center.provider(for: .googleCalendar) === center.pageMail && center.provider(for: .outlookCalendar) === center.pageMail,
                  label("Google Calendar and Outlook calendar are read from their own page by default"))
            // Opened in this profile before (history), and pictured once, but no page of it is loaded now.
            app?.history.recordVisit(profileID: profile, url: gcalURL, title: "Google Calendar")
            app?.history.recordVisit(profileID: profile, url: outURL, title: "Outlook Calendar")
            let ctx = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(CGColor(red: 0.01, green: 0.6, blue: 0.9, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            if let img = ctx?.makeImage() { TabPreviewCache.shared.store(img, url: gcalURL, tab: "calprev-none", item: gcalItem, profileID: profile) }
            _ = try? c.store.openTab(url: "http://\(CalPrevFixtures.outlookHost):\(fx.port)/plain.html", inSpace: home, title: "Plain")
            c.reloadAll(animated: false)
            check(row(gcalItem) != nil && tile(outItem) != nil, label("the pinned Google Calendar row and the Outlook Favorite are in the sidebar"))
        }

        // MARK: No page yet

        hoverFresh({ row(gcalItem) }, settle: 0.8)
        run { [self] in
            check(tp().thumbnail == .service && model?.state == .needsPage && TestAnchors.frames["svc.openPage"] != nil,
                  label("before the page is loaded, the card says to open Google Calendar (\(String(describing: model?.state)))"))
            check(TestAnchors.frames["svc.snapshot"] != nil, label("behind it, the item's last page picture"))
            check(readsOf(gcalURL) == 0, label("nothing is read without the account's page (\(readsOf(gcalURL)) reads)"))
        }
        capture("calprev-needs-page")
        clickCard({ "svc.openPage" }) { stored(gcalURL).count == expected(googleEvents).count }
        hoverFresh({ row(gcalItem) }, settle: 0.6)
        var requestsAtRead = 0
        run { [self] in
            check(shownTab().item == gcalItem, label("Open loads the pinned Google Calendar itself"))
            check(shown().map(\.title) == expected(googleEvents),
                  label("the card lists today and tomorrow from the page: all-day first, no declined or past event (\(shown().map(\.title)))"))
            check(!shown().contains { $0.title == monday.title || $0.title == declined.title || $0.title == past.title },
                  label("not the day after tomorrow, a declined or an ended event"))
            // calgrid: today in Arc's hour grid, tomorrow in the list under it.
            let f = TestAnchors.frames
            let grid = f["svc.grid"] ?? .zero, now = f["svc.nowLine"]
            // The card's ids are the reader's (PageCalendar), not the fixture's: find each event by its title.
            func id(_ e: E) -> String { model.flatMap { m -> String? in
                if case .calendar(let all)? = m.state.content { return all.first { $0.title == e.title }?.id }; return nil } ?? "-" }
            func frame(_ e: E) -> CGRect? { f["svc.event.\(id(e))"] }
            check(!grid.isEmpty && now != nil && f["svc.day.Tomorrow"] != nil, label("an hour grid with a now line, and Tomorrow under it"))
            let hourHeight = self.hourHeight(model)
            let wantNow = CGFloat(PreviewTimeline.lead / 3600) * hourHeight + CalendarHourGrid.topInset
            check(abs((now?.midY ?? 0) - grid.minY - wantNow) < 3,
                  label(String(format: "the grid opens a quarter hour before now (now line %.1f pt down, want %.1f)", (now?.midY ?? 0) - grid.minY, wantNow)))
            let su = frame(standup), lu = frame(lunch)
            let want = CGFloat(lunch.start.timeIntervalSince(standup.start) / 3600) * hourHeight
            check(su.map { grid.intersects($0) && $0.minY > (now?.midY ?? .infinity) } ?? false && lu.map { abs($0.minY - (su?.minY ?? 0) - want) < 2 } ?? false,
                  label(String(format: "standup and lunch sit at their times, under the now line (lunch %.1f pt below standup, want %.1f)",
                               (lu?.minY ?? 0) - (su?.minY ?? 0), want)))
            check(frame(past).map { $0.maxY <= grid.minY + 1 } ?? false, label("the ended event is above, scrolled out of view"))
            check(f["svc.allDay.\(id(holiday))"].map { $0.maxY <= grid.minY + 1 } ?? false, label("today's all-day event in the strip above the hours"))
            check(f["svc.tomorrow.\(id(offsite))"].map { $0.minY >= grid.maxY - 1 } ?? false && f["svc.tomorrow.\(id(planning))"] == nil,
                  label("under the grid, tomorrow in one line: the all-day offsite first, planning in its \"+1\""))
            check(frame(declined) == nil && frame(monday) == nil, label("no declined event, nothing the day after tomorrow"))
            let p = shown().first { $0.title == planning.title }
            check(p?.link?.service == .meet && f["svc.join.\(p?.id ?? "")"] == nil,
                  label("tomorrow's meeting with a Meet link is read with its call; no Join yet (Arc's Join is for one moments away)"))
            let line = rowLines(row(gcalItem))
            check(line.contains { lines(standup).contains($0) }, label("the row counts down to the next event, \"\(lines(standup)[1])\" (\(line))"))
            check(fx?.requests.allSatisfy { [CalPrevFixtures.googleHost, CalPrevFixtures.outlookHost].contains($0.host) && !$0.path.contains("feed") } == true,
                  label("only the fixture's pages were asked, nothing else"))
            requestsAtRead = pageRequests()
            center.refresh(account(gcalURL), force: true)
        }
        wait(1.2)
        run { [self] in
            check(pageRequests() == requestsAtRead && readsOf(gcalURL) >= 2,
                  label("a read asks nothing: it reads the page's markup (\(pageRequests() - requestsAtRead) requests, \(readsOf(gcalURL)) reads)"))
        }
        capture("calprev-google-card")

        // MARK: A click opens the event

        clickCard({ "svc.event." + (shown().first { $0.title == standup.title }?.id ?? "-") }) { shownTab().title.hasPrefix(standup.title) }
        run { [self] in
            let t = shownTab()
            check(t.item == gcalItem && t.url.contains("/r/eventedit/\(standup.id)") && t.title == "Standup - Google Calendar",
                  label("a click on an event opens its own page in the pinned tab (\(t.url), \"\(t.title)\")"))
            check(stored(gcalURL).count == expected(googleEvents).count, label("on the event's page, the card keeps its events"))
        }

        // MARK: The full card: Join, all day, overlaps, Tomorrow (calcard)

        // A call moments away (the big Join), three all-day events (two chips and "+1"), two meetings side by side, one
        // in Arc's last hour, and tomorrow: Arc's six hours still show without scrolling.
        let kickoff = E(id: "ZXZraWNrb2Zm", title: "Kickoff", start: at(6), end: at(40), meet: true)
        let design = E(id: "ZXZkZXNpZ24", title: "Design review", start: at(60), end: at(120))
        let pairing = E(id: "ZXZwYWlyaW5n", title: "Pairing", start: at(90), end: at(150))
        let wrapUp = E(id: "ZXZ3cmFwdXA", title: "Wrap-up", start: at(300), end: at(330))
        let moving = E(id: "ZXZtb3Zpbmc", title: "Moving day", start: today, end: tomorrow, allDay: true)
        let conference = E(id: "ZXZjb25m", title: "Conference", start: today, end: tomorrow, allDay: true)
        let fullEvents = [kickoff, design, pairing, wrapUp, holiday, moving, conference, planning, offsite]
        run { [self] in
            tp().hide()
            fx?.set(google: fullEvents)
            load(gcalItem, gcalURL)
        }
        step { [self] done in waitUntil({ stored(gcalURL).contains { $0.title == wrapUp.title } }, timeout: 8) { done() } }
        hoverFresh({ row(gcalItem) }, settle: 0.8)
        run { [self] in
            let f = TestAnchors.frames
            func id(_ e: E) -> String { model.flatMap { m -> String? in
                if case .calendar(let all)? = m.state.content { return all.first { $0.title == e.title }?.id }; return nil } ?? "-" }
            let grid = f["svc.grid"] ?? .zero, now = f["svc.nowLine"]
            let layout = cardLayout(model) ?? PreviewTimeline.CardLayout(cardHeight: 0, join: false, allDay: false, tomorrow: false)
            let hourHeight = self.hourHeight(model)
            let join = f["svc.join.\(id(kickoff))"], allDay = f["svc.allDay"], later = f["svc.tomorrow"], whole = f["svc.calendar"]
            check(layout.join && layout.allDay && layout.tomorrow && join != nil && allDay != nil && later != nil,
                  label("the full card: the big Join, the all-day strip and Tomorrow all show"))
            check(model?.cardHeight == CGFloat(PreviewTimeline.CardLayout.calendarCardHeight) || (model?.cardHeight ?? 0) == c.root.bounds.height - 16,
                  label(String(format: "the calendar card is %.0f pt tall (the mail card 268)", model?.cardHeight ?? 0)))
            check((join?.maxY ?? .infinity) <= (allDay?.minY ?? 0) + 1 && (allDay?.maxY ?? .infinity) <= grid.minY + 1
                  && (later?.minY ?? 0) >= grid.maxY - 1 && (later?.maxY ?? .infinity) <= (whole?.maxY ?? 0) + 1,
                  label("top to bottom: Join, all day, the hours, Tomorrow, all on the card"))
            let sixHours = CalendarHourGrid.topInset + 6 * hourHeight
            check(!grid.isEmpty && grid.height >= sixHours - 1 && layout.visibleHours >= 6,
                  label(String(format: "Arc's six hours show without scrolling (grid %.0f pt, six hours %.0f at %.1f pt an hour)", grid.height, sixHours, hourHeight)))
            let wantNow = CGFloat(PreviewTimeline.lead / 3600) * hourHeight + CalendarHourGrid.topInset
            check(abs((now?.midY ?? 0) - grid.minY - wantNow) < 3,
                  label(String(format: "it opens a quarter hour before now (now line %.1f pt down, want %.1f)", (now?.midY ?? 0) - grid.minY, wantNow)))
            let d = f["svc.event.\(id(design))"], p = f["svc.event.\(id(pairing))"], w = f["svc.event.\(id(wrapUp))"]
            check(d.map { d in p.map { abs($0.width - d.width) < 1 && $0.minX >= d.maxX - 1 && abs($0.minY - d.minY - hourHeight / 2) < 2 } ?? false } ?? false,
                  label("the overlapping meetings side by side, half an hour apart"))
            check(w.map { $0.minY >= grid.minY && $0.maxY <= grid.maxY + 1 } ?? false,
                  label(String(format: "the meeting in the sixth hour is on the card without scrolling (bottom %.0f, grid bottom %.0f)", w?.maxY ?? 0, grid.maxY)))
            check(f["svc.allDay.\(id(holiday))"] != nil && f["svc.allDay.\(id(conference))"] != nil && f["svc.allDay.\(id(moving))"] == nil,
                  label("all day in one line: two chips and \"+1\""))
            check(f["svc.tomorrow.\(id(offsite))"] != nil && (f["svc.action"].map { a in later.map { $0.minY >= a.maxY - 1 } ?? false } ?? false),
                  label("Tomorrow in one line under \"+\", across the card"))
        }
        capture("calprev-full-card")
        clickCard({ "svc.tomorrow." + ({ if case .calendar(let all)? = model?.state.content { return all.first { $0.title == offsite.title }?.id }; return nil }() ?? "-") }) { shownTab().title.hasPrefix(offsite.title) }
        run { [self] in
            check(shownTab().item == gcalItem && shownTab().title == "Offsite - Google Calendar",
                  label("a click on Tomorrow's chip opens that event in the pinned tab (\"\(shownTab().title)\")"))
        }

        // MARK: Refresh: a new event; the day view

        run { [self] in
            tp().hide()
            postedHover(nil)
            fx?.set(google: googleEvents + [coffee])
            load(gcalItem, gcalURL)
        }
        step { [self] done in waitUntil({ rowLines(row(gcalItem)).contains { lines(coffee).contains($0) } }, timeout: 8) { done() } }
        run { [self] in
            let line = rowLines(row(gcalItem))
            check(line.contains { lines(coffee).contains($0) },
                  label("the page reloaded with a new event: the row follows without a hover (\(line))"))
            fx?.set(google: googleEvents.filter { $0.id != lunch.id } + [coffee])
            load(gcalItem, gcalURL.replacingOccurrences(of: "/r/week", with: "/r/day"))
        }
        step { [self] done in waitUntil({ !stored(gcalURL).contains { $0.title == lunch.title } }, timeout: 8) { done() } }
        run { [self] in
            let titles = stored(gcalURL).map(\.title)
            check(!titles.contains(lunch.title) && titles.contains(coffee.title), label("the day view reads today again: a removed event goes (\(titles))"))
            check(titles.contains(planning.title) && titles.contains(offsite.title), label("tomorrow, not on the day view, keeps what was read"))
        }

        // MARK: Signed out

        run { [self] in
            fx?.set(googleSignedOut: true)
            load(gcalItem, gcalURL)
        }
        wait(1.5)
        run { center.refresh(account(gcalURL), force: true) }
        step { [self] done in waitUntil({ center.state(account(gcalURL)) == .signedOut }, timeout: 8) { done() } }
        hoverFresh({ row(gcalItem) }, settle: 0.6)
        run { [self] in
            check(shownTab().url.contains(CalPrevFixtures.accountsHost), label("the pinned calendar went to its sign-in page (\(shownTab().url))"))
            check(model?.state == .signedOut && TestAnchors.frames["svc.signIn"] != nil, label("signed out: the signed-out card with Open"))
            check(!rowLines(row(gcalItem)).contains { $0.hasPrefix("Event") }, label("signed out: no line on the row"))
            fx?.set(googleSignedOut: false)
        }
        capture("calprev-signed-out")
        clickCard({ "svc.signIn" }) { !stored(gcalURL).isEmpty }
        run { [self] in
            check(shownTab().item == gcalItem && shownTab().url.hasPrefix(gcalURL) && !stored(gcalURL).isEmpty,
                  label("signed in again, Open loads the calendar and the card fills (\(stored(gcalURL).count) events)"))
        }

        // MARK: Outlook, a Favorite

        let o1 = E(id: "AAMkAGI1", title: "Launch review", start: at(30), end: at(60))
        let o2 = E(id: "AAMkAGI2", title: "Team lunch", start: tomorrowAt(12), end: tomorrowAt(13))
        let o3 = E(id: "AAMkAGI3", title: "Skipped", start: at(70), end: at(80), declined: true)
        run { [self] in
            fx?.set(outlook: [o2, o3, o1])
            guard let t = try? c.store.openItem(outItem, inSpace: home) else { return check(false, label("open the Outlook Favorite")) }
            c.show(t.id)
        }
        step { [self] done in waitUntil({ stored(outURL).count == 2 }, timeout: 8) { done() } }
        hoverFresh({ tile(outItem) }, settle: 0.6)
        run { [self] in
            check(model?.account?.service == .outlookCalendar && shown().map(\.title) == expected([o1, o2, o3]),
                  label("the Outlook Favorite: its events from the page, no declined one (\(shown().map(\.title)))"))
        }
        capture("calprev-outlook-card")
        clickCard({ "svc.event." + (shown().first { $0.title == o2.title }?.id ?? "-") }) { shownTab().title.hasPrefix(o2.title) }
        run { [self] in
            let t = shownTab()
            check(t.item == outItem && t.url.contains("/calendar/0/item/\(o2.id)") && t.title == "Team lunch - Outlook",
                  label("a click opens the Outlook event in the Favorite (\(t.url), \"\(t.title)\")"))
        }

        // MARK: Never opened, off, private

        hoverFresh({ row(gcal2Item) }, settle: 0.8)
        run { [self] in
            check(tp().thumbnail != .service && readsOf(gcal2URL) == 0, label("a second Google account (/u/1/) never opened keeps the picture card and is never read"))
        }
        var readsAtOff = 0
        run { [self] in
            guard let s = app?.settings else { return check(false, label("settings")) }
            load(gcalItem, gcalURL)
            SitePreviewsSettingsSection.set(.googleCalendar, on: false, in: s)
            readsAtOff = readsOf(gcalURL)
        }
        hoverFresh({ row(gcalItem) }, settle: 0.8)
        wait(2.5)
        run { [self] in
            check(app?.settings.values.servicePreviewsOff == ["googleCalendar"], label("Settings › Site Previews › Google Calendar off is saved"))
            check(tp().thumbnail != .service && !rowLines(row(gcalItem)).contains { $0.hasPrefix("Event") },
                  label("Google Calendar off: the page picture, no line"))
            check(readsOf(gcalURL) == readsAtOff && center.state(account(gcalURL)) == nil, label("Google Calendar off: nothing read or kept"))
            check(center.state(account(outURL)) != nil, label("Outlook's stays on"))
            if let s = app?.settings { SitePreviewsSettingsSection.set(.googleCalendar, on: true, in: s) }
        }
        step { [self] done in waitUntil({ rowLines(row(gcalItem)).contains { $0.hasPrefix("Event") } }, timeout: 8) { done() } }
        run { [self] in check(rowLines(row(gcalItem)).contains { $0.hasPrefix("Event") }, label("back on, the row's line is back")) }

        // MARK: The owner's setup (pageread): Gmail and Google Calendar Favorites, Live Calendar on

        // Gmail and Google Calendar as Favorites (Google's own address forms), Live Calendar on with an Apple Calendar
        // meeting that isn't on the Google page. Open, and active: the Gmail Favorite's card lists its unread mail and
        // the Google Calendar Favorite's card the page's events, never the Mac's. Closed: "Open Gmail" / "Open Google
        // Calendar".
        var gmailFav = "", gcalFav = "", gmailFavURL = "", gcalFavURL = ""
        let unread = [CalPrevFixtures.Mail(id: "18c1a", sender: "Ada Fixture", address: "ada@example.com", subject: "Quarterly numbers",
                                           snippet: "The draft is attached", minutesAgo: 5),
                      CalPrevFixtures.Mail(id: "18c1b", sender: "Bo Fixture", address: "bo@example.com", subject: "Lunch on Friday?",
                                           snippet: "Shall we try the new place", minutesAgo: 40),
                      CalPrevFixtures.Mail(id: "18c1c", sender: "Read Already", address: "read@example.com", subject: "Old news",
                                           snippet: "Nothing new", minutesAgo: 90, unread: false)]
        let appleOnly = CalendarEvent(id: "apple-dentist", title: "Dentist (Apple Calendar)", start: at(25), end: at(55))
        let favEvent = E(id: "ZXZmYXZvcml0ZQ", title: "Roadmap sync", start: at(30), end: at(60))
        let calendarSource = CalendarCenter.shared.source as? SyntheticCalendarSource
        func gmailAccount() -> PreviewAccount { account(gmailFavURL) }
        /// What the provider sees for `a` (pageread diagnostics): each loaded page of its service, and why it does or
        /// doesn't count.
        func pagesSeen(_ a: PreviewAccount) -> String {
            guard let app else { return "-" }
            var out: [String] = []
            for w in app.controllers {
                for (tabID, p) in w.pages {
                    guard let u = p.url?.absoluteString, let s = PreviewService.detect(u), s == a.service else { continue }
                    let tab = w.store.tab(tabID)
                    out.append("\(s.rawValue)@\(PreviewService.accountKey(u)) profile \(tab?.profileID == a.profileID ? "same" : "other(\(tab?.profileID ?? "no tab"))")"
                               + " closed \(p.isClosed) loading \(p.isLoading) shown \(w.shownTabID == tabID)")
                }
            }
            let found = center.pageMail.page(for: a).flatMap { $0.url.map { PreviewService.accountKey($0.absoluteString) } }
            return "[\(out.joined(separator: "; "))] page(for:) \(found ?? "nil") state \(String(describing: center.state(a)))"
        }
        run { [self] in
            guard let fx else { return }
            fx.set(google: googleEvents.filter { $0.id != lunch.id } + [favEvent], gmail: unread)
            PreviewService.fixtureHosts[CalPrevFixtures.gmailHost] = "mail.google.com"
            gmailFavURL = "http://\(CalPrevFixtures.gmailHost):\(fx.port)/mail/u/0/#inbox"
            gcalFavURL = "http://\(CalPrevFixtures.googleHost):\(fx.port)/calendar/u/2/r"
            do {
                try favorite(gmailFavURL, title: "Inbox - Gmail", icon: nil, profile: profile, space: home)
                try favorite(gcalFavURL, title: "Google Calendar", icon: nil, profile: profile, space: home)
            } catch { check(false, label("pageread Favorites (\(error))")) }
            gmailFav = c.store.favorites(ofProfile: profile).first { $0.savedURL == gmailFavURL }?.id ?? ""
            gcalFav = c.store.favorites(ofProfile: profile).first { $0.savedURL == gcalFavURL }?.id ?? ""
            app?.history.recordVisit(profileID: profile, url: gmailFavURL, title: "Inbox - Gmail")
            app?.history.recordVisit(profileID: profile, url: gcalFavURL, title: "Google Calendar")
            calendarSource?.set([appleOnly])
            CalendarCenter.shared.setEnabled(true)
            c.reloadAll(animated: false)
            check(!gmailFav.isEmpty && !gcalFav.isEmpty && tile(gcalFav)?.calendarFace != nil,
                  label("pageread: the Gmail and Google Calendar Favorites; Google Calendar is the Calendar Favorite"))
        }
        wait(1)
        // Closed (never loaded since launch): the cards say to open them, and no Apple Calendar meeting.
        hoverFresh({ tile(gcalFav) }, settle: 1.0)
        run { [self] in
            note(label("pageread closed calendar: \(pagesSeen(account(gcalFavURL)))"))
            check(CalendarCard.shared.panel == nil && tp().thumbnail == .service && model?.state == .needsPage && TestAnchors.frames["svc.openPage"] != nil,
                  label("pageread: the Google Calendar Favorite, not loaded: its card says Open Google Calendar, not Live Calendar's card "
                        + "(Live Calendar card \(CalendarCard.shared.panel != nil), \(String(describing: model?.state)))"))
            check(CalendarCard.shared.model.events.allSatisfy { $0.title != appleOnly.title } || CalendarCard.shared.panel == nil,
                  label("pageread: never the Apple Calendar meeting on the Google Calendar Favorite"))
        }
        capture("pageread-calendar-closed")
        hoverFresh({ tile(gmailFav) }, settle: 1.0)
        run { [self] in
            note(label("pageread closed gmail: \(pagesSeen(gmailAccount()))"))
            check(tp().thumbnail == .service && model?.state == .needsPage && TestAnchors.frames["svc.openPage"] != nil,
                  label("pageread: Gmail not open: its card says Open Gmail (\(String(describing: model?.state)))"))
        }
        // Open the Google Calendar Favorite, then Gmail's (active, shown), as the owner has them.
        run { [self] in
            tp().hide()
            if let it = c.store.item(gcalFav) { c.activate(entry: .favorite(it, c.store.liveTab(forItem: gcalFav))) }
        }
        step { [self] done in waitUntil({ stored(gcalFavURL).contains { $0.title == favEvent.title } }, timeout: 10) { done() } }
        run { [self] in
            if let it = c.store.item(gmailFav) { c.activate(entry: .favorite(it, c.store.liveTab(forItem: gmailFav))) }
        }
        step { [self] done in
            waitUntil({ if case .mail? = center.state(gmailAccount())?.content { return true }; return false }, timeout: 12) { done() }
        }
        hoverFresh({ tile(gmailFav) }, settle: 1.0)
        run { [self] in
            note(label("pageread open gmail: \(pagesSeen(gmailAccount())), reads \(readsOf(gmailFavURL))"))
            let mail: [PreviewMail] = { if case .mail(let m)? = model?.state.content { return m }; return [] }()
            let shownTabItem = shownTab().item
            check(shownTabItem == gmailFav, label("pageread: the Gmail Favorite is the active tab"))
            check(tp().thumbnail == .service && mail.map(\.subject) == ["Quarterly numbers", "Lunch on Friday?"]
                  && TestAnchors.frames["svc.mail.18c1a"] != nil && TestAnchors.frames["svc.openPage"] == nil,
                  label("pageread: Gmail open and active: its card lists the unread messages (\(mail.map(\.subject)), \(String(describing: model?.state)))"))
        }
        capture("pageread-gmail-open")
        hoverFresh({ tile(gcalFav) }, settle: 1.0)
        run { [self] in
            note(label("pageread open calendar: \(pagesSeen(account(gcalFavURL)))"))
            let titles = shown().map(\.title)
            check(CalendarCard.shared.panel == nil && tp().thumbnail == .service && titles.contains(favEvent.title) && !titles.contains(appleOnly.title)
                  && TestAnchors.frames["svc.grid"] != nil,
                  label("pageread: the Google Calendar Favorite, loaded: its card is the page's day (\(titles)), not the Mac's calendar "
                        + "(Live Calendar card \(CalendarCard.shared.panel != nil))"))
        }
        capture("pageread-calendar-open")
        // Gmail closed again: "Open Gmail".
        run { [self] in
            tp().hide()
            if let t = c.store.liveTab(forItem: gmailFav) { c.closeTab(t.id) }
            center.register(center.pageMail)   // forget what was read: only a page can answer now
        }
        wait(1)
        hoverFresh({ tile(gmailFav) }, settle: 1.0)
        run { [self] in
            note(label("pageread gmail closed again: \(pagesSeen(gmailAccount()))"))
            check(tp().thumbnail == .service && model?.state == .needsPage && TestAnchors.frames["svc.openPage"] != nil,
                  label("pageread: Gmail closed: Open Gmail again (\(String(describing: model?.state)))"))
            tp().hide()
            CalendarCenter.shared.setEnabled(false)
            calendarSource?.set([])
        }

        var privateWindow: PrivateWindowController?
        var readsAtPrivate = 0
        step { [self] done in
            guard let app else { return done() }
            load(gcalItem, "http://\(CalPrevFixtures.outlookHost):\(fx?.port ?? 0)/plain.html")
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: gcalURL))
                done()
            }
        }
        wait(2)
        run { [self] in
            center.register(center.pageMail)   // forget what was read: only a page can answer now
            readsAtPrivate = readsOf(gcalURL)
            center.refresh(account(gcalURL), force: true)
        }
        wait(2.5)
        run { [self] in
            check(privateWindow != nil && readsOf(gcalURL) == readsAtPrivate && center.state(account(gcalURL)) == .needsPage,
                  label("a private window's page of the account is never read; the card waits for a normal one (\(String(describing: center.state(account(gcalURL)))))"))
            privateWindow?.closeWindow()
        }
        wait(0.5)
        run { [self] in
            note(label("hovers: \(realHovers) real driver pointer moves, \(postedHovers) posted; card clicks: \(realClicks) real driver clicks, \(postedClicks) posted"))
            check(UIDriverClient.available && postedHovers == 0 && postedClicks == 0 && realClicks >= 4,
                  label("every hover and card click was real driver input (\(postedHovers) posted hovers, \(postedClicks) posted clicks)"))
            restore()
        }
    }
}
#endif
