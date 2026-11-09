// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

final class ServicePreviewsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: Which site, whose account

    func testDetectsEachServiceAndNothingElse() {
        let cases: [(String, PreviewService?)] = [
            ("https://mail.google.com/mail/u/0/#inbox", .gmail),
            ("https://mail.google.com/", .gmail),
            ("https://calendar.google.com/calendar/u/1/r", .googleCalendar),
            ("https://outlook.live.com/mail/0/", .outlookMail),
            ("https://outlook.office.com/calendar/view/week", .outlookCalendar),
            ("https://outlook.office365.com/mail/inbox", .outlookMail),
            ("https://www.notion.so/Team-Directory-0123", .notion),
            ("https://www.figma.com/design/abc/Mockups", .figma),
            ("https://linear.app/acme/team/ENG/active", .linear),
            ("https://acme.atlassian.net/wiki/spaces/ENG/overview", .confluence),
            ("https://acme.atlassian.net/jira/your-work", nil),
            ("https://calendar.notion.so/", nil),
            ("https://docs.google.com/document/d/1", nil),
            ("https://github.com/pulls", nil),
            ("file:///tmp/mail.google.com", nil),
            ("https://mail.google.com.example/", nil),
        ]
        for (url, want) in cases { XCTAssertEqual(PreviewService.detect(url), want, url) }
    }

    func testGoogleAccountsAreTheirUIndexAndOutlookItsHost() {
        XCTAssertEqual(PreviewService.accountKey("https://mail.google.com/mail/u/1/#inbox"), "u/1")
        XCTAssertEqual(PreviewService.accountKey("https://mail.google.com/mail/?authuser=2"), "u/2")
        XCTAssertEqual(PreviewService.accountKey("https://mail.google.com/mail/"), "u/0")
        XCTAssertEqual(PreviewService.accountKey("https://calendar.google.com/calendar/u/3/r/week"), "u/3")
        XCTAssertEqual(PreviewService.accountKey("https://outlook.live.com/mail/0/"), "live")
        XCTAssertEqual(PreviewService.accountKey("https://outlook.office.com/mail/"), "work")
        XCTAssertEqual(PreviewService.accountKey("https://acme.atlassian.net/wiki/home"), "acme.atlassian.net")
        let a = PreviewAccount(url: "https://mail.google.com/mail/u/0/", profileID: "p1")
        let b = PreviewAccount(url: "https://mail.google.com/mail/u/1/", profileID: "p1")
        let c = PreviewAccount(url: "https://mail.google.com/mail/u/0/", profileID: "p2")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNil(PreviewAccount(url: "https://example.com/", profileID: "p1"))
    }

    func testActionsOpenInTheSameAccount() {
        XCTAssertEqual(PreviewService.actionURL(for: "https://mail.google.com/mail/u/1/#inbox")?.absoluteString,
                       "https://mail.google.com/mail/u/1/#inbox?compose=new")
        XCTAssertEqual(PreviewService.actionURL(for: "https://calendar.google.com/calendar/u/2/r")?.absoluteString,
                       "https://calendar.google.com/calendar/u/2/r/eventedit")
        XCTAssertEqual(PreviewService.actionURL(for: "https://outlook.office.com/mail/")?.absoluteString,
                       "https://outlook.office.com/mail/0/deeplink/compose")
        XCTAssertEqual(PreviewService.actionURL(for: "https://outlook.live.com/calendar/0/view/day")?.absoluteString,
                       "https://outlook.live.com/calendar/0/deeplink/compose")
        XCTAssertEqual(PreviewService.actionURL(for: "https://www.notion.so/x")?.absoluteString, "https://www.notion.so/new")
        XCTAssertEqual(PreviewService.actionURL(for: "https://linear.app/acme")?.absoluteString, "https://linear.app/new")
        XCTAssertEqual(PreviewService.actionURL(for: "https://acme.atlassian.net/wiki/x")?.absoluteString,
                       "https://acme.atlassian.net/wiki/create-content/page")
        XCTAssertNil(PreviewService.actionURL(for: "https://example.com/"))
    }

    func testArcsWordsPerCard() {
        XCTAssertEqual(PreviewService.gmail.emptyText, "No unread emails, you can exhale!")
        XCTAssertEqual(PreviewService.outlookMail.emptyText, "No unread emails, you can exhale!")
        XCTAssertEqual(PreviewService.linear.emptyText, "Recent Linear projects and issues appear here.")
        XCTAssertEqual(PreviewService.googleCalendar.signInButton, "Connect Calendar")
        XCTAssertEqual(PreviewService.gmail.signInText, "Sign in to your Email to see messages at a glance.")
        XCTAssertNil(PreviewService.notion.signInText)
        XCTAssertEqual(PreviewService.figma.actionTitle, "New File")
        XCTAssertEqual(PreviewService.linear.actionTitle, "New Issue")
        XCTAssertEqual(PreviewService.outlookCalendar.header, "Upcoming")
        XCTAssertEqual(PreviewService.confluence.settingsDetail, "Recent pages")
        XCTAssertFalse(PreviewService.notion.needsAccount)
        XCTAssertTrue(PreviewService.gmail.needsAccount)
    }

    // MARK: The cache

    func testTheCacheNeverCrossesAccountsAndForgetsAProfile() {
        var cache = PreviewCache()
        let work = PreviewAccount(service: .gmail, profileID: "work", key: "u/0")
        let home = PreviewAccount(service: .gmail, profileID: "home", key: "u/0")
        let second = PreviewAccount(service: .gmail, profileID: "work", key: "u/1")
        let mail = PreviewMail(id: "1", sender: "Ada", subject: "Hi", snippet: "…", date: t0)
        cache.store(.ready(.mail([mail])), for: work, at: t0)
        XCTAssertEqual(cache.entry(work)?.state, .ready(.mail([mail])))
        XCTAssertNil(cache.entry(home))
        XCTAssertNil(cache.entry(second))
        cache.store(.signedOut, for: home, at: t0)
        cache.forget(profileID: "work")
        XCTAssertNil(cache.entry(work))
        XCTAssertEqual(cache.entry(home)?.state, .signedOut)
        XCTAssertEqual(cache.count, 1)
    }

    func testLoadingKeepsContentFailureKeepsItStaleSigningOutDropsIt() {
        var cache = PreviewCache()
        let a = PreviewAccount(service: .notion, profileID: "p", key: "history")
        let page = PreviewPage(url: "https://www.notion.so/a", title: "A", date: t0)
        cache.store(.loading, for: a, at: t0)
        XCTAssertEqual(cache.entry(a)?.state, .loading)
        XCTAssertTrue(cache.isStale(a, now: t0, interval: 60), "loading isn't a fresh answer")
        cache.store(.ready(.recents([page])), for: a, at: t0)
        XCTAssertFalse(cache.isStale(a, now: at(0.5), interval: 60))
        XCTAssertTrue(cache.isStale(a, now: at(1), interval: 60))
        cache.store(.loading, for: a, at: at(2))
        XCTAssertEqual(cache.entry(a)?.state, .ready(.recents([page])))
        cache.store(.failed(stale: nil), for: a, at: at(3))
        XCTAssertEqual(cache.entry(a)?.state, .failed(stale: .recents([page])))
        cache.store(.expired, for: a, at: at(4))
        XCTAssertEqual(cache.entry(a)?.state, .expired)
        cache.store(.failed(stale: nil), for: a, at: at(5))
        XCTAssertEqual(cache.entry(a)?.state, .failed(stale: nil), "nothing of a signed-out account comes back")
    }

    func testTheCacheIsBounded() {
        var cache = PreviewCache()
        for i in 0..<(PreviewCache.limit + 5) {
            cache.store(.signedOut, for: PreviewAccount(service: .gmail, profileID: "p", key: "u/\(i)"), at: t0)
        }
        XCTAssertEqual(cache.count, PreviewCache.limit)
        XCTAssertNil(cache.entry(PreviewAccount(service: .gmail, profileID: "p", key: "u/0")))
    }

    // MARK: Times

    func testAges() {
        XCTAssertEqual(PreviewTime.mailAge(at(-0.5), now: t0), "now")
        XCTAssertEqual(PreviewTime.mailAge(at(-5), now: t0), "5m")
        XCTAssertEqual(PreviewTime.mailAge(at(-22 * 60), now: t0), "22h")
        XCTAssertEqual(PreviewTime.mailAge(at(-26 * 60), now: t0), "1d")
        XCTAssertEqual(PreviewTime.mailAge(at(-15 * 1440), now: t0), "2w")
        XCTAssertEqual(PreviewTime.pageAge(at(-0.2), now: t0), "Just now")
        XCTAssertEqual(PreviewTime.pageAge(at(-1), now: t0), "1 minute ago")
        XCTAssertEqual(PreviewTime.pageAge(at(-8), now: t0), "8 minutes ago")
        XCTAssertEqual(PreviewTime.pageAge(at(-61), now: t0), "1 hour ago")
        XCTAssertEqual(PreviewTime.pageAge(at(-3 * 1440), now: t0), "3 days ago")
        XCTAssertEqual(PreviewTime.pageAge(at(-90 * 1440), now: t0), "3 months ago")
    }

    // MARK: The timeline

    private func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        return c
    }

    func testTheWindowStartsAtTheLocalHourInEveryZone() {
        // 1_800_000_000 is 2027-01-15 08:00:00 UTC.
        let now = t0.addingTimeInterval(17 * 60)   // 08:17 UTC
        let utc = PreviewTimeline.window(now: now, calendar: calendar("UTC"))
        XCTAssertEqual(utc.start, t0)
        XCTAssertEqual(utc.end, t0.addingTimeInterval(16 * 3600), "to midnight")
        // India is UTC+5:30: 13:47 there, so its hour began at 13:00 local = 07:30 UTC.
        let india = PreviewTimeline.window(now: now, calendar: calendar("Asia/Kolkata"))
        XCTAssertEqual(india.start, t0.addingTimeInterval(-30 * 60))
        // Late in the day it still shows six hours, past midnight.
        let late = PreviewTimeline.window(now: t0.addingTimeInterval(14 * 3600 + 600), calendar: calendar("UTC"))   // 22:10
        XCTAssertEqual(late.duration, TimeInterval(PreviewTimeline.visibleHours * 3600))
        XCTAssertEqual(PreviewTimeline.hours(in: late, calendar: calendar("UTC")).count, 6)
    }

    func testOverlappingEventsShareColumnsPerCluster() {
        let w = DateInterval(start: t0, duration: 6 * 3600)
        func e(_ id: String, _ s: Double, _ end: Double, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: id, start: at(s), end: at(end), isAllDay: allDay)
        }
        let blocks = PreviewTimeline.layout([
            e("standup", 0, 30), e("1:1", 15, 45), e("review", 30, 60),   // one cluster, two columns
            e("lunch", 120, 180),                                          // alone
            e("holiday", -600, 900, allDay: true),                         // all day: not a block
            e("yesterday", -300, -200),                                    // before the window
        ], in: w)
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.event.id, $0) })
        XCTAssertEqual(Set(byID.keys), ["standup", "1:1", "review", "lunch"])
        XCTAssertEqual(byID["standup"]?.column, 0)
        XCTAssertEqual(byID["1:1"]?.column, 1)
        XCTAssertEqual(byID["review"]?.column, 0, "standup's column is free again at 30")
        XCTAssertEqual(byID["standup"]?.columns, 2)
        XCTAssertEqual(byID["lunch"]?.columns, 1)
        XCTAssertEqual(byID["lunch"]?.column, 0)
    }

    // MARK: Row status lines

    func testMailStatus() {
        XCTAssertNil(PreviewStatus.mail(0))
        XCTAssertEqual(PreviewStatus.mail(1), "1 Recent")
        XCTAssertEqual(PreviewStatus.mail(4), "4 Recent")
        XCTAssertEqual(PreviewStatus.mail(PreviewStatus.several), "Several Recent")
    }

    func testCalendarStatus() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let time: (Date) -> String = { d in
            let f = DateFormatter()
            f.timeZone = cal.timeZone
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        func e(_ id: String, _ s: Double, _ end: Double, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: id, start: at(s), end: at(end), isAllDay: allDay)
        }
        let day = [e("holiday", -480, 900, allDay: true), e("standup", 9, 24), e("review", 180, 240)]
        XCTAssertEqual(PreviewStatus.calendar(day, now: t0, calendar: cal, time: time), "Event in 9m")
        XCTAssertEqual(PreviewStatus.calendar(day, now: at(8.5), calendar: cal, time: time), "Event in 1m")
        XCTAssertEqual(PreviewStatus.calendar(day, now: at(9.2), calendar: cal, time: time), "Event right now")
        XCTAssertEqual(PreviewStatus.calendar(day, now: at(11.5), calendar: cal, time: time), "Event began 2m ago")
        XCTAssertEqual(PreviewStatus.calendar(day, now: at(15), calendar: cal, time: time), "Event at 11:00", "five minutes on, the next one")
        XCTAssertEqual(PreviewStatus.calendar(day, now: at(130), calendar: cal, time: time), "Event in 50m")
        XCTAssertNil(PreviewStatus.calendar(day, now: at(300), calendar: cal, time: time), "nothing more today")
        // 08:00 UTC; a meeting tomorrow morning isn't "Event at".
        XCTAssertNil(PreviewStatus.calendar([e("tomorrow", 60 * 20, 60 * 21)], now: t0, calendar: cal, time: time))
        // The next change: the minute ticking over, then the start.
        XCTAssertEqual(PreviewStatus.nextChange(day, now: t0.addingTimeInterval(10)), at(1))
        XCTAssertEqual(PreviewStatus.nextChange(day, now: at(11.5)), at(12))
    }

    // MARK: Peek Email

    func testFindsTheNewestCodeFromTheSite() {
        let mail = [
            PreviewMail(id: "old", sender: "Tracker", senderAddress: "notifications@tracker.example", subject: "Your login code",
                        snippet: "Your login code is 111111", date: at(-40)),
            PreviewMail(id: "new", sender: "Tracker", senderAddress: "notifications@tracker.example", subject: "Tracker login code",
                        snippet: "Enter this code to sign in: 482-913. It expires in 10 minutes.", date: at(-2)),
            PreviewMail(id: "other", sender: "Shop", senderAddress: "no-reply@shop.example", subject: "Your code",
                        snippet: "Code 999999", date: at(-1)),
        ]
        XCTAssertEqual(SignInMail.find(in: mail, host: "tracker.example", now: t0), .code("482913"))
        XCTAssertEqual(SignInMail.find(in: mail, host: "www.shop.example", now: t0), .code("999999"))
        XCTAssertNil(SignInMail.find(in: mail, host: "tracker.example", now: at(30)), "older than 15 minutes")
        XCTAssertNil(SignInMail.find(in: mail, host: "bank.example", now: t0))
    }

    func testAMagicLinkWhenThereIsNoCode() {
        let mail = [PreviewMail(id: "1", sender: "Docs Team", senderAddress: "notify@mail.docs.example", subject: "Sign in to Docs",
                                snippet: "Click the link below", date: at(-1),
                                body: "Sign in: https://www.docs.example/loginwithemail?token=abc123 — or ignore this. Help: https://www.docs.example/help")]
        XCTAssertEqual(SignInMail.find(in: mail, host: "www.docs.example", now: t0),
                       .link(URL(string: "https://www.docs.example/loginwithemail?token=abc123")!))
        let elsewhere = [PreviewMail(id: "2", sender: "Docs", senderAddress: "x@docs.example", subject: "Sign in",
                                     snippet: "https://evil.example/login?token=1", date: at(-1))]
        XCTAssertNil(SignInMail.find(in: elsewhere, host: "docs.example", now: t0), "a link to another site is never used")
    }

    func testCodesNeedAWordLikeCodeAndAreNotYears() {
        XCTAssertEqual(SignInMail.code(in: "Your verification code: 0427"), "0427")
        XCTAssertEqual(SignInMail.code(in: "Use AB12CD to sign in"), "AB12CD")
        XCTAssertEqual(SignInMail.code(in: "Security code 123 456"), "123456")
        XCTAssertNil(SignInMail.code(in: "Your order 123456 has shipped"))
        XCTAssertNil(SignInMail.code(in: "Sign in again in 2026"))
    }
}
