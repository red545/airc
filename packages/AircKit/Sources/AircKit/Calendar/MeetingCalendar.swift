// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// One meeting from the calendars on this Mac (Arc's Live Calendar, arc_behavior_spec.md §2.3). The app builds these
/// from EventKit; nothing here knows where they came from, so tests and scripted runs use synthetic ones.
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    /// Unique per occurrence (a recurring event's occurrences share EventKit's identifier, not their start).
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The video call to join, if the event has one (MeetingLink.find).
    public var link: MeetingLink?
    /// The person's own answer to the invitation (Arc reads the `self` attendee's `responseStatus`).
    public var response: Response
    /// What sort of event it is (Arc reads Google's `eventType`): only meetings count down or get a Join.
    public var kind: Kind
    /// The event's own page in its web calendar, when the source knows it (calprev: a calendar card's row opens it).
    public var url: URL?

    /// The person's answer to an invitation. `none`: not an invitation (their own event, or the source doesn't say).
    public enum Response: String, Sendable, Equatable {
        case none, accepted, tentative, declined, needsAction
    }

    /// Google's event types (Outlook's "Away" and "Working elsewhere" map to the last two).
    public enum Kind: String, Sendable, Equatable {
        case meeting, focusTime, outOfOffice, workingLocation
    }

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, link: MeetingLink? = nil,
                response: Response = .none, kind: Kind = .meeting, url: URL? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.link = link
        self.response = response
        self.kind = kind
        self.url = url
    }

    /// Whether Live Calendar shows it (Arc's rules): a timed event the person hasn't declined that isn't an
    /// out-of-office or working-location block. Tentative and unanswered invitations count, as in Arc.
    public var isLive: Bool {
        !isAllDay && response != .declined && kind != .outOfOffice && kind != .workingLocation
    }
}

/// A video-call link found in an event: Google Meet, Zoom, Microsoft Teams or Webex, else a plain https link.
public struct MeetingLink: Sendable, Equatable {
    public enum Service: String, Sendable, CaseIterable {
        case meet, zoom, teams, webex
        /// Around (`around.co/r/…`), one of the four call links Arc recognised in an event's text.
        case around
        /// Not a known video service: the event's own URL or a link in its location.
        case web
    }

    public var url: URL
    public var service: Service

    public init(url: URL, service: Service) {
        self.url = url
        self.service = service
    }

    /// The event's call link. A known video service wins wherever it is (the event's URL, then its location, then its
    /// notes, where Google and Outlook put "Join with Google Meet: …"). Without one, an https URL in the event's URL or
    /// location field. Notes alone never give a plain link: they hold agendas and documents, not calls.
    public static func find(url: String?, location: String?, notes: String?) -> MeetingLink? {
        let fromURL = url.map(links(in:)) ?? []
        let fromLocation = location.map(links(in:)) ?? []
        let fromNotes = notes.map(links(in:)) ?? []
        for u in fromURL + fromLocation + fromNotes {
            if let s = service(of: u) { return MeetingLink(url: cleaned(u, service: s), service: s) }
        }
        if let u = (fromURL + fromLocation).first(where: { $0.scheme == "https" }) { return MeetingLink(url: cleaned(u, service: .web), service: .web) }
        return nil
    }

    /// calmeet2: the first call link of a known video service among `urls` (links read from an event's chip or its
    /// detail page, the ones labelled "Join" first), never a plain web link: a detail page links to documents, people
    /// and the calendar itself.
    public static func firstCall(in urls: [String]) -> MeetingLink? {
        for raw in urls {
            for u in links(in: raw) {
                if let s = service(of: u) { return MeetingLink(url: cleaned(u, service: s), service: s) }
            }
        }
        return nil
    }

    /// Query parameters that only track where a click came from. What a call needs stays: Zoom's `pwd`, Teams'
    /// `context`, Webex's `MTID`, Meet's `authuser` (which signed-in account joins).
    static let trackingParameters: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi",
                                                   "mkt_tok", "igshid", "yclid"]
    /// Meet's own tracking, added by Calendar and Gmail ("hangout source", invite and link-medium markers).
    static let meetTracking: Set<String> = ["hs", "ijlm", "pli", "lpl"]

    /// `u` without tracking parameters (utm_*, click IDs; Meet's `hs`), the rest of it untouched.
    public static func cleaned(_ u: URL, service: Service) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false), let items = c.percentEncodedQueryItems else { return u }
        let kept = items.filter { item in
            let n = item.name.lowercased()
            if n.hasPrefix("utm_") || trackingParameters.contains(n) { return false }
            return !(service == .meet && meetTracking.contains(n))
        }
        guard kept.count != items.count else { return u }
        c.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return c.url ?? u
    }

    /// The video service a link belongs to, if it's a meeting link of one we know.
    public static func service(of url: URL) -> Service? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let raw = url.host?.lowercased() else { return nil }
        // The checks' look-alike hosts (PreviewService.fixtureHosts, empty outside them) stand for the real ones.
        let host = PreviewService.fixtureHosts[raw] ?? raw
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com" { return path.count > 1 ? .meet : nil }
        if on("zoom.us") || on("zoomgov.com") {
            return ["/j/", "/w/", "/s/", "/my/", "/wc/"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") ? .teams : nil
        }
        if host == "around.co" || host == "www.around.co" { return path.hasPrefix("/r/") && path.count > 3 ? .around : nil }
        if on("webex.com") {
            return path.count > 1 && (path.contains("/meet/") || path.contains("j.php") || path.contains("/join")
                                      || path.contains("/wbxmjs/") || path.contains("/webappng/")) ? .webex : nil
        }
        return nil
    }

    nonisolated(unsafe) private static let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'{}|\\^`\[\]]+"#, options: [.caseInsensitive])

    /// The http(s) links in a field, in order. Undoes Google's redirect wrapper and HTML's `&amp;`, and drops
    /// punctuation that ends the sentence around a link.
    public static func links(in text: String) -> [URL] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var s = ns.substring(with: m.range).replacingOccurrences(of: "&amp;", with: "&")
            while let last = s.last, ".,;:!?".contains(last) || (last == ")" && !s.contains("(")) { s.removeLast() }
            guard var u = URL(string: s), u.host != nil else { return nil }
            if let host = u.host?.lowercased(), host == "www.google.com" || host == "google.com", u.path == "/url",
               let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
               let inner = URL(string: q), inner.host != nil {
                u = inner
            }
            // Outlook's Safe Links wrapper (`*.safelinks.protection.outlook.com/?url=…`): the link it guards.
            if let host = u.host?.lowercased(), host.hasSuffix(".safelinks.protection.outlook.com"),
               let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
               let inner = URL(string: q), inner.host != nil {
                u = inner
            }
            return u
        }
    }
}

/// Which Favorite is the Calendar Favorite: a web calendar the person keeps in Favorites.
public enum CalendarSites {
    public static func isCalendarFavorite(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let raw = c.host?.lowercased() else { return false }
        // The checks' look-alike hosts (PreviewService.fixtureHosts, empty outside them) stand for the real ones.
        let host = PreviewService.fixtureHosts[raw] ?? raw
        let path = c.path.lowercased()
        switch host {
        case "calendar.google.com", "calendar.proton.me": return true
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com": return path.hasPrefix("/calendar")
        case "app.fastmail.com", "www.fastmail.com", "fastmail.com": return path.hasPrefix("/calendar")
        default: return false
        }
    }

    /// The Calendar Favorite's page for a new event (Arc's hover card "+", which links to Google's event editor), in
    /// the same account (`/u/N/`). nil for calendars without one we know.
    public static func newEventURL(_ favorite: String) -> URL? {
        guard isCalendarFavorite(favorite), let c = URLComponents(string: favorite), let host = c.host?.lowercased() else { return nil }
        switch host {
        case "calendar.google.com": return URL(string: "https://calendar.google.com/calendar/u/\(googleAccount(c.path))/r/eventedit")
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com": return URL(string: "https://\(host)/calendar/0/deeplink/compose")
        default: return nil
        }
    }

    /// The Calendar Favorite's page for one day (a meeting picked in the hover card). nil for calendars without one we
    /// know.
    public static func dayURL(_ favorite: String, day: Date, calendar: Calendar = .current) -> URL? {
        guard isCalendarFavorite(favorite), let c = URLComponents(string: favorite), let host = c.host?.lowercased() else { return nil }
        let d = calendar.dateComponents([.year, .month, .day], from: day)
        guard let y = d.year, let m = d.month, let n = d.day else { return nil }
        switch host {
        case "calendar.google.com": return URL(string: "https://calendar.google.com/calendar/u/\(googleAccount(c.path))/r/day/\(y)/\(m)/\(n)")
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com": return URL(string: "https://\(host)/calendar/0/view/day/\(y)/\(m)/\(n)")
        default: return nil
        }
    }

    /// Google's account index in `/calendar/u/N/…` (0 when there's none).
    private static func googleAccount(_ path: String) -> Int {
        let parts = path.split(separator: "/")
        guard let i = parts.firstIndex(of: "u"), i + 1 < parts.count, let n = Int(parts[i + 1]), n >= 0 else { return 0 }
        return n
    }
}

/// calmeet (owner, 2026-11-15): where Live Calendar's meetings come from (the Calendar Favorite's countdown, its Join,
/// ⌃⌘J and Live Calendar's card). The calendars on this Mac (EventKit) can be another calendar altogether than the web
/// calendar the person keeps in the sidebar, so a web calendar whose page Airc reads wins outright, and the two are never
/// merged.
public enum LiveCalendarSource: String, Sendable, Equatable {
    /// The calendars on this Mac (EventKit): no calendar Favorite or pinned tab Airc reads (none at all, or only
    /// calendars Airc doesn't read, such as Proton or Fastmail).
    case mac
    /// The events read from the web calendars' own pages (Google Calendar, Outlook), in their sidebar items' order.
    /// While no page is loaded, the last ones read; never EventKit's.
    case pages

    /// `calendars`: the saved addresses of the person's calendar Favorites and pinned tabs; `reads`: whether Airc reads
    /// a service's page (it has a provider).
    public static func choose(_ calendars: [String], reads: (PreviewService) -> Bool) -> LiveCalendarSource {
        calendars.contains { url in
            guard let s = PreviewService.detect(url), s.family == .calendar else { return false }
            return reads(s)
        } ? .pages : .mac
    }

    /// The meetings for `source`: EventKit's (`mac`), or the accounts' (`pages`, one list per account, the first
    /// account's first). A meeting two accounts both show (the same title, start and end: an invitation in both) is kept
    /// once, from the first.
    public static func events(_ source: LiveCalendarSource, mac: [CalendarEvent], pages: [[CalendarEvent]]) -> [CalendarEvent] {
        guard source == .pages else { return mac }
        struct Key: Hashable { let title: String, start: Date, end: Date }
        var seen = Set<Key>()
        var out: [CalendarEvent] = []
        for e in pages.joined() where seen.insert(Key(title: e.title, start: e.start, end: e.end)).inserted { out.append(e) }
        return out
    }
}

/// How long before a meeting the sidebar's Join prompt comes (Arc's "Show Meeting Link" times, from the Calendar
/// Favorite's menu).
public enum JoinLead: String, Codable, CaseIterable, Sendable {
    case tenMinutes, fiveMinutes, twoMinutes, onStart

    public var seconds: TimeInterval {
        switch self {
        case .tenMinutes: 600
        case .fiveMinutes: 300
        case .twoMinutes: 120
        case .onStart: 0
        }
    }

    /// Arc's menu titles.
    public var title: String {
        switch self {
        case .tenMinutes: "Ten Minutes Before"
        case .fiveMinutes: "Five Minutes Before"
        case .twoMinutes: "Two Minutes Before"
        case .onStart: "On Start"
        }
    }

    public init(from decoder: Decoder) throws {
        self = JoinLead(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .twoMinutes
    }
}

/// When the countdown, the Join prompt and the hover card show what. All of it is a function of the events and the
/// time, so the app asks again only at `nextBoundary` (one one-shot timer, MEM-6) and when the calendar changes.
public enum MeetingSchedule {
    /// The tile counts down from an hour before a meeting ("in 45m").
    public static let countdownLead: TimeInterval = 60 * 60
    /// The sidebar's "Meeting in 1 min · Join" shows from a minute before.
    public static let promptLead: TimeInterval = 60
    /// After the start, the tile says "now" and the prompt stays, for five minutes (or until the meeting ends).
    public static let lateJoin: TimeInterval = 5 * 60
    /// The hover card lists meetings starting in the next 24 hours.
    public static let cardHorizon: TimeInterval = 24 * 60 * 60
    /// The hover card's Join is the big (primary) one from this long before the start ("a meeting moments away").
    public static let soonJoin: TimeInterval = 10 * 60

    /// The events Live Calendar shows (CalendarEvent.isLive: timed, not declined, not out of office), in order of
    /// start (then end, then ID, so ties are stable).
    static func timed(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter(\.isLive).sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }

    /// The meeting the tile counts down to: the first that starts within the hour, or started in the last five
    /// minutes and hasn't ended.
    public static func countdownEvent(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        timed(events).first { e in
            let r = e.start.timeIntervalSince(now)
            return r > 0 ? r <= countdownLead : (-r < lateJoin && now < e.end)
        }
    }

    /// S03b: the Calendar Favorite's "meeting soon" badge comes this long before the countdown's meeting starts, and
    /// stays while it's on (the five late minutes).
    public static let soonBadge: TimeInterval = 5 * 60

    /// Whether the countdown's meeting is soon (or on now): the tile's countdown then sits on Arc's bright subtitle pill.
    public static func isSoon(_ events: [CalendarEvent], now: Date) -> Bool {
        guard let e = countdownEvent(events, now: now) else { return false }
        return e.start.timeIntervalSince(now) <= soonBadge
    }

    /// The tile's countdown: "in 5m" (minutes rounded up, so "in 1m" until it starts), "in 1h" at exactly an hour,
    /// then "now".
    public static func tileLabel(_ events: [CalendarEvent], now: Date) -> String? {
        guard let e = countdownEvent(events, now: now) else { return nil }
        return label(for: e, now: now)
    }

    public static func label(for e: CalendarEvent, now: Date) -> String {
        let r = e.start.timeIntervalSince(now)
        guard r > 0 else { return "now" }
        let m = Int((r / 60).rounded(.up))
        return m >= 60 ? "in 1h" : "in \(m)m"
    }

    /// The meeting for the sidebar's Join prompt: one with a link, from `lead` before its start (a minute unless the
    /// person chose one of Arc's times, JoinLead) to five minutes after (or its end). `dismissed` holds the IDs the
    /// person closed.
    public static func promptEvent(_ events: [CalendarEvent], now: Date, dismissed: Set<String> = [],
                                   lead: TimeInterval = promptLead) -> CalendarEvent? {
        timed(events).first { e in
            guard e.link != nil, !dismissed.contains(e.id) else { return false }
            let r = e.start.timeIntervalSince(now)
            return r <= lead && -r < lateJoin && now < e.end
        }
    }

    /// ⌃⌘J, Arc's "Open meeting link for your next event": the meeting whose call it joins. The one the Join prompt
    /// shows (even if the person closed the prompt), else one with a link that is on now (the latest to start: the one
    /// you're late for), else the next one with a link starting within a day. nil when there's none.
    public static func joinTarget(_ events: [CalendarEvent], now: Date, lead: TimeInterval = promptLead) -> CalendarEvent? {
        if let e = promptEvent(events, now: now, lead: lead) { return e }
        let linked = timed(events).filter { $0.link != nil && $0.end > now }
        if let on = linked.filter({ $0.start <= now }).last { return on }
        return linked.first { $0.start.timeIntervalSince(now) <= cardHorizon }
    }

    /// "in 1 min" before the start, "now" after it.
    public static func promptLabel(for e: CalendarEvent, now: Date) -> String {
        let r = e.start.timeIntervalSince(now)
        guard r > 0 else { return "now" }
        let m = Int((r / 60).rounded(.up))
        return "in \(m) min"
    }

    /// The hover card's list: meetings not yet over that start within a day, in order, at most `limit`.
    public static func upcoming(_ events: [CalendarEvent], now: Date, limit: Int = 4) -> [CalendarEvent] {
        Array(timed(events).filter { $0.end > now && $0.start.timeIntervalSince(now) <= cardHorizon }.prefix(limit))
    }

    /// The next moment anything above changes: a countdown minute ticking over, a meeting entering the hour, the
    /// prompt's time (`promptLead` before), the card's big Join (`soonJoin` before), a start, the end of the five late minutes, an end, or a meeting entering the card's day.
    /// nil when nothing is coming.
    public static func nextBoundary(_ events: [CalendarEvent], now: Date, promptLead: TimeInterval = promptLead) -> Date? {
        var next: Date?
        func consider(_ t: Date) { if t > now, next.map({ t < $0 }) ?? true { next = t } }
        for e in timed(events) where e.end > now || e.start.addingTimeInterval(lateJoin) > now {
            let r = e.start.timeIntervalSince(now)
            consider(e.start.addingTimeInterval(-cardHorizon))
            consider(e.start.addingTimeInterval(-countdownLead))
            consider(e.start.addingTimeInterval(-promptLead))
            consider(e.start.addingTimeInterval(-soonJoin))
            if r > 0, r <= countdownLead {
                // The label is ceil(r / 60) minutes; it next changes when r reaches the minute below.
                let m = (r / 60).rounded(.up)
                consider(e.start.addingTimeInterval(-(m - 1) * 60))
            }
            consider(e.start)
            consider(e.start.addingTimeInterval(lateJoin))
            consider(e.end)
        }
        return next
    }
}
