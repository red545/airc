// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit

/// M08's seam (CalendarAccountEvents): Live Calendar's meetings from a Calendar Favorite's account (Google Calendar,
/// Outlook Calendar) when its calendars aren't on this Mac. It reads what the service previews' calendar provider last
/// answered for each Calendar Favorite's account (ServicePreviewCenter), and asks again only for accounts whose site
/// was opened in their profile, at most once a minute. Airc has no real calendar provider yet (P11b/c); scripted runs
/// use the fake one on loopback fixtures.
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

    /// Each Calendar Favorite's account, where its service has a provider (Live Calendar is the Favorites'; a pinned
    /// calendar has its card and row line only).
    var accounts: [PreviewAccount] {
        guard let store = (NSApp.delegate as? AppDelegate)?.store else { return [] }
        let center = ServicePreviewCenter.shared
        var out: [PreviewAccount] = []
        for item in store.state.items.values where item.isFavorite && CalendarTileFace.isCalendar(item) {
            guard let url = item.savedURL, let profile = item.profileID ?? item.spaceID.map({ store.profile(ofSpace: $0).id }),
                  let a = PreviewAccount(url: url, profileID: profile), a.service.family == .calendar,
                  center.provider(for: a.service) != nil, !out.contains(a) else { continue }
            out.append(a)
        }
        return out.sorted { $0.description < $1.description }
    }

    var hasAccounts: Bool {
        accounts.contains { a in
            if case .calendar? = ServicePreviewCenter.shared.state(a)?.content { return true }
            return false
        }
    }

    /// The accounts' meetings, each ID made unique to its account (two accounts can use the same event IDs).
    func events(from: Date, to: Date) -> [CalendarEvent] {
        var out: [CalendarEvent] = []
        for a in accounts {
            guard case .calendar(let events)? = ServicePreviewCenter.shared.state(a)?.content else { continue }
            for var e in events where e.end > from && e.start < to {
                e.id = "\(a.service.rawValue)/\(a.key)/\(e.id)"
                out.append(e)
            }
        }
        return out
    }

    func refresh() {
        for a in accounts { ServicePreviewCenter.shared.refresh(a) }
    }
}
