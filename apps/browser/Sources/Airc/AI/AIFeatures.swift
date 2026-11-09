// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Combine

/// Arc Max-style features on Apple's on-device model (docs/user/ai.md): Tidy Titles, the short names long page titles
/// of pinned and Today tabs get in the sidebar (AircKit's TidyTitles has the rules, the cache and the queue); Ask on
/// Page (AskPageCard.swift); link previews (LinkPreviewCard.swift); Tidy Downloads (TidyDownloadsFeature.swift).
///
/// All off by default. Rows ask only while Settings → AI → "Tidy tab titles" is on, and the launch makes this object
/// only when another AI setting is on (`startIfNeeded`), so a launch with them all off never makes it. Without Apple
/// Intelligence (macOS before 26, a Mac that can't run it, or it's turned off) there's no model: every row shows its
/// page's own title and the other features stay hidden. Private windows never reach any of them: they draw their own
/// rows (PrivateWindow.swift), their find bar has no Ask, their links get no previews, and their downloads are their own.
@MainActor
final class AIFeatures {
    static let shared = AIFeatures()
    /// Posted when the availability changes (Settings → AI follows it).
    static let availabilityChanged = Notification.Name("AircAIAvailabilityChanged")

    let tidy: TidyTitles
    /// Link previews kept for the session, and the hidden page loads behind them.
    let links = LinkPreviews()
    /// Tidy Downloads' suggestions for this session.
    let downloads = TidyDownloads()
    /// Ask on Page's model, when it can run.
    private(set) var askModel: (any AskPageModel)?
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
    /// Scripted runs: fake models for Ask on Page, link previews and Tidy Downloads (with `testOverride`'s availability).
    struct TestModels {
        var ask: (any AskPageModel)?
        var links: (any LinkPreviewModel)?
        var downloads: (any TidyDownloadModel)?
    }
    var testModels: TestModels? {
        didSet { applyModels(force: true) }
    }
    /// The last `feature.used` event a switch recorded (the scripted check reads it).
    private(set) var lastToggleEvent: TelemetryEvent?
    /// The AI features' recent `feature.used` events (switches and uses), for the scripted checks.
    private(set) var events: [TelemetryEvent] = []
    private var modelsFor: Bool?
    private var lastPreviewUse: CFTimeInterval = -1000
    /// Whether `shared` exists yet (the relaunch check: a row made it at launch, with the setting on).
    private(set) static var instantiated = false

    private var settingsSink: AnyCancellable?
    private var otherSinks: [AnyCancellable] = []
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
        links.fetch = { url, profileID in await LinkPreviewFeature.fetch(url, profileID: profileID) }
        downloads.onChange = { key in TidyDownloadsFeature.suggestionChanged(key) }
        if let settings = (NSApp.delegate as? AppDelegate)?.settings {
            // No row refresh here: the first row to draw with the setting on makes this object (`shared`), and a
            // refresh from inside its own initialisation would reach `shared` again. The rows draw after it anyway.
            tidy.isEnabled = settings.values.tidyTitles
            downloads.isEnabled = settings.values.tidyDownloads
            settingsSink = settings.$values.map(\.tidyTitles).removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { on in MainActor.assumeIsolated { AIFeatures.shared.apply(enabled: on) } }
            otherSinks.append(settings.$values.map { [$0.askPage, $0.linkPreviews, $0.tidyDownloads] }.removeDuplicates().dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { _ in MainActor.assumeIsolated { AIFeatures.shared.settingsChanged() } })
        }
        applyModels(force: true)
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
        applyModels()
        guard changed else { return }
        AIFeatures.refreshAllRows()
        NotificationCenter.default.post(name: Self.availabilityChanged, object: nil)
    }

    /// At launch, after the page script's other parts: makes this object when an AI setting other than Tidy Titles is
    /// on (link previews need their page-script part before the first page opens).
    static func startIfNeeded(settings: AppSettings) {
        let v = settings.values
        guard v.askPage || v.linkPreviews || v.tidyDownloads else { return }
        _ = shared
    }

    /// The models of Ask on Page, link previews and Tidy Downloads follow the availability (and a check's fakes). They
    /// change only when the availability does, so the session's previews stay.
    private func applyModels(force: Bool = false) {
        let on = availability.isAvailable
        guard force || modelsFor != on else { return }
        modelsFor = on
        if let t = testModels {
            askModel = on ? t.ask : nil
            links.model = on ? t.links : nil
            downloads.model = on ? t.downloads : nil
        } else if testOverride != nil {
            // A scripted run with the availability made up and no fakes for these: no model.
            askModel = nil
            links.model = nil
            downloads.model = nil
        } else {
            askModel = on ? AppleIntelligence.askModel() : nil
            links.model = on ? AppleIntelligence.summaryModel() : nil
            downloads.model = on ? AppleIntelligence.fileNameModel() : nil
        }
        // Never `shared` here: this runs inside its initialisation too.
        LinkPreviewFeature.shared.update(active: canPreviewLinks)
    }

    private func settingsChanged() {
        guard let v = (NSApp.delegate as? AppDelegate)?.settings.values else { return }
        downloads.isEnabled = v.tidyDownloads
        if !v.linkPreviews { links.forget(); HiddenPageReader.shared.cancelAll() }
        LinkPreviewFeature.shared.update(active: canPreviewLinks)
        if !v.askPage { AskPageFeature.closeAll() }
    }

    /// Clear Data and Delete Profile (Settings → Profiles): the AI features forget the profile. Its Ask on Page sessions
    /// (the page's text, the question and answer, a read or a model call under way, the card); Tidy Titles' names; its
    /// link previews (a card showing one goes, hidden loads and model calls under way stop, no late answer puts one
    /// back); Tidy Downloads' suggestions, the model call under way for one, and its renames. Other profiles keep theirs.
    /// Settings calls it before deleting anything, while the profile is still there to match.
    func forget(profileID: String) {
        AskPageFeature.forget(profileID: profileID)
        tidy.forget(profileID: profileID)
        LinkPreviewFeature.shared.forget(profileID: profileID)
        links.forget(profileID: profileID)
        HiddenPageReader.shared.cancel(profileID: profileID)
        downloads.forget(profileID: profileID)
        TidyDownloadsFeature.forget(profileID: profileID)
    }

    /// Whether Ask on Page can answer now: on, Apple Intelligence available, a model.
    var canAsk: Bool {
        ((NSApp.delegate as? AppDelegate)?.settings.values.askPage ?? false) && availability.isAvailable && askModel != nil
    }
    var canPreviewLinks: Bool {
        ((NSApp.delegate as? AppDelegate)?.settings.values.linkPreviews ?? false) && availability.isAvailable && links.model != nil
    }

    /// Settings → AI's switches for Ask on Page, link previews and Tidy Downloads. Only the person's change counts
    /// (`feature.used` with on or off; never a page, a question or a file).
    func setAskPage(_ on: Bool, settings: AppSettings) {
        guard toggle(\.askPage, on, settings, .aiAskPage(on ? .on : .off)) else { return }
        if on { AppleIntelligence.prewarmAsk() }
    }

    func setLinkPreviews(_ on: Bool, settings: AppSettings) {
        toggle(\.linkPreviews, on, settings, .aiLinkPreview(on ? .on : .off))
    }

    func setTidyDownloads(_ on: Bool, settings: AppSettings) {
        toggle(\.tidyDownloads, on, settings, .aiTidyDownloads(on ? .on : .off))
    }

    @discardableResult
    private func toggle(_ key: WritableKeyPath<AppSettings.Values, Bool>, _ on: Bool, _ settings: AppSettings,
                        _ feature: TelemetryFeature) -> Bool {
        guard settings.values[keyPath: key] != on, availability.isAvailable || !on else { return false }
        settings.values[keyPath: key] = on
        record(feature)
        lastToggleEvent = events.last
        settingsChanged()
        return true
    }

    /// A feature used: a question asked, a preview shown (at most once a minute), a suggested name applied.
    func recordUse(_ feature: TelemetryFeature) {
        if case .aiLinkPreview = feature {
            let now = CACurrentMediaTime()
            guard now - lastPreviewUse >= 60 else { return }
            lastPreviewUse = now
        }
        record(feature)
    }

    private func record(_ feature: TelemetryFeature) {
        let e = TelemetryEvent.featureUsed(feature)
        events.append(e)
        if events.count > 40 { events.removeFirst(events.count - 40) }
        Telemetry.shared.record(e)
    }

    /// Settings → AI's switch. Only the person's change counts (`feature.used` `ai.tidy_titles`, on or off; never a
    /// title, a page or a name).
    func setTidyTitles(_ on: Bool, settings: AppSettings) {
        guard settings.values.tidyTitles != on, availability.isAvailable || !on else { return }
        settings.values.tidyTitles = on
        record(.aiTidyTitles(on ? .on : .off))
        lastToggleEvent = events.last
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
    private func tidyProfileID(_ entry: SidebarEntry) -> String {
        switch entry {
        case .today(let tab): return tab.profileID
        case .pinned(let item, _, _): return item.spaceID.flatMap { controller?.store.space($0)?.profileID } ?? ""
        default: return ""
        }
    }

    func tidyName(for entry: SidebarEntry, engineTab: EngineTab?) -> String? {
        guard controller?.app?.settings.values.tidyTitles == true,
              let s = AIFeatures.subject(of: entry, engineTab: engineTab) else { return nil }
        // Main windows only: a private window's rows are PrivateTabRow, never this one.
        return AIFeatures.shared.tidy.name(for: s.title, url: s.url, customName: s.customName, isPrivate: false, profileID: tidyProfileID(entry))
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
