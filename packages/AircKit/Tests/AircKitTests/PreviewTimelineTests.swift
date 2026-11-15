// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// calgrid: the calendar card's hour grid (Arc 1.171's CalendarLayout).
final class PreviewTimelineTests: XCTestCase {
    /// 2027-01-15 08:00:00 UTC (a Friday).
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    private func zone(_ id: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: id)!
        return c
    }
    private func e(_ id: String, _ s: Double, _ end: Double, allDay: Bool = false, declined: Bool = false,
                   link: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: at(s), end: at(end), isAllDay: allDay,
                      link: link ? MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet) : nil,
                      response: declined ? .declined : .none)
    }
    private func ids(_ events: [CalendarEvent]) -> [String] { events.map(\.id) }

    // MARK: The hours

    func testOpensOnArcsSixHoursFromAQuarterHourBeforeNow() {
        let now = at(17)   // 08:17 UTC
        let v = PreviewTimeline.visible(now: now)
        XCTAssertEqual(v.start, at(2), "Arc: now - 900 s")
        XCTAssertEqual(v.duration, 6 * 3600, "Arc: + 21600 s")
        let utc = zone("UTC")
        let w = PreviewTimeline.window(now: now, calendar: utc)
        XCTAssertEqual(w.start, at(-8 * 60), "the grid scrolls back to midnight")
        XCTAssertEqual(w.end, at(16 * 60), "and on to the end of the day")
        XCTAssertEqual(PreviewTimeline.hours(in: w, calendar: utc).count, 24)
        XCTAssertEqual(PreviewTimeline.offset(of: v.start, in: w, hourHeight: 40), (8 * 60 + 2) / 60 * 40, accuracy: 0.001)
    }

    func testLateInTheDayTheGridRunsPastMidnight() {
        let utc = zone("UTC")
        let late = at(14 * 60 + 10)   // 22:10
        let w = PreviewTimeline.window(now: late, calendar: utc)
        XCTAssertEqual(w.start, at(-8 * 60))
        XCTAssertEqual(w.end, at(20 * 60), "six hours from 21:55 end at 03:55; the grid ends on the next whole hour, 04:00")
        let hours = PreviewTimeline.hours(in: w, calendar: utc)
        XCTAssertEqual(hours.count, 28)
        XCTAssertTrue(hours.contains(at(16 * 60)), "a line at midnight")
        // Just after midnight the grid begins in the last hour of yesterday, so the quarter hour before now shows.
        let early = PreviewTimeline.window(now: at(16 * 60 + 5), calendar: utc)   // 00:05
        XCTAssertEqual(early.start, at(15 * 60), "23:00")
        XCTAssertEqual(early.end, at(40 * 60), "the end of that day")
        // An hour exactly on the window's end isn't rounded up a whole hour more.
        XCTAssertEqual(PreviewTimeline.window(now: at(14 * 60 + 15), calendar: utc).end, at(20 * 60), "22:15 + 5:45 = 04:00")
    }

    func testHoursInAZoneHalfAnHourOffUTC() {
        let india = zone("Asia/Kolkata")   // UTC+5:30: 08:17 UTC is 13:47 there
        let w = PreviewTimeline.window(now: at(17), calendar: india)
        XCTAssertEqual(w.start, at(-13 * 60 - 30), "midnight in India is 18:30 UTC")
        let hours = PreviewTimeline.hours(in: w, calendar: india)
        XCTAssertTrue(hours.allSatisfy { Int($0.timeIntervalSince1970) % 3600 == 1800 }, "the lines fall at :30 UTC")
    }

    // MARK: Events side by side

    func testOverlappingEventsShareColumnsPerCluster() {
        let w = DateInterval(start: t0, duration: 6 * 3600)
        let blocks = PreviewTimeline.layout([
            e("standup", 0, 30), e("1:1", 15, 45), e("review", 30, 60),   // one cluster, two columns
            e("lunch", 120, 180),                                          // alone
            e("a", 200, 260), e("b", 210, 230), e("c", 220, 240),          // three at once
            e("holiday", -600, 900, allDay: true),                         // all day: not a block
            e("yesterday", -300, -200),                                    // before the window
            e("skipped", 120, 150, declined: true),                        // declined: not shown at all
        ], in: w)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.event.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["standup", "1:1", "review", "lunch", "a", "b", "c"])
        XCTAssertEqual(byID["standup"]?.column, 0)
        XCTAssertEqual(byID["1:1"]?.column, 1)
        XCTAssertEqual(byID["review"]?.column, 0, "standup's column is free again at 30")
        XCTAssertEqual(byID["standup"]?.columns, 2)
        XCTAssertEqual(byID["review"]?.columns, 2, "the whole cluster shares its width")
        XCTAssertEqual(byID["lunch"]?.columns, 1, "the declined lunch-time event doesn't squeeze lunch")
        XCTAssertEqual(byID["lunch"]?.column, 0)
        XCTAssertEqual(["a", "b", "c"].map { byID[$0]?.column }, [0, 1, 2])
        XCTAssertEqual(["a", "b", "c"].map { byID[$0]?.columns }, [3, 3, 3])
    }

    func testBlocksAreClippedToTheGrid() {
        let w = DateInterval(start: t0, duration: 4 * 3600)
        let blocks = PreviewTimeline.layout([e("night", -120, 30), e("late", 200, 400)], in: w)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.event.id, $0) })
        XCTAssertEqual(byID["night"]?.start, t0, "an event from before the grid starts at its top")
        XCTAssertEqual(byID["night"]?.event.start, at(-120), "the event itself keeps its times")
        XCTAssertEqual(byID["late"]?.end, w.end, "one past the end stops at the bottom")
    }

    // MARK: All day

    func testAllDayEventsGoInTheStrip() {
        let now = at(17)
        let utc = zone("UTC")
        let events = [
            e("holiday", -8 * 60, 16 * 60, allDay: true),        // today
            e("conference", -32 * 60, 40 * 60, allDay: true),    // yesterday to tomorrow
            e("tomorrow", 16 * 60, 40 * 60, allDay: true),       // tomorrow only
            e("yesterday", -32 * 60, -8 * 60, allDay: true),     // over
            e("skipped", -8 * 60, 16 * 60, allDay: true, declined: true),
            e("standup", 30, 45),
        ]
        XCTAssertEqual(ids(PreviewTimeline.allDay(events, now: now, calendar: utc)), ["conference", "holiday"])
        XCTAssertFalse(PreviewTimeline.layout(events, in: PreviewTimeline.window(now: now, calendar: utc)).contains { $0.event.isAllDay })
        XCTAssertEqual(ids(PreviewTimeline.tomorrow(events, now: now, calendar: utc)), ["tomorrow"], "tomorrow's all-day event is listed under the grid")
    }

    // MARK: Past midnight, and tomorrow

    func testEventsPastMidnight() {
        let utc = zone("UTC")
        let events = [
            e("party", 15 * 60 + 30, 16 * 60 + 45),   // 23:30 – 00:45
            e("flight", 18 * 60, 19 * 60),            // 02:00 – 03:00 tomorrow
            e("planning", 25 * 60, 25 * 60 + 30),     // 09:00 tomorrow
            e("offsite", 16 * 60, 40 * 60, allDay: true),
            e("later", 49 * 60, 50 * 60),             // the day after tomorrow
            e("skip", 26 * 60, 27 * 60, declined: true),
        ]
        // In the morning, the grid ends at midnight: the party is clipped there, and the rest of tomorrow is listed.
        let morning = at(17)
        let mw = PreviewTimeline.window(now: morning, calendar: utc)
        let mb = PreviewTimeline.layout(events, in: mw)
        XCTAssertEqual(ids(mb.map(\.event)), ["party"])
        XCTAssertEqual(mb.first?.end, at(16 * 60), "clipped at midnight")
        XCTAssertEqual(ids(PreviewTimeline.tomorrow(events, now: morning, calendar: utc)), ["offsite", "flight", "planning"],
                       "all-day first, then by start; not the party (it began today), the declined one or the day after")
        // At 22:10 the grid reaches 04:00: the party and the flight are in it, so only planning is left for the list.
        let late = at(14 * 60 + 10)
        let lb = PreviewTimeline.layout(events, in: PreviewTimeline.window(now: late, calendar: utc))
        XCTAssertEqual(ids(lb.map(\.event)), ["party", "flight"])
        XCTAssertEqual(lb.first?.end, at(16 * 60 + 45), "not clipped any more")
        XCTAssertEqual(ids(PreviewTimeline.tomorrow(events, now: late, calendar: utc)), ["offsite", "planning"])
    }

    // MARK: Another time zone

    func testAPageInAnotherTimeZoneIsPlacedOnTheMacsHours() {
        // The page said "9am" in Los Angeles: that's 17:00 UTC. The card places the moment, not the page's hour.
        let la = zone("America/Los_Angeles")
        let nine = la.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 9))!
        XCTAssertEqual(nine, at(9 * 60))
        let event = CalendarEvent(id: "sync", title: "West coast sync", start: nine, end: nine.addingTimeInterval(1800))
        let now = at(17)
        // On a Mac in UTC: 9 hours after 08:00 UTC, i.e. 17 hours below midnight UTC.
        let utc = zone("UTC")
        let w = PreviewTimeline.window(now: now, calendar: utc)
        let b = PreviewTimeline.layout([event], in: w).first
        XCTAssertEqual(b.map { PreviewTimeline.offset(of: $0.start, in: w, hourHeight: 40) } ?? -1, 17 * 40, accuracy: 0.001)
        // On a Mac in Los Angeles it's 00:17 there: the grid begins at midnight LA (08:00 UTC), the sync 9 hours down.
        let lw = PreviewTimeline.window(now: now, calendar: la)
        XCTAssertEqual(lw.start, t0)
        let lb = PreviewTimeline.layout([event], in: lw).first
        XCTAssertEqual(lb.map { PreviewTimeline.offset(of: $0.start, in: lw, hourHeight: 40) } ?? -1, 9 * 40, accuracy: 0.001)
        // In Tokyo (UTC+9) it's 17:17 there: the sync is at 02:00 tomorrow, after the grid's midnight, so it's listed under it.
        let tokyo = zone("Asia/Tokyo")
        XCTAssertTrue(PreviewTimeline.layout([event], in: PreviewTimeline.window(now: now, calendar: tokyo)).isEmpty)
        XCTAssertEqual(ids(PreviewTimeline.tomorrow([event], now: now, calendar: tokyo)), ["sync"])
    }

    // MARK: Join

    func testTheBigJoinIsForAMeetingMomentsAway() {
        let now = t0
        let events = [e("standup", 5, 20, link: true), e("later", 20, 50, link: true), e("noCall", 2, 30),
                      e("on", -10, 10, link: true), e("skip", 3, 30, declined: true, link: true), e("done", -30, -5, link: true)]
        XCTAssertEqual(ids(PreviewTimeline.soon(events, now: now)), ["on", "standup"])
    }

    // MARK: Six hours on the card (calcard)

    func testSixHoursFitInEveryCombination() {
        typealias L = PreviewTimeline.CardLayout
        for join in [false, true] {
            for allDay in [false, true] {
                for tomorrow in [false, true] {
                    let l = L(join: join, allDay: allDay, tomorrow: tomorrow)
                    let name = "join \(join), all-day \(allDay), tomorrow \(tomorrow)"
                    XCTAssertGreaterThanOrEqual(l.visibleHours, 6, name)
                    XCTAssertGreaterThanOrEqual(l.hourHeight, 34, "an hour stays readable: \(name)")
                    XCTAssertLessThanOrEqual(l.hourHeight, L.maxHourHeight, name)
                    let parts = L.header + (join ? L.join + L.spacing : 0) + (allDay ? L.allDay + L.spacing : 0)
                        + (tomorrow ? L.spacing + L.tomorrow + L.bottom : 0)
                    XCTAssertEqual(parts + l.gridHeight, L.calendarCardHeight, accuracy: 0.001, "the parts fill the card: \(name)")
                }
            }
        }
        // As Arc, six hours are the whole grid when the card has no more room than that; with room to spare an hour
        // stops at 48 pt and a little more than six hours show.
        let full = L(join: true, allDay: true, tomorrow: true)
        XCTAssertEqual(full.hourHeight, (full.gridHeight - L.topInset - L.bottomInset) / 6, accuracy: 0.001)
        let bare = L(join: false, allDay: false, tomorrow: false)
        XCTAssertEqual(bare.hourHeight, L.maxHourHeight)
        XCTAssertGreaterThan(bare.visibleHours, 6)
        // A short window makes the card smaller (never under the 268 pt mail card): the hours shrink and still fit.
        for h in stride(from: 268.0, through: L.calendarCardHeight, by: 8) {
            let l = L(cardHeight: h, join: true, allDay: true, tomorrow: true)
            XCTAssertGreaterThanOrEqual(l.visibleHours, 6, "a \(h) pt card")
            XCTAssertGreaterThanOrEqual(l.hourHeight, L.minHourHeight)
        }
    }

    /// The full card: a big Join, today's all-day events, overlapping meetings, one ending at the six hours' end, and
    /// tomorrow. Every block in Arc's six hours sits inside the grid without scrolling.
    func testTheFullCardShowsSixHoursWithoutScrolling() {
        let utc = zone("UTC")
        let now = at(17)   // 08:17: Arc's six hours are 08:02 – 14:02
        let events = [
            e("standup", 20, 35, link: true),                      // 08:20, a call moments away: the big Join
            e("design", 60, 120), e("review", 90, 150),            // overlapping: side by side
            e("1:1", 100, 130),                                    // a third at once
            e("wrap-up", 5 * 60 + 30, 6 * 60),                     // 13:30 – 14:00, the six hours' last
            e("holiday", -8 * 60, 16 * 60, allDay: true),
            e("conference", -32 * 60, 40 * 60, allDay: true),
            e("moving day", -8 * 60, 16 * 60, allDay: true),       // three all-day: two chips and "+1"
            e("offsite", 16 * 60, 40 * 60, allDay: true),          // tomorrow
            e("planning", 25 * 60, 25 * 60 + 30, link: true),      // tomorrow 09:00
        ]
        let l = PreviewTimeline.CardLayout(events, now: now, calendar: utc)
        XCTAssertTrue(l.join && l.allDay && l.tomorrow, "the Join, the all-day strip and Tomorrow all show")
        XCTAssertGreaterThanOrEqual(l.visibleHours, 6)
        let w = PreviewTimeline.window(now: now, calendar: utc)
        let v = PreviewTimeline.visible(now: now)
        let blocks = PreviewTimeline.layout(events, in: w)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.event.id, $0) })
        XCTAssertEqual(["design", "review", "1:1"].map { byID[$0]?.columns }, [3, 3, 3])
        // The grid opens with 15 minutes before now `topInset` below its top.
        func y(_ d: Date) -> Double {
            PreviewTimeline.offset(of: d, in: w, hourHeight: l.hourHeight) - PreviewTimeline.offset(of: v.start, in: w, hourHeight: l.hourHeight)
                + PreviewTimeline.CardLayout.topInset
        }
        for b in blocks where b.start >= v.start && b.end <= v.end {
            XCTAssertGreaterThanOrEqual(y(b.start), 0, b.event.id)
            XCTAssertLessThanOrEqual(y(b.end), l.gridHeight, "\(b.event.id) ends inside the grid, no scrolling")
        }
        XCTAssertNotNil(byID["wrap-up"])
        XCTAssertLessThanOrEqual(y(v.end), l.gridHeight + 0.001, "the six hours' end is on the card")
        XCTAssertEqual(ids(PreviewTimeline.tomorrow(events, now: now, calendar: utc)), ["offsite", "planning"])
    }
}
