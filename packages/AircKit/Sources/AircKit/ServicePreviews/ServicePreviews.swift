// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Arc's service previews (arc_behavior_spec.md §2.3; resources.arc.net "Previews: Glance Top Sites", arc.net's
/// integration pages): resting the pointer on a pinned tab or Favorite of one of these sites shows what's there, not
/// a picture of the page. Mail shows unread messages and "+" for a new one; a calendar shows the day's meetings with
/// Join; Notion, Confluence, Figma and Linear show the pages recently visited there and "+" for a new one. GitHub's
/// preview is left out: Arc retired it (2024 release notes).
///
/// Everything here is model: which site a URL is, whose account it is, what each card says in each state, and the
/// timeline's layout. Where the content comes from (an account, the profile's own history) is the app's (Previews/).
public enum PreviewService: String, CaseIterable, Codable, Sendable {
    case gmail, outlookMail, googleCalendar, outlookCalendar, notion, confluence, figma, linear

    public enum Family: String, Sendable { case mail, calendar, recents }

    public var family: Family {
        switch self {
        case .gmail, .outlookMail: .mail
        case .googleCalendar, .outlookCalendar: .calendar
        case .notion, .confluence, .figma, .linear: .recents
        }
    }

    public var name: String {
        switch self {
        case .gmail: "Gmail"
        case .outlookMail: "Outlook"
        case .googleCalendar: "Google Calendar"
        case .outlookCalendar: "Outlook Calendar"
        case .notion: "Notion"
        case .confluence: "Confluence"
        case .figma: "Figma"
        case .linear: "Linear"
        }
    }

    /// What Arc's Settings → General → Previews says each one shows ("Gmail: Unread emails").
    public var settingsDetail: String {
        switch family {
        case .mail: "Unread emails"
        case .calendar: "Today's events"
        case .recents: "Recent pages"
        }
    }

    /// The card's header (Arc 1.171: "Unread", "Upcoming", "Recents").
    public var header: String {
        switch family {
        case .mail: "Unread"
        case .calendar: "Upcoming"
        case .recents: "Recents"
        }
    }

    /// What an empty card says (Arc's own words). A calendar with nothing on shows its empty hours instead.
    public var emptyText: String? {
        switch self {
        case .gmail, .outlookMail: "No unread emails, you can exhale!"
        case .notion: "Recent Notion docs appear here."
        case .confluence: "Recent Confluence pages appear here."
        case .figma: "Recent Figma files appear here."
        case .linear: "Recent Linear projects and issues appear here."
        case .googleCalendar, .outlookCalendar: nil
        }
    }

    /// The card's "+" (its tooltip; Arc's labels).
    public var actionTitle: String {
        switch self {
        case .gmail, .outlookMail: "New Email"
        case .googleCalendar, .outlookCalendar: "New Event"
        case .notion, .confluence: "New Page"
        case .figma: "New File"
        case .linear: "New Issue"
        }
    }

    /// A signed-out card's text and button (Arc's words). Recent pages come from the profile's history: no sign-in.
    public var signInText: String? {
        switch family {
        case .mail: "Sign in to your Email to see messages at a glance."
        case .calendar: "See upcoming meetings and join video calls instantly with the Calendar Preview."
        case .recents: nil
        }
    }

    public var signInButton: String? {
        switch family {
        case .mail: "Sign In"
        case .calendar: "Connect Calendar"
        case .recents: nil
        }
    }

    /// The card's content needs an account (mail and calendars); recent pages don't.
    public var needsAccount: Bool { family != .recents }

    /// The service a page belongs to, if it's one with a preview. Only http(s) pages; "www." is ignored. Notion
    /// Calendar (calendar.notion.so) isn't Notion's documents, and a Confluence page is an Atlassian site's /wiki.
    public static func detect(_ url: String) -> PreviewService? {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = c.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = c.path.lowercased()
        switch host {
        case "mail.google.com": return path.hasPrefix("/mail") || path.isEmpty || path == "/" ? .gmail : nil
        case "calendar.google.com": return .googleCalendar
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com":
            if path.hasPrefix("/calendar") { return .outlookCalendar }
            return path.hasPrefix("/mail") || path.isEmpty || path == "/" ? .outlookMail : nil
        case "notion.so", "notion.com": return .notion
        case "figma.com": return .figma
        case "linear.app": return .linear
        default:
            return host.hasSuffix(".atlassian.net") && (path == "/wiki" || path.hasPrefix("/wiki/")) ? .confluence : nil
        }
    }

    /// Whose account a page is, within its profile: Google's `/u/N/` (or `authuser=N`), the Nth account signed in there;
    /// Outlook's consumer or work host; an Atlassian site. Pages of one service in one profile with different keys are
    /// different accounts and never share a card. Recent pages are the profile's own: one key.
    public static func accountKey(_ url: String) -> String {
        guard let service = detect(url), let c = URLComponents(string: url) else { return "" }
        let host = c.host?.lowercased() ?? ""
        switch service {
        case .gmail, .googleCalendar:
            let parts = c.path.split(separator: "/")
            if let i = parts.firstIndex(where: { $0 == "u" || $0 == "b" }), i + 1 < parts.count, let n = Int(parts[i + 1]), n >= 0 {
                return "u/\(n)"
            }
            if let a = c.queryItems?.first(where: { $0.name == "authuser" })?.value, let n = Int(a), n >= 0 { return "u/\(n)" }
            return "u/0"
        case .outlookMail, .outlookCalendar:
            return host == "outlook.live.com" ? "live" : "work"
        case .confluence:
            return host
        case .notion, .figma, .linear:
            return "history"
        }
    }

    /// The page for the card's "+" in the same account (Arc's links): Gmail's compose in `/u/N/`, Outlook's compose
    /// deep links, Google Calendar's event editor, notion.so/new, linear.app/new, figma.com/new, a Confluence site's new
    /// page.
    public static func actionURL(for pageURL: String) -> URL? {
        guard let service = detect(pageURL), let c = URLComponents(string: pageURL), let host = c.host?.lowercased() else { return nil }
        let key = accountKey(pageURL)
        let n = key.hasPrefix("u/") ? String(key.dropFirst(2)) : "0"
        switch service {
        case .gmail: return URL(string: "https://mail.google.com/mail/u/\(n)/#inbox?compose=new")
        case .googleCalendar: return URL(string: "https://calendar.google.com/calendar/u/\(n)/r/eventedit")
        case .outlookMail: return URL(string: "https://\(host)/mail/0/deeplink/compose")
        case .outlookCalendar: return URL(string: "https://\(host)/calendar/0/deeplink/compose")
        case .notion: return URL(string: "https://www.notion.so/new")
        case .linear: return URL(string: "https://linear.app/new")
        case .figma: return URL(string: "https://www.figma.com/new")
        case .confluence: return URL(string: "https://\(host)/wiki/create-content/page")
        }
    }

    /// For recent pages: a page of this service from the profile's history. The service's own home and sign-in pages
    /// count (Arc's list showed whatever was visited there).
    public func owns(_ url: String) -> Bool { Self.detect(url) == self }
}

/// One account's card: a service, in a profile, under one account key (PreviewService.accountKey).
public struct PreviewAccount: Hashable, Codable, Sendable, CustomStringConvertible {
    public var service: PreviewService
    public var profileID: String
    public var key: String

    public init(service: PreviewService, profileID: String, key: String) {
        self.service = service
        self.profileID = profileID
        self.key = key
    }

    /// The account of a page in `profileID`; nil when the page has no preview.
    public init?(url: String, profileID: String) {
        guard let s = PreviewService.detect(url) else { return nil }
        self.init(service: s, profileID: profileID, key: PreviewService.accountKey(url))
    }

    public var description: String { "\(service.rawValue)@\(key) (\(profileID))" }
}

/// An unread message on a mail card.
public struct PreviewMail: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var sender: String
    /// The sender's address, when the account gives it (Peek Email matches it to the page's site).
    public var senderAddress: String?
    public var subject: String
    public var snippet: String
    public var date: Date
    /// The message's own page in the mail site, when known (a row opens it).
    public var url: String?
    /// More of the text than the snippet, when the account gives it (Peek Email looks for a code in it).
    public var body: String?

    public init(id: String, sender: String, senderAddress: String? = nil, subject: String, snippet: String, date: Date,
                url: String? = nil, body: String? = nil) {
        self.id = id
        self.sender = sender
        self.senderAddress = senderAddress
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.url = url
        self.body = body
    }
}

/// A recently visited page on a recents card.
public struct PreviewPage: Hashable, Codable, Sendable, Identifiable {
    public var url: String
    public var title: String
    public var date: Date
    public var id: String { url }

    public init(url: String, title: String, date: Date) {
        self.url = url
        self.title = title
        self.date = date
    }
}

/// What a card lists.
public enum PreviewContent: Equatable, Sendable {
    case mail([PreviewMail])
    case calendar([CalendarEvent])
    case recents([PreviewPage])

    public var isEmpty: Bool {
        switch self {
        case .mail(let m): m.isEmpty
        case .calendar(let e): e.isEmpty
        case .recents(let p): p.isEmpty
        }
    }
}

/// The states a card can be in. `failed` keeps what the card showed before, if anything, so a moment offline doesn't
/// blank it (Arc: "having trouble getting new data, but will try again soon").
public enum PreviewState: Equatable, Sendable {
    case loading
    case signedOut
    /// The account's sign-in ran out (Arc: "You were signed out of …"): sign in again or remove it.
    case expired
    case ready(PreviewContent)
    case failed(stale: PreviewContent?)

    public var content: PreviewContent? {
        switch self {
        case .ready(let c): c
        case .failed(let c): c
        default: nil
        }
    }
}

/// The last state of each account's card, in memory only, under its exact account: never shown for another account,
/// service or profile. Bounded (least recently stored go first) and forgotten per profile.
public struct PreviewCache: Sendable {
    public struct Entry: Equatable, Sendable {
        public var state: PreviewState
        public var at: Date
    }

    public static let limit = 32
    private var entries: [PreviewAccount: Entry] = [:]
    private var order: [PreviewAccount] = []

    public init() {}

    public func entry(_ a: PreviewAccount) -> Entry? { entries[a] }
    public var count: Int { entries.count }
    public var accounts: [PreviewAccount] { order }

    /// Keeps `state` for `a`. Loading over content keeps the content (it's being refreshed); a failure keeps the last
    /// content as stale; signed out and expired drop it (nothing of an account shows once it's signed out).
    public mutating func store(_ state: PreviewState, for a: PreviewAccount, at now: Date) {
        let previous = entries[a]?.state.content
        let kept: PreviewState
        switch state {
        case .loading: kept = previous.map { .ready($0) } ?? .loading
        case .failed(let stale): kept = .failed(stale: stale ?? previous)
        default: kept = state
        }
        // A refresh that's still loading doesn't count as fresh.
        let at = state == .loading ? (entries[a]?.at ?? .distantPast) : now
        entries[a] = Entry(state: kept, at: at)
        order.removeAll { $0 == a }
        order.append(a)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    /// Whether `a`'s card should ask its source again: never asked, or asked more than `interval` ago.
    public func isStale(_ a: PreviewAccount, now: Date, interval: TimeInterval) -> Bool {
        guard let e = entries[a] else { return true }
        return now.timeIntervalSince(e.at) >= interval
    }

    public mutating func forget(_ a: PreviewAccount) {
        entries[a] = nil
        order.removeAll { $0 == a }
    }

    /// A profile deleted or its browsing data cleared.
    public mutating func forget(profileID: String) {
        for a in order where a.profileID == profileID { entries[a] = nil }
        order.removeAll { $0.profileID == profileID }
    }

    public mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

/// How old something is, as the cards say it.
public enum PreviewTime {
    /// A mail row's age (Arc: "22h", "1d"): "now", "5m", "22h", "3d", "2w".
    public static func mailAge(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d" }
        return "\(Int(s / (7 * 86_400)))w"
    }

    /// A recent page's age (Arc: "Just now", "8 minutes ago").
    public static func pageAge(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        func ago(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if s < 60 { return "Just now" }
        if s < 3600 { return ago(Int(s / 60), "minute") }
        if s < 86_400 { return ago(Int(s / 3600), "hour") }
        if s < 7 * 86_400 { return ago(Int(s / 86_400), "day") }
        if s < 30 * 86_400 { return ago(Int(s / (7 * 86_400)), "week") }
        return ago(max(1, Int(s / (30 * 86_400))), "month")
    }
}

/// The line under a pinned mail or calendar row (Arc: "Mail · 1 Recent", "Calendar · Event in 9m"), from its card's
/// content. Arc 1.171's strings: "1 Recent", "… Recent", "Several Recent"; "Event in …", "Event began … m ago",
/// "Event right now", "Event at …". When "Several" starts is not in them: Airc says it from 10.
public enum PreviewStatus {
    public static let several = 10

    /// Unread mail: "1 Recent", "4 Recent", "Several Recent"; nothing when there's none.
    public static func mail(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 Recent"
        case ..<several: "\(count) Recent"
        default: "Several Recent"
        }
    }

    /// The next meeting: "Event right now" in its first minute, "Event began 2m ago" for the five minutes after its start
    /// (MeetingSchedule.lateJoin), "Event in 9m" within the hour, "Event at 3:00 PM" later today (`time` formats it);
    /// nothing else. All-day events don't count.
    public static func calendar(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current,
                                time: (Date) -> String) -> String? {
        let timed = events.filter { !$0.isAllDay && $0.end > now }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        if let on = timed.last(where: { $0.start <= now && now.timeIntervalSince($0.start) < MeetingSchedule.lateJoin }) {
            let m = Int(now.timeIntervalSince(on.start) / 60)
            return m < 1 ? "Event right now" : "Event began \(m)m ago"
        }
        guard let next = timed.first(where: { $0.start > now }) else { return nil }
        let r = next.start.timeIntervalSince(now)
        if r <= 3600 { return "Event in \(Int((r / 60).rounded(.up)))m" }
        return calendar.isDate(next.start, inSameDayAs: now) ? "Event at \(time(next.start))" : nil
    }

    /// When the calendar line next changes (a minute ticking over, a meeting entering the hour, starting, or its five
    /// minutes ending); nil when nothing is coming today.
    public static func nextChange(_ events: [CalendarEvent], now: Date) -> Date? {
        var next: Date?
        func consider(_ t: Date) { if t > now, next.map({ t < $0 }) ?? true { next = t } }
        for e in events where !e.isAllDay && e.end > now {
            let r = e.start.timeIntervalSince(now)
            if r > 0 {
                consider(e.start.addingTimeInterval(-3600))
                consider(e.start.addingTimeInterval(-(((r / 60).rounded(.up)) - 1) * 60))
            } else if -r < MeetingSchedule.lateJoin {
                consider(e.start.addingTimeInterval((((-r) / 60).rounded(.down) + 1) * 60))
            }
            consider(e.start)
            consider(e.start.addingTimeInterval(MeetingSchedule.lateJoin))
            consider(e.end)
        }
        return next
    }
}

/// The calendar card's day (Arc's preview: an hour grid from the current hour, the meetings as blocks, a line at now).
public enum PreviewTimeline {
    /// Arc's card shows about six hours at once; the rest of the day scrolls.
    public static let visibleHours = 6

    /// From the start of the current local hour to the end of the day (at least `visibleHours`). Hours are the
    /// calendar's (its time zone): in a zone half an hour off UTC they start at :30 UTC.
    public static func window(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let dayEnd = calendar.dateInterval(of: .day, for: now)?.end ?? start.addingTimeInterval(86_400)
        let minEnd = start.addingTimeInterval(TimeInterval(visibleHours) * 3600)
        return DateInterval(start: start, end: max(dayEnd, minEnd))
    }

    /// The hours to label, in the calendar's time zone ("2 PM").
    public static func hours(in w: DateInterval, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var t = w.start
        while t < w.end {
            out.append(t)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: t) else { break }
            t = next
        }
        return out
    }

    public struct Block: Equatable, Sendable {
        public var event: CalendarEvent
        /// Side by side with the events it overlaps: its column and how many there are.
        public var column: Int
        public var columns: Int
    }

    /// The timed events that show in `w`, each in a column beside the ones it overlaps (a cluster of overlapping
    /// events shares its columns). All-day events are left out: the card lists those above the hours.
    public static func layout(_ events: [CalendarEvent], in w: DateInterval) -> [Block] {
        let shown = events.filter { !$0.isAllDay && $0.end > w.start && $0.start < w.end }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        var out: [Block] = []
        var cluster: [(CalendarEvent, Int)] = []
        var clusterEnd = Date.distantPast
        var columnEnds: [Date] = []
        func flush() {
            let n = max(1, columnEnds.count)
            out += cluster.map { Block(event: $0.0, column: $0.1, columns: n) }
            cluster = []
            columnEnds = []
        }
        for e in shown {
            if e.start >= clusterEnd { flush() }
            // The first column free by this start, else a new one.
            let col = columnEnds.firstIndex { $0 <= e.start } ?? columnEnds.count
            if col == columnEnds.count { columnEnds.append(e.end) } else { columnEnds[col] = e.end }
            cluster.append((e, col))
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return out
    }
}

/// Arc's "Peek Email…" (⌘E in Arc 1.171's menu): on a site that just emailed a sign-in code or link, the code or the
/// link from the newest such message in your mail preview. From Arc's types (PeekedEmailAuthResult: a code or a URL;
/// EmailPeeking.authCodeFound / authCodePasteFailed): the code goes into the page, the link opens.
public enum SignInMail {
    public enum Found: Equatable, Sendable {
        case code(String)
        case link(URL)
    }

    /// Only messages this recent count: a code from yesterday is spent.
    public static let maxAge: TimeInterval = 15 * 60

    /// The newest message from the last `maxAge` that is about `host`'s site (its registrable domain in the sender's
    /// address, or the site's name in the sender, subject or text) and carries a code or a sign-in link of that site.
    public static func find(in mail: [PreviewMail], host: String, now: Date, maxAge: TimeInterval = maxAge,
                            suffixes: PublicSuffixList = .shared) -> Found? {
        let h = host.lowercased()
        let site = suffixes.registrableDomain(h) ?? h
        let label = String(site.split(separator: ".").first ?? "")
        for m in mail.sorted(by: { $0.date > $1.date }) {
            let age = now.timeIntervalSince(m.date)
            guard age >= -60, age <= maxAge else { continue }
            let text = [m.subject, m.snippet, m.body ?? ""].joined(separator: "\n")
            let fromSite = m.senderAddress.flatMap { $0.split(separator: "@").last.map(String.init) }
                .map { (suffixes.registrableDomain($0.lowercased()) ?? $0.lowercased()) == site } ?? false
            let named = label.count >= 3 && [m.sender, m.subject, text].contains { mentions($0, label) }
            guard fromSite || named else { continue }
            if let c = code(in: text) { return .code(c) }
            if let u = link(in: text, site: site, suffixes: suffixes) { return .link(u) }
        }
        return nil
    }

    static func mentions(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    nonisolated(unsafe) private static let keyword = try! NSRegularExpression(
        pattern: #"\b(code|passcode|verification|verify|one[- ]time|otp|pin|sign[- ]?in|log[- ]?in|security|confirm)"#,
        options: [.caseInsensitive])
    /// 4–8 digits (also "123 456" and "123-456"), or 6–8 capitals and digits with at least two digits.
    nonisolated(unsafe) private static let token = try! NSRegularExpression(
        pattern: #"(?<![\w-])(\d{3,4}[ -]\d{3,4}|\d{4,8}|(?=(?:[A-Z]*\d){2})[A-Z0-9]{6,8})(?![\w-])"#)

    /// The code near a word like "code" or "verification" (within 60 characters), digits joined.
    public static func code(in text: String) -> String? {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        let words = keyword.matches(in: text, range: all).map(\.range)
        guard !words.isEmpty else { return nil }
        for m in token.matches(in: text, range: all) {
            let r = m.range(at: 1)
            let near = words.contains { w in
                let gap = w.location > r.location ? w.location - (r.location + r.length) : r.location - (w.location + w.length)
                return gap <= 60
            }
            guard near else { continue }
            let t = ns.substring(with: r).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            // A year is not a code.
            if t.count == 4, let y = Int(t), (1900...2100).contains(y) { continue }
            return t
        }
        return nil
    }

    /// An https link of the site itself that signs in (login, sign-in, verify, magic, auth, token or confirm in it).
    static func link(in text: String, site: String, suffixes: PublicSuffixList) -> URL? {
        MeetingLink.links(in: text).first { u in
            guard u.scheme == "https", let h = u.host?.lowercased(), (suffixes.registrableDomain(h) ?? h) == site else { return false }
            let s = (u.path + "?" + (u.query ?? "")).lowercased()
            return ["login", "signin", "sign-in", "sign_in", "verify", "magic", "auth", "token", "confirm"].contains { s.contains($0) }
        }
    }
}
