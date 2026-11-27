// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AppKit
import AircDesign
import AircImport
import AircKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Command-line options.
///   --data-dir <dir>     use <dir> instead of ~/Library/Application Support/Airc
///   --ephemeral          throwaway data (fresh store in a temp folder, non-persistent web data)
///   --skip-onboarding    never show onboarding (ON-4)
///   --engine webkit|chromium   the web engine (default webkit; chromium needs a build with the framework)
/// Test builds only (AIRC_TESTING, TestingGate.swift):
///   --snapshot <dir>     run a scripted scenario, write window PNGs to <dir>, then quit
///   --script <name>      the scenario for --snapshot (default "showcase"; "onboarding" runs the first-run flow
///                        on a synthetic import fixture)
///   --onboarding         always show onboarding, even when it has run (ON-4, for tests)
///   --automated          behave like a scripted run (no focus, mock Keychain, never the owner's Arc data) without a
///                        script, e.g. an update proof's test install
///   --perf-workload, --perf-events, --perf-control, --perf-load   `--script perf` (infra/perf/README.md)
/// A test install's bundle can carry default options (`AircLaunchArguments`, from AIRC_LAUNCH_ARGS in build-app.sh); they
/// come before the command line's, and survive Sparkle's relaunch after an update, which drops the command line.
/// Every other `--switch` (and `--switch=value`) is passed to Chromium, e.g. `--user-data-dir=<dir>`; without one,
/// Chromium's profiles live in `<data dir>/Chromium`. Public builds keep the engine's harness switches (`--airc-…`) out.
struct LaunchOptions {
    var dataDir: URL?
    var ephemeral = false
    var skipOnboarding = false
    var engine = "webkit"
    /// Switches meant for Chromium (anything that isn't one of ours).
    var engineSwitches: [String] = []
    #if AIRC_TESTING
    var snapshotDir: URL?
    var script = "showcase"
    var forceOnboarding = false
    var automated = false
    /// `--script perf` (infra/perf/README.md): the reference workload, the JSON-lines events file and the control file.
    var perfWorkload: URL?
    var perfEvents: URL?
    var perfControl: URL?
    /// `--perf-load all`: every workload tab's page is loaded, not only the recent ones (MEM-4's all-30 variant).
    var perfLoadAll = false

    /// Scripted runs never read the owner's Arc data or Keychain, and never take focus.
    var isAutomated: Bool { automated || snapshotDir != nil || ProcessInfo.processInfo.environment["AIRC_AUTOMATED"] == "1" }
    /// A scripted scenario (snapshots, perf, the launch smoke before publishing): the updater never runs.
    var isScripted: Bool { snapshotDir != nil || scriptGiven }
    private var scriptGiven = false
    #else
    // Public builds never run scripted or automated: constants, so the shared code's test-only branches compile away.
    var snapshotDir: URL? { nil }
    var forceOnboarding: Bool { false }
    var isAutomated: Bool { false }
    var isScripted: Bool { false }
    #endif

    static let current = LaunchOptions.parse()

    static func parse(_ commandLine: [String] = CommandLine.arguments) -> LaunchOptions {
        #if AIRC_TESTING
        let bundled = Bundle.main.object(forInfoDictionaryKey: "AircLaunchArguments") as? [String] ?? []
        let args = Array(commandLine.prefix(1)) + bundled + commandLine.dropFirst()
        #else
        let args = commandLine
        #endif
        var o = LaunchOptions()
        var engineGiven = false
        var i = 1
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "--data-dir": o.dataDir = next.map { URL(fileURLWithPath: $0, isDirectory: true) }; i += 1
            case "--ephemeral": o.ephemeral = true
            case "--skip-onboarding": o.skipOnboarding = true
            case "--engine": o.engine = next ?? o.engine; engineGiven = true; i += 1
            #if AIRC_TESTING
            case "--snapshot": o.snapshotDir = next.map { URL(fileURLWithPath: $0, isDirectory: true) }; i += 1
            case "--script": o.script = next ?? o.script; o.scriptGiven = true; i += 1
            case "--onboarding": o.forceOnboarding = true
            case "--automated": o.automated = true
            case "--perf-workload": o.perfWorkload = next.map { URL(fileURLWithPath: $0) }; i += 1
            case "--perf-events": o.perfEvents = next.map { URL(fileURLWithPath: $0) }; i += 1
            case "--perf-control": o.perfControl = next.map { URL(fileURLWithPath: $0) }; i += 1
            case "--perf-load": o.perfLoadAll = next == "all"; i += 1
            #endif
            default:
                if a.hasPrefix("--engine=") { o.engine = String(a.dropFirst("--engine=".count)); engineGiven = true }
                else if a.hasPrefix("--"), forwardsToEngine(a) { o.engineSwitches.append(a) }
            }
            i += 1
        }
        // A bundle can name its default engine (AircDefaultEngine in Info.plist), e.g. a Chromium copy for the perf
        // harness, which launches the app without engine flags.
        if !engineGiven, let e = Bundle.main.object(forInfoDictionaryKey: "AircDefaultEngine") as? String { o.engine = e }
        #if AIRC_TESTING
        if o.snapshotDir != nil {
            // Scenarios decide: the onboarding one forces it, every other one skips it.
            if o.script == "onboarding" { o.forceOnboarding = true } else { o.skipOnboarding = true }
        }
        #endif
        return o
    }

    /// The engine's harness switches (`--airc-test`, `--airc-trace`, `--airc-background`, `--airc-switches`,
    /// `--airc-data-dir`; engine/core/airc_launch_switches.h) reach Chromium from test builds only. The engine gates
    /// its test hooks at run time as well (docs/release.md, "Engine test hooks").
    private static func forwardsToEngine(_ engineSwitch: String) -> Bool {
        #if AIRC_TESTING
        return true
        #else
        return !engineSwitch.hasPrefix("--airc-")
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if canImport(Sparkle)
    /// "Check for Updates…" (release builds, with SPARKLE_ROOT). Release builds check only when asked until the feed is
    /// live (SUEnableAutomaticChecks false); dev builds check and download by themselves (AircUpdateDelegate).
    /// Scripted runs (snapshots, perf, the publish smoke) never start the updater, so they never update their build.
    private let updateDelegate = AircUpdateDelegate()
    lazy var updaterController = SPUStandardUpdaterController(startingUpdater: !options.isScripted, updaterDelegate: updateDelegate,
                                                              userDriverDelegate: nil)
    #endif
    let options = LaunchOptions.current
    var store: SpacesStore!
    var settings: AppSettings!
    var history: HistoryStore!
    var engine: BrowserEngine!
    /// SB-3: routes the engine's prompts to the window showing their page (PagePrompts.swift).
    var promptCenter: PromptCenter?
    var profiles: ProfileHost!
    var blocking: BlockingCenter!
    var credentialSink: EngineCredentialSink!
    /// Every open browser window, the one used last first (WIN-7, Browser/MultiWindow.swift).
    var controllers: [WindowController] = []
    /// The browser window commands, links and panels go to: the key one, else the one used last.
    var controller: WindowController? { controllers.first }
    var windowSession = WindowSessionState()
    var onboarding: OnboardingController?
    var settingsWindow: SettingsWindowController?
    #if AIRC_TESTING
    var snapshotRunner: SnapshotRunner?
    #endif
    private var keyMonitor: Any?
    #if canImport(Sparkle)
    private var devUpdateTimer: Timer?
    #endif
    private var pendingURLs: [URL] = []

    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // With Chromium, main.swift starts the app from engineDidStart, and AppKit may still send its own
        // did-finish-launching afterwards (release builds start fast enough): set up exactly once.
        guard !launched else { return }
        launched = true
        let launchSetup = LaunchTimeline.begin("didFinishLaunching")
        defer { launchSetup() }
        WebKitPasskeyGuard.wrapQuitAppleEvent()   // wkpasskeyquit: a Dock or logout quit isn't held by a system sheet
        AppPaths.prepare(options)
        #if canImport(Sparkle)
        // Dev builds: a check at launch, then every 10 minutes (the ship loop publishes about every 20; Sparkle's own
        // schedule can't go below an hour), downloading by themselves.
        if Bundle.main.object(forInfoDictionaryKey: "AircDevChannel") as? Bool == true, !options.isScripted {
            updateDelegate.log("launched from \(Bundle.main.bundlePath)")
            let updater = updaterController.updater
            // Override preferences left by an earlier manually checked dev build.
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
            updater.updateCheckInterval = 3600
            // Off the launch's path: once every profile is ready, a few seconds later.
            whenProfilesReady { [weak updater] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { updater?.checkForUpdatesInBackground() }
            }
            devUpdateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak updater] _ in
                // Not while a downloaded update waits for its restart (the pill is showing).
                guard let updater, !updater.sessionInProgress, UpdateCenter.shared.ready == nil else { return }
                updater.checkForUpdatesInBackground()
            }
        }
        #endif
        let firstRun = !FileManager.default.fileExists(atPath: AppPaths.store.path)
        let storeOpen = LaunchTimeline.begin("store open")
        defer { storeOpen() }
        do {
            store = try SpacesStore(path: AppPaths.store.path)
            storeOpen()
        } catch {
            LaunchEvent.shared.releaseActivation(activate: true)
            let alert = NSAlert()
            alert.messageText = "Airc can't open its data"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        // M4: a failed write stays pending and is retried; the user hears about it once.
        store.onWriteFailure = { [weak self] _ in
            self?.controller?.showToast("Airc couldn't save your latest changes. It keeps trying.")
        }
        ProfileHost.migrateColors(in: store)
        settings = AppSettings(directory: AppPaths.dataDirectory)
        // darkfix: Settings › Appearance (Auto follows macOS; Light / Dark force it), before any window draws.
        AppAppearance.start(app: self)
        let services = LaunchTimeline.begin("telemetry, crash reports, feedback")
        AppTelemetry.shared.start(app: self, firstRun: firstRun)
        AppCrashReports.shared.start()
        FeedbackCenter.shared.start(app: self)   // feedback saved while offline goes once the network is back
        CallNotes.shared.start()   // Settings › Calendar › Start Granola notes (Call/CallNotes.swift)
        services()
        let historyOpen = LaunchTimeline.begin("history open")
        history = (try? HistoryStore(path: AppPaths.history.path)) ?? (try! HistoryStore(path: nil))
        historyOpen()
        // Scripted runs never keep web data (cookies, caches), even when the store persists.
        let engineMade = LaunchTimeline.begin("engine object")
        defer { engineMade() }
        #if canImport(AircCore)
        if options.engine == "chromium" { engine = ChromiumEngine() }
        else { engine = Self.makeWebKitEngine(options) }
        #else
        engine = Self.makeWebKitEngine(options)
        #endif
        engineMade()
        let pageScripts = LaunchTimeline.begin("page scripts")
        // BST-1: the Boosts part of the engine's page script, before the first page opens.
        BoostCenter.start(engine: engine)
        // SB-2: the page script's location and device-ask part (SiteUse.swift), on the same script.
        SiteUse.start()
        // P07: Arc's page palette (--arc-palette-*), the theme of each page's Space (ThemePagePalette.swift).
        ThemePagePalette.start(app: self)
        // Pages prefer their Space's light or dark, live (PageColorScheme.swift).
        PageColorScheme.start(app: self)
        DeveloperMode.shared.start(settings: settings)
        // Link previews' part of the page script, before the first page opens (only when an AI setting is on).
        MainActor.assumeIsolated { AIFeatures.startIfNeeded(settings: settings) }
        pageScripts()
        profiles = ProfileHost(store: store, engine: engine)
        MainActor.assumeIsolated {
            let center = LaunchTimeline.begin("blocking center")
            blocking = BlockingCenter(app: self)
            center()
            profiles.beforeUse = { [weak self] profile, id, ready in
                MainActor.assumeIsolated {
                    self?.blocking.prepare(profile: profile, id: id) { [weak self] in
                        ready()
                        guard let self else { return }
                        for controller in self.controllers where controller.store.profile(ofSpace: controller.currentSpaceID).id == id {
                            BlockingNotices.show(in: controller)
                        }
                    }
                }
            }
        }
        promptCenter = PromptCenter(engine: engine)
        BlockedPopupNotice.shared.start()   // a blocked pop-up where the address field's icon can't be seen
        installLinkRouter()
        credentialSink = EngineCredentialSink.make(engine: engine, profiles: profiles)
        // L4: private copies of Arc's databases that a crash left behind.
        DispatchQueue.global(qos: .utility).async { ArcCredentialImporter.removeStaleCopies() }
        let menu = LaunchTimeline.begin("main menu")
        NSApp.mainMenu = MainMenu.build(app: self)
        menu()
        keyMonitor = KeyMonitor.install(app: self)
        #if AIRC_TESTING
        if options.snapshotDir != nil { snapshotRunner = SnapshotRunner(app: self, directory: options.snapshotDir!, script: options.script) }
        #endif
        // fastlaunch: the window doesn't wait for the profiles. Each profile's pages wait for its blocking rules
        // (`beforeUse`); its windows show their page once it is ready (profileBecameReady). The launch's visible
        // profiles load first, the others after them; what needs every profile (agents, sync, links that came
        // with the launch, a check's start) runs when all are ready.
        profiles.onReady { [weak self] id in self?.profileBecameReady(id) }
        // --agent-headless opens no window, and AgentCenter decides that with the profiles loaded.
        let headless = CommandLine.arguments.contains("--agent-headless")
        LaunchTimeline.mark("profiles requested")
        profiles.loadAll(first: headless ? [] : launchProfileIDs()) { [weak self] in
            guard let self else { return }
            LaunchTimeline.mark("all profiles ready")
            self.allProfilesReady(headless: headless, firstRun: firstRun)
        }
        if !headless { openBrowserAtLaunch(firstRun: firstRun) }
    }

    private func openBrowserAtLaunch(firstRun: Bool) {
        if shouldShowOnboarding(firstRun: firstRun) {
            // First run, even for a link (it waits for onboarding): onboarding comes forward.
            LaunchEvent.shared.releaseActivation(activate: !options.isAutomated)
            startOnboarding(mode: .firstRun)
        } else {
            openWindowAtLaunch()
        }
    }

    /// The profiles the launch shows first: those of the restored windows' Spaces (else the selected Space's).
    private func launchProfileIDs() -> Set<String> {
        let saved = (savedSession()?.windows ?? []).map(\.spaceID).filter { store.space($0) != nil }
        return Set((saved.isEmpty ? [store.selectedSpace.id] : saved).map { store.profile(ofSpace: $0).id })
    }

    /// Work that waits for every profile: none is pending once they all are ready.
    private var profilesReadyWaiters: [() -> Void]? = []
    var allProfilesAreReady: Bool { profilesReadyWaiters == nil }
    func whenProfilesReady(_ block: @escaping () -> Void) {
        if profilesReadyWaiters == nil { block() } else { profilesReadyWaiters!.append(block) }
    }

    private func allProfilesReady(headless: Bool, firstRun: Bool) {
        // Agents (Agent/AgentCenter.swift, docs/user/agents.md): the MCP connector, after the window.
        let agents = LaunchTimeline.begin("agents")
        let windowless = AgentCenter.shared.launch(app: self)
        agents()
        if headless {
            if windowless { LaunchEvent.shared.releaseActivation(activate: false) } else { openBrowserAtLaunch(firstRun: firstRun) }
        }
        let waiters = profilesReadyWaiters ?? []
        profilesReadyWaiters = nil
        waiters.forEach { $0() }
    }

    /// A profile is ready (launch, or a profile loaded later): windows that picked one of its tabs before then show it.
    private func profileBecameReady(_ id: String) {
        LaunchTimeline.mark("profile ready \(store.profile(id)?.name ?? id)")
        // In the order the windows picked their tabs (restore order), not the windows' recency order.
        let waits = controllers.filter { $0.waitingForProfile != nil }.sorted { $0.waitingForProfile!.order < $1.waitingForProfile!.order }
        for c in waits {
            guard let waiting = c.waitingForProfile, let tab = store.tab(waiting.tabID), tab.profileID == id else { continue }
            c.waitingForProfile = nil
            // Only while the window still shows that profile (no Space switch to another profile since).
            guard c.currentProfileID == id else { continue }
            c.show(tab.id, focus: waiting.focus, updatesRows: false, takeOver: false)
        }
    }

    /// ON-4: the app decides first run (a fresh data folder, or an onboarding that was started and not finished).
    private func shouldShowOnboarding(firstRun: Bool) -> Bool {
        if options.forceOnboarding { return true }
        if options.skipOnboarding { return false }
        guard settings.values.onboardingCompletedAt == nil else { return false }
        return firstRun || settings.values.onboardingStartedAt != nil
    }

    // MARK: Onboarding

    /// First run, or Settings → Import → "Run onboarding again" (ON-3).
    func startOnboarding(mode: OnboardingController.Mode, atImport: Bool = false, atPasswordManager: Bool = false) {
        guard onboarding == nil else { onboarding?.window.makeKeyAndOrderFront(nil); return }
        #if AIRC_TESTING
        let fixture = options.isAutomated ? OnboardingFixture.plan() : nil
        #else
        let fixture: ImportPlan? = nil
        #endif
        let o = OnboardingController(app: self, mode: mode, fixture: fixture)
        onboarding = o
        if atImport { o.startAtImport() } else if atPasswordManager { o.startAtPasswordManager() }
        o.present(focus: !options.isAutomated)
        AppTelemetry.shared.launched()
        if !options.isAutomated { NSApp.activate(ignoringOtherApps: true) }
        #if AIRC_TESTING
        whenProfilesReady { [weak self] in self?.snapshotRunner?.onboardingDidStart(o) }
        #endif
    }

    /// "Open Airc": the onboarding window grows into the browser window (ON-5).
    func onboardingDidFinish(_ o: OnboardingController) {
        let c: WindowController
        if let existing = controller {
            c = existing
            c.applyTranslucency(settings.translucency)
            c.reloadAll(animated: false)
            c.switchToSpace(store.selectedSpace.id, animated: false)
        } else {
            c = makeController()
        }
        c.root.layoutSubtreeIfNeeded()
        let w = o.window, target = c.window
        var done = false
        let finish = { [weak self] in
            guard let self, !done else { return }
            done = true
            self.onboarding = nil
            self.windowSession.browserReady = true
            if o.mode == .firstRun { self.didOpen(c); AgentButtonHint.afterOnboarding(c) }
            o.onFinished?(c)
        }
        onMain { w.expand(into: target) { finish() } }
        // The expansion is a Core Animation spring; with the display asleep it never completes. The browser window
        // takes over anyway once the spring would have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !done else { return }
            target.alphaValue = 1
            w.orderOut(nil)
            target.makeKeyAndOrderFront(nil)
            finish()
        }
    }

    /// A re-run was closed without finishing.
    func onboardingDidCancel(_ o: OnboardingController) {
        if onboarding === o { onboarding = nil }
        controller?.window.makeKeyAndOrderFront(nil)
    }

    // MARK: Windows

    /// A browser window (WIN-7: the first of several, a ⌘N one, a restored one), now the window used last.
    func makeController(frame: NSRect? = nil, opening: WindowOpening = WindowOpening()) -> WindowController {
        let c = WindowController(store: store, profiles: profiles, engine: engine, frame: frame ?? initialFrame(), app: self,
                                 opening: opening)
        controllers.insert(c, at: 0)
        return c
    }

    /// linklaunch: the launch's browser window, unless the launch was for a link that opens in Little Airc. Arc showed
    /// only Little Arc then: no browser window, so no switch to the desktop's Space over a full-screen app (WhatsApp).
    /// Decided one run-loop turn after the profiles loaded, since AppKit hands the launch's link to the app around
    /// did-finish-launching, in either order; a launch whose Apple event is a link waits for it (at most 1.5 s).
    /// A plain launch ('oapp') always opens the window, even if a link comes while it launches.
    private func openWindowAtLaunch() {
        let deadline = Date().addingTimeInterval(1.5)
        func decide() {
            LaunchTimeline.mark("launch window decision")
            let launch = LaunchEvent.shared
            if pendingURLs.isEmpty, launch.announcesLink, Date() < deadline {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: decide)
            }
            if !launch.isPlainLaunch, !pendingURLs.isEmpty, pendingURLs.allSatisfy(routesToLittleArc) {
                launchWithoutWindow()
            } else {
                if !pendingURLs.isEmpty {
                    LinkLog.write("launch: \(pendingURLs.count) link(s) at launch, the browser window opens (launch event \(launch.summary), "
                                  + "link before did-finish-launching \(LinkLog.yesNo(launch.linkDuringLaunch)), Little Airc for all "
                                  + "\(LinkLog.yesNo(pendingURLs.allSatisfy(routesToLittleArc))))")
                }
                // A launch held for a link that the browser window shows after all: activated as Launch Services would have.
                LaunchEvent.shared.releaseActivation(activate: !options.isAutomated || LittleArcController.actsAsOwner)
                openWindow()
            }
        }
        DispatchQueue.main.async(execute: decide)
    }

    /// Whether `routeExternal` sends this link to Little Airc (no rule's Space, Settings → Links says Little Airc).
    func routesToLittleArc(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !BoostSharing.accepts(url) else { return false }
        return settings.values.externalLinks == .littleArc
            && LinkRouting.space(for: url, rules: settings.values.linkRules, existingSpaces: Set(store.state.spaces.keys)) == nil
    }

    /// linklaunch: launched for links that open in Little Airc. The store, profiles and session are ready, but no browser
    /// window is made or ordered in; the session's windows come back when the person asks for one: the Dock
    /// (applicationShouldHandleReopen), ⌘N, ⌘O in Little Airc, a link to a Space (`reopenWindows`, MultiWindow.swift).
    private func launchWithoutWindow() {
        windowSession.browserReady = true
        windowSession.windowsDeferred = true
        LinkLog.write("launch: launched by a link for Little Airc (launch event \(LaunchEvent.shared.summary), link before "
                      + "did-finish-launching \(LinkLog.yesNo(LaunchEvent.shared.linkDuringLaunch))): no browser window until one is asked for")
        // Chromium: the hidden window that keeps every loaded profile alive (Little Arc's too), as with a first window.
        installWindowHooksOnce()
        didLaunchBrowser()
        AppTelemetry.shared.launched()
        #if AIRC_TESTING
        snapshotRunner?.launchedWithoutWindow()
        #endif
        // Once Little Airc is on screen over the sending app: a regular app again (the Dock icon), not activated.
        // Little Airc becomes key again then (it couldn't while the app was held), still without activating the app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard LaunchEvent.shared.holdingActivation else { return }
            LaunchEvent.shared.releaseActivation(activate: false)
            if let l = self?.littleArcs.last, l.overFullScreen, l.window.isVisible, !l.window.isKeyWindow { l.window.makeKeyAndOrderFront(nil) }
        }
        // Should Little Airc not open after all (the links failed to route), the session's windows come, never nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            LaunchEvent.shared.releaseActivation(activate: false)
            guard let self, self.windowSession.windowsDeferred, self.littleArcsOpened == 0, self.onboarding == nil else { return }
            LinkLog.write("launch: no Little Airc opened for the launch's link; the browser window opens")
            self.reopenWindows()
        }
    }

    private func openWindow() {
        // WIN-7: the last session's windows, the one used last in front.
        let restoring = LaunchTimeline.begin("windows restore")
        let restored = restoreWindows()
        restoring()
        guard let c = restored.first else { return }
        windowSession.browserReady = true
        if options.snapshotDir != nil {
            // Don't take focus on the owner's Mac.
            for w in restored.reversed() { w.window.orderFront(nil) }
        } else {
            presentRestored(restored)
        }
        LaunchTimeline.mark("window on screen")
        LaunchTimeline.markInteractiveAtNextIdle()
        didOpen(c)
        AppTelemetry.shared.launched()
        #if AIRC_TESTING
        // A check starts with every profile ready, as before fastlaunch; the launch timeline check starts at once.
        if options.script.hasPrefix("launchtimeline") { snapshotRunner?.windowDidOpen(c) }
        else { whenProfilesReady { [weak self] in self?.snapshotRunner?.windowDidOpen(c) } }
        #endif
    }

    private func didOpen(_ c: WindowController) {
        firstWindowOpened(c)
        didLaunchBrowser()
    }

    /// The launch's first browser window (at launch, after onboarding, or when a link launch's deferred windows open).
    func firstWindowOpened(_ c: WindowController) {
        MainActor.assumeIsolated { BlockingNotices.show(in: c) }
        #if AIRC_TESTING
        LaunchDiagnostics.start(c)   // AIRC_DIAG_LOG only
        #endif
        // H4: rows this build can't read stay on disk; say so once instead of losing them quietly.
        if !store.unreadableRows.isEmpty {
            c.showToast(store.newerSchemaVersion != nil ? "Some data is from a newer Airc and is kept for it"
                                                       : "Some saved items couldn't be read and are kept on disk")
        }
    }

    /// The browser is up (with its first window, or for a link launch without one): the app's own launch work, then
    /// the links that waited for it.
    private func didLaunchBrowser() {
        let launchWork = LaunchTimeline.begin("browser launch work")
        defer { launchWork() }
        // List updates (network), sync and the launch's links wait for every profile, off the launch's path.
        whenProfilesReady { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { Task { await self.blocking.refresh() } }
        }
        // H6: the spare loads when a profile might be created; only recorded orphan spares are removed, at idle. M5: the
        // op log and the archive are trimmed once per launch, also at idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.profiles.removeOrphanSpares()
            try? self.store.compactOperations(olderThan: 7 * 86400)
            try? self.store.pruneArchive()
            // Notes no row points at any more, then pictures no note shows (Notes/NoteEditor.swift, NoteImages).
            NoteCenter.collectGarbage(store: self.store, backups: self.settings.backupFolders)
        }
        _ = try? settings.backUp(store)
        EaselCenter.register()   // P19b: a duplicated Easel row copies its Easel (Easels/EaselCenter.swift)
        // iCloud sync (Sync/SyncCenter.swift): off until turned on in Settings → Sync.
        whenProfilesReady { [weak self] in
            guard let self else { return }
            let sync = LaunchTimeline.begin("sync start")
            SyncCenter.shared.start(app: self)
            sync()
        }
        // The launch's links now: their windows and tabs show at once, their pages wait for their profile's rules.
        if !pendingURLs.isEmpty { LaunchTimeline.mark("launch links routed") }
        pendingURLs.forEach(open)
        pendingURLs = []
    }

    func initialFrame() -> NSRect {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if options.snapshotDir != nil {
            return NSRect(x: screen.minX + 40, y: screen.maxY - 840, width: 1280, height: 800)
        }
        if let f = store.windowState.frame, f.count == 4 {
            let r = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if screen.intersects(r) { return r }
        }
        let w = min(1440, screen.width - 80), h = min(900, screen.height - 60)
        return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }

    // MARK: Settings (⌘,)

    func showSettings(page: SettingsPage? = nil) {
        let w = settingsWindow ?? SettingsWindowController(app: self)
        settingsWindow = w
        if let page { w.model.page = page }
        w.show(focus: !options.isAutomated)
    }

    // MARK: Links from other apps (AT-1) and Little Arc (LA-1)

    /// Open Little Arc windows.
    private(set) var littleArcs: [LittleArcController] = []
    /// How many Little Arc windows opened since the launch.
    private var littleArcsOpened = 0

    func application(_ application: NSApplication, open urls: [URL]) {
        openFromOtherApp(urls, source: LinkLog.eventSource())
    }

    /// Links from other apps: GURL Apple events (URLEventHandler, while the event is current; or from its launch queue)
    /// and files from Finder (AppKit). `source` is the sending app's bundle ID, for Links.log.
    func openFromOtherApp(_ urls: [URL], source: String?) {
        // LA-1: the sending app, while its Apple event is current. In native full screen, Little Arc opens over it, in
        // whatever order Launch Services activates Airc and hands over the link (LittleArcFullScreen.linkArrived).
        let sender = LinkLog.eventSenderPID()
        LaunchTimeline.mark("link received")
        URLEventHandler.noteLaunchLink()
        let senderState = LinkLog.enabled ? LinkLog.senderState(sender) : ""
        for url in urls { LittleArcFullScreen.shared.linkArrived(from: sender, url: url) }
        for url in urls {
            linkTraces[url.absoluteString] = LinkTrace(source: source, activeAtReceipt: NSApp.isActive, front: senderState,
                                                       via: windowSession.browserReady ? "the app" : "the launch queue")
        }
        // Before the first browser window (launching, onboarding). After it, a link with every window closed opens one
        // (routeExternal). A link whose profile isn't ready yet (launch) opens its window or tab at once; only its page
        // waits for the profile's blocking rules (WindowController.waitingForProfile, LittleArcController.waitingURL).
        if !windowSession.browserReady {
            pendingURLs += urls
            for url in urls {
                LinkLog.write("link \(LinkLog.host(url)) from \(source ?? "no Apple event"): waiting for the browser window "
                              + "(launching\(onboarding != nil ? ", onboarding" : ""))")
            }
            return
        }
        // Through the engine's routing policy while the Apple event is current (it knows the sending app); it hands
        // external links to `routeExternal` (linkRouter). An engine without one: straight there.
        for url in urls {
            if BoostSharing.accepts(url) { routeExternal(url); continue }
            if engine.routeExternalURL(url) { linkTraces[url.absoluteString]?.via = "the engine's policy" } else { routeExternal(url) }
        }
    }

    /// Links.log (LinkLog.swift): a link from another app, from its Apple event until it's routed.
    private struct LinkTrace {
        var source: String?
        var activeAtReceipt: Bool
        /// The sending app as the link came: in full screen, and its Space on screen (LinkLog.senderState).
        var front: String
        var via: String
    }
    private var linkTraces: [String: LinkTrace] = [:]
    /// The Little Arc window a link just opened, and when: the app's activation can hand the key window back to the
    /// browser window after the link made Little Arc key (`littleArcKeyAfterActivation`).
    private var openedLittleArc: (controller: LittleArcController, at: Date)?
    private var littleArcPressMonitor: Any?

    private func open(_ url: URL) { routeExternal(url) }

    /// The engine's routing policy: links from other apps are Airc's (rules, Little Arc); a page's own links keep
    /// Chromium's behaviour. Tab changes wait for the next turn, as the engine asks.
    func installLinkRouter() {
        // LA-1: links from an app in native full screen open Little Arc over it (LittleArcFullScreen).
        LittleArcFullScreen.shared.install(app: self)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // After AppKit has picked its key window for the activation.
            DispatchQueue.main.async { self?.littleArcKeyAfterActivation() }
        }
        // LA-1: a press on a Little Arc page works the first time (takeFirstPress), and Links.log hears the first ones.
        littleArcPressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] e in
            guard let l = self?.littleArc(for: e.window) else { return e }
            if e.type == .leftMouseUp { return l.takeRelease(e) }
            let wasKey = l.window.isKeyWindow
            let handed = l.takeFirstPress(e)
            l.notePress(e, wasKey: wasKey)
            return handed
        }
        LittleArcLinkClicks.start()
        engine.linkRouter = { [weak self] request in
            if request.source == "external" {
                DispatchQueue.main.async { self?.routeExternal(request.url) }
                return true
            }
            guard let self, request.source == "page", let opener = request.opener else { return false }
            // P06d: a link clicked with ⌥⌘ opens in Little Airc (Browser/LittleArcLinkClicks.swift).
            if let sid = self.optionCommandClickSpace(request, from: opener) {
                DispatchQueue.main.async { [weak self] in _ = self?.openLittleArc(url: request.url, spaceID: sid) }
                return true
            }
            // No fallback to the most recent window: private and Little Arc pages must stay there.
            guard let c = self.controllers.first(where: { $0.tabID(for: opener) != nil || $0.peek?.page === opener }) else { return false }
            // PK-1 / AT-1 (LinkRouting.pageTarget): Peek for another site from a pinned tab or Favorite, or a ⇧-click;
            // a rule's Space instead for a link a rule matches; a meeting link in a new tab.
            let target = LinkRouting.pageTarget(from: opener.url, to: request.url, userGesture: request.userGesture,
                                                wantsPeek: c.wantsPeek(request), explicitPeek: request.disposition == "window",
                                                fromPeek: c.peek?.page === opener, rules: self.settings.values.linkRules,
                                                existingSpaces: Set(self.store.orderedSpaces.map(\.id)))
            switch target {
            case .engine: return false
            case .peek:
                DispatchQueue.main.async { [weak c] in c?.openPeek(request.url, from: opener) }
            case .newTab:
                DispatchQueue.main.async { [weak c] in c?.navigate(to: request.url, newTab: true) }
            case .space(let id):
                // A link followed inside Peek leaves the card behind: it closes, then the rule's Space shows the link.
                let fromPeek = c.peek?.page === opener
                DispatchQueue.main.async { [weak c] in
                    if fromPeek { c?.closePeek() }
                    c?.openExternal(request.url, inSpace: id)
                }
            }
            return true
        }
        // SP-31: Chromium's "Open link in Space ›" (WebKit's menu asks its tab's delegate the same way).
        engine.contextMenuSpaces = { [weak self] page, _ in
            self?.controllers.lazy.map { $0.linkSpaces(for: page) }.first { !$0.isEmpty } ?? []
        }
        engine.openLinkInSpace = { [weak self] page, raw, id in
            guard let url = URL(string: raw) else { return }
            self?.controllers.forEach { $0.tab(page, openLink: url, inSpace: id) }
        }
    }

    /// AT-1: the first rule that matches sends the link to its Space (whose profile is signed in); otherwise Little Arc
    /// in the most recent Space's profile, or a tab in that Space (Settings → Links).
    func routeExternal(_ url: URL) {
        guard windowSession.browserReady, onboarding == nil || controller != nil else { pendingURLs.append(url); return }
        if BoostSharing.accepts(url), let c = browserWindow() {
            BoostSharing.open(url, on: c.window)
            return
        }
        let trace = linkTraces.removeValue(forKey: url.absoluteString)
        // The full-screen app the link came from, if it was in full screen (every route takes it; Little Arc uses it).
        let fullScreenApp = LittleArcFullScreen.shared.takeLinkSource(for: url)
        let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        let rule = web ? LinkRouting.space(for: url, rules: settings.values.linkRules, existingSpaces: Set(store.state.spaces.keys)) : nil
        if web, rule == nil, settings.values.externalLinks == .littleArc {
            let open = { [weak self] in
                guard let self else { return }
                let l = self.openLittleArc(url: url, overFullScreenOf: fullScreenApp)
                if let l, trace != nil { self.openedLittleArc = (l, Date()) }
                self.logLink(url, trace, route: "Little Arc", window: l?.window, created: l != nil)
            }
            // A link that launched Airc (or one macOS switched away for): back to the full-screen app's Space first.
            // A link launch from an app that isn't in full screen: activated now, as Launch Services would have, so Little
            // Arc comes forward as an ordinary window (LaunchEvent.holdActivation).
            if fullScreenApp == nil { LaunchEvent.shared.releaseActivation(activate: !options.isAutomated || LittleArcController.actsAsOwner) }
            if let fs = fullScreenApp, LittleArcFullScreen.shared.needsReturn(to: fs) {
                LittleArcFullScreen.shared.returnToFullScreen(of: fs, then: open)
            } else {
                open()
            }
            return
        }
        // WIN-7: the window used last; with every window closed, the last session's come back first.
        let created = controller == nil
        guard let c = browserWindow() else { pendingURLs.append(url); return }
        if let sid = rule {
            c.openExternal(url, inSpace: sid)
            bringForward(c.window)
            logLink(url, trace, route: "a rule's Space", window: c.window, created: created)
            return
        }
        c.openExternal(url, inSpace: c.currentSpaceID)
        bringForward(c.window)
        logLink(url, trace, route: web ? "a tab in the current Space" : "a tab (not a web link)", window: c.window, created: created)
    }

    /// Links.log: the route, and half a second later where the key window is (a link that opened a window the person
    /// can't click into shows here as key no, or the app inactive).
    private func logLink(_ url: URL, _ trace: LinkTrace?, route: String, window: NSWindow?, created: Bool) {
        guard LinkLog.enabled, let trace else { return }
        let head = "link \(LinkLog.host(url)) from \(trace.source ?? "no Apple event") (app active \(LinkLog.yesNo(trace.activeAtReceipt)), \(trace.front)) "
            + "via \(trace.via): \(route), window \(created ? "created" : window == nil ? "none" : "existing")"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
            let state = window.map(LinkLog.windowState) ?? "no window"
            LinkLog.write(head + "; 0.5 s later: \(state); app active \(LinkLog.yesNo(NSApp.isActive)), "
                          + "key window \(self?.windowName(NSApp.keyWindow) ?? "-")")
        }
    }

    /// What a window is, for Links.log.
    func windowName(_ w: NSWindow?) -> String {
        guard let w else { return "none" }
        if let c = controller(for: w) {
            let n = controllers.count > 1 ? " \((controllers.firstIndex { $0 === c } ?? 0) + 1) of \(controllers.count)" : ""
            return "the browser window" + n + (w.styleMask.contains(.fullScreen) ? " (full screen)" : "")
        }
        if littleArc(for: w) != nil { return "a Little Arc window" }
        if w === settingsWindow?.window { return "Settings" }
        if w === onboarding?.window { return "onboarding" }
        return String(describing: type(of: w))
    }

    /// LA-1: the app became active (Launch Services activates it for a link from another app) right after a link made
    /// a Little Arc window key: AppKit gives the key back to the window that had it before (the browser window), and the
    /// first click on Little Arc's page would then only activate its window (Chromium takes no first click). Little Arc
    /// stays the key window.
    private func littleArcKeyAfterActivation() {
        guard let (l, at) = openedLittleArc else { return }
        openedLittleArc = nil
        guard Date().timeIntervalSince(at) < 3, littleArcs.contains(where: { $0 === l }), l.window.isVisible,
              !l.window.isKeyWindow, !l.isMiniPlayer else { return }
        LinkLog.write("activation: the key window was \(windowName(NSApp.keyWindow)); Little Arc made key again")
        l.window.makeKeyAndOrderFront(nil)
    }

    /// ⌥⌘N, and links from other apps: a Little Arc window in `spaceID`'s profile (the most recent Space by default).
    /// A link from an app in native full screen (`overFullScreenOf` that app) opens it as a panel over that app.
    @discardableResult
    func openLittleArc(url: URL?, spaceID: String? = nil, overFullScreenOf fullScreenApp: pid_t? = nil) -> LittleArcController? {
        // WIN-7: with every browser window closed, in the last Space.
        guard store != nil, windowSession.browserReady else { return nil }
        let c = controller
        let recent = spaceID ?? c?.currentSpaceID ?? store.selectedSpace.id
        let sid = spaceID ?? url.map { settings.values.littleArcProfiles.space(for: $0, rules: settings.values.linkRules,
                            spaces: store.orderedSpaces, recentSpaceID: recent) } ?? recent
        let screen = (c?.window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(840, screen.width - 80), height: min(620, screen.height - 80))
        // Cascaded from the screen's upper middle, as Arc places it.
        let n = CGFloat(littleArcs.count % 6) * 24
        let frame = NSRect(x: screen.midX - size.width / 2 + n, y: screen.maxY - size.height - 60 - n, width: size.width, height: size.height)
        // linklaunch: the process's first Little Airc page is made after its window is on screen.
        var deferPage = !LittleArcController.madeFirstPage && littleArcsOpened == 0
        #if AIRC_TESTING
        if LinkLaunchBaseline.enabled { deferPage = false }
        #endif
        let l = LittleArcController(app: self, url: url, spaceID: sid, frame: frame, overFullScreen: fullScreenApp != nil,
                                    deferPage: deferPage)
        if deferPage { LaunchTimeline.mark("little airc window made") }
        Telemetry.shared.record(.featureUsed(.littleArcOpen(url == nil ? .shortcut : .link)))
        littleArcs.append(l)
        littleArcsOpened += 1
        if let fullScreenApp {
            // Key without activating Airc (a non-activating panel): no Space switch, and the full-screen app stays.
            if options.isAutomated, !LittleArcController.actsAsOwner { l.window.orderFront(nil) } else { l.window.makeKeyAndOrderFront(nil) }
            LittleArcFullScreen.shared.shown(l, over: fullScreenApp)
        } else {
            bringForward(l.window)
        }
        if deferPage {
            l.window.displayIfNeeded()
            CATransaction.flush()
            LaunchTimeline.mark("little airc window shown")
            l.openDeferredPage()
        }
        return l
    }

    func littleArcClosed(_ l: LittleArcController) { littleArcs.removeAll { $0 === l } }

    func littleArc(for window: NSWindow?) -> LittleArcController? { littleArcs.first { $0.window === window } }

    private func bringForward(_ w: NSWindow) {
        // A scratch copy in the by-hand full-screen proof acts as the owner's build (LittleArcController.actsAsOwner).
        if options.isAutomated, !LittleArcController.actsAsOwner { w.orderFront(nil) } else { w.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    /// The WebKit dev engine. A scripted run keeps its cookies in memory only, except the quitdata pair, which checks that
    /// they survive a quit and relaunch (and chromeaccept's isolation pair): its store persists, named from its data folder (as the Chromium build's WebKit
    /// pages' stores are), so it never shares the daily one's (artifacts/wkcookie). Run it with CFFIXED_USER_HOME, as
    /// its runner does: the store is in that home's Library/WebKit.
    private static func makeWebKitEngine(_ options: LaunchOptions) -> WebKitEngine {
        #if AIRC_TESTING
        // chromeaccept-write/-read (ChromeAcceptCheck.swift): profile isolation across a relaunch, the same way.
        if options.script.hasPrefix("quitdata-") || options.script.hasPrefix("chromeaccept-"), options.snapshotDir != nil, !options.ephemeral {
            return WebKitEngine(ephemeral: false, storeScope: AppPaths.dataDirectory.standardizedFileURL.path)
        }
        #endif
        return WebKitEngine(ephemeral: options.ephemeral || options.snapshotDir != nil)
    }

    /// WIN-7: Airc stays open with no window (as Arc and Chrome); ⌘N, the Dock or a link brings one back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var awaitingDownloadQuitAnswer = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if AIRC_TESTING
        QuitDiagnostics.mark("applicationShouldTerminate")
        #endif
        // wkpasskeyquit: a system sheet (and, with the passkey capability, a page's passkey request) ends first.
        WebKitPasskeyGuard.prepareForQuit()
        if awaitingDownloadQuitAnswer { return .terminateLater }
        let library = MediaLibrary.shared
        guard let downloads = library.downloads, !downloads.engine.asksBeforeClosingWithDownloads,
              downloads.runningCount > 0, let confirm = downloads.engine.downloadsCloseConfirmation else {
            // WIN-7: every window is in the session as it is now; the quit closing them doesn't take them out.
            quitWillCloseWindows()
            flushForQuit()
            return .terminateNow
        }
        awaitingDownloadQuitAnswer = true
        confirm(downloads.runningCount) { [weak self] quit in
            self?.awaitingDownloadQuitAnswer = false
            if quit { self?.quitWillCloseWindows(); self?.flushForQuit() }
            else { BundleReplacementMonitor.shared.quitCancelled() }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    /// Writes Airc's own state as soon as a quit is accepted, before Chromium's teardown starts. Under heavy disk load
    /// that teardown can wait on its own file flushes until Chromium's Mac teardown watchdog ends the process at 10 s
    /// (`_exit`, no willTerminate), so willTerminate's flush is not guaranteed to run (artifacts/quitflush).
    private func flushForQuit() {
        try? store?.flush()
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if AIRC_TESTING
        QuitDiagnostics.mark("willTerminate")
        defer { QuitDiagnostics.mark("willTerminate done") }
        #endif
        BundleReplacementMonitor.shared.applicationWillTerminate()
        // WIN-7: the dev engine quits with its windows still open (Chromium's closed them, already saved).
        quitWillCloseWindows()
        try? store?.flush()
        #if AIRC_TESTING
        QuitDiagnostics.mark("store flushed")
        #endif
        AppTelemetry.shared.willTerminate()
        #if AIRC_TESTING
        QuitDiagnostics.mark("telemetry done")
        #endif
        // An --ephemeral data folder goes only once the engine has finished. With Chromium, the first willTerminate comes
        // from chrome::HandleAppExitingForPlatform, while Chromium still runs and launches helpers into that folder:
        // deleting it then made a helper's CHECK(CreateDirectory(--user-data-dir)) abort, and under disk load the
        // recursive delete held the main thread past the 15 s quit bound (quitflush). main.swift calls this again after
        // ChromiumRuntime.run returns, with chromiumRunning false.
        if options.ephemeral, !Self.chromiumRunning, AppPaths.mayDeleteEphemeral(AppPaths.dataDirectory) {
            Self.removeEphemeral(AppPaths.dataDirectory)
        }
    }

    /// Moves `dir` aside at once (a rename, so nothing can use the old path) and deletes the moved copy in a detached
    /// `rm`, so the quit never waits on a recursive delete. Falls back to deleting in place if the rename fails.
    private static func removeEphemeral(_ dir: URL) {
        let fm = FileManager.default
        let aside = dir.deletingLastPathComponent()
            .appendingPathComponent(".\(dir.lastPathComponent).deleting-\(ProcessInfo.processInfo.processIdentifier)")
        guard (try? fm.moveItem(at: dir, to: aside)) != nil else { try? fm.removeItem(at: dir); return }
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/bin/rm")
        rm.arguments = ["-rf", aside.path]
        rm.standardInput = FileHandle.nullDevice
        rm.standardOutput = FileHandle.nullDevice
        rm.standardError = FileHandle.nullDevice
        if (try? rm.run()) == nil { try? fm.removeItem(at: aside) }
    }

    /// True while ChromiumRuntime.run owns the process (main.swift): Chromium hasn't finished its shutdown yet.
    nonisolated(unsafe) static var chromiumRunning = false
}
