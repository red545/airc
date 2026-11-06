// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircKit
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Asking to become the default browser (spec §2.13 step 5, AT-1; research onboarding_and_import.md §5): the onboarding
// step, the Settings rows, and one gentle reminder card in the sidebar later.

// MARK: - The system

/// Launch Services, behind a protocol so checks can inject "is default" and the set-default call: a scripted run must
/// never change the owner's real default browser.
protocol DefaultBrowserSystem: AnyObject {
    /// Airc opens both http and https links.
    var isDefault: Bool { get }
    /// The browser links open in now ("Safari"), for the onboarding step's picture of the macOS dialog.
    var currentName: String? { get }
    /// False in automated runs: the real system is never asked there.
    var canAsk: Bool { get }
    /// Shows macOS's confirmation; true once Airc is the default.
    func makeDefault(_ done: @escaping (Bool) -> Void)
}

/// What Chromium does (`shell_integration_mac.mm`, `SetAsDefaultBrowser`).
final class SystemDefaultBrowser: DefaultBrowserSystem {
    private static let probe = ["http", "https"].map { URL(string: "\($0)://example.com/")! }

    var isDefault: Bool {
        guard let me = Bundle.main.bundleIdentifier else { return false }
        return Self.probe.allSatisfy { url in
            NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier } == me
        }
    }

    var currentName: String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: Self.probe[1]) else { return nil }
        let b = Bundle(url: app)
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? b?.object(forInfoDictionaryKey: "CFBundleName")) as? String
            ?? app.deletingPathExtension().lastPathComponent
    }

    var canAsk: Bool { !LaunchOptions.current.isAutomated }

    func makeDefault(_ done: @escaping (Bool) -> Void) {
        guard canAsk else { return done(false) }
        let ws = NSWorkspace.shared, app = Bundle.main.bundleURL
        ws.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { [weak self] error in
            // Declined ("Keep Safari"): asking for https as well would prompt a second time (crbug.com/496408111).
            guard error == nil else { return DispatchQueue.main.async { done(false) } }
            ws.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async { done(self?.isDefault ?? false) }
            }
        }
        // Since macOS 26.4 the HTML content type raises a second (Finder) confirmation, so it's left out there.
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)) {
            ws.setDefaultApplication(at: app, toOpen: .html) { _ in }
        }
        // CoreServicesUIAgent shows the confirmation, sometimes behind our window: bring it to the front. It may only
        // start on the request, so look once more a moment later.
        if !Self.activateUIAgent() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = Self.activateUIAgent() }
        }
    }

    @discardableResult
    private static func activateUIAgent() -> Bool {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.coreservices.uiagent").first
        else { return false }
        agent.activate(options: .activateAllWindows)
        return true
    }
}

/// The default-browser state everything shows (Settings rows, onboarding, the reminder). It re-reads Launch Services
/// when Airc becomes active again, which is when the macOS dialog (another app's) or System Settings hands back, and
/// after each request. Nothing polls.
final class DefaultBrowser: ObservableObject {
    static let shared = DefaultBrowser()

    /// Checks replace this with a fake.
    var system: DefaultBrowserSystem { didSet { refresh() } }
    @Published private(set) var isDefault: Bool
    /// The macOS dialog is up (the buttons wait).
    @Published private(set) var isAsking = false
    private var observer: NSObjectProtocol?

    private init() {
        let s = SystemDefaultBrowser()
        system = s
        isDefault = s.isDefault
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.refresh() }
    }

    var canAsk: Bool { system.canAsk }
    var currentName: String? { system.currentName }

    func refresh() {
        let v = system.isDefault
        if v != isDefault { isDefault = v }
    }

    /// One macOS confirmation. `done` gets whether Airc is the default now.
    func makeDefault(_ done: ((Bool) -> Void)? = nil) {
        guard canAsk, !isAsking else { done?(false); return }
        isAsking = true
        system.makeDefault { [weak self] _ in
            guard let self else { return }
            self.isAsking = false
            self.refresh()
            Telemetry.shared.record(.featureUsed(.defaultBrowser(self.isDefault ? .accepted : .declined)))
            done?(self.isDefault)
        }
    }
}

// MARK: - State (AppSettings)

/// Kept in `settings.json` (`AppSettings.Values.defaultBrowser`).
struct DefaultBrowserState: Codable, Equatable {
    enum Answer: String, Codable {
        /// Confirmed in the macOS dialog.
        case madeDefault
        case notNow
        /// "Keep Safari" in the macOS dialog.
        case declined
        /// The step was skipped: Airc already was the default.
        case alreadyDefault
    }

    /// The onboarding step's answer; nil when it never ran (onboarding skipped, or finished before the step existed).
    var answer: Answer?
    /// How often the reminder card has shown, and when it last did.
    var reminders = 0
    var remindedAt: Date?
    /// "Don't ask again".
    var neverAsk = false
    /// When the reminder first looked, for an install that never finished onboarding (its 3 days count from here).
    var firstSeenAt: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = try? c.decodeIfPresent(Answer.self, forKey: .answer)
        reminders = (try? c.decodeIfPresent(Int.self, forKey: .reminders)) ?? 0
        remindedAt = try? c.decodeIfPresent(Date.self, forKey: .remindedAt)
        neverAsk = (try? c.decodeIfPresent(Bool.self, forKey: .neverAsk)) ?? false
        firstSeenAt = try? c.decodeIfPresent(Date.self, forKey: .firstSeenAt)
    }
}

// MARK: - When the reminder shows

/// The rules, without a clock or a window, so checks can run them at any time.
enum DefaultBrowserReminderRules {
    static let firstAfter: TimeInterval = 3 * 86_400
    static let secondAfter: TimeInterval = 7 * 86_400
    static let quietAfterLaunch: TimeInterval = 60
    static let maxReminders = 2

    struct Conditions {
        var now: Date
        var launchedAt: Date
        /// When onboarding finished (nil: it never did; `state.firstSeenAt` stands in).
        var onboardedAt: Date?
        var isDefault: Bool
        /// False in automated runs with the real system.
        var canAsk: Bool
        /// A page is audible, capturing, or has an active media session, or the window isn't on screen.
        var busy: Bool
        var fullScreen: Bool
    }

    /// Never again: "Don't ask again", shown twice, or the onboarding answer wasn't "Not now" (or none).
    static func isDone(_ s: DefaultBrowserState) -> Bool {
        if s.neverAsk || s.reminders >= maxReminders { return true }
        switch s.answer {
        case nil, .notNow?, .declined?: return false
        case .madeDefault?, .alreadyDefault?: return true
        }
    }

    /// The earliest the next reminder may show, ignoring the launch quiet and what's on screen.
    static func due(_ s: DefaultBrowserState, onboardedAt: Date?) -> Date? {
        if isDone(s) { return nil }
        if s.reminders == 0 { return (onboardedAt ?? s.firstSeenAt).map { $0.addingTimeInterval(firstAfter) } }
        return s.remindedAt.map { $0.addingTimeInterval(secondAfter) }
    }

    static func shouldShow(_ s: DefaultBrowserState, _ c: Conditions) -> Bool {
        guard c.canAsk, !c.isDefault, !c.busy, !c.fullScreen,
              c.now >= c.launchedAt.addingTimeInterval(quietAfterLaunch),
              let due = due(s, onboardedAt: c.onboardedAt) else { return false }
        return c.now >= due
    }
}

/// Puts the reminder card in the main window's sidebar when the rules allow, and records what was answered. Looks
/// when the quiet minute after launch is over, whenever Airc becomes active, and at the due time.
final class DefaultBrowserReminder {
    private(set) static var current: DefaultBrowserReminder?

    /// The newest browser window shows the card.
    static func attach(_ controller: WindowController) {
        guard let settings = controller.app?.settings else { return }
        if let r = current {
            r.controller = controller
        } else {
            current = DefaultBrowserReminder(controller: controller, settings: settings)
        }
    }

    weak var controller: WindowController?
    let settings: AppSettings
    /// Checks set these.
    var now: () -> Date = Date.init
    var launchedAt: Date
    /// (busy, full screen, on screen) for the window; see `Conditions`.
    var probe: (() -> (busy: Bool, fullScreen: Bool, visible: Bool))?
    private(set) var isShowing = false
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []

    private init(controller: WindowController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        launchedAt = NSRunningApplication.current.launchDate ?? Date()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        DefaultBrowser.shared.$isDefault.removeDuplicates().sink { [weak self] isDefault in
            if isDefault { DispatchQueue.main.async { self?.hide() } }
        }.store(in: &subscriptions)
        arm()
    }

    private var state: DefaultBrowserState {
        get { settings.values.defaultBrowser }
        set { settings.values.defaultBrowser = newValue }
    }

    func conditions() -> DefaultBrowserReminderRules.Conditions {
        let p = probe?() ?? controller.map { c in
            (c.defaultBrowserCardBusy, c.window.styleMask.contains(.fullScreen), NSApp.isActive && c.window.isVisible && !c.window.isMiniaturized)
        } ?? (false, false, false)
        return .init(now: now(), launchedAt: launchedAt, onboardedAt: settings.values.onboardingCompletedAt,
                     isDefault: DefaultBrowser.shared.isDefault, canAsk: DefaultBrowser.shared.canAsk,
                     busy: p.busy || !p.visible, fullScreen: p.fullScreen)
    }

    /// Shows the card if it's time. Safe to call any time.
    func evaluate() {
        guard !isShowing, controller != nil, !DefaultBrowserReminderRules.isDone(state) else { return }
        if settings.values.onboardingCompletedAt == nil, state.firstSeenAt == nil, DefaultBrowser.shared.canAsk {
            state.firstSeenAt = now()
        }
        DefaultBrowser.shared.refresh()
        if DefaultBrowserReminderRules.shouldShow(state, conditions()) {
            show()
        } else {
            arm()
        }
    }

    /// The next look: the quiet minute, the due time, or an hour from now (timers stop while the Mac sleeps).
    private func arm() {
        timer?.invalidate()
        timer = nil
        guard !DefaultBrowserReminderRules.isDone(state), DefaultBrowser.shared.canAsk || probe != nil else { return }
        let t = now()
        let quiet = launchedAt.addingTimeInterval(DefaultBrowserReminderRules.quietAfterLaunch + 1)
        var at = max(quiet, DefaultBrowserReminderRules.due(state, onboardedAt: settings.values.onboardingCompletedAt) ?? t)
        if at <= t { at = t.addingTimeInterval(600) }   // due but busy, full screen or away: look again in 10 minutes
        let delay = min(at.timeIntervalSince(t), 3600)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.evaluate() }
        timer.tolerance = min(60, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func show() {
        guard !isShowing else { return }
        isShowing = true
        Telemetry.shared.record(.featureUsed(.defaultBrowser(.shown)))
        timer?.invalidate()
        state.reminders += 1
        state.remindedAt = now()
        controller?.scheduleReload()
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        controller?.scheduleReload()
        arm()
    }

    // The card's buttons.

    func makeDefault() {
        hide()
        DefaultBrowser.shared.makeDefault { [weak self] ok in
            if ok { self?.controller?.showToast("Airc is your default browser") }
        }
    }

    func notNow() { hide() }

    func neverAgain() {
        state.neverAsk = true
        hide()
    }
}

// MARK: - The card (sidebar, under + New Tab)

/// The reminder's designed copy.
enum DefaultBrowserCopy {
    static let title = "Make Airc your default browser?"
    static let message = "Links from other apps will open in Airc and go through Air Traffic Control."
    static let makeDefault = "Make Default"
    static let notNow = "Not now"
    static let neverAsk = "Don't ask again"
}

/// An Arc-style card on the sidebar's theme, like "Sign in to Google" (`AircSidebarCard`): the app icon and title,
/// the message, Make Default (primary small, full width), then Not now and Don't ask again (plain small).
struct DefaultBrowserCard: View {
    var onMakeDefault: () -> Void = {}
    var onNotNow: () -> Void = {}
    var onNeverAsk: () -> Void = {}
    @Environment(\.aircTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AircMetrics.Profile.signInCardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 7) {
                Image(nsImage: AppIconImage.image).resizable().interpolation(.high)
                    .frame(width: 18, height: 18).padding(-1).accessibilityHidden(true)
                Text(DefaultBrowserCopy.title).aircFont(AircFont.body.weight(.semibold)).foregroundStyle(theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(DefaultBrowserCopy.message).aircFont(AircFont.callout).foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
            Button(DefaultBrowserCopy.makeDefault, action: onMakeDefault)
                .buttonStyle(.airc(.primary, size: .small, fullWidth: true))
                .padding(.top, 10)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { notNow; Spacer(minLength: 4); neverAsk }
                VStack(alignment: .leading, spacing: 0) { notNow; neverAsk }
            }
            .padding(.horizontal, -6)
            .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 11, leading: 12, bottom: 6, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.sidebarCardFill.color).aircShadow(theme.selectedHasShadow ? .rowSelected : .none))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(DefaultBrowserCopy.title)
    }

    private var notNow: some View {
        Button(DefaultBrowserCopy.notNow, action: onNotNow).buttonStyle(.airc(.plain, size: .small))
    }

    private var neverAsk: some View {
        Button(DefaultBrowserCopy.neverAsk, action: onNeverAsk).buttonStyle(.airc(.plain, size: .small))
    }
}

/// The card as a sidebar row (SpacePage's `.defaultBrowser`), like `SignInCardView`.
final class DefaultBrowserCardView: SidebarRowView {
    private let host = AircFirstClickHostingView(rootView: AnyView(EmptyView()))
    private var theme: ResolvedTheme?

    override init(frame: NSRect) {
        super.init(frame: frame)
        showsPlate = false
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(palette: Palette) {
        self.palette = palette
        guard palette.resolved != theme else { return }
        theme = palette.resolved
        host.rootView = Self.content(theme: palette.resolved)
    }

    private static func content(theme: ResolvedTheme) -> AnyView {
        let r = { DefaultBrowserReminder.current }
        return AnyView(DefaultBrowserCard(onMakeDefault: { r()?.makeDefault() }, onNotNow: { r()?.notNow() },
                                          onNeverAsk: { r()?.neverAgain() })
            .aircTheme(theme))
    }

    /// The row's height in a sidebar list `width` wide (the card wraps its copy), plus 8 pt below.
    static func height(width: CGFloat, theme: ResolvedTheme) -> CGFloat {
        let w = width - 2 * AircMetrics.Sidebar.inset
        if let h = heights[w] { return h }
        let measure = NSHostingController(rootView: content(theme: theme))
        let h = ceil(measure.sizeThatFits(in: NSSize(width: w, height: 1000)).height) + 8
        heights[w] = h
        return h
    }

    private static var heights: [CGFloat: CGFloat] = [:]

    override func layout() {
        super.layout()
        let inset = AircMetrics.Sidebar.inset
        host.frame = NSRect(x: inset, y: 0, width: bounds.width - 2 * inset, height: bounds.height - 8)
    }

    override func mouseDown(with event: NSEvent) {}
}

extension WindowController {
    /// SpacePage's hook: the reminder card is up.
    var showsDefaultBrowserCard: Bool { DefaultBrowserReminder.current?.isShowing == true && DefaultBrowserReminder.current?.controller === self }

    /// A page is playing sound (a video, or a call's other side): no reminder now.
    var defaultBrowserCardBusy: Bool {
        pages.values.contains {
            DefaultBrowserReminderRules.isBusy(audible: $0.isAudible,
                activity: (app?.engine as? EngineSiteControls)?.siteActivity(of: $0) ?? SiteActivity(),
                media: (app?.engine as? EngineMedia)?.mediaSession(of: $0) ?? EngineMediaSession())
        }
    }
}

extension DefaultBrowserReminderRules {
    /// Pure state predicate: muted calls and silent video sessions also defer the reminder.
    static func isBusy(audible: Bool, activity: SiteActivity, media: EngineMediaSession) -> Bool {
        audible || activity.camera || activity.microphone || activity.screen || media.active
            || media.capture.camera || media.capture.microphone || media.capture.screen || media.capture.tab
    }
}
