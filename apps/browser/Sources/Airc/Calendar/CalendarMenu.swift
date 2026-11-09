// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

// Live Calendar's entries in a Calendar Favorite's menu, as in Arc's tab menu for a calendar Favorite: "Show Hover
// Preview", "Show Time to Next Meeting", "Show Next Meeting Link" (each per Favorite, on until turned off), the "Show
// Meeting Link" time (Ten, Five or Two Minutes Before, On Start; one for every calendar) and Arc's "Disable Live
// Calendar". While the feature is off, one entry turns it on.

extension WindowController {
    /// Adds the Calendar Favorite's Live Calendar entries to its menu (nothing for other items).
    func addCalendarItems(to m: NSMenu, item: Item) {
        guard item.isFavorite, CalendarTileFace.isCalendar(item) else { return }
        let center = CalendarCenter.shared
        m.addItem(.separator())
        defer { m.addItem(.separator()) }
        guard center.preferences.enabled else {
            m.add("Show Upcoming Meetings…") { center.setEnabled(true) }
            return
        }
        for s in CalendarPreferences.Switch.allCases {
            let on = center.shows(s, for: item.id)
            m.add(s.title) { [weak self] in
                guard let self else { return }
                center.set(s, !on, for: item.id, store: self.store)
            }.state = on ? .on : .off
        }
        let lead = NSMenuItem(title: "Show Meeting Link", action: nil, keyEquivalent: "")
        let times = NSMenu()
        for l in JoinLead.allCases {
            times.add(l.title) { center.setJoinLead(l) }.state = center.preferences.joinLead == l ? .on : .off
        }
        lead.submenu = times
        lead.isEnabled = center.shows(.joinLink, for: item.id)
        m.addItem(lead)
        m.add("Turn Off Live Calendar") { center.setEnabled(false) }
    }
}

extension WindowController {
    /// The Command Bar's "Join Next Meeting" (Arc's "Join next video conference"), while Live Calendar is on and a
    /// Calendar Favorite exists.
    func calendarCommandActions() -> [CommandAction] {
        let center = CalendarCenter.shared
        guard center.preferences.enabled, center.joinSpace(self) != nil else { return [] }
        return [.init(title: "Join Next Meeting", symbol: "video", hint: ShortcutCenter.hint("tabs.joinMeeting", "⌃⌘J"),
                      keywords: ["meeting", "call", "calendar", "zoom", "meet", "teams", "video", "join"]) { [weak self] in
            guard let self else { return }
            center.joinNext(controller: self)
        }]
    }
}
