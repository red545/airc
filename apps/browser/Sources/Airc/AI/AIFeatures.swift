// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine

/// Arc Max-style features on Apple's on-device model (docs/user/ai.md). Today: Tidy Titles, the short names long page
/// titles of pinned and Today tabs get in the sidebar (AircKit's TidyTitles has the rules, the cache and the queue).
///
/// Off by default. Rows ask only while Settings → AI → "Tidy tab titles" is on, so a launch with it off never makes
/// this object. Without Apple Intelligence (macOS before 26, a Mac that can't run it, or it's turned off) there's no
/// model and every row shows its page's own title. Private windows draw their own rows (PrivateWindow.swift), which
/// never come here, and the queue refuses them anyway.
@MainActor
final class AIFeatures {
    static let shared = AIFeatures()
    /// Posted when the availability changes (Settings → AI follows it).
    static let availabilityChanged = Notification.Name("AircAIAvailabilityChanged")

    let tidy: TidyTitles
    private(set) var availability: AIAvailability
    /// How long the first availability read took (the scripted check logs it).
    private(set) var availabilityReadSeconds: Double = 0
    /// Scripted runs (Debug/AIMaxCheck.swift): this availability and model instead of the system's.
    var testOverride: (availability: AIAvailability, model: (any TidyTitleModel)?)? {
        didSet { refreshAvailability() }
    }
    /// The person is typing, scrolling or dragging (in any app, CGEventSource's idle times): the queue waits, so a
    /// model run never competes with them.
    var isPersonActive: () -> Bool = { AIFeatures.recentInput() }
    /// The last `feature.used` event the switch recorded (the scripted check reads it).
    private(set) var lastToggleEvent: TelemetryEvent?
    /// Whether `shared` exists yet (the relaunch check: a row made it at launch, with the setting on).
    private(set) static var instantiated = false

    private var settingsSink: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    private init() {
        Self.instantiated = true
        tidy = TidyTitles(fileURL: AppPaths.dataDirectory.appendingPathComponent("TidyTitles.json"))
        let start = CACurrentMediaTime()
        availability = AppleIntelligence.availability
        availabilityReadSeconds = CACurrentMediaTime() - start
        tidy.model = availability.isAvailable ? AppleIntelligence.titleModel() : nil
        tidy.isBusy = { [unowned self] in self.isPersonActive() }
        tidy.onChange = { urls in AIFeatures.refreshRows(showing: urls) }
        if let settings = (NSApp.delegate as? AppDelegate)?.settings {
            // No row refresh here: the first row to draw with the setting on makes this object (`shared`), and a
            // refresh from inside its own initialisation would reach `shared` again. The rows draw after it anyway.
            tidy.isEnabled = settings.values.tidyTitles
            settingsSink = settings.$values.map(\.tidyTitles).removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { on in MainActor.assumeIsolated { AIFeatures.shared.apply(enabled: on) } }
        }
        let center = NotificationCenter.default
        // Apple Intelligence turned on (or its model finished downloading) while Airc runs.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AIFeatures.shared.refreshAvailability() }
        })
        // Names made in the last seconds before quitting are kept too.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AIFeatures.shared.tidy.save() }
        })
    }

    /// Reads the availability again; a change re-draws every row and tells Settings.
    func refreshAvailability() {
        let a = testOverride?.availability ?? AppleIntelligence.availability
        let changed = a != availability
        availability = a
        if !a.isAvailable {
            if tidy.model != nil { tidy.model = nil }
        } else if let o = testOverride {
            tidy.model = o.model
        } else if tidy.model == nil {
            tidy.model = AppleIntelligence.titleModel()
            if tidy.isEnabled { AppleIntelligence.prewarm() }
        }
        guard changed else { return }
        AIFeatures.refreshAllRows()
        NotificationCenter.default.post(name: Self.availabilityChanged, object: nil)
    }

    /// Settings → AI's switch. Only the person's change counts (`feature.used` `ai.tidy_titles`, on or off; never a
    /// title, a page or a name).
    func setTidyTitles(_ on: Bool, settings: AppSettings) {
        guard settings.values.tidyTitles != on, availability.isAvailable || !on else { return }
        settings.values.tidyTitles = on
        let event = TelemetryEvent.featureUsed(.aiTidyTitles(on ? .on : .off))
        lastToggleEvent = event
        Telemetry.shared.record(event)
        apply(enabled: on)
        if on, testOverride == nil, availability.isAvailable { AppleIntelligence.prewarm() }
    }

    private func apply(enabled: Bool) {
        guard tidy.isEnabled != enabled else { return }
        tidy.isEnabled = enabled
        // Turning it off forgets every name (TidyTitles.json goes).
        if !enabled { tidy.forget() }
        AIFeatures.refreshAllRows()
    }

    // MARK: Rows

    /// The page a row is named after: its title, the address the name is kept under, and the person's own name for
    /// the tab. Pinned tabs and Today tabs only (not Favorites, folders or splits).
    static func subject(of entry: SidebarEntry, engineTab: EngineTab?) -> (title: String, url: String, customName: String?)? {
        switch entry {
        case let .pinned(item, _, _):
            guard item.kind == .tab, let url = item.savedURL else { return nil }
            return (item.pageTitle ?? "", url, item.title)
        case let .today(tab):
            let title = engineTab.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.title
            return (title, tab.url, nil)
        default:
            return nil
        }
    }

    /// Rows showing one of these pages draw their names again.
    static func refreshRows(showing urls: Set<String>?) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        for w in app.controllers {
            for id in w.store.state.spaces.keys { w.pageView(for: id)?.refreshTidyTitles(urls) }
        }
    }

    static func refreshAllRows() { refreshRows(showing: nil) }

    nonisolated static func recentInput() -> Bool {
        let quiet: CFTimeInterval = 0.75
        let kinds: [CGEventType] = [.keyDown, .scrollWheel, .leftMouseDragged, .otherMouseDragged]
        return kinds.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < quiet }
    }
}

extension TabRowView {
    /// Tidy Titles: the short name this row shows instead of its page's title, or nil (the setting is off, the model
    /// can't run, the title is short already, the tab has a name of its own, or the name is still coming).
    func tidyName(for entry: SidebarEntry, engineTab: EngineTab?) -> String? {
        guard controller?.app?.settings.values.tidyTitles == true,
              let s = AIFeatures.subject(of: entry, engineTab: engineTab) else { return nil }
        // Main windows only: a private window's rows are PrivateTabRow, never this one.
        return AIFeatures.shared.tidy.name(for: s.title, url: s.url, customName: s.customName, isPrivate: false)
    }

    /// A tidied row shows the page's own title on hover: in the tab preview card (it always shows the page's title),
    /// or, with previews off, as the row's tooltip.
    func showTidyOriginal(_ tidied: Bool, entry: SidebarEntry, engineTab: EngineTab?) {
        var tip: String?
        if tidied, controller?.app?.settings.values.tabPreviews == false {
            tip = AIFeatures.subject(of: entry, engineTab: engineTab)?.title
        }
        if toolTip != tip { toolTip = tip }
    }
}

extension SpacePageView {
    /// Tidy Titles: rows of pinned and Today tabs showing one of these pages (all of them for nil) draw their titles again.
    func refreshTidyTitles(_ urls: Set<String>?) {
        guard let c = controller else { return }
        var tabs: [String] = []
        for case let r as TabRowView in rows.values {
            guard let e = r.entry, let s = AIFeatures.subject(of: e, engineTab: nil), urls?.contains(s.url) ?? true else { continue }
            if let id = r.tabID {
                tabs.append(id)
            } else if case let .pinned(item, depth, nil) = e, let fresh = c.store.item(item.id) {
                r.configure(.pinned(fresh, depth: depth, nil), palette: palette, selected: r.isSelected)
            }
        }
        for id in tabs { refreshTab(id) }
    }
}
