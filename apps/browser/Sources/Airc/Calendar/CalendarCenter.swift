// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine
import EventKit

/// Live Calendar (Arc ref §2.3): the Calendar Favorite counts down to the next meeting, lists the next ones on hover
/// with Join buttons, and the sidebar says "Meeting in 1 min · Join". The meetings come from the calendars on this Mac
/// (EventKit), which is where Google, iCloud and Exchange accounts sync to. Off until the person turns it on.

/// Settings → General → Calendar, saved with the other settings.
struct CalendarPreferences: Codable, Equatable {
    var enabled = false
    /// The Calendar Favorite's one-time "Show your next meetings here?" was answered "Not Now".
    var invitationDismissed = false
    /// Arc's "Show Meeting Link" time: how long before a meeting the sidebar's Join comes (the Calendar Favorite's menu,
    /// and Settings).
    var joinLead: JoinLead = .twoMinutes
    /// Calendar Favorites (item IDs) with one of Arc's per-Favorite switches turned off: "Show Time to Next Meeting"
    /// (the tile's countdown), "Show Next Meeting Link" (the Join under the Favorites) and "Show Hover Preview" (the
    /// card). A Calendar Favorite has all three until the person turns one off in its menu.
    var noCountdown: Set<String> = []
    var noJoinLink: Set<String> = []
    var noPreview: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        invitationDismissed = (try? c.decodeIfPresent(Bool.self, forKey: .invitationDismissed)) ?? false
        joinLead = (try? c.decodeIfPresent(JoinLead.self, forKey: .joinLead)) ?? .twoMinutes
        noCountdown = (try? c.decodeIfPresent(Set<String>.self, forKey: .noCountdown)) ?? []
        noJoinLink = (try? c.decodeIfPresent(Set<String>.self, forKey: .noJoinLink)) ?? []
        noPreview = (try? c.decodeIfPresent(Set<String>.self, forKey: .noPreview)) ?? []
    }

    /// Arc's per-Favorite switches.
    enum Switch: CaseIterable {
        case countdown, joinLink, preview

        /// Arc's menu titles.
        var title: String {
            switch self {
            case .countdown: "Show Time to Next Meeting"
            case .joinLink: "Show Next Meeting Link"
            case .preview: "Show Hover Preview"
            }
        }
    }

    func shows(_ s: Switch, for itemID: String) -> Bool {
        switch s {
        case .countdown: !noCountdown.contains(itemID)
        case .joinLink: !noJoinLink.contains(itemID)
        case .preview: !noPreview.contains(itemID)
        }
    }

    /// `existing`: the Calendar Favorites there are, so a deleted one's switches don't stay behind.
    mutating func set(_ s: Switch, _ on: Bool, for itemID: String, existing: Set<String>) {
        func apply(_ set: inout Set<String>) {
            if on { set.remove(itemID) } else { set.insert(itemID) }
            set.formIntersection(existing.union([itemID]))
        }
        switch s {
        case .countdown: apply(&noCountdown)
        case .joinLink: apply(&noJoinLink)
        case .preview: apply(&noPreview)
        }
    }
}

enum CalendarAccess: Equatable {
    case notDetermined, granted, denied
}

/// Where meetings come from: EventKit, or a synthetic source in tests and scripted runs (Debug/CalendarCheck.swift),
/// which never touch the person's calendars or raise the permission prompt.
protocol CalendarEventSource: AnyObject {
    var access: CalendarAccess { get }
    /// Asks for access (EventKit shows the system prompt once); `done` runs on the main queue.
    func requestAccess(_ done: @escaping (Bool) -> Void)
    /// Timed and all-day events overlapping the range, on any queue.
    func events(from: Date, to: Date) -> [CalendarEvent]
    /// Called on the main queue when the calendars changed (EKEventStoreChanged).
    var onChange: (() -> Void)? { get set }
}

/// The calendars synced to this Mac. The store is made on first use, after the person turned the feature on.
final class EventKitCalendarSource: CalendarEventSource {
    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied   // write-only, denied, restricted
        }
    }

    private func eventStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: s, queue: .main) { [weak self] _ in
            self?.onChange?()
        }
        return s
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        eventStore().requestFullAccessToEvents { granted, _ in DispatchQueue.main.async { done(granted) } }
    }

    func events(from: Date, to: Date) -> [CalendarEvent] {
        guard access == .granted else { return [] }
        let s = eventStore()
        return s.events(matching: s.predicateForEvents(withStart: from, end: to, calendars: nil)).compactMap { e in
            guard e.status != .canceled,
                  e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined,
                  let start = e.startDate, let end = e.endDate else { return nil }
            return CalendarEvent(id: "\(e.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
                                 title: e.title?.isEmpty == false ? e.title! : "Untitled meeting", start: start, end: end,
                                 isAllDay: e.isAllDay,
                                 link: MeetingLink.find(url: e.url?.absoluteString, location: e.location, notes: e.notes))
        }
    }
}

/// M08: meetings from calendar accounts that aren't on this Mac (EventKit has no account for them): a Calendar
/// Favorite's account in the service previews (Previews/CalendarProvider.swift). They join EventKit's meetings for the
/// countdown, the Join prompt, ⌃⌘J and the card, and work without EventKit's access. With nothing signed in, Live
/// Calendar is EventKit's alone.
protocol CalendarAccountEvents: AnyObject {
    /// Whether an account gives meetings now (signed in, and answered).
    var hasAccounts: Bool { get }
    /// The accounts' meetings overlapping the range, from their last answers (main queue).
    func events(from: Date, to: Date) -> [CalendarEvent]
    /// Asks the accounts again when their answers are old (only accounts whose site was opened in their profile).
    func refresh()
    /// Called on the main queue when an account's meetings may have changed.
    var onChange: (() -> Void)? { get set }
}

/// The meetings, what the tile, the card and the prompt show, and when that next changes. Nothing polls: it reads the
/// calendars when they change (and every few hours, for the window it reads), and wakes once, on a one-shot timer,
/// at the next moment a label changes (MeetingSchedule.nextBoundary). Idle while no Calendar Favorite is on screen.
final class CalendarCenter: ObservableObject {
    static let shared = CalendarCenter()
    /// Posted (main queue) whenever what the tile, the card or the prompt shows may have changed.
    static let changed = Notification.Name("AircCalendarChanged")

    private(set) var source: CalendarEventSource
    /// The time; scripted runs move it to see the countdown, the prompt and the end of a meeting without waiting.
    var now: () -> Date = Date.init
    #if AIRC_TESTING
    /// Scripted runs: what the card's "+" and its rows would open in the Calendar Favorite, instead of opening it.
    var openedForTesting: ((URL, String) -> Void)?
    #endif
    @Published private(set) var access: CalendarAccess
    private(set) var events: [CalendarEvent] = []
    /// The prompts the person closed (this launch).
    private(set) var dismissed: Set<String> = []
    /// The one pending wake-up, if any (scripted runs check there is never more than this one).
    private(set) var timer: Timer?
    private(set) var fetchedAt: Date?
    private var fetching = false
    private var refetchAfterFetch = false
    private let queue = DispatchQueue(label: "airc.calendar", qos: .utility)
    /// Calendar Favorite tiles alive in any window (CalendarTileFace); the center runs only while there are some.
    private var faces = 0
    /// M08's calendar accounts (set when a calendar preview provider registers, ServicePreviewCenter.register).
    var accounts: CalendarAccountEvents? {
        didSet {
            accounts?.onChange = { [weak self] in self?.accountsChanged() }
            accountsChanged()
        }
    }
    private var hasAccounts: Bool { accounts?.hasAccounts == true }
    private var systemObservers: [NSObjectProtocol] = []

    private init() {
        #if AIRC_TESTING
        // Scripted and automated runs never read the real calendars or ask for access.
        source = LaunchOptions.current.isAutomated ? SyntheticCalendarSource() : EventKitCalendarSource()
        #else
        source = EventKitCalendarSource()
        #endif
        access = source.access
        source.onChange = { [weak self] in self?.fetch() }
    }

    private var settings: AppSettings? { (NSApp.delegate as? AppDelegate)?.settings }
    var preferences: CalendarPreferences { settings?.values.calendar ?? CalendarPreferences() }
    /// On, allowed (or an account gives meetings, M08), and a Calendar Favorite to show it on.
    var isActive: Bool { preferences.enabled && (access == .granted || hasAccounts) && faces > 0 }

    // MARK: What to show

    var tileLabel: String? { isActive ? MeetingSchedule.tileLabel(events, now: now()) : nil }
    var promptEvent: CalendarEvent? {
        isActive ? MeetingSchedule.promptEvent(events, now: now(), dismissed: dismissed, lead: preferences.joinLead.seconds) : nil
    }
    var upcoming: [CalendarEvent] { isActive ? MeetingSchedule.upcoming(events, now: now()) : [] }

    /// Arc's per-Favorite switch (the Calendar Favorite's menu).
    func shows(_ s: CalendarPreferences.Switch, for itemID: String?) -> Bool {
        itemID.map { preferences.shows(s, for: $0) } ?? true
    }

    func set(_ s: CalendarPreferences.Switch, _ on: Bool, for itemID: String, store: SpacesStore) {
        guard let settings else { return }
        let existing = Set(store.state.items.values.filter { CalendarTileFace.isCalendar($0) }.map(\.id))
        settings.values.calendar.set(s, on, for: itemID, existing: existing)
        if s == .preview, !on { CalendarCard.shared.hide() }
        notify()
    }

    /// Arc's "Show Meeting Link" time.
    func setJoinLead(_ lead: JoinLead) {
        guard let settings, settings.values.calendar.joinLead != lead else { return }
        settings.values.calendar.joinLead = lead
        reschedule()
        notify()
    }

    /// Whether the card's Join for `e` is the big one: a meeting moments away (Arc), or on now.
    func isSoon(_ e: CalendarEvent) -> Bool {
        let r = e.start.timeIntervalSince(now())
        return r <= MeetingSchedule.soonJoin && now() < e.end
    }

    func label(for e: CalendarEvent) -> String? {
        let r = e.start.timeIntervalSince(now())
        return r <= MeetingSchedule.countdownLead && (r > 0 || -r < MeetingSchedule.lateJoin) ? MeetingSchedule.label(for: e, now: now()) : nil
    }

    func promptLabel(for e: CalendarEvent) -> String { MeetingSchedule.promptLabel(for: e, now: now()) }

    /// What the hover card should show.
    enum CardState: Equatable { case invitation, denied, events }
    var cardState: CardState? {
        let p = preferences
        if !p.enabled { return p.invitationDismissed ? nil : .invitation }
        if hasAccounts { return .events }
        return access == .denied ? .denied : access == .granted ? .events : .invitation
    }

    // MARK: Turning it on and off

    /// Settings' switch, or the invitation's Turn On (`true`). Asks for access the first time.
    func setEnabled(_ on: Bool) {
        guard let settings else { return }
        settings.values.calendar.enabled = on
        if on {
            Telemetry.shared.record(.featureUsed(.calendarEnable))
            if source.access == .notDetermined {
                source.requestAccess { [weak self] _ in self?.accessChanged() }
                return
            }
        }
        accessChanged()
    }

    func dismissInvitation() {
        settings?.values.calendar.invitationDismissed = true
        notify()
    }

    func dismissPrompt(_ id: String) {
        dismissed.insert(id)
        notify()
    }

    /// Re-reads access (after the prompt, or when Airc comes back from System Settings).
    func accessChanged() {
        let a = source.access
        if a != access { access = a }
        update()
    }

    // MARK: Tiles

    func faceAppeared() {
        faces += 1
        if faces == 1 { update() }
    }

    func faceGone() {
        faces = max(0, faces - 1)
        if faces == 0 { update() }
    }

    // MARK: Refresh

    /// Starts or stops reading and waking, as `isActive` says, and tells the views.
    func update() {
        // The accounts are asked whenever Live Calendar is on with a Calendar Favorite, so they can make it active.
        if preferences.enabled, faces > 0 { accounts?.refresh() }
        if isActive {
            observeSystem(true)
            if fetchedAt == nil { fetch() } else { reschedule() }
        } else {
            observeSystem(false)
            timer?.invalidate()
            timer = nil
            events = []
            fetchedAt = nil
        }
        notify()
    }

    /// Reads the events from an hour ago to 36 hours ahead (off the main queue).
    func fetch() {
        guard isActive else { return }
        guard !fetching else { refetchAfterFetch = true; return }
        fetching = true
        let t = now()
        let src = source
        queue.async { [weak self] in
            let events = src.events(from: t.addingTimeInterval(-3600), to: t.addingTimeInterval(36 * 3600))
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if self.refetchAfterFetch {
                    self.refetchAfterFetch = false
                    return self.fetch()
                }
                guard self.isActive else { return }
                let window = (t.addingTimeInterval(-3600), t.addingTimeInterval(36 * 3600))
                self.events = Self.merged(events, self.accounts?.events(from: window.0, to: window.1) ?? [])
                self.fetchedAt = t
                self.reschedule()
                self.notify()
            }
        }
    }

    /// EventKit's meetings, then the accounts' that EventKit doesn't have too (the same title, start and end: one
    /// calendar synced to this Mac and signed in to as well).
    static func merged(_ local: [CalendarEvent], _ accounts: [CalendarEvent]) -> [CalendarEvent] {
        struct Key: Hashable { let title: String, start: Date, end: Date }
        var seen = Set(local.map { Key(title: $0.title, start: $0.start, end: $0.end) })
        var out = local
        for e in accounts where seen.insert(Key(title: e.title, start: e.start, end: e.end)).inserted { out.append(e) }
        return out
    }

    /// An account's meetings changed, or one signed in or out.
    private func accountsChanged() {
        if isActive, fetchedAt != nil { fetch() } else { update() }
    }

    /// One one-shot timer for the next label change, or for re-reading the window before it runs out.
    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard isActive else { return }
        let t = now()
        var wake = (fetchedAt ?? t).addingTimeInterval(6 * 3600)
        if let b = MeetingSchedule.nextBoundary(events, now: t, promptLead: preferences.joinLead.seconds), b < wake { wake = b }
        let fire = Timer(fire: Date().addingTimeInterval(max(0.05, wake.timeIntervalSince(t) + 0.05)), interval: 0, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
        fire.tolerance = 0.5
        RunLoop.main.add(fire, forMode: .common)
        timer = fire
    }

    private func timerFired() {
        timer = nil
        if let f = fetchedAt, now().timeIntervalSince(f) >= 6 * 3600 { return fetch() }
        reschedule()
        notify()
    }

    /// Scripted runs: the clock moved; show what's due now.
    func clockMoved() {
        reschedule()
        notify()
    }

    /// Sleep, a new day or a clock change: timers don't follow the wall clock, so read again.
    private func observeSystem(_ on: Bool) {
        guard on != !systemObservers.isEmpty else { return }
        if !on {
            systemObservers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
            systemObservers = []
            return
        }
        let again: (Notification) -> Void = { [weak self] _ in self?.fetch() }
        systemObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: again),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: again),
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: again),
            // Back from System Settings after allowing (or refusing) access.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.source.access != self.access else { return }
                self.accessChanged()
            },
        ]
    }

    private func notify() {
        objectWillChange.send()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Join

    /// ⌃⌘J (Arc's "Join Next Meeting", "Open meeting link for your next event"): the meeting the Join prompt shows,
    /// else the one on now, else the next one today or tomorrow (MeetingSchedule.joinTarget), in the Space whose
    /// Calendar Favorite it belongs to (`joinSpace`). Says why when there's nothing to join.
    func joinNext(controller c: WindowController) {
        guard let space = joinSpace(c) else {
            NSSound.beep()
            return c.showToast("Add your calendar to Favorites to join meetings")
        }
        guard preferences.enabled else {
            NSSound.beep()
            return c.showToast("Turn on upcoming meetings in Settings → General → Calendar")
        }
        guard access == .granted || hasAccounts else {
            NSSound.beep()
            return c.showToast("Allow Airc to read your calendars in System Settings")
        }
        guard let e = MeetingSchedule.joinTarget(events, now: now(), lead: preferences.joinLead.seconds) else {
            NSSound.beep()
            return c.showToast("No meeting to join")
        }
        join(e, spaceID: space, controller: c)
    }

    /// Where ⌃⌘J opens a call: the window's Space if its profile has a Calendar Favorite, else the first Space (sidebar
    /// order) of a profile that has one, so the call opens signed in to that calendar's account. nil: no Calendar
    /// Favorite anywhere.
    func joinSpace(_ c: WindowController) -> String? {
        let profiles = Set(c.store.state.items.values.filter { CalendarTileFace.isCalendar($0) }.compactMap(\.profileID))
        guard !profiles.isEmpty else { return nil }
        if profiles.contains(c.store.profile(ofSpace: c.currentSpaceID).id) { return c.currentSpaceID }
        return c.windowSpaces.first { profiles.contains($0.profileID) }?.id ?? c.store.orderedSpaces.first { profiles.contains($0.profileID) }?.id
    }

    /// The hover card's "+" and its rows: `url` (the calendar's new-event or day page) in the Calendar Favorite
    /// `itemID`, shown in `spaceID`. The Favorite goes back to its own page later, as Favorites do (SB-31).
    func open(_ url: URL, inFavorite itemID: String, spaceID: String?, controller c: WindowController) {
        CalendarCard.shared.hide()
        #if AIRC_TESTING
        // Scripted runs never load the real calendar sites: the check reads what would open where.
        if let hook = openedForTesting { return hook(url, itemID) }
        #endif
        let space = spaceID.flatMap { c.store.space($0) }?.id ?? c.currentSpaceID
        if space != c.currentSpaceID { c.switchToSpace(space, animated: false) }
        guard let t = try? c.store.openItem(itemID, inSpace: space) else { return }
        c.show(t.id)
        if let page = c.engineTab(for: t.id) { c.engineWindow.load(url, in: page) }
    }

    /// Opens the meeting's link in Airc, in `spaceID` (the Space whose Calendar Favorite was used) or the current Space.
    /// A tab of that Space already on the link is shown instead of a second one.
    func join(_ e: CalendarEvent, spaceID: String?, controller c: WindowController) {
        guard let link = e.link?.url else { return }
        let space = spaceID.flatMap { c.store.space($0) }?.id ?? c.currentSpaceID
        Telemetry.shared.record(.featureUsed(.calendarJoin))
        CalendarCard.shared.hide()
        if let open = c.store.todayRows(ofSpace: space).compactMap(\.liveTab).first(where: { $0.url == link.absoluteString }) {
            if space != c.currentSpaceID { c.switchToSpace(space, animated: false) }
            c.show(open.id)
            return
        }
        c.openExternal(link, inSpace: space)
    }
}
