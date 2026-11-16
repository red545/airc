// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// calmeet: where Live Calendar's countdown, Join and ⌃⌘J take their meetings from.
final class LiveCalendarSourceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private let reads: (PreviewService) -> Bool = { [.googleCalendar, .outlookCalendar].contains($0) }

    func testAGoogleOrOutlookCalendarFavoriteOrPinnedTabUsesThePages() {
        XCTAssertEqual(LiveCalendarSource.choose(["https://calendar.google.com/calendar/u/0/r"], reads: reads), .pages)
        XCTAssertEqual(LiveCalendarSource.choose(["https://outlook.office.com/calendar/view/day"], reads: reads), .pages)
        XCTAssertEqual(LiveCalendarSource.choose(["https://outlook.live.com/calendar/0/view/week"], reads: reads), .pages)
    }

    func testOnlyCalendarsAircDoesNotReadKeepTheMac() {
        XCTAssertEqual(LiveCalendarSource.choose([], reads: reads), .mac)
        XCTAssertEqual(LiveCalendarSource.choose(["https://calendar.proton.me/u/0/week"], reads: reads), .mac)
        XCTAssertEqual(LiveCalendarSource.choose(["https://app.fastmail.com/calendar/week"], reads: reads), .mac)
        // Gmail is read, but it isn't a calendar.
        XCTAssertEqual(LiveCalendarSource.choose(["https://mail.google.com/mail/u/0/#inbox"], reads: { _ in true }), .mac)
        // A calendar service without a provider isn't read.
        XCTAssertEqual(LiveCalendarSource.choose(["https://calendar.google.com/calendar/u/0/r"], reads: { _ in false }), .mac)
    }

    func testAWebCalendarBesideAnUnreadOneWins() {
        let both = ["https://calendar.proton.me/u/0/week", "https://calendar.google.com/calendar/u/0/r"]
        XCTAssertEqual(LiveCalendarSource.choose(both, reads: reads), .pages)
    }

    func testPagesNeverMergeTheMacsMeetings() {
        let apple = CalendarEvent(id: "apple", title: "Apple standup", start: at(10), end: at(40),
                                  link: MeetingLink(url: URL(string: "https://zoom.us/j/111")!, service: .zoom))
        let page = CalendarEvent(id: "googleCalendar/0/abc", title: "Team sync", start: at(10), end: at(40),
                                 link: MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet))
        let events = LiveCalendarSource.events(.pages, mac: [apple], pages: [[page]])
        XCTAssertEqual(events.map(\.id), ["googleCalendar/0/abc"])
        // The countdown, the Join prompt and ⌃⌘J then name the page's meeting and its Meet link.
        XCTAssertEqual(MeetingSchedule.countdownEvent(events, now: at(0))?.title, "Team sync")
        XCTAssertEqual(MeetingSchedule.promptEvent(events, now: at(9))?.title, "Team sync")
        XCTAssertEqual(MeetingSchedule.joinTarget(events, now: at(0))?.link?.service, .meet)
        // Without a web calendar it's the Mac's alone.
        XCTAssertEqual(LiveCalendarSource.events(.mac, mac: [apple], pages: [[page]]).map(\.id), ["apple"])
    }

    func testAPageNotReadYetGivesNothingNotTheMac() {
        let apple = CalendarEvent(id: "apple", title: "Apple standup", start: at(10), end: at(40))
        XCTAssertEqual(LiveCalendarSource.events(.pages, mac: [apple], pages: []), [])
        XCTAssertNil(MeetingSchedule.joinTarget(LiveCalendarSource.events(.pages, mac: [apple], pages: [[]]), now: at(0)))
    }

    func testAMeetingTwoAccountsShowIsKeptOnceFromTheFirst() {
        let a = CalendarEvent(id: "outlookCalendar/live/1", title: "Review", start: at(30), end: at(60))
        var b = a
        b.id = "googleCalendar/0/1"
        let other = CalendarEvent(id: "googleCalendar/0/2", title: "Lunch", start: at(90), end: at(120))
        XCTAssertEqual(LiveCalendarSource.events(.pages, mac: [], pages: [[a], [b, other]]).map(\.id),
                       ["outlookCalendar/live/1", "googleCalendar/0/2"])
    }

    func testFixtureMeetHostsStandForMeet() {
        let fixture = URL(string: "http://meet.google.calprev.co.uk:8080/abc-defg-hij")!
        XCTAssertNil(MeetingLink.service(of: fixture))
        PreviewService.fixtureHosts = ["meet.google.calprev.co.uk": "meet.google.com"]
        defer { PreviewService.fixtureHosts = [:] }
        XCTAssertEqual(MeetingLink.service(of: fixture), .meet)
        XCTAssertEqual(MeetingLink.find(url: nil, location: nil, notes: "10am to 11am, Team sync, \(fixture.absoluteString), No location")?.url,
                       fixture)
    }
}
