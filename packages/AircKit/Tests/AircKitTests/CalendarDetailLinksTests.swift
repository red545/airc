// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// calmeet2: a meeting's call link from its chip, its open bubble, or its own page (read for the next meeting only), and
/// the call links themselves without tracking parameters.
final class CalendarDetailLinksTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return c
    }()

    private func answer(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    private func events(_ s: PreviewState?) -> [CalendarEvent] {
        if case .ready(.calendar(let e))? = s { return e }
        XCTFail("not events: \(String(describing: s))")
        return []
    }

    // MARK: Links

    func testMeetZoomTeamsWebexWithTrackingParameters() {
        let meet = MeetingLink.find(url: nil, location: nil,
                                    notes: "Join with Google Meet: https://meet.google.com/abc-defg-hij?authuser=1&hs=122&utm_source=calendar")
        XCTAssertEqual(meet?.service, .meet)
        XCTAssertEqual(meet?.url.absoluteString, "https://meet.google.com/abc-defg-hij?authuser=1", "authuser picks the account; hs and utm go")

        let zoom = MeetingLink.firstCall(in: ["https://us02web.zoom.us/j/81234567890?pwd=Zm9vYmFy.1&utm_medium=email&fbclid=IwAR0x"])
        XCTAssertEqual(zoom?.service, .zoom)
        XCTAssertEqual(zoom?.url.absoluteString, "https://us02web.zoom.us/j/81234567890?pwd=Zm9vYmFy.1", "Zoom's pwd stays")

        let teamsURL = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjE5%40thread.v2/0?context=%7b%22Tid%22%3a%2272f9%22%7d"
        let teams = MeetingLink.firstCall(in: [teamsURL + "&utm_campaign=x&gclid=abc"])
        XCTAssertEqual(teams?.service, .teams)
        XCTAssertEqual(teams?.url.absoluteString, teamsURL, "Teams' context stays, percent-encoding untouched")

        let webex = MeetingLink.firstCall(in: ["https://acme.webex.com/acme/j.php?MTID=m0123456789abcdef&utm_source=invite"])
        XCTAssertEqual(webex?.service, .webex)
        XCTAssertEqual(webex?.url.absoluteString, "https://acme.webex.com/acme/j.php?MTID=m0123456789abcdef")

        // Nothing to strip: the link as it was.
        XCTAssertEqual(MeetingLink.firstCall(in: ["https://zoom.us/j/111"])?.url.absoluteString, "https://zoom.us/j/111")
        // Only tracking: no "?" left over.
        XCTAssertEqual(MeetingLink.firstCall(in: ["https://meet.google.com/aaa-bbbb-ccc?hs=224&utm_source=x"])?.url.absoluteString,
                       "https://meet.google.com/aaa-bbbb-ccc")
    }

    func testWrappedLinks() {
        // Google's redirect wrapper (in event descriptions) and Outlook's Safe Links (in invitation bodies).
        let google = "https://www.google.com/url?q=https%3A%2F%2Fzoom.us%2Fj%2F222%3Fpwd%3Dabc&sa=D&source=calendar&ust=1&usg=AOv"
        XCTAssertEqual(MeetingLink.firstCall(in: [google])?.url.absoluteString, "https://zoom.us/j/222?pwd=abc")
        let inner = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d"
        let safe = "https://eur01.safelinks.protection.outlook.com/?url=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            + "&data=05%7C01&sdata=xyz&reserved=0"
        let teams = MeetingLink.firstCall(in: [safe])
        XCTAssertEqual(teams?.service, .teams)
        XCTAssertEqual(teams?.url.absoluteString, inner)
    }

    func testFirstCallIsAKnownServiceInOrder() {
        // A detail page's links: the calendar itself, a document, then the call (Join first when the script found one).
        XCTAssertEqual(MeetingLink.firstCall(in: ["https://calendar.google.com/calendar/u/0/r", "https://docs.example.com/agenda",
                                                  "https://teams.live.com/meet/9876543210", "https://zoom.us/j/1"])?.service, .teams)
        XCTAssertNil(MeetingLink.firstCall(in: ["https://docs.example.com/agenda", "https://example.com/event/42"]),
                     "a detail page never gives a plain web link")
        XCTAssertNil(MeetingLink.firstCall(in: []))
    }

    // MARK: Chips and bubbles

    func testChipLinksAndOpenBubble() {
        let day = "2026-11-14"
        let o: [String: Any] = ["v": 1, "gridFound": true, "days": [day], "items": [
            // A Zoom call in an attribute of the chip (no address in its text).
            ["id": "Y2hpcA", "label": "10am to 10:30am, Standup, Accepted, No location, November 14, 2026", "day": day,
             "links": ["https://calendar.google.com/calendar/u/0/r/eventedit/Y2hpcA", "https://zoom.us/j/333?pwd=p&utm_source=chip"],
             "url": "https://calendar.google.com/calendar/u/0/r/eventedit/Y2hpcA"],
            // Meet only in its open bubble ("Join with Google Meet").
            ["id": "YnViYmxl", "label": "11am to 11:30am, Design, Accepted, No location, November 14, 2026", "day": day, "links": [],
             "url": "https://calendar.google.com/calendar/u/0/r/eventedit/YnViYmxl"],
            // No call anywhere.
            ["id": "bm9uZQ", "label": "1pm to 2pm, Lunch, No location, November 14, 2026", "day": day],
        ], "details": [["id": "YnViYmxl", "links": ["https://meet.google.com/xyz-abcd-efg?authuser=0&hs=179", "https://example.com/doc"]]]]
        let e = events(PageCalendar.state(from: answer(o), service: .googleCalendar, now: Date(timeIntervalSince1970: 0), calendar: cal))
        XCTAssertEqual(e.map(\.title), ["Standup", "Design", "Lunch"])
        XCTAssertEqual(e[0].link?.url.absoluteString, "https://zoom.us/j/333?pwd=p")
        XCTAssertEqual(e[1].link?.url.absoluteString, "https://meet.google.com/xyz-abcd-efg?authuser=0")
        XCTAssertNil(e[2].link)
    }

    func testScriptsReadChipLinksAndDetailIsSameOriginAndHidden() {
        let g = PageCalendar.script(for: .googleCalendar)!
        XCTAssertTrue(g.contains("links:lk(e)") && g.contains("bubbles('data-eventid')"))
        XCTAssertTrue(PageCalendar.script(for: .outlookCalendar)!.contains("bubbles('data-calitemid')"))
        let url = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit/YWJj")!
        let d = PageCalendar.detailScript(for: .googleCalendar, url: url, token: 7)!
        XCTAssertTrue(d.contains("u.origin!==location.origin"), "another origin is never loaded")
        XCTAssertTrue(d.contains("sandbox','allow-same-origin allow-scripts'"), "the frame can't navigate the page, open windows or submit")
        XCTAssertTrue(d.contains("left:-30000px") && d.contains("opacity:0") && d.contains("pointer-events:none"))
        XCTAssertTrue(d.contains("f.remove()"))
        XCTAssertTrue(d.contains("var T=7,"))
        XCTAssertNil(PageCalendar.detailScript(for: .gmail, url: url))
        XCTAssertTrue(PageCalendar.detailPollScript(token: 7).contains("D[7]"))
    }

    func testDetailResult() {
        XCTAssertEqual(PageCalendar.detailResult(from: answer(["detail": true, "loaded": true,
                                                                "links": ["https://example.com", "https://meet.google.com/abc-defg-hij?hs=1"]])),
                       .link(MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet)))
        XCTAssertEqual(PageCalendar.detailResult(from: answer(["detail": true, "loaded": true, "links": ["https://example.com"]])), .noCall)
        XCTAssertEqual(PageCalendar.detailResult(from: answer(["detail": true, "loaded": false, "links": []])), .failed)
        XCTAssertEqual(PageCalendar.detailResult(from: answer(["detail": true, "gone": true])), .failed)
        XCTAssertEqual(PageCalendar.detailResult(from: nil), .failed)
        XCTAssertTrue(PageCalendar.detailPending(answer(["pending": true])))
        XCTAssertFalse(PageCalendar.detailPending(answer(["detail": true, "loaded": true])))
    }

    // MARK: The cache: only the next meeting, until it changes

    func testOnlyTheNextMeetingIsReadAndKeptUntilItChanges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let page = URL(string: "https://calendar.google.com/calendar/u/0/r/eventedit/x")!
        let next = CalendarEvent(id: "a@1", title: "Team sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400), url: page)
        let later = CalendarEvent(id: "b@2", title: "Retro", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(3600), url: page)
        let far = CalendarEvent(id: "c@3", title: "Tomorrow", start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000), url: page)
        var d = CalendarDetailLinks()
        XCTAssertEqual(d.candidate([later, next, far], now: now)?.id, "a@1", "the countdown's meeting, not the others")
        XCTAssertNil(d.candidate([far], now: now), "nothing beyond the countdown's hour is read")
        var noPage = next
        noPage.url = nil
        XCTAssertNil(d.candidate([noPage], now: now), "no page of its own: nothing to read")
        var linked = next
        linked.link = MeetingLink(url: URL(string: "https://zoom.us/j/1")!, service: .zoom)
        XCTAssertNil(d.candidate([linked, later], now: now), "the chip has its call: nothing read")

        let meet = MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet)
        d.store(.link(meet), for: next, now: now)
        XCTAssertEqual(d.apply([next, later]).map(\.link), [meet, nil])
        XCTAssertNil(d.candidate([next, later], now: now), "read once: not again")
        XCTAssertEqual(d.apply([linked]).first?.link?.service, .zoom, "a link on the chip wins")

        // The chip changed (moved by ten minutes): its old call isn't trusted, and it's read again.
        var moved = next
        moved.start = next.start.addingTimeInterval(600)
        moved.end = next.end.addingTimeInterval(600)
        XCTAssertNil(d.apply([moved]).first?.link)
        XCTAssertEqual(d.candidate([moved], now: now)?.id, "a@1")

        // A page without a call is asked again only after retryAfter.
        d.store(.noCall, for: moved, now: now)
        XCTAssertNil(d.candidate([moved], now: now.addingTimeInterval(60)))
        XCTAssertEqual(d.candidate([moved], now: now.addingTimeInterval(CalendarDetailLinks.retryAfter + 1))?.id, "a@1")

        // Gone from the calendar: forgotten.
        d.prune(keeping: [later], now: now)
        XCTAssertTrue(d.entries.isEmpty)
    }
}
