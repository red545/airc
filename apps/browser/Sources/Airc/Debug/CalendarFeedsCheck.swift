// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// M08, `--script calendar`'s third part (both engines): Live Calendar fed from a web calendar's own answer, the way Arc
/// read Google Calendar and Outlook. A loopback server answers like `calendar/v3/calendars/primary/events` and Graph's
/// calendar view with synthetic meetings (never a real account); CalendarFeeds reads them into the synthetic source.
/// On a clock the check moves (CalendarCenter.now):
///   - the tile counts down at several offsets, and skips a declined meeting that starts earlier;
///   - the hover card's day list ("Today", then "Tomorrow") leaves out declined, all-day and out-of-office events and
///     keeps a tentative one;
///   - Join on the card (a real click from the stable UI driver when AIRC_REAL_KEYS=1 in a dedicated session, else a
///     posted click; the log says which) opens the conference's own link;
///   - the "Show Meeting Link" time from Settings moves the Join prompt (Ten Minutes Before shows it at 9 minutes,
///     Two Minutes Before doesn't), and a declined meeting never gets one.
/// Writes calendar-feeds-card.png.
extension SnapshotRunner {
    func calendarFeeds(center: CalendarCenter, source: SyntheticCalendarSource, spaceID: @escaping () -> String,
                       tile: @escaping () -> FavoriteTileView?, prompt: @escaping () -> CalendarPromptView?,
                       setNow: @escaping (Date) -> Void) {
        var server: LocalPageServer?
        var base = ""
        let cal = Calendar.current
        // A fixed afternoon today, so "Today" and "Tomorrow" don't depend on when the run happens.
        let t = cal.date(bySettingHour: 15, minute: 0, second: 0, of: Date()) ?? Date()
        func at(_ m: Double) -> Date { t.addingTimeInterval(m * 60) }
        let tomorrow9 = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 9, minute: 0, second: 0, of: t) ?? t) ?? t
        let iso = ISO8601DateFormatter()
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        func when(_ d: Date) -> String { "{\"dateTime\": \"\(iso.string(from: d))\"}" }
        let me = { (r: String) in "\"attendees\": [{\"email\": \"organizer@example.com\", \"responseStatus\": \"accepted\"}, "
            + "{\"email\": \"me@example.com\", \"self\": true, \"responseStatus\": \"\(r)\"}]" }
        var google: String {
            """
            {"kind": "calendar#events", "items": [
              {"id": "feedstandup", "summary": "Feed standup", "start": \(when(at(30))), "end": \(when(at(60))), \(me("accepted")),
               "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "\(base)/feedcall"}]}},
              {"id": "declined", "summary": "Declined sync", "start": \(when(at(10))), "end": \(when(at(40))), \(me("declined")),
               "location": "\(base)/declinedcall"},
              {"id": "maybe", "summary": "Maybe review", "start": \(when(at(60))), "end": \(when(at(90))), \(me("tentative")),
               "description": "Join: https://meet.google.com/abc-defg-hij"},
              {"id": "holiday", "summary": "Holiday", "start": {"date": "\(day.string(from: t))"},
               "end": {"date": "\(day.string(from: tomorrow9))"}},
              {"id": "ooo", "summary": "Out of office", "eventType": "outOfOffice", "start": \(when(at(15))), "end": \(when(at(120)))}
            ]}
            """
        }
        var outlook: String {
            let utc = DateFormatter()
            utc.locale = Locale(identifier: "en_US_POSIX")
            utc.timeZone = TimeZone(identifier: "UTC")
            utc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
            func w(_ d: Date) -> String { "{\"dateTime\": \"\(utc.string(from: d))\", \"timeZone\": \"UTC\"}" }
            return """
            {"value": [
              {"id": "planning", "subject": "Planning", "showAs": "busy", "start": \(w(tomorrow9)),
               "end": \(w(tomorrow9.addingTimeInterval(1800))), "responseStatus": {"response": "organizer"},
               "onlineMeeting": {"joinUrl": "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"}},
              {"id": "away", "subject": "Away", "showAs": "oof", "start": \(w(at(200))), "end": \(w(at(260)))}
            ]}
            """
        }
        var feed: [CalendarEvent] = []

        step { [self] done in
            server = LocalPageServer(responses: [
                "/feedcall": .init(body: "<title>Feed call</title><h1>Feed call</h1>"),
                "/declinedcall": .init(body: "<title>Declined call</title>"),
            ])
            // The answers are made per request, so their links point at this server's port.
            server?.handler = { path in
                let json = ["Content-Type": "application/json"]
                switch path {
                case "/calendar/v3/calendars/primary/events": return .init(headers: json, body: google)
                case "/v1.0/me/calendarView": return .init(headers: json, body: outlook)
                default: return nil
                }
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "calendar feeds: a loopback server") }
                done()
            }
        }
        // Fetched over loopback as a provider would, and read by CalendarFeeds.
        step { [self] done in
            func get(_ path: String, _ then: @escaping (Data?) -> Void) {
                guard let u = URL(string: base + path) else { return then(nil) }
                URLSession.shared.dataTask(with: u) { d, _, _ in DispatchQueue.main.async { then(d) } }.resume()
            }
            get("/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime") { gd in
                get("/v1.0/me/calendarView") { od in
                    let g = gd.flatMap { CalendarFeeds.google($0) }
                    let o = od.flatMap { CalendarFeeds.outlook($0) }
                    self.check(g?.count == 5 && o?.count == 2,
                               "calendar feeds: Google's and Outlook's answers fetched over loopback and read (\(g?.count ?? -1), \(o?.count ?? -1))")
                    feed = (g ?? []) + (o ?? [])
                    source.set(feed)
                    setNow(at(0))
                    self.waitUntil({ center.events.contains { $0.title == "Feed standup" } }, timeout: 3) { done() }
                }
            }
        }
        wait(0.3)
        run { [self] in
            let standup = center.events.first { $0.title == "Feed standup" }
            check(standup?.link?.url.absoluteString == base + "/feedcall" && standup?.response == .accepted,
                  "calendar feeds: the meeting's call is its conference's video link (\(standup?.link?.url.absoluteString ?? "-"))")
            check(center.events.first { $0.title == "Declined sync" }?.response == .declined
                  && center.events.first { $0.title == "Holiday" }?.isAllDay == true
                  && center.events.first { $0.title == "Out of office" }?.kind == .outOfOffice
                  && center.events.first { $0.title == "Away" }?.kind == .outOfOffice,
                  "calendar feeds: declined, all-day and out-of-office events arrive marked")
        }

        // The countdown at several offsets of the injectable clock: 15:30 is the next live meeting, 15:10 is declined.
        let offsets: [(Double, String?, String)] = [
            (-30.5, nil, "61 min before: nothing yet"),
            (-30, "in 1h", "an hour before"),
            (0, "in 30m", "30 min before (the declined 15:10 doesn't count)"),
            (29.5, "in 1m", "30 s before"),
            (30, "now", "at the start"),
            (34.9, "now", "4.9 min late"),
            (35, "in 25m", "5 min late: the tentative 16:00 is next"),
        ]
        for (m, label, what) in offsets {
            run { setNow(at(m)) }
            wait(0.15)
            run { [self] in
                let text = tile()?.calendarFace?.text
                check(text == label, "calendar feeds: countdown \(what): \(label ?? "none") (\(text ?? "none"))")
            }
        }

        // The day list.
        run { [self] in
            setNow(at(29))
            if let t = tile() { CalendarCard.shared.show(beside: t) }
        }
        wait(0.5)
        run { [self] in
            let m = CalendarCard.shared.model
            let titles = m.events.map(\.title)
            let days = m.events.map { CalendarCard.dayTitle($0, now: center.now()) }
            check(titles == ["Feed standup", "Maybe review", "Planning"],
                  "calendar feeds: the card lists the day without declined, all-day or out-of-office events, tentative kept (\(titles))")
            check(days == ["Today", "Today", "Tomorrow"], "calendar feeds: the card's days are Today, then Tomorrow (\(days))")
            if let p = CalendarCard.shared.panel {
                check(TestAnchors.frame("calendar.day.0", in: p) != nil && TestAnchors.frame("calendar.day.2", in: p) != nil
                      && TestAnchors.frame("calendar.day.1", in: p) == nil,
                      "calendar feeds: the card shows a Today header and a Tomorrow header before Planning")
            }
        }
        capture("calendar-feeds-card")

        // Join on the card: the conference's link opens in this Space.
        step { [self] done in
            let before = c.store.todayRows(ofSpace: spaceID()).compactMap { $0.liveTab?.url }.filter { $0 == base + "/feedcall" }.count
            func verify(_ how: String) {
                waitUntil({ self.c.store.tab(self.c.shownTabID)?.url == base + "/feedcall" }, timeout: 4) {
                    let now = self.c.store.todayRows(ofSpace: spaceID()).compactMap { $0.liveTab?.url }.filter { $0 == base + "/feedcall" }.count
                    self.check(self.c.store.tab(self.c.shownTabID)?.url == base + "/feedcall" && now == before + 1,
                               "calendar feeds: Join (\(how)) opens the conference link as a Today tab (\(self.c.store.tab(self.c.shownTabID)?.url ?? "-"))")
                    done()
                }
            }
            guard let panel = CalendarCard.shared.panel, let w = panel.window, let p = anchorPoint("calendar.join.0", in: panel) else {
                check(false, "calendar feeds: the card's first Join is on screen")
                return done()
            }
            if UIDriverClient.available, ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1",
               let primary = NSScreen.screens.first, NSApp.isActive, c.window.isOnActiveSpace {
                let s = w.convertPoint(toScreen: p)
                UIDriverClient.run(["--click", String(Double(s.x)), String(Double(primary.frame.maxY - s.y))]) { ok, out in
                    if !ok {
                        self.failEnv("calendar feeds: Join [real click]", out)
                        self.clickAnchor("calendar.join.0", in: panel) { verify("posted click after the driver failed") }
                    } else {
                        verify("real click from the stable UI driver")
                    }
                }
            } else {
                whenOwnerAway { why in
                    if let why {
                        self.failEnv("calendar feeds: Join [posted click]", why)
                        if let e = CalendarCard.shared.model.events.first { CalendarCard.shared.model.onJoin(e) }
                        return verify("direct call")
                    }
                    self.clickAnchor("calendar.join.0", in: panel) { verify("posted click") }
                }
            }
        }
        run { CalendarCard.shared.hide() }

        // Settings › Calendar › Show Meeting Link moves the Join prompt; the declined meeting never gets one.
        run { [self] in
            center.setJoinLead(.tenMinutes)
            setNow(at(21))
            c.reloadAll(animated: false)
        }
        wait(0.3)
        run { [self] in
            check(prompt()?.event?.title == "Feed standup",
                  "calendar feeds: Show Meeting Link Ten Minutes Before: the Join shows 9 minutes before (\(prompt()?.event?.title ?? "none"))")
            center.setJoinLead(.twoMinutes)
            c.reloadAll(animated: false)
        }
        wait(0.3)
        run { [self] in
            check(prompt() == nil, "calendar feeds: Two Minutes Before: no Join 9 minutes before (\(prompt()?.event?.title ?? "none"))")
            setNow(at(9.5))
            c.reloadAll(animated: false)
        }
        wait(0.3)
        run { [self] in
            check(prompt() == nil && MeetingSchedule.joinTarget(center.events, now: center.now())?.title == "Feed standup",
                  "calendar feeds: the declined 15:10 gets no Join, and ⌃⌘J's target is the next live meeting")
            server?.stop()
        }
    }
}
#endif
