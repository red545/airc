// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class MeetingCalendarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private let meet = MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet)

    private func event(_ id: String, _ start: Double, _ end: Double, link: MeetingLink? = nil, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: at(start), end: at(end), isAllDay: allDay, link: link)
    }

    // MARK: Links

    func testKnownServicesAreFoundInEveryField() {
        let notes = """
            Join with Google Meet: https://meet.google.com/abc-defg-hij
            Or dial: +1 555 0100 PIN: 123#
            """
        XCTAssertEqual(MeetingLink.find(url: nil, location: nil, notes: notes), meet)
        let zoom = MeetingLink.find(url: nil, location: "https://us02web.zoom.us/j/81234567890?pwd=abc.1", notes: nil)
        XCTAssertEqual(zoom?.service, .zoom)
        XCTAssertEqual(zoom?.url.absoluteString, "https://us02web.zoom.us/j/81234567890?pwd=abc.1")
        let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%22Tid%22%7d"
        XCTAssertEqual(MeetingLink.find(url: nil, location: "Microsoft Teams Meeting", notes: "Join: <\(teams)>")?.service, .teams)
        XCTAssertEqual(MeetingLink.find(url: nil, location: nil, notes: "https://teams.live.com/meet/9876543210")?.service, .teams)
        XCTAssertEqual(MeetingLink.find(url: "https://acme.webex.com/acme/j.php?MTID=m123", location: nil, notes: nil)?.service, .webex)
        XCTAssertEqual(MeetingLink.find(url: nil, location: nil, notes: "https://acme.webex.com/meet/jane")?.service, .webex)
    }

    func testAKnownServiceBeatsAPlainLinkAndTheEventURLComesFirst() {
        let found = MeetingLink.find(url: "https://example.com/event/42", location: "Room 4",
                                     notes: "Agenda https://docs.example.com/x then https://zoom.us/j/123")
        XCTAssertEqual(found?.service, .zoom)
        let both = MeetingLink.find(url: "https://zoom.us/j/111", location: "https://meet.google.com/aaa-bbbb-ccc", notes: nil)
        XCTAssertEqual(both?.url.absoluteString, "https://zoom.us/j/111")
    }

    func testPlainHTTPSComesOnlyFromTheURLOrLocation() {
        XCTAssertEqual(MeetingLink.find(url: "https://whereby.com/team", location: nil, notes: nil),
                       MeetingLink(url: URL(string: "https://whereby.com/team")!, service: .web))
        XCTAssertEqual(MeetingLink.find(url: nil, location: "Call: https://around.co/r/x", notes: nil)?.service, .web)
        XCTAssertNil(MeetingLink.find(url: nil, location: "Room 4", notes: "Doc: https://docs.example.com/agenda"))
        XCTAssertNil(MeetingLink.find(url: "http://intranet.example/meeting", location: nil, notes: nil), "http isn't a fallback")
        XCTAssertNil(MeetingLink.find(url: nil, location: nil, notes: nil))
    }

    func testNotMeetingPagesOfTheServicesAreNotCalls() {
        for s in ["https://meet.google.com/", "https://zoom.us/pricing", "https://teams.microsoft.com/v2/",
                  "https://www.webex.com/", "https://calendar.google.com/calendar/r", "mailto:a@b.c"] {
            XCTAssertNil(URL(string: s).flatMap(MeetingLink.service(of:)), s)
        }
    }

    func testLinksAreCleanedUp() {
        let links = MeetingLink.links(in: """
            See (https://zoom.us/j/1?pwd=a&amp;b=2). Also https://www.google.com/url?q=https://meet.google.com/xyz-abcd-efg&sa=D,
            <a href="https://acme.webex.com/meet/bob">x</a>
            """)
        XCTAssertEqual(links.map(\.absoluteString), ["https://zoom.us/j/1?pwd=a&b=2", "https://meet.google.com/xyz-abcd-efg",
                                                     "https://acme.webex.com/meet/bob"])
    }

    // MARK: Calendar Favorite

    func testCalendarFavorites() {
        for s in ["https://calendar.google.com/calendar/u/0/r", "https://outlook.live.com/calendar/0/view/week",
                  "https://outlook.office.com/calendar/", "https://outlook.office365.com/calendar/view/day",
                  "https://calendar.proton.me/u/0/", "https://app.fastmail.com/calendar/", "https://www.fastmail.com/calendar"] {
            XCTAssertTrue(CalendarSites.isCalendarFavorite(s), s)
        }
        for s in ["https://outlook.live.com/mail/0/", "https://mail.google.com/", "https://app.fastmail.com/mail/Inbox",
                  "https://mail.proton.me/", "not a url"] {
            XCTAssertFalse(CalendarSites.isCalendarFavorite(s), s)
        }
    }

    // MARK: Countdown

    func testTheTileCountsDownTheLastHourInWholeMinutesRoundedUp() {
        let e = [event("a", 30, 60)]
        XCTAssertNil(MeetingSchedule.tileLabel([event("a", 61, 90)], now: t0), "more than an hour away")
        XCTAssertEqual(MeetingSchedule.tileLabel([event("a", 60, 90)], now: t0), "in 1h")
        XCTAssertEqual(MeetingSchedule.tileLabel(e, now: t0), "in 30m")
        XCTAssertEqual(MeetingSchedule.tileLabel(e, now: at(25.5)), "in 5m")
        XCTAssertEqual(MeetingSchedule.tileLabel(e, now: at(29.99)), "in 1m")
        XCTAssertEqual(MeetingSchedule.tileLabel(e, now: at(30)), "now")
        XCTAssertEqual(MeetingSchedule.tileLabel(e, now: at(34.9)), "now")
        XCTAssertNil(MeetingSchedule.tileLabel(e, now: at(35)), "five minutes in, the countdown is done")
        XCTAssertNil(MeetingSchedule.tileLabel([event("short", 0, 2)], now: at(2)), "a meeting that ended")
    }

    func testTheTileSkipsAllDayEventsAndFindsTheNextMeeting() {
        let events = [event("holiday", -600, 900, allDay: true), event("later", 50, 80), event("over", -60, -10),
                      event("soon", 10, 20)]
        XCTAssertEqual(MeetingSchedule.countdownEvent(events, now: t0)?.id, "soon")
        XCTAssertEqual(MeetingSchedule.tileLabel(events, now: at(16)), "in 34m", "after soon's five minutes, later")
    }

    func testThePromptNeedsALinkAndShowsAroundTheStart() {
        let e = [event("nolink", 0.5, 30), event("call", 1, 30, link: meet)]
        XCTAssertNil(MeetingSchedule.promptEvent(e, now: at(-0.1)), "more than a minute before")
        XCTAssertEqual(MeetingSchedule.promptEvent(e, now: at(0))?.id, "call")
        XCTAssertEqual(MeetingSchedule.promptLabel(for: e[1], now: at(0.2)), "in 1 min")
        XCTAssertEqual(MeetingSchedule.promptLabel(for: e[1], now: at(1)), "now")
        XCTAssertEqual(MeetingSchedule.promptEvent(e, now: at(5.9))?.id, "call")
        XCTAssertNil(MeetingSchedule.promptEvent(e, now: at(6)))
        XCTAssertNil(MeetingSchedule.promptEvent(e, now: at(0.5), dismissed: ["call"]))
        XCTAssertNil(MeetingSchedule.promptEvent([event("quick", 0, 2, link: meet)], now: at(2)), "it ended")
    }

    func testTheCardListsTheNextDayInOrder() {
        let events = [event("tomorrow-late", 25 * 60, 26 * 60), event("b", 90, 120), event("now", -10, 20),
                      event("done", -60, -1), event("a", 30, 45), event("allday", 0, 1440, allDay: true)]
        XCTAssertEqual(MeetingSchedule.upcoming(events, now: t0).map(\.id), ["now", "a", "b"])
        XCTAssertEqual(MeetingSchedule.upcoming(events, now: t0, limit: 2).map(\.id), ["now", "a"])
    }

    // MARK: Boundaries (one one-shot timer at a time)

    func testTheNextBoundaryIsTheNextLabelChange() {
        let e = [event("a", 120, 150, link: meet)]
        // Two hours out: the next change is when it enters the hour.
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: t0), at(60))
        // Inside the hour, each minute: with 25.5 minutes left the label is "in 26m", and "in 25m" at 25 left.
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: at(94.5)), at(95))
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: at(95)), at(96))
        // The prompt's minute and the start coincide with minute ticks; then "now" ends, then the meeting does.
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: at(119)), at(120))
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: at(120)), at(125))
        XCTAssertEqual(MeetingSchedule.nextBoundary(e, now: at(125)), at(150))
        XCTAssertNil(MeetingSchedule.nextBoundary(e, now: at(150)))
        XCTAssertNil(MeetingSchedule.nextBoundary([], now: t0))
    }

    func testEveryLabelChangeHappensAtABoundary() {
        // Walking the clock second by second, the tile, the prompt and the card never change between two boundaries.
        let events = [event("a", 3, 20, link: meet), event("b", 18, 40), event("c", 70, 71, link: meet),
                      event("d", 24 * 60 + 30, 24 * 60 + 60)]
        func state(_ now: Date) -> String {
            [MeetingSchedule.tileLabel(events, now: now) ?? "-",
             MeetingSchedule.promptEvent(events, now: now).map { $0.id + MeetingSchedule.promptLabel(for: $0, now: now) } ?? "-",
             MeetingSchedule.upcoming(events, now: now).map(\.id).joined()].joined(separator: "|")
        }
        var now = at(-1)
        var boundary = MeetingSchedule.nextBoundary(events, now: now)
        var last = state(now)
        var changes = 0
        while now < at(80) {
            now = now.addingTimeInterval(1)
            let s = state(now)
            if s != last {
                changes += 1
                XCTAssertNotNil(boundary, "changed at \(now.timeIntervalSince(t0)) s with no boundary due")
                if let b = boundary { XCTAssertLessThanOrEqual(b, now, "changed at \(now.timeIntervalSince(t0)) s, before \(b.timeIntervalSince(t0)) s") }
                last = s
            }
            if let b = boundary, b <= now { boundary = MeetingSchedule.nextBoundary(events, now: now) }
        }
        XCTAssertGreaterThan(changes, 60)
    }
}
