// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class PageCalendarTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func answer(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func events(_ s: PreviewState?) -> [CalendarEvent] {
        if case .ready(.calendar(let e))? = s { return e }
        XCTFail("not events: \(String(describing: s))")
        return []
    }

    func testTimeRanges() {
        XCTAssertEqual(PageCalendar.timeRange("10am to 10:30am")?.0, 600)
        XCTAssertEqual(PageCalendar.timeRange("10am to 10:30am")?.1, 630)
        XCTAssertEqual(PageCalendar.timeRange("10 to 11pm").map { [$0.0, $0.1] }, [22 * 60, 23 * 60])
        XCTAssertEqual(PageCalendar.timeRange("12pm to 1pm").map { [$0.0, $0.1] }, [12 * 60, 13 * 60])
        XCTAssertEqual(PageCalendar.timeRange("12am to 1am").map { [$0.0, $0.1] }, [0, 60])
        XCTAssertEqual(PageCalendar.timeRange("10:00 AM to 10:30 AM").map { [$0.0, $0.1] }, [600, 630])
        XCTAssertEqual(PageCalendar.timeRange("14:00 – 15:15").map { [$0.0, $0.1] }, [840, 915])
        XCTAssertEqual(PageCalendar.timeRange("9.30 a.m. to 10 a.m.").map { [$0.0, $0.1] }, [570, 600])
        XCTAssertNil(PageCalendar.timeRange("Standup"))
        XCTAssertNil(PageCalendar.timeRange("13pm to 2pm"))
        XCTAssertNil(PageCalendar.timeRange("November 14"))
    }

    func testGoogleChipText() {
        let p = PageCalendar.parse("10am to 10:30am, Standup, Ada Lovelace, Accepted, No location, November 14, 2026",
                                   service: .googleCalendar, day: nil, calendar: cal)
        XCTAssertEqual(p?.title, "Standup")
        XCTAssertEqual(p?.start, at(2026, 11, 14, 10))
        XCTAssertEqual(p?.end, at(2026, 11, 14, 10, 30))
        XCTAssertEqual(p?.response, .accepted)
        XCTAssertEqual(p?.allDay, false)
        // The column's day wins over the text.
        let q = PageCalendar.parse("11pm to 1am, Late deploy, Declined, November 14, 2026", service: .googleCalendar,
                                   day: at(2026, 11, 15), calendar: cal)
        XCTAssertEqual(q?.start, at(2026, 11, 15, 23))
        XCTAssertEqual(q?.end, at(2026, 11, 16, 1))
        XCTAssertEqual(q?.response, .declined)
        let a = PageCalendar.parse("All day, Holiday, November 14, 2026", service: .googleCalendar, day: nil, calendar: cal)
        XCTAssertEqual(a?.allDay, true)
        XCTAssertEqual(a?.title, "Holiday")
        XCTAssertEqual(a?.end, at(2026, 11, 15))
        XCTAssertNil(PageCalendar.parse("Create", service: .googleCalendar, day: at(2026, 11, 14), calendar: cal))
        XCTAssertNil(PageCalendar.parse("10am to 11am, Standup", service: .googleCalendar, day: nil, calendar: cal), "no day")
    }

    func testOutlookLabel() {
        let p = PageCalendar.parse("Design review, 2:00 PM to 3:00 PM, Saturday, November 15, 2026, Microsoft Teams Meeting, Organizer: Grace, Tentative",
                                   service: .outlookCalendar, day: nil, calendar: cal)
        XCTAssertEqual(p?.title, "Design review")
        XCTAssertEqual(p?.start, at(2026, 11, 15, 14))
        XCTAssertEqual(p?.response, .tentative)
        let uk = PageCalendar.parse("Lunch, 12:30 to 13:30, 14 November 2026", service: .outlookCalendar, day: nil, calendar: cal)
        XCTAssertEqual(uk?.start, at(2026, 11, 14, 12, 30))
    }

    func testStateMergesDaysThePageDoesNotShowAndSkipsJunk() {
        let now = at(2026, 11, 14, 9)
        let first = PageCalendar.state(from: answer([
            "gridFound": true, "days": ["2026-11-14", "2026-11-15"],
            "items": [
                ["id": "a1", "label": "10am to 10:30am, Standup, Accepted, November 14, 2026", "day": "2026-11-14",
                 "url": "https://calendar.google.com/calendar/u/0/r/eventedit/a1"],
                ["id": "b2", "label": "2pm to 3pm, Review, https://meet.google.com/abc-defg-hij, November 15, 2026", "day": "2026-11-15"],
                ["id": "", "label": "Create", "day": "2026-11-14"],
            ],
        ]), service: .googleCalendar, now: now, calendar: cal)
        let e1 = events(first)
        XCTAssertEqual(e1.map(\.title), ["Standup", "Review"])
        XCTAssertEqual(e1[0].url?.absoluteString, "https://calendar.google.com/calendar/u/0/r/eventedit/a1")
        XCTAssertEqual(e1[1].link?.service, .meet)
        // Day view of today: today is replaced, tomorrow kept from before.
        let second = PageCalendar.state(from: answer([
            "gridFound": true, "days": ["2026-11-14"],
            "items": [["id": "c3", "label": "11am to 12pm, Planning, November 14, 2026", "day": "2026-11-14"]],
        ]), service: .googleCalendar, now: now, previous: e1, calendar: cal)
        XCTAssertEqual(events(second).map(\.title), ["Planning", "Review"])
        // Not a calendar view, signed out, cancelled.
        XCTAssertNil(PageCalendar.state(from: answer(["gridFound": false, "items": []]), service: .googleCalendar, now: now))
        XCTAssertEqual(PageCalendar.state(from: answer(["signedOut": true]), service: .googleCalendar, now: now), .signedOut)
        XCTAssertNil(PageCalendar.state(from: answer(["cancelled": true]), service: .googleCalendar, now: now))
        XCTAssertNil(PageCalendar.state(from: "nonsense", service: .googleCalendar, now: now))
    }

    func testUpcomingIsTodayAndTomorrowWithoutDeclined() {
        let now = at(2026, 11, 14, 11)
        let ev = [
            CalendarEvent(id: "past", title: "Past", start: at(2026, 11, 14, 9), end: at(2026, 11, 14, 10)),
            CalendarEvent(id: "now", title: "Now", start: at(2026, 11, 14, 10, 30), end: at(2026, 11, 14, 11, 30)),
            CalendarEvent(id: "declined", title: "No", start: at(2026, 11, 14, 12), end: at(2026, 11, 14, 13), response: .declined),
            CalendarEvent(id: "allday2", title: "Trip", start: at(2026, 11, 15), end: at(2026, 11, 16), isAllDay: true),
            CalendarEvent(id: "t9", title: "Tomorrow 9", start: at(2026, 11, 15, 9), end: at(2026, 11, 15, 10)),
            CalendarEvent(id: "later", title: "Monday", start: at(2026, 11, 16, 9), end: at(2026, 11, 16, 10)),
            CalendarEvent(id: "allday1", title: "Holiday", start: at(2026, 11, 14), end: at(2026, 11, 15), isAllDay: true),
        ]
        XCTAssertEqual(PageCalendar.upcoming(ev, now: now, calendar: cal).map(\.id), ["allday1", "now", "allday2", "t9"])
    }

    func testScriptsAndFixtureHosts() {
        XCTAssertNotNil(PageCalendar.script(for: .googleCalendar, token: 3)?.range(of: "var T=3,"))
        XCTAssertNotNil(PageCalendar.script(for: .outlookCalendar))
        XCTAssertNil(PageCalendar.script(for: .gmail))
        XCTAssertEqual(PreviewService.detect("http://calendar.google.calprev.co.uk:8080/calendar/u/0/r"), nil)
        PreviewService.fixtureHosts = ["calendar.google.calprev.co.uk": "calendar.google.com", "outlook.live.calprev.co.uk": "outlook.live.com",
                                       "accounts.google.calprev.co.uk": "accounts.google.com"]
        defer { PreviewService.fixtureHosts = [:] }
        XCTAssertEqual(PreviewService.detect("http://calendar.google.calprev.co.uk:8080/calendar/u/1/r"), .googleCalendar)
        XCTAssertEqual(PreviewService.accountKey("http://calendar.google.calprev.co.uk:8080/calendar/u/1/r"), "u/1")
        XCTAssertEqual(PreviewService.detect("http://outlook.live.calprev.co.uk:8080/calendar/0/view/week"), .outlookCalendar)
        XCTAssertEqual(PreviewService.accountKey("http://outlook.live.calprev.co.uk:8080/calendar/0/view/week"), "live")
        XCTAssertTrue(PreviewService.isSignInPage("http://accounts.google.calprev.co.uk:8080/ServiceLogin"))
        XCTAssertTrue(PreviewService.isSignInPage("https://login.microsoftonline.com/common/oauth2"))
        XCTAssertFalse(PreviewService.isSignInPage("https://calendar.google.com/calendar/u/0/r"))
    }
}
