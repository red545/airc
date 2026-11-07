// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import Darwin
import QuartzCore

/// Airc's product analytics in the app (docs/user/telemetry.md). AircKit's `Telemetry` does the queueing and sending;
/// this decides whether it runs (Info.plist's `AircTelemetryHost` and `AircTelemetryKey`, `AIRC_TELEMETRY_ENABLED`, the
/// `AircTelemetryEnabled` default, Settings → Privacy, scripted runs) and records the app-wide events: `app.launched`,
/// `app.active_day` and `perf.daily`. Feature call sites are one line each:
/// `Telemetry.shared.record(.featureUsed(.find))`.
///
/// Its files live in `<data dir>/Telemetry`: install.json (the random ID), queue.json (events not sent yet), state.json
/// (the days already reported, the last build) and `running`, the sentinel that tells a clean exit from a crash.
final class AppTelemetry {
    static let shared = AppTelemetry()

    /// What Settings → Privacy shows. Main thread.
    private(set) var resolution = TelemetryResolution.unavailable
    private weak var app: AppDelegate?
    private var context: TelemetryContext?
    private var firstRun = false
    private var launchRecorded = false
    private var terminated = false
    private var observers: [NSObjectProtocol] = []
    /// Command Bar samples (ms) and background CPU since the last perf.daily, and the day they started. Main thread.
    private var commandBarSamples: [Double] = []
    private var idleCPU = (cpu: 0.0, wall: 0.0)
    private var resigned: (wall: CFTimeInterval, cpu: Double)?
    private var samplesDay: String?
    private var lastActiveDayChecked: String?
    private var throttled: [String: CFTimeInterval] = [:]

    /// File work (the sentinel, state.json) happens here, never on the main thread.
    private let work = DispatchQueue(label: "org.airc.telemetry.app", qos: .utility)
    private var state = State()   // `work` only
    private var previousExit = TelemetryEvent.PreviousExit.clean   // `work` only

    private struct State: Codable {
        /// The last calendar day app.active_day and perf.daily went out for ("yyyy-MM-dd", local time).
        var activeDay: String?
        var perfDay: String?
        /// The build the app last ran on this data folder (for update.install).
        var build: String?
    }

    private var directory: URL { AppPaths.dataDirectory.appendingPathComponent("Telemetry", isDirectory: true) }

    // MARK: Launch and quit

    /// Right after the store and settings load (AppDelegate). `firstRun`: a fresh data folder.
    func start(app: AppDelegate, firstRun: Bool) {
        self.app = app
        self.firstRun = firstRun
        context = Self.makeContext(app: app)
        apply()
        // Observed even while sharing is off, so switching it on in Settings needs no relaunch; each handler checks.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.becameActive()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard self?.resolution.records == true else { return }
                self?.resigned = (CACurrentMediaTime(), Self.cpuSeconds())
            },
            // Posted by Foundation at midnight: a session that runs for days still reports each day. No timer of ours.
            center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in self?.checkDay() },
        ]
        guard resolution.records else { return }
        let build = context?.build
        let dir = directory
        work.async {
            self.state = Self.loadState(dir)
            let sentinel = dir.appendingPathComponent("running")
            self.previousExit = firstRun ? .none : FileManager.default.fileExists(atPath: sentinel.path) ? .unclean : .clean
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: sentinel.path, contents: nil)
            if let build, build != "unknown", let last = self.state.build, last != build, (Int(build) ?? 0) > (Int(last) ?? 0) {
                Telemetry.shared.record(.featureUsed(.updateInstalled))
            }
            self.state.build = build
            Self.saveState(self.state, dir)
        }
    }

    /// The first window is on screen (the browser window, or onboarding on a first run): app.launched, once.
    func launched() {
        guard resolution.records, !launchRecorded else { return }
        launchRecorded = true
        let ms = Self.processStart().map { Date().timeIntervalSince($0) * 1000 } ?? 0
        let first = firstRun
        work.async { Telemetry.shared.record(.appLaunched(launchMilliseconds: ms, firstLaunch: first, previousExit: self.previousExit)) }
        // The day's counts once the launch has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.checkDay() }
    }

    /// applicationWillTerminate: perf.daily if today has none yet, a clean-exit mark, then a short best-effort send.
    func willTerminate() {
        guard resolution.records, !terminated else { return }
        terminated = true
        let perf = takePerf()
        let dir = directory
        work.sync {
            if let perf { recordPerf(perf) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("running"))
        }
        Telemetry.shared.flushForQuit(timeout: 1)
    }

    // MARK: Settings → Privacy

    /// Settings → Privacy → "Share anonymous usage data".
    func setUserEnabled(_ on: Bool) {
        app?.settings.values.shareUsageData = on
        let wasRecording = resolution.records
        apply()
        let sentinel = directory.appendingPathComponent("running")
        let dir = directory
        if resolution.records, !wasRecording {
            work.async {
                self.state = Self.loadState(dir)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: sentinel.path, contents: nil)
            }
        } else if !resolution.records {
            work.async { try? FileManager.default.removeItem(at: sentinel) }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Settings → Privacy → "Reset": a new random ID; nothing queued under the old one is sent.
    func resetInstallID() {
        Telemetry.shared.resetInstallID()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    static let didChange = Notification.Name("AircTelemetryDidChange")

    #if AIRC_TESTING
    /// The checks that read what Airc records (crash reports, Live Calendar, the update button) set up their own state:
    /// in a run with telemetry off (`AIRC_TELEMETRY_ENABLED=0`, as the release suite runs) or a build without a key, this
    /// run becomes record-only. Events then show in "See what Airc sends" and are never sent or kept on disk, as in any
    /// scripted run. A run that already records (record-only, or a loopback mock) stays as it is. Returns the state it
    /// replaced, if any.
    @discardableResult
    func recordOnlyForCheck() -> TelemetryResolution.State? {
        guard !resolution.records, let context else { return nil }
        let replaced = resolution.state
        resolution = TelemetryResolution(state: .recordOnly, endpoint: resolution.endpoint, apiKey: resolution.apiKey)
        Telemetry.shared.start(.init(resolution: resolution, context: context, directory: directory))
        NotificationCenter.default.post(name: Self.didChange, object: self)
        return replaced
    }
    #endif

    private func apply() {
        guard let app, let context else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let defaults = UserDefaults.standard.object(forKey: TelemetryResolution.defaultsKey)
        let defaultsValue = (defaults as? Bool) ?? (defaults as? String).map { !["0", "false", "no", "off"].contains($0.lowercased()) }
        resolution = TelemetryResolution.resolve(host: info["AircTelemetryHost"] as? String, key: info["AircTelemetryKey"] as? String,
                              environment: ProcessInfo.processInfo.environment, defaultsValue: defaultsValue,
                              userEnabled: app.settings.values.shareUsageData,
                              automated: app.options.isAutomated || app.options.isScripted)
        Telemetry.shared.start(.init(resolution: resolution, context: context, directory: directory))
    }

    // MARK: Feature hooks that need more than one line

    /// The Command Bar opened (WindowController.openCommandBar): counted, and its main-thread work up to the frame it
    /// shows in timed for perf.daily. A one-shot run-loop observer after Core Animation's commit takes the time.
    func commandBarOpened(_ mode: CommandBarMode) {
        guard resolution.records else { return }
        Telemetry.shared.record(.featureUsed(.commandBar(mode == .newTab ? .newTab : .editURL)))
        let t0 = CACurrentMediaTime()
        guard let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                false, CFIndex.max, { [weak self] _, _ in
            self?.addCommandBarSample((CACurrentMediaTime() - t0) * 1000)
        }) else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Counts `feature` at most once per `seconds` (a theme picker recolours live on every change).
    func record(_ feature: TelemetryFeature, atMostEvery seconds: CFTimeInterval) {
        guard resolution.records else { return }
        let now = CACurrentMediaTime()
        if let last = throttled[feature.name], now - last < seconds { return }
        throttled[feature.name] = now
        Telemetry.shared.record(.featureUsed(feature))
    }

    /// OnboardingController.go: the step being left, and how. Skips: "Start fresh" (no import), "Skip" on logins and
    /// "Not now" on the default-browser step.
    static func onboardingStep(from: OnboardingStep, to: OnboardingStep, model: OnboardingModel, settings: AppSettings) {
        guard from != to else { return }
        let action: TelemetryEvent.OnboardingAction
        if to < from {
            action = .back
        } else if (from == .arc && to == .theme) || (from == .logins && model.logins == .skipped)
                    || (from == .defaultBrowser && settings.values.defaultBrowser.answer == .notNow) {
            action = .skip
        } else {
            action = .next
        }
        Telemetry.shared.record(.onboardingStep(step: telemetryStep(from), action: action))
        if to == .defaultBrowser, action != .back { Telemetry.shared.record(.featureUsed(.defaultBrowser(.shown))) }
    }

    /// OnboardingController.finish: the import's outcome (if one ran) and the finish itself. A failed import is
    /// recorded where it fails (OnboardingController.runImport).
    static func onboardingFinished(model: OnboardingModel) {
        // Another browser's import is recorded when it runs (import.browser).
        if let r = model.result, model.importedFromArc {
            var logins = false
            if case .done = model.logins { logins = true }
            Telemetry.shared.record(.importArc(.init(result: .success, spaces: r.spacesCreated + r.spacesUpdated,
                                                     tabs: r.pinnedTabs + r.todayTabs + r.favorites,
                                                     profiles: r.profilesCreated.count + r.profilesUpdated, logins: logins)))
        }
        Telemetry.shared.record(.onboardingFinished(imported: model.result != nil))
    }

    private static func telemetryStep(_ s: OnboardingStep) -> TelemetryEvent.OnboardingStep {
        switch s {
        case .welcome: .welcome
        case .arc: .arc
        case .accounts: .accounts
        case .logins: .logins
        case .theme: .theme
        case .defaultBrowser: .defaultBrowser
        case .done: .done
        }
    }

    // MARK: Daily events

    private func becameActive() {
        guard resolution.records else { return }
        if let r = resigned {
            let wall = CACurrentMediaTime() - r.wall
            // Only spans of a minute or more count as idle (a quick ⌘Tab away and back isn't).
            if wall >= 60 { idleCPU = (idleCPU.cpu + max(0, Self.cpuSeconds() - r.cpu), idleCPU.wall + wall) }
            resigned = nil
        }
        checkDay()
    }

    /// app.active_day for today if it hasn't gone out, and perf.daily for an earlier day's samples.
    private func checkDay() {
        guard resolution.records, let app, let store = app.store else { return }
        let today = Self.day(Date())
        if let d = samplesDay, d != today, let perf = takePerf() { work.async { self.recordPerf(perf) } }
        guard lastActiveDayChecked != today else { return }
        lastActiveDayChecked = today
        let s = store.state
        var pinned = 0, favorites = 0
        for item in s.items.values where item.kind != .folder {
            if case .pinned = item.container { pinned += 1 } else { favorites += 1 }
        }
        let counts = (spaces: s.spaces.count, profiles: s.profiles.count, pinned: pinned, favorites: favorites, tabs: s.tabs.count)
        let side: TelemetryEvent.SidebarPosition = store.windowState.sidebarOnRight ? .right : .left
        let isDefault = SettingsActions.isDefaultBrowser
        let dir = directory
        work.async {
            guard self.state.activeDay != today else { return }
            self.state.activeDay = today
            Self.saveState(self.state, dir)
            Telemetry.shared.record(.activeDay(.init(spaces: counts.spaces, profiles: counts.profiles, pinnedTabs: counts.pinned,
                                                     favorites: counts.favorites, openTabs: counts.tabs, sidebarPosition: side,
                                                     isDefaultBrowser: isDefault)))
        }
    }

    private func addCommandBarSample(_ ms: Double) {
        if samplesDay == nil { samplesDay = Self.day(Date()) }
        if commandBarSamples.count < 2000 { commandBarSamples.append(ms) }
    }

    private struct PerfSample {
        var day: String
        var event: TelemetryEvent.PerfDaily
    }

    /// The samples since the last perf.daily, cleared. nil when there are none.
    private func takePerf() -> PerfSample? {
        guard let day = samplesDay ?? (idleCPU.wall > 0 ? Self.day(Date()) : nil) else { return nil }
        let sorted = commandBarSamples.sorted()
        func percentile(_ p: Double) -> Double? {
            sorted.isEmpty ? nil : sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
        }
        let idle = idleCPU.wall >= 60 ? idleCPU.cpu / idleCPU.wall * 100 : nil
        let event = TelemetryEvent.PerfDaily(commandBarOpens: sorted.count, commandBarP50Milliseconds: percentile(0.5),
                                             commandBarP95Milliseconds: percentile(0.95), memoryMegabytes: Self.footprintMegabytes(),
                                             idleCPUPercent: idle)
        commandBarSamples = []
        idleCPU = (0, 0)
        samplesDay = nil
        return PerfSample(day: day, event: event)
    }

    /// On `work`: at most one perf.daily per calendar day.
    private func recordPerf(_ p: PerfSample) {
        guard state.perfDay != p.day else { return }
        state.perfDay = p.day
        Self.saveState(state, directory)
        Telemetry.shared.record(.perfDaily(p.event))
    }

    // MARK: Helpers

    private static func makeContext(app: AppDelegate) -> TelemetryContext {
        let info = Bundle.main.infoDictionary ?? [:]
        #if AIRC_TESTING
        let channel = TelemetryContext.Channel.dev
        #else
        // (Not the dev-channel key: public executables must not name it, scripts/release/scan-bundle.py.)
        let channel: TelemetryContext.Channel = info["AircUpdateChannel"] as? String == "dev" ? .dev : .stable
        #endif
        // The engine doesn't exist yet at this point; AppDelegate picks it from the same option.
        #if canImport(AircCore)
        let engine: TelemetryContext.Engine = app.options.engine == "chromium" ? .chromium : .webkit
        #else
        let engine = TelemetryContext.Engine.webkit
        #endif
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return TelemetryContext(appVersion: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "",
                                channel: channel, engine: engine, osVersion: ProcessInfo.processInfo.operatingSystemVersion, arch: arch,
                                preferredLanguage: Locale.preferredLanguages.first)
    }

    private static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func loadState(_ dir: URL) -> State {
        (try? Data(contentsOf: dir.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private static func saveState(_ s: State, _ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: dir.appendingPathComponent("state.json"), options: .atomic)
    }

    /// When this process started (the kernel's record), for launch_ms.
    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// This process's CPU time (user and system), in seconds.
    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    /// The browser process's memory footprint (what Activity Monitor shows as Memory).
    private static func footprintMegabytes() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}
