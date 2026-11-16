// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// M08's seam (CalendarAccountEvents): Live Calendar's meetings from a Calendar Favorite's account (Google Calendar,
/// Outlook Calendar) when its calendars aren't on this Mac. It reads what the service previews' calendar provider last
/// answered for each Calendar Favorite's account (ServicePreviewCenter), and asks again only for accounts whose site
/// was opened in their profile, at most once a minute. The provider is the calendar page's own reader (calprev,
/// PageMailProvider): a Favorite's account gives meetings once its page has been read in its profile. calmeet: pinned
/// calendar tabs count too, and with any of them Live Calendar uses these meetings alone (LiveCalendarSource).
final class PreviewCalendarAccounts: CalendarAccountEvents {
    static let shared = PreviewCalendarAccounts()
    var onChange: (() -> Void)?
    private var observer: NSObjectProtocol?
    private var pending = false

    private init() {
        observer = NotificationCenter.default.addObserver(forName: ServicePreviewCenter.changed, object: nil, queue: .main) { [weak self] n in
            if let a = n.object as? PreviewAccount, a.service.family != .calendar { return }
            self?.changed()
        }
    }

    /// Several answers in one turn tell Live Calendar once, after the turn (never from inside its own update).
    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.onChange?()
        }
    }

    /// The calendar Favorites and pinned tabs (Favorites first, then pinned ones, each in a stable order).
    private var calendarItems: [Item] {
        guard let store = (NSApp.delegate as? AppDelegate)?.store else { return [] }
        let items = store.state.items.values.filter { CalendarTileFace.isCalendar($0) && $0.savedURL != nil }
        return items.filter(\.isFavorite).sorted { $0.id < $1.id } + items.filter { !$0.isFavorite }.sorted { $0.id < $1.id }
    }

    /// Whether Airc reads `s`'s page (calmeet: a Google Calendar or Outlook page, through its provider).
    private func reads(_ s: PreviewService) -> Bool { ServicePreviewCenter.shared.provider(for: s) != nil }

    /// calmeet: a Google or Outlook calendar is a Favorite or pinned tab, so Live Calendar takes its meetings from the
    /// pages alone, never from EventKit (LiveCalendarSource).
    var hasWebCalendar: Bool { LiveCalendarSource.choose(calendarItems.compactMap(\.savedURL), reads: reads) == .pages }

    /// Each calendar Favorite's and pinned tab's account, where its service has a provider, Favorites first.
    var accounts: [PreviewAccount] {
        guard let store = (NSApp.delegate as? AppDelegate)?.store else { return [] }
        var favorites: [PreviewAccount] = [], pinned: [PreviewAccount] = []
        for item in calendarItems {
            guard let url = item.savedURL, let profile = item.profileID ?? item.spaceID.map({ store.profile(ofSpace: $0).id }),
                  let a = PreviewAccount(url: url, profileID: profile), a.service.family == .calendar, reads(a.service),
                  !favorites.contains(a), !pinned.contains(a) else { continue }
            if item.isFavorite { favorites.append(a) } else { pinned.append(a) }
        }
        return favorites.sorted { $0.description < $1.description } + pinned.sorted { $0.description < $1.description }
    }

    var hasAccounts: Bool {
        accounts.contains { a in
            if case .calendar? = ServicePreviewCenter.shared.state(a)?.content { return true }
            return false
        }
    }

    /// The accounts' meetings, each ID made unique to its account (two accounts can use the same event IDs), one list per
    /// account in `accounts`' order. An account whose page isn't loaded keeps what was read last (PageMailProvider).
    func events(from: Date, to: Date) -> [[CalendarEvent]] {
        accounts.map { a in
            guard case .calendar(let events)? = ServicePreviewCenter.shared.state(a)?.content else { return [] }
            return events.filter { $0.end > from && $0.start < to }.map { e in
                var e = e
                e.id = "\(a.service.rawValue)/\(a.key)/\(e.id)"
                return e
            }
        }
    }

    func refresh() {
        for a in accounts { ServicePreviewCenter.shared.refresh(a) }
    }
}
