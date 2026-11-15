// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit

/// calgrid: synthetic calendar answers for the marketing shot (no page, no network): the events it was given, always.
final class MarketingCalendarProvider: ServicePreviewProvider {
    let services: Set<PreviewService> = [.googleCalendar]
    var fetchesRemotely: Bool { false }
    var events: [CalendarEvent] = []
    func fetch(_ account: PreviewAccount, completion: @escaping (PreviewState) -> Void) {
        let e = events
        DispatchQueue.main.async { completion(.ready(.calendar(e))) }
    }
    func signIn(_ account: PreviewAccount, completion: @escaping () -> Void) { completion() }
    func remove(_ account: PreviewAccount) {}
}

extension SnapshotRunner {
    /// `calendar-preview` and `calendar-preview-dark`: resting on a pinned Google Calendar tab shows Arc's hour grid (calgrid). The clock reads 15:55
    /// local whenever the shot is taken, so the grid is the same in every run; the events are synthetic.
    func mkCalGridShots(_ d: MarketingDemo) {
        let name = "calendar-preview"
        let center = ServicePreviewCenter.shared
        let provider = MarketingCalendarProvider()
        var items: [String: String] = [:]
        let calendarWasOn = CalendarCenter.shared.cardState != nil
        mkShow(d, "personal", "swift")
        mkSettleShown(timeout: 15, extra: 0.6)
        run { [self] in
            let cal = Calendar.current
            let t0 = cal.date(bySettingHour: 15, minute: 55, second: 0, of: Date()) ?? Date()
            let day = cal.startOfDay(for: t0)
            func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
            func tomorrow(_ h: Int, _ m: Int = 0) -> Date { cal.date(byAdding: .minute, value: 24 * 60 + h * 60 + m, to: day) ?? t0 }
            let meet = { (s: String) in MeetingLink(url: URL(string: "https://meet.google.com/" + s)!, service: .meet) }
            provider.events = [
                CalendarEvent(id: "lunch", title: "Lunch with Maya", start: at(-175), end: at(-115)),
                CalendarEvent(id: "trip", title: "Lisbon trip", start: day, end: cal.date(byAdding: .day, value: 1, to: day) ?? t0, isAllDay: true),
                CalendarEvent(id: "review", title: "Design review", start: at(5), end: at(50), link: meet("abc-mnop-xyz")),
                CalendarEvent(id: "sync", title: "1:1 with Jonas", start: at(20), end: at(50),
                              link: MeetingLink(url: URL(string: "https://zoom.us/j/5550100")!, service: .zoom)),
                CalendarEvent(id: "focus", title: "Write the launch notes", start: at(65), end: at(155)),
                CalendarEvent(id: "tram", title: "Tram 28 to Alfama", start: at(185), end: at(215)),
                CalendarEvent(id: "dinner", title: "Dinner at Time Out Market", start: at(245), end: at(335)),
                CalendarEvent(id: "standup", title: "Team standup", start: tomorrow(9, 30), end: tomorrow(9, 45), link: meet("qrs-tuvw-xyz")),
                CalendarEvent(id: "launch", title: "Launch planning", start: tomorrow(11), end: tomorrow(12)),
            ]
            center.now = { t0 }
            if calendarWasOn { CalendarCenter.shared.setEnabled(false) }
            center.register(provider)
            // A pinned Google Calendar tab of the same account (its week view), as the mail shot pins Gmail.
            let url = "https://calendar.google.com/calendar/u/0/r/week"
            for space in ["personal", "work"] {
                guard let sid = d.space[space] else { continue }
                do {
                    try pin(url, title: "Google Calendar", icon: nil, space: sid)
                    items[space] = c.store.pinnedRoots(ofSpace: sid).last { $0.savedURL == url }?.id ?? ""
                } catch { note("marketing: MISSING \(name): \(error)") }
            }
            c.reloadAll(animated: false)
        }
        // Light: Personal (Mint) on swift.org. Dark: Work (Grape, a dark theme) on linear.app with the system dark, as the
        // dark hero does; the card follows the window's theme.
        for (dark, space, tab) in [(false, "personal", "swift"), (true, "work", "linear")] {
            run { [self] in
                if let row = c.tabPreview.shownRow { c.tabPreview.hoverEnded(row, event: nil) }
                c.tabPreview.hide()
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            }
            mkShow(d, space, tab)
            mkSettleShown(timeout: 10, extra: 0.8)
            wait(0.4)
            run { [self] in
                guard let page = c.pageView(for: c.currentSpaceID) else { return }
                page.layoutSubtreeIfNeeded()
                guard let row = page.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.entry?.item?.id == items[space] }) else {
                    return note("marketing: MISSING \(name): no pinned Google Calendar row")
                }
                let p = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
                if let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                    row.mouseEntered(with: e)
                }
            }
            wait(TabPreviewController.dwell + 1.2)
            run { [self] in
                if c.tabPreview.thumbnail != .service { note("marketing: MISSING \(name): the card shows \(c.tabPreview.thumbnail.rawValue)") }
                let blocks = TestAnchors.frames.keys.filter { $0.hasPrefix("svc.event.") }.count
                if case .calendar(let e)? = c.tabPreview.serviceCard?.model.state.content, TestAnchors.frames["svc.grid"] != nil {
                    note("marketing: \(name) \(space): theme dark \(c.tabPreview.serviceCard?.model.theme.isDark == true), \(e.count) events, \(blocks) on the card, now line \(TestAnchors.frames["svc.nowLine"] != nil)")
                } else {
                    note("marketing: MISSING \(name): no hour grid (\(String(describing: c.tabPreview.serviceCard?.model.state)))")
                }
            }
            mkWindowShot(dark ? name + "-dark" : name, dark: dark)
        }
        run { [self] in
            if let row = c.tabPreview.shownRow { c.tabPreview.hoverEnded(row, event: nil) }
            c.tabPreview.hide()
            center.now = Date.init
            center.unregister(provider.services)
            if calendarWasOn { CalendarCenter.shared.setEnabled(true) }
            NSApp.appearance = nil
        }
        wait(0.3)
    }
}
#endif
