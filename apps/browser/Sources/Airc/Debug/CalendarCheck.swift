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
///   - Arc's per-Favorite menu (2026-11-07): "Show Meeting Link" times (Two Minutes Before by default; Ten Minutes Before
///     brings the Join earlier), "Show Next Meeting Link", "Show Time to Next Meeting" and "Show Hover Preview" each turn
///     their part off and on for that Favorite;
///   - the card: the big Join only for meetings moments away, "+" opens the calendar's new-event page and a meeting row
///     its day, in the Calendar Favorite (read through a hook: no real calendar site loads);
///   - ⌃⌘J joins the next meeting outside the prompt's time, shows the open call the second time, and from a Space of
///     another profile opens it in the calendar's Space;
///   - `calendar.enable` and `calendar.join` are recorded, with nothing but their names.
/// Posted clicks and keys in the new parts wait for the owner to be away (no hardware input for 120 s, our window on
/// the active Space); otherwise those checks are FAIL-ENV with the evidence, and the same actions run directly.
/// Writes calendar-invite.png, calendar-tile.png, calendar-card.png, calendar-prompt.png, calendar-menu-lead.png and
/// calendar-card-soon.png.
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
        // A run with telemetry off (AIRC_TELEMETRY_ENABLED=0, the release suite) records nothing: this run turns
        // record-only for the check, so the events below are checked either way. Nothing is sent.
        AppTelemetry.shared.recordOnlyForCheck()
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
        }
        calendarArcParity(center: center, base: { base }, spaceID: { spaceID }, calendarItem: { calendarItem }, events: { events },
                          tile: tile, prompt: prompt, todayURLs: todayURLs, setNow: setNow)
        run { center.setEnabled(false) }
        wait(0.2)
        run { [self] in
            check(tile()?.calendarFace?.text == nil && prompt() == nil && center.timer == nil,
                  "calendar: turned off, no countdown, no prompt, no timer")
            if AppTelemetry.shared.resolution.records {
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

    /// The Calendar Favorite's menu, its per-Favorite switches and Join time, the card's "+", rows and big Join, and
    /// ⌃⌘J (calendarScenario's second half; "review" is the next meeting with a call, 45 minutes after the start).
    private func calendarArcParity(center: CalendarCenter, base: @escaping () -> String, spaceID: @escaping () -> String,
                                   calendarItem: @escaping () -> String, events: @escaping () -> [CalendarEvent],
                                   tile: @escaping () -> FavoriteTileView?, prompt: @escaping () -> CalendarPromptView?,
                                   todayURLs: @escaping () -> [String], setNow: @escaping (Date) -> Void) {
        var review: CalendarEvent { events().first { $0.id == "review" }! }
        func menu() -> NSMenu? {
            guard let item = c.store.item(calendarItem()) else { return nil }
            return c.menu(for: .favorite(item, c.store.liveTab(forItem: item.id)))
        }
        /// Runs the menu item titled `title` (in `path`'s submenu) as a click on it would.
        func pick(_ title: String, in path: String? = nil) -> Bool {
            guard var m = menu() else { return false }
            if let path { guard let sub = m.item(withTitle: path)?.submenu else { return false }; m = sub }
            guard let i = m.items.firstIndex(where: { $0.title == title }), m.items[i].isEnabled else { return false }
            m.performActionForItem(at: i)
            return true
        }
        func state(_ title: String, in path: String? = nil) -> NSControl.StateValue? {
            let m = path.flatMap { menu()?.item(withTitle: $0)?.submenu } ?? menu()
            return m?.item(withTitle: title)?.state
        }
        var opened: [(url: String, item: String)] = []
        center.openedForTesting = { url, item in opened.append((url.absoluteString, item)) }

        // The menu, and Arc's Join times.
        run { [self] in
            let titles = menu()?.items.map(\.title) ?? []
            let times = menu()?.item(withTitle: "Show Meeting Link")?.submenu?.items.map(\.title) ?? []
            let switches = ["Show Time to Next Meeting", "Show Next Meeting Link", "Show Hover Preview"]
            check(switches.allSatisfy { titles.contains($0) && state($0) == .on } && titles.contains("Turn Off Live Calendar")
                  && times == ["Ten Minutes Before", "Five Minutes Before", "Two Minutes Before", "On Start"]
                  && state("Two Minutes Before", in: "Show Meeting Link") == .on,
                  "calendar menu: Arc's per-Favorite switches (on), Show Meeting Link › \(times) with Two Minutes Before ticked")
            setNow(review.start.addingTimeInterval(-9.5 * 60))
        }
        wait(0.3)
        run { [self] in
            check(prompt() == nil, "calendar menu: 9½ minutes before, no Join yet with Two Minutes Before (\(prompt()?.text ?? "none"))")
            check(pick("Ten Minutes Before", in: "Show Meeting Link"), "calendar menu: Ten Minutes Before can be picked")
        }
        wait(0.4)
        run { [self] in
            check(prompt()?.text == "Design review · in 10 min" && state("Ten Minutes Before", in: "Show Meeting Link") == .on
                  && app?.settings.values.calendar.joinLead == .tenMinutes,
                  "calendar menu: Ten Minutes Before brings the Join now (\(prompt()?.text ?? "none")), saved and ticked")
            check(pick("Show Next Meeting Link"), "calendar menu: Show Next Meeting Link can be turned off")
        }
        wait(0.4)
        run { [self] in
            check(prompt() == nil && state("Show Next Meeting Link") == .off && menu()?.item(withTitle: "Show Meeting Link")?.isEnabled == false,
                  "calendar menu: Show Next Meeting Link off hides this Favorite's Join (\(prompt()?.text ?? "none")) and greys its times")
            _ = pick("Show Next Meeting Link")
            check(pick("Show Time to Next Meeting"), "calendar menu: Show Time to Next Meeting can be turned off")
        }
        wait(0.4)
        run { [self] in
            check(prompt()?.text == "Design review · in 10 min", "calendar menu: on again, the Join is back (\(prompt()?.text ?? "none"))")
            check(tile()?.calendarFace?.text == nil, "calendar menu: Show Time to Next Meeting off hides the countdown (\(tile()?.calendarFace?.text ?? "none"))")
            _ = pick("Show Time to Next Meeting")
        }
        wait(0.3)
        run { [self] in
            check(tile()?.calendarFace?.text == "in 10m", "calendar menu: on again, the countdown is back (\(tile()?.calendarFace?.text ?? "none"))")
            check(pick("Show Hover Preview"), "calendar menu: Show Hover Preview can be turned off")
            CalendarCard.shared.hide()
            if let t = tile() { t.calendarFace?.hover(true) }
        }
        capture("calendar-menu-lead")
        wait(0.8)
        run { [self] in
            check(CalendarCard.shared.panel == nil, "calendar menu: Show Hover Preview off, resting on the tile shows no card")
            tile()?.calendarFace?.hover(false)
            _ = pick("Show Hover Preview")
            if let t = tile() { t.calendarFace?.hover(true) }
        }
        wait(0.8)
        run { [self] in
            let m = CalendarCard.shared.model
            check(CalendarCard.shared.panel != nil, "calendar menu: on again, resting on the tile shows the card")
            tile()?.calendarFace?.hover(false)
            // Upcoming: the coffee chat (on now, no call), the review (9½ minutes away), lunch (later, no call).
            check(m.events.map(\.id) == ["coffee", "review", "lunch"] && m.soon.contains("review") && !m.soon.contains("lunch")
                  && TestAnchors.frames["calendar.join.1"] != nil && m.canCreate && TestAnchors.frames["calendar.newEvent"] != nil,
                  "calendar card: the big Join only for meetings moments away (\(m.soon.sorted())), and the calendar's “+” (\(m.events.map(\.id)))")
        }
        capture("calendar-card-soon")
        // "+" and a row, by real clicks while the owner is away (the card comes back: the hover ended above).
        run { [self] in if let t = tile() { CalendarCard.shared.show(beside: t) } }
        wait(0.4)
        step { [self] done in
            whenOwnerAway { why in
                let want = "https://calendar.google.com/calendar/u/0/r/eventedit"
                if let why {
                    self.failEnv("calendar card: a real click on “+”", why)
                    CalendarCard.shared.model.onNewEvent()
                    self.check(opened.last?.url == want && opened.last?.item == calendarItem(),
                               "calendar card: “+” (run directly) opens the new-event page in the Calendar Favorite (\(opened.last?.url ?? "-"))")
                    return done()
                }
                self.clickAnchor("calendar.newEvent", in: CalendarCard.shared.panel ?? self.c.root) {
                    self.check(opened.last?.url == want && opened.last?.item == calendarItem() && CalendarCard.shared.panel == nil,
                               "calendar card: a click on “+” opens the new-event page in the Calendar Favorite and closes the card "
                               + "(\(opened.last?.url ?? "-"), \(TestAnchors.lastHit["calendar.newEvent"] ?? "-"))")
                    done()
                }
            }
        }
        run { [self] in if let t = tile() { CalendarCard.shared.show(beside: t) } }
        wait(0.4)
        step { [self] done in
            let d = Calendar.current.dateComponents([.year, .month, .day], from: review.start)
            let want = "https://calendar.google.com/calendar/u/0/r/day/\(d.year!)/\(d.month!)/\(d.day!)"
            let count = opened.count
            whenOwnerAway { why in
                if let why {
                    self.failEnv("calendar card: a real click on a meeting row", why)
                    CalendarCard.shared.model.onOpen(review)
                    self.check(opened.count == count + 1 && opened.last?.url == want,
                               "calendar card: a meeting row (run directly) opens its day in the Calendar Favorite (\(opened.last?.url ?? "-"))")
                    return done()
                }
                self.clickAnchor("calendar.row.1", in: CalendarCard.shared.panel ?? self.c.root) {
                    self.check(opened.count == count + 1 && opened.last?.url == want,
                               "calendar card: a click on a meeting row opens its day in the Calendar Favorite (\(opened.last?.url ?? "-"), "
                               + "\(TestAnchors.lastHit["calendar.row.1"] ?? "-"))")
                    done()
                }
            }
        }
        run {
            CalendarCard.shared.hide()
            center.openedForTesting = nil
        }

        // ⌃⌘J: the next meeting, outside the prompt's time; again, the open call; from another profile's Space, in the
        // calendar's Space.
        run { [self] in
            setNow(review.start.addingTimeInterval(-25 * 60))
            let bound = CommandMenus.all.first { $0.id == "tabs.joinMeeting" }
            check(bound?.key == "j" && bound?.modifiers == [.command, .control], "⌃⌘J: Join Next Meeting is bound to ⌃⌘J")
            check(c.commandActions().contains { $0.title == "Join Next Meeting" }, "⌃⌘J: the Command Bar lists Join Next Meeting")
        }
        wait(0.3)
        func joinKey(_ label: String) {
            step { [self] done in
                whenOwnerAway { why in
                    if let why {
                        self.failEnv("⌃⌘J (\(label)): the posted key", why)
                        CommandMenus.all.first { $0.id == "tabs.joinMeeting" }?.run(self.c)
                        return done()
                    }
                    self.postKey("j", keyCode: 38, modifiers: [.command, .control])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        var before = 0
        run { before = todayURLs().filter { $0 == base() + "/review" }.count }
        joinKey("first")
        step { [self] done in
            waitUntil({ self.c.store.tab(self.c.shownTabID)?.url == base() + "/review" }, timeout: 3) {
                let shown = self.c.store.tab(self.c.shownTabID)
                self.check(shown?.url == base() + "/review" && self.c.currentSpaceID == spaceID() && todayURLs().filter { $0 == base() + "/review" }.count == before + 1,
                           "⌃⌘J: 25 minutes before, it joins the next meeting with a call, in this Space (\(shown?.url ?? "-"))")
                done()
            }
        }
        var other = ""
        run { [self] in
            guard let p = try? c.store.createProfile(name: "Calendar elsewhere"),
                  let s = try? c.store.createSpace(name: "No calendar", profileID: p.id, after: spaceID()) else {
                return check(false, "⌃⌘J: a Space of another profile")
            }
            other = s.id
            c.switchToSpace(other, animated: false)
            check(center.joinSpace(c) == spaceID(), "⌃⌘J: from a Space whose profile has no calendar, the call's Space is the calendar's")
        }
        wait(0.5)
        joinKey("another profile's Space")
        step { [self] done in
            waitUntil({ self.c.currentSpaceID == spaceID() && self.c.store.tab(self.c.shownTabID)?.url == base() + "/review" }, timeout: 3) {
                self.check(self.c.currentSpaceID == spaceID() && self.c.store.tab(self.c.shownTabID)?.url == base() + "/review"
                           && todayURLs().filter { $0 == base() + "/review" }.count == before + 1,
                           "⌃⌘J: from another profile's Space it goes to the calendar's Space and shows the open call, no second tab "
                           + "(Space \(self.c.currentSpaceID == spaceID() ? "the calendar's" : "another"))")
                if !other.isEmpty { try? self.c.store.deleteSpace(other) }
                done()
            }
        }
    }
}
#endif
