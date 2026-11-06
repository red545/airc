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

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, link: MeetingLink? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.link = link
    }
}

/// A video-call link found in an event: Google Meet, Zoom, Microsoft Teams or Webex, else a plain https link.
public struct MeetingLink: Sendable, Equatable {
    public enum Service: String, Sendable, CaseIterable {
        case meet, zoom, teams, webex
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
            if let s = service(of: u) { return MeetingLink(url: u, service: s) }
        }
        if let u = (fromURL + fromLocation).first(where: { $0.scheme == "https" }) { return MeetingLink(url: u, service: .web) }
        return nil
    }

    /// The video service a link belongs to, if it's a meeting link of one we know.
    public static func service(of url: URL) -> Service? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "meet.google.com" { return path.count > 1 ? .meet : nil }
        if on("zoom.us") || on("zoomgov.com") {
            return ["/j/", "/w/", "/s/", "/my/", "/wc/"].contains { path.hasPrefix($0) } ? .zoom : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") ? .teams : nil
        }
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
            return u
        }
    }
}

/// Which Favorite is the Calendar Favorite: a web calendar the person keeps in Favorites.
public enum CalendarSites {
    public static func isCalendarFavorite(_ url: String) -> Bool {
        guard let c = URLComponents(string: url), let host = c.host?.lowercased() else { return false }
        let path = c.path.lowercased()
        switch host {
        case "calendar.google.com", "calendar.proton.me": return true
        case "outlook.live.com", "outlook.office.com", "outlook.office365.com": return path.hasPrefix("/calendar")
        case "app.fastmail.com", "www.fastmail.com", "fastmail.com": return path.hasPrefix("/calendar")
        default: return false
        }
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

    /// Timed events only, in order of start (then end, then ID, so ties are stable).
    static func timed(_ events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { !$0.isAllDay }.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    }

    /// The meeting the tile counts down to: the first that starts within the hour, or started in the last five
    /// minutes and hasn't ended.
    public static func countdownEvent(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        timed(events).first { e in
            let r = e.start.timeIntervalSince(now)
            return r > 0 ? r <= countdownLead : (-r < lateJoin && now < e.end)
        }
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

    /// The meeting for the sidebar's Join prompt: one with a link, from a minute before its start to five minutes
    /// after (or its end). `dismissed` holds the IDs the person closed.
    public static func promptEvent(_ events: [CalendarEvent], now: Date, dismissed: Set<String> = []) -> CalendarEvent? {
        timed(events).first { e in
            guard e.link != nil, !dismissed.contains(e.id) else { return false }
            let r = e.start.timeIntervalSince(now)
            return r <= promptLead && -r < lateJoin && now < e.end
        }
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
    /// prompt's minute, a start, the end of the five late minutes, an end, or a meeting entering the card's day.
    /// nil when nothing is coming.
    public static func nextBoundary(_ events: [CalendarEvent], now: Date) -> Date? {
        var next: Date?
        func consider(_ t: Date) { if t > now, next.map({ t < $0 }) ?? true { next = t } }
        for e in timed(events) where e.end > now || e.start.addingTimeInterval(lateJoin) > now {
            let r = e.start.timeIntervalSince(now)
            consider(e.start.addingTimeInterval(-cardHorizon))
            consider(e.start.addingTimeInterval(-countdownLead))
            consider(e.start.addingTimeInterval(-promptLead))
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
