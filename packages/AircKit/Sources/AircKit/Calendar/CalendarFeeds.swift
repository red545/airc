// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import Foundation

/// Live Calendar's meetings from a web calendar's own answer, the way Arc read them (M08): Google Calendar's
/// `calendar/v3/calendars/primary/events` list and Microsoft Graph's calendar view. Arc fetched these for the account
/// signed in to the Calendar Favorite; Airc's calendar providers (Previews/CalendarProvider.swift) hand their answers
/// here, and scripted runs serve synthetic ones from loopback. Nothing here talks to the network.
///
/// What Arc kept: timed events (`start.dateTime`; an all-day event has only `start.date`), not cancelled, not declined
/// by the person (`attendees[self].responseStatus`), not an out-of-office block (`eventType`). The call link: the
/// event's video conference (`conferenceData.entryPoints`, then `hangoutLink`; Outlook's `onlineMeeting.joinUrl`), else
/// a Meet, Zoom, Teams, Webex or Around link in its location or description. The schedule (MeetingSchedule) applies
/// the same rules to every source, so a feed keeps all-day and declined events and only marks them.
public enum CalendarFeeds {
    /// Google Calendar API v3 `events` list (`{"items": [...]}`, `singleEvents=true`). Malformed items are skipped;
    /// nil when the data isn't such a list.
    public static func google(_ data: Data, calendar: Calendar = .current) -> [CalendarEvent]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }
        return items.compactMap { googleEvent($0, calendar: calendar) }
    }

    static func googleEvent(_ e: [String: Any], calendar: Calendar) -> CalendarEvent? {
        guard let id = e["id"] as? String, (e["status"] as? String) != "cancelled",
              let start = e["start"] as? [String: Any], let end = e["end"] as? [String: Any] else { return nil }
        let allDay = start["dateTime"] == nil
        guard let s = googleTime(start, calendar: calendar), let en = googleTime(end, calendar: calendar) else { return nil }
        let me = (e["attendees"] as? [[String: Any]])?.first { ($0["self"] as? Bool) == true }
        let response: CalendarEvent.Response = switch (me?["responseStatus"] as? String) ?? "" {
        case "accepted": .accepted
        case "tentative": .tentative
        case "declined": .declined
        case "needsAction": .needsAction
        default: .none
        }
        let kind: CalendarEvent.Kind = switch (e["eventType"] as? String) ?? "" {
        case "outOfOffice": .outOfOffice
        case "focusTime": .focusTime
        case "workingLocation": .workingLocation
        default: .meeting
        }
        var link: MeetingLink?
        let entries = ((e["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]]) ?? []
        if let uri = entries.first(where: { ($0["entryPointType"] as? String) == "video" })?["uri"] as? String {
            link = conference(uri)
        }
        if link == nil, let h = e["hangoutLink"] as? String { link = conference(h) }
        if link == nil {
            link = MeetingLink.find(url: nil, location: e["location"] as? String, notes: e["description"] as? String)
        }
        let title = (e["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled meeting"
        return CalendarEvent(id: "\(id)@\(Int(s.timeIntervalSince1970))", title: title, start: s, end: en,
                             isAllDay: allDay, link: link, response: response, kind: kind)
    }

    /// `{"dateTime": "2026-11-11T10:00:00+01:00"}` or, all day, `{"date": "2026-11-11"}` (that day's local midnight).
    static func googleTime(_ t: [String: Any], calendar: Calendar) -> Date? {
        if let s = t["dateTime"] as? String { return rfc3339(s) }
        guard let d = t["date"] as? String else { return nil }
        let p = d.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// Microsoft Graph `calendarView` (`{"value": [...]}`): `dateTime` without an offset in `timeZone` (UTC unless
    /// the request asked for another). nil when the data isn't such a list.
    public static func outlook(_ data: Data, calendar: Calendar = .current) -> [CalendarEvent]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["value"] as? [[String: Any]] else { return nil }
        return items.compactMap { outlookEvent($0, calendar: calendar) }
    }

    static func outlookEvent(_ e: [String: Any], calendar: Calendar) -> CalendarEvent? {
        guard let id = e["id"] as? String, (e["isCancelled"] as? Bool) != true,
              let s = graphTime(e["start"]), let en = graphTime(e["end"]) else { return nil }
        let response: CalendarEvent.Response = switch ((e["responseStatus"] as? [String: Any])?["response"] as? String) ?? "" {
        case "accepted": .accepted
        case "tentativelyAccepted": .tentative
        case "declined": .declined
        case "notResponded": .needsAction
        default: .none   // "organizer", "none"
        }
        let kind: CalendarEvent.Kind = switch (e["showAs"] as? String) ?? "" {
        case "oof": .outOfOffice
        case "workingElsewhere": .workingLocation
        default: .meeting
        }
        var link = ((e["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String).flatMap(conference)
        if link == nil, let u = e["onlineMeetingUrl"] as? String { link = conference(u) }
        if link == nil {
            let location = (e["location"] as? [String: Any])?["displayName"] as? String
            link = MeetingLink.find(url: nil, location: location, notes: e["bodyPreview"] as? String)
        }
        let title = (e["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled meeting"
        return CalendarEvent(id: "\(id)@\(Int(s.timeIntervalSince1970))", title: title, start: s, end: en,
                             isAllDay: (e["isAllDay"] as? Bool) == true, link: link, response: response, kind: kind)
    }

    static func graphTime(_ v: Any?) -> Date? {
        guard let t = v as? [String: Any], let s = t["dateTime"] as? String else { return nil }
        let zone = (t["timeZone"] as? String).flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        // "2026-11-11T09:00:00.0000000": seconds precision is enough for a meeting.
        let base = String(s.prefix(19))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: base)
    }

    /// RFC 3339 with or without fractional seconds.
    static func rfc3339(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// A conference's own join link: a known service's, else any http(s) link (the conference says it's the call).
    static func conference(_ s: String) -> MeetingLink? {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else {
            return nil
        }
        return MeetingLink(url: u, service: MeetingLink.service(of: u) ?? .web)
    }
}
