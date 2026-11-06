// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// Scripted and automated runs' calendar (CalendarCenter picks it whenever the run is automated): made-up meetings,
/// access granted at once with no prompt, so no run ever reads the person's calendars or asks macOS for them.
final class SyntheticCalendarSource: CalendarEventSource {
    private let lock = NSLock()
    private var stored: [CalendarEvent] = []
    private(set) var access: CalendarAccess = .notDetermined
    private(set) var requests = 0
    var onChange: (() -> Void)?

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        requests += 1
        access = .granted
        DispatchQueue.main.async { done(true) }
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored.filter { $0.end > from && $0.start < to }
    }

    /// New meetings, announced like EKEventStoreChanged.
    func set(_ events: [CalendarEvent]) {
        lock.lock()
        stored = events
        lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }
}

/// `--script calendar` (both engines): Live Calendar on a Google Calendar Favorite, with synthetic meetings whose call
/// links are loopback pages (no real Meet or Zoom page loads, so nothing asks for the camera or microphone):
///   - hovering the tile shows the one-time invitation; Turn On (a real click) turns it on without any prompt;
///   - the tile counts down ("in 5m"), the hover card lists the next meetings with Join where there's a link;
///   - Join (a real click) opens the call in the Space whose Favorite was used, as a Today tab;
///   - a minute before, the sidebar shows "Standup · in 1 min" and Join; a click shows the open call tab, no second one;
///   - after the five late minutes the prompt goes and the tile counts down to the next meeting;
///   - one one-shot timer at the next minute boundary, a calendar change shows at once, and turning it off stops it;
///   - `calendar.enable` and `calendar.join` are recorded, with nothing but their names.
/// Writes calendar-invite.png, calendar-tile.png, calendar-card.png and calendar-prompt.png.
extension SnapshotRunner {
    func calendarScenario() {
        let center = CalendarCenter.shared
        guard let source = center.source as? SyntheticCalendarSource else {
            check(false, "calendar: a scripted run uses the synthetic calendar")
            return
        }
        var server: LocalPageServer?
        var base = ""
        var offset: TimeInterval = 0
        center.now = { Date().addingTimeInterval(offset) }
        func setNow(_ d: Date) {
            offset = d.timeIntervalSinceNow
            center.clockMoved()
        }
        let t0 = Date()
        var standup: CalendarEvent!
        var events: [CalendarEvent] = []
        var calendarItem = ""
        var spaceID = ""
        var records: [TelemetryRecord] = []
        let telemetryToken = Telemetry.shared.observeRecent { records = $0 }
        let tile = { () -> FavoriteTileView? in
            guard let p = self.c.pageView(for: self.c.currentSpaceID) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == calendarItem }
        }
        let prompt = { () -> CalendarPromptView? in
            self.c.pageView(for: self.c.currentSpaceID)?.layoutSubtreeIfNeeded()
            return self.c.pageView(for: self.c.currentSpaceID)?.favorites.subviews.compactMap { $0 as? CalendarPromptView }.first
        }
        let todayURLs = { self.c.store.todayRows(ofSpace: spaceID).compactMap { $0.liveTab?.url } }

        step { [self] done in
            server = LocalPageServer(pages: ["/standup": "<title>Standup call</title><h1>Standup call</h1>",
                                             "/review": "<title>Review call</title><h1>Review call</h1>"])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "calendar: a loopback page server") }
                done()
            }
        }
        run { [self] in
            spaceID = c.currentSpaceID
            let profile = c.store.profile(ofSpace: spaceID).id
            do {
                try favorite("https://mail.google.com/mail/u/0/#inbox", title: "Inbox - Gmail",
                             icon: "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico", profile: profile, space: spaceID)
                try favorite("https://calendar.google.com/calendar/u/0/r", title: "Google Calendar", icon: nil, profile: profile, space: spaceID)
            } catch { check(false, "calendar: Favorites (\(error))") }
            calendarItem = c.store.favorites(ofProfile: profile).first { CalendarSites.isCalendarFavorite($0.savedURL ?? "") }?.id ?? ""
            func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
            standup = CalendarEvent(id: "standup", title: "Standup", start: at(5), end: at(20),
                                    link: MeetingLink(url: URL(string: base + "/standup")!, service: .meet))
            events = [standup,
                      CalendarEvent(id: "review", title: "Design review", start: at(45), end: at(75),
                                    link: MeetingLink(url: URL(string: base + "/review")!, service: .zoom)),
                      CalendarEvent(id: "lunch", title: "Lunch with Sam", start: at(120), end: at(180)),
                      CalendarEvent(id: "holiday", title: "Holiday", start: at(-600), end: at(840), isAllDay: true)]
            source.set(events)
            setNow(standup.start.addingTimeInterval(-(4 * 60 + 45)))
            c.reloadAll(animated: false)
            check(tile() != nil && tile()?.calendarFace != nil, "calendar: the Google Calendar Favorite is the Calendar Favorite")
            check(app?.settings.values.calendar.enabled == false && tile()?.calendarFace?.text == nil && source.requests == 0,
                  "calendar: off by default, no countdown, no access asked")
        }

        // The invitation, and Turn On by a real click.
        run { [self] in if let t = tile() { CalendarCard.shared.show(beside: t) } }
        wait(0.4)
        run { [self] in check(CalendarCard.shared.panel != nil && CalendarCard.shared.model.state == .invitation, "calendar: hover shows the invitation") }
        capture("calendar-invite")
        clickIn({ CalendarCard.shared.panel }, "calendar.turnOn")
        step { [self] done in
            waitUntil({ center.isActive }, timeout: 2) {
                if !center.isActive {
                    // Posted clicks on SwiftUI buttons miss now and then while the owner works: once more.
                    self.note("calendar: Turn On missed (\(TestAnchors.lastHit["calendar.turnOn"] ?? "-")), clicking again")
                    self.clickAnchor("calendar.turnOn", in: CalendarCard.shared.panel ?? self.c.root) { done() }
                } else { done() }
            }
        }
        step { [self] done in
            waitUntil({ center.isActive && center.tileLabel != nil }, timeout: 2) {
                self.check(center.isActive, "calendar: Turn On turns it on (\(TestAnchors.lastHit["calendar.turnOn"] ?? "-"))")
                if !center.isActive { center.setEnabled(true) }
                done()
            }
        }
        step { done in self.waitUntil({ center.tileLabel != nil }, timeout: 2, then: done) }

        // The countdown and the card.
        run { [self] in
            check(source.requests == 1 && app?.settings.values.calendar.enabled == true, "calendar: access asked once (synthetic, no prompt)")
            check(tile()?.calendarFace?.text == "in 5m", "calendar: the tile counts down (\(tile()?.calendarFace?.text ?? "-"))")
            let label = tile()?.calendarFace?.label
            check(label.map { !$0.isHidden && $0.frame.width > 0 && tile()!.bounds.contains($0.frame) } == true,
                  "calendar: the countdown is drawn inside the tile (\(label.map { NSStringFromRect($0.frame) } ?? "-"))")
            check(prompt() == nil, "calendar: no Join prompt five minutes before")
            CalendarCard.shared.hide()
        }
        capture("calendar-tile")
        run { [self] in if let t = tile() { CalendarCard.shared.show(beside: t) } }
        wait(0.4)
        run { [self] in
            let m = CalendarCard.shared.model
            check(m.state == .events && m.events.map(\.id) == ["standup", "review", "lunch"],
                  "calendar: the card lists the next meetings, not the all-day one (\(m.events.map(\.id)))")
            check(TestAnchors.frames["calendar.join.0"] != nil && TestAnchors.frames["calendar.join.1"] != nil
                  && TestAnchors.frames["calendar.join.2"] == nil, "calendar: Join on the meetings with a call link only")
        }
        capture("calendar-card")
        clickIn({ CalendarCard.shared.panel }, "calendar.join.0")
        step { [self] done in
            waitUntil({ todayURLs().contains(base + "/standup") }, timeout: 2) {
                if !todayURLs().contains(base + "/standup") {
                    self.note("calendar: Join missed (\(TestAnchors.lastHit["calendar.join.0"] ?? "-")), clicking again")
                    if let p = CalendarCard.shared.panel { return self.clickAnchor("calendar.join.0", in: p) { done() } }
                }
                done()
            }
        }
        step { [self] done in
            waitUntil({ todayURLs().contains(base + "/standup") && self.c.engineTab(for: self.c.shownTabID ?? "")?.title == "Standup call" }, timeout: 5) {
                let shown = self.c.store.tab(self.c.shownTabID)
                self.check(shown?.url == base + "/standup" && shown?.spaceID == spaceID && self.c.currentSpaceID == spaceID,
                           "calendar: Join opens the call in this Space (\(shown?.url ?? "-"), \(TestAnchors.lastHit["calendar.join.0"] ?? "-"))")
                self.check(CalendarCard.shared.panel == nil, "calendar: the card closes on Join")
                done()
            }
        }

        // A minute before: the prompt.
        run { [self] in setNow(standup.start.addingTimeInterval(-40)) }
        wait(0.3)
        run { [self] in
            check(tile()?.calendarFace?.text == "in 1m", "calendar: the tile says in 1m (\(tile()?.calendarFace?.text ?? "-"))")
            check(prompt()?.text == "Standup · in 1 min", "calendar: the sidebar says Standup · in 1 min (\(prompt()?.text ?? "none"))")
            if let p = prompt(), let t = tile() {
                check(p.frame.minY > t.frame.maxY && p.convert(p.bounds, to: nil).width > 100, "calendar: the prompt sits under the Favorites")
            }
        }
        capture("calendar-prompt")
        step { [self] done in
            guard let p = prompt() else { check(false, "calendar: a prompt to click"); return done() }
            let before = todayURLs().count
            click(at: p.convert(NSPoint(x: p.joinRect.midX, y: p.joinRect.midY), to: nil), in: c.window) {
                self.waitUntil({ self.c.store.tab(self.c.shownTabID)?.url == base + "/standup" }, timeout: 2) {
                    self.check(self.c.store.tab(self.c.shownTabID)?.url == base + "/standup" && todayURLs().count == before,
                               "calendar: the prompt's Join shows the open call tab, no second one (\(todayURLs().count - before) new)")
                    done()
                }
            }
        }

        // Past the five late minutes: the prompt goes; the next meeting counts down.
        run { [self] in setNow(standup.start.addingTimeInterval(6 * 60)) }
        wait(0.3)
        run { [self] in
            check(prompt() == nil, "calendar: the prompt goes five minutes after the start")
            check(tile()?.calendarFace?.text == "in 34m", "calendar: the tile counts down to the next meeting (\(tile()?.calendarFace?.text ?? "-"))")
            let wake = center.timer.map { $0.fireDate.timeIntervalSinceNow }
            check(center.timer?.isValid == true && center.timer?.timeInterval == 0 && (wake ?? 99) <= 61,
                  "calendar: one one-shot timer, for the next minute (\(wake.map { String(format: "%.1f s", $0) } ?? "none"))")
            // A meeting added in the calendar app shows at once (EKEventStoreChanged).
            let coffee = CalendarEvent(id: "coffee", title: "Coffee chat", start: center.now().addingTimeInterval(110),
                                       end: center.now().addingTimeInterval(1800))
            source.set(events + [coffee])
        }
        step { done in self.waitUntil({ tile()?.calendarFace?.text == "in 2m" }, timeout: 2, then: done) }
        run { [self] in
            check(tile()?.calendarFace?.text == "in 2m", "calendar: a calendar change shows at once (\(tile()?.calendarFace?.text ?? "-"))")
            center.setEnabled(false)
        }
        wait(0.2)
        run { [self] in
            check(tile()?.calendarFace?.text == nil && prompt() == nil && center.timer == nil,
                  "calendar: turned off, no countdown, no prompt, no timer")
            if AppTelemetry.shared.resolution.state == .recordOnly {
                let features = records.filter { $0.event == "feature.used" }.compactMap { $0.properties["feature"]?.description }
                check(features.contains("calendar.enable") && features.contains("calendar.join"),
                      "calendar: calendar.enable and calendar.join recorded (\(features.filter { $0.hasPrefix("calendar") }))")
                let props = records.filter { $0.properties["feature"]?.description.hasPrefix("calendar") == true }.map { Set($0.properties.keys) }
                check(props.allSatisfy { !$0.contains("variant") && !$0.contains("title") && !$0.contains("url") },
                      "calendar: the events carry only their names")
            } else {
                skip("calendar: telemetry records nothing in this build (\(AppTelemetry.shared.resolution.state))")
            }
            Telemetry.shared.removeObserver(telemetryToken)
            center.now = Date.init
            server?.stop()
        }
    }
}
#endif
