// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// M08: Google Calendar and Outlook answers read the way Arc read them, and the schedule's Arc rules (no all-day,
/// declined or out-of-office events) whatever the source.
final class CalendarFeedsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private let google = """
    {"kind": "calendar#events", "items": [
      {"id": "standup", "status": "confirmed", "summary": "Standup",
       "start": {"dateTime": "2026-11-11T10:00:00+01:00"}, "end": {"dateTime": "2026-11-11T10:15:00+01:00"},
       "hangoutLink": "https://meet.google.com/abc-defg-hij",
       "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1-555-0100"},
                                          {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"}]},
       "attendees": [{"email": "a@example.com", "responseStatus": "declined"},
                     {"email": "me@example.com", "self": true, "responseStatus": "accepted"}]},
      {"id": "declined", "summary": "Skipped sync", "start": {"dateTime": "2026-11-11T09:30:00Z"},
       "end": {"dateTime": "2026-11-11T10:00:00Z"}, "location": "https://zoom.us/j/123",
       "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "declined"}]},
      {"id": "maybe", "summary": "Maybe", "start": {"dateTime": "2026-11-11T11:00:00.000Z"},
       "end": {"dateTime": "2026-11-11T11:30:00.000Z"}, "description": "Join: https://us02web.zoom.us/j/81234567890",
       "attendees": [{"email": "me@example.com", "self": true, "responseStatus": "tentative"}]},
      {"id": "holiday", "summary": "Holiday", "start": {"date": "2026-11-11"}, "end": {"date": "2026-11-12"}},
      {"id": "ooo", "summary": "Out of office", "eventType": "outOfOffice",
       "start": {"dateTime": "2026-11-11T13:00:00Z"}, "end": {"dateTime": "2026-11-11T17:00:00Z"}},
      {"id": "gone", "status": "cancelled", "start": {"dateTime": "2026-11-11T12:00:00Z"}, "end": {"dateTime": "2026-11-11T12:30:00Z"}},
      {"id": "custom", "summary": "", "start": {"dateTime": "2026-11-11T12:00:00Z"}, "end": {"dateTime": "2026-11-11T12:30:00Z"},
       "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://video.example.com/room/7"}]}},
      {"id": "broken", "summary": "No times"}
    ]}
    """

    func testGoogleEventsReadAsArcDid() throws {
        let events = try XCTUnwrap(CalendarFeeds.google(Data(google.utf8), calendar: utc))
        XCTAssertEqual(events.map { $0.id.components(separatedBy: "@")[0] }, ["standup", "declined", "maybe", "holiday", "ooo", "custom"],
                       "cancelled and malformed items are dropped; the rest are kept and marked")
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id.components(separatedBy: "@")[0], $0) })
        let standup = try XCTUnwrap(byID["standup"])
        XCTAssertEqual(standup.start, CalendarFeeds.rfc3339("2026-11-11T09:00:00Z"))
        XCTAssertEqual(standup.response, .accepted, "the person's own answer, not another attendee's")
        XCTAssertEqual(standup.link, MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet),
                       "the conference's video entry point, not its phone one")
        XCTAssertEqual(byID["declined"]?.response, .declined)
        XCTAssertEqual(byID["maybe"]?.response, .tentative)
        XCTAssertEqual(byID["maybe"]?.link?.service, .zoom, "a call link in the description")
        XCTAssertEqual(byID["holiday"]?.isAllDay, true)
        XCTAssertEqual(byID["holiday"]?.start, utc.date(from: DateComponents(year: 2026, month: 11, day: 11)))
        XCTAssertEqual(byID["ooo"]?.kind, .outOfOffice)
        XCTAssertEqual(byID["custom"]?.title, "Untitled meeting")
        XCTAssertEqual(byID["custom"]?.link?.service, .web, "a conference's own link counts even on an unknown host")
        XCTAssertNil(CalendarFeeds.google(Data("{\"error\": {}}".utf8)))
    }

    func testOutlookEventsReadAsArcDid() throws {
        let json = """
        {"value": [
          {"id": "AAMk1", "subject": "Planning", "isAllDay": false, "isCancelled": false, "showAs": "busy",
           "start": {"dateTime": "2026-11-11T09:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T09:30:00.0000000", "timeZone": "UTC"},
           "responseStatus": {"response": "tentativelyAccepted"},
           "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"}},
          {"id": "AAMk2", "subject": "Declined", "start": {"dateTime": "2026-11-11T10:00:00", "timeZone": "Europe/Vienna"},
           "end": {"dateTime": "2026-11-11T10:30:00", "timeZone": "Europe/Vienna"},
           "responseStatus": {"response": "declined"}, "location": {"displayName": "https://zoom.us/j/9"}},
          {"id": "AAMk3", "subject": "Away", "showAs": "oof", "start": {"dateTime": "2026-11-11T12:00:00", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T13:00:00", "timeZone": "UTC"}},
          {"id": "AAMk4", "subject": "Cancelled", "isCancelled": true, "start": {"dateTime": "2026-11-11T12:00:00", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-11T13:00:00", "timeZone": "UTC"}},
          {"id": "AAMk5", "subject": "Day off", "isAllDay": true, "start": {"dateTime": "2026-11-12T00:00:00", "timeZone": "UTC"},
           "end": {"dateTime": "2026-11-13T00:00:00", "timeZone": "UTC"}}
        ]}
        """
        let events = try XCTUnwrap(CalendarFeeds.outlook(Data(json.utf8), calendar: utc))
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].link?.service, .teams)
        XCTAssertEqual(events[0].response, .tentative)
        XCTAssertEqual(events[0].start, CalendarFeeds.rfc3339("2026-11-11T09:00:00Z"))
        XCTAssertEqual(events[1].start, CalendarFeeds.rfc3339("2026-11-11T09:00:00Z"), "Vienna is UTC+1 in November")
        XCTAssertEqual(events[1].response, .declined)
        XCTAssertEqual(events[2].kind, .outOfOffice)
        XCTAssertEqual(events[3].isAllDay, true)
    }

    func testTheScheduleLeavesOutWhatArcLeftOut() throws {
        let events = try XCTUnwrap(CalendarFeeds.google(Data(google.utf8), calendar: utc))
        let now = try XCTUnwrap(CalendarFeeds.rfc3339("2026-11-11T08:30:00Z"))
        XCTAssertEqual(MeetingSchedule.upcoming(events, now: now, limit: 10).map(\.title), ["Standup", "Maybe", "Untitled meeting"],
                       "no declined, all-day or out-of-office events; tentative ones stay")
        XCTAssertEqual(MeetingSchedule.tileLabel(events, now: now), "in 30m", "the declined 9:30 doesn't count down")
        let atStandup = now.addingTimeInterval(30 * 60)
        XCTAssertEqual(MeetingSchedule.joinTarget(events, now: atStandup)?.title, "Standup")
        XCTAssertNil(MeetingSchedule.promptEvent(events, now: now.addingTimeInterval(59 * 60)),
                     "the declined 9:30 never gets the Join prompt")
    }

    func testTheCountdownAtSeveralOffsets() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let e = [CalendarEvent(id: "m", title: "m", start: t0, end: t0.addingTimeInterval(1800))]
        let cases: [(TimeInterval, String?)] = [(-3661, nil), (-3600, "in 1h"), (-3599, "in 1h"), (-3541, "in 1h"),
                                                 (-3540, "in 59m"), (-45 * 60, "in 45m"), (-61, "in 2m"), (-60, "in 1m"),
                                                 (-1, "in 1m"), (0, "now"), (299, "now"), (300, nil)]
        for (offset, label) in cases {
            XCTAssertEqual(MeetingSchedule.tileLabel(e, now: t0.addingTimeInterval(offset)), label, "at \(offset) s")
        }
    }
}
