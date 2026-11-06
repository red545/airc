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
    var credentialSink: EngineCredentialSink!
    var controller: WindowController?
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
            updater.checkForUpdatesInBackground()
            devUpdateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak updater] _ in
                // Not while a downloaded update waits for its restart (the pill is showing).
                guard let updater, !updater.sessionInProgress, UpdateCenter.shared.ready == nil else { return }
                updater.checkForUpdatesInBackground()
            }
        }
        #endif
        let firstRun = !FileManager.default.fileExists(atPath: AppPaths.store.path)
        do {
            store = try SpacesStore(path: AppPaths.store.path)
        } catch {
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
        AppTelemetry.shared.start(app: self, firstRun: firstRun)
        AppCrashReports.shared.start()
        history = (try? HistoryStore(path: AppPaths.history.path)) ?? (try! HistoryStore(path: nil))
        // Scripted runs never keep web data (cookies, caches), even when the store persists.
        #if canImport(AircCore)
        if options.engine == "chromium" { engine = ChromiumEngine() }
        else { engine = WebKitEngine(ephemeral: options.ephemeral || options.snapshotDir != nil) }
        #else
        engine = WebKitEngine(ephemeral: options.ephemeral || options.snapshotDir != nil)
        #endif
        // BST-1: the Boosts part of the engine's page script, before the first page opens.
        BoostCenter.start(engine: engine)
        // SB-2: the page script's location and device-ask part (SiteUse.swift), on the same script.
        SiteUse.start()
        profiles = ProfileHost(store: store, engine: engine)
        promptCenter = PromptCenter(engine: engine)
        installLinkRouter()
        credentialSink = EngineCredentialSink.make(engine: engine, profiles: profiles)
        // L4: private copies of Arc's databases that a crash left behind.
        DispatchQueue.global(qos: .utility).async { ArcCredentialImporter.removeStaleCopies() }
        NSApp.mainMenu = MainMenu.build(app: self)
        keyMonitor = KeyMonitor.install(app: self)
        #if AIRC_TESTING
        if options.snapshotDir != nil { snapshotRunner = SnapshotRunner(app: self, directory: options.snapshotDir!, script: options.script) }
        #endif
        profiles.loadAll { [weak self] in
            guard let self else { return }
            if self.shouldShowOnboarding(firstRun: firstRun) {
                self.startOnboarding(mode: .firstRun)
            } else {
                self.openWindow()
            }
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
    func startOnboarding(mode: OnboardingController.Mode, atImport: Bool = false) {
        guard onboarding == nil else { onboarding?.window.makeKeyAndOrderFront(nil); return }
        #if AIRC_TESTING
        let fixture = options.isAutomated ? OnboardingFixture.plan() : nil
        #else
        let fixture: ImportPlan? = nil
        #endif
        let o = OnboardingController(app: self, mode: mode, fixture: fixture)
        onboarding = o
        if atImport { o.startAtImport() }
        o.present(focus: !options.isAutomated)
        AppTelemetry.shared.launched()
        if !options.isAutomated { NSApp.activate(ignoringOtherApps: true) }
        #if AIRC_TESTING
        snapshotRunner?.onboardingDidStart(o)
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
            if o.mode == .firstRun { self.didOpen(c) }
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

    private func makeController() -> WindowController {
        let c = WindowController(store: store, profiles: profiles, engine: engine, frame: initialFrame(), app: self)
        controller = c
        return c
    }

    private func openWindow() {
        let c = makeController()
        if options.snapshotDir != nil {
            // Don't take focus on the owner's Mac.
            c.window.orderFront(nil)
        } else {
            c.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        didOpen(c)
        AppTelemetry.shared.launched()
        #if AIRC_TESTING
        snapshotRunner?.windowDidOpen(c)
        #endif
    }

    private func didOpen(_ c: WindowController) {
        #if AIRC_TESTING
        LaunchDiagnostics.start(c)   // AIRC_DIAG_LOG only
        #endif
        // H4: rows this build can't read stay on disk; say so once instead of losing them quietly.
        if !store.unreadableRows.isEmpty {
            c.showToast(store.newerSchemaVersion != nil ? "Some data is from a newer Airc and is kept for it"
                                                       : "Some saved items couldn't be read and are kept on disk")
        }
        // H6: the spare loads when a profile might be created; only recorded orphan spares are removed, at idle. M5: the
        // op log and the archive are trimmed once per launch, also at idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.profiles.removeOrphanSpares()
            try? self.store.compactOperations(olderThan: 7 * 86400)
            try? self.store.pruneArchive()
        }
        _ = try? store.backupIfNeeded(to: settings.values.backupFolder.map { URL(fileURLWithPath: $0) } ?? AppPaths.backups)
        pendingURLs.forEach(open)
        pendingURLs = []
    }

    private func initialFrame() -> NSRect {
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

    func application(_ application: NSApplication, open urls: [URL]) {
        openFromOtherApp(urls, source: LinkLog.eventSource())
    }

    /// Links from other apps: GURL Apple events (URLEventHandler, while the event is current; or from its launch queue)
    /// and files from Finder (AppKit). `source` is the sending app's bundle ID, for Links.log.
    func openFromOtherApp(_ urls: [URL], source: String?) {
        for url in urls {
            linkTraces[url.absoluteString] = LinkTrace(source: source, activeAtReceipt: NSApp.isActive, front: LinkLog.frontApp(),
                                                       via: controller == nil ? "the launch queue" : "the app")
        }
        if controller == nil {
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
            if engine.routeExternalURL(url) { linkTraces[url.absoluteString]?.via = "the engine's policy" } else { routeExternal(url) }
        }
    }

    /// Links.log (LinkLog.swift): a link from another app, from its Apple event until it's routed.
    private struct LinkTrace {
        var source: String?
        var activeAtReceipt: Bool
        /// The front app as the link came, and whether it was in full screen.
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
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // After AppKit has picked its key window for the activation.
            DispatchQueue.main.async { self?.littleArcKeyAfterActivation() }
        }
        // LA-1: a press on a Little Arc page works the first time (takeFirstPress), and Links.log hears the first ones.
        littleArcPressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let l = self?.littleArc(for: e.window) else { return e }
            let wasKey = l.window.isKeyWindow
            l.takeFirstPress(e)
            l.notePress(e, wasKey: wasKey)
            return e
        }
        engine.linkRouter = { [weak self] request in
            if request.source == "external" {
                DispatchQueue.main.async { self?.routeExternal(request.url) }
                return true
            }
            // PK-1: a page's link that should open in Peek.
            guard let c = self?.controller, c.wantsPeek(request), let opener = request.opener else { return false }
            DispatchQueue.main.async { [weak c] in c?.openPeek(request.url, from: opener) }
            return true
        }
    }

    /// AT-1: the first rule that matches sends the link to its Space (whose profile is signed in); otherwise Little Arc
    /// in the most recent Space's profile, or a tab in that Space (Settings → Links).
    func routeExternal(_ url: URL) {
        guard let c = controller else { pendingURLs.append(url); return }
        let trace = linkTraces.removeValue(forKey: url.absoluteString)
        let web = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        if web, let sid = LinkRouting.space(for: url, rules: settings.values.linkRules, existingSpaces: Set(store.state.spaces.keys)) {
            c.openExternal(url, inSpace: sid)
            bringForward(c.window)
            logLink(url, trace, route: "a rule's Space", window: c.window, created: false)
            return
        }
        if web, settings.values.externalLinks == .littleArc {
            let l = openLittleArc(url: url)
            if let l, trace != nil { openedLittleArc = (l, Date()) }
            logLink(url, trace, route: "Little Arc", window: l?.window, created: l != nil)
            return
        }
        c.openExternal(url, inSpace: c.currentSpaceID)
        bringForward(c.window)
        logLink(url, trace, route: web ? "a tab in the current Space" : "a tab (not a web link)", window: c.window, created: false)
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
        if w === controller?.window { return "the browser window" + (w.styleMask.contains(.fullScreen) ? " (full screen)" : "") }
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
    @discardableResult
    func openLittleArc(url: URL?, spaceID: String? = nil) -> LittleArcController? {
        guard let c = controller else { return nil }
        let sid = spaceID ?? c.currentSpaceID
        let screen = (c.window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(840, screen.width - 80), height: min(620, screen.height - 80))
        // Cascaded from the screen's upper middle, as Arc places it.
        let n = CGFloat(littleArcs.count % 6) * 24
        let frame = NSRect(x: screen.midX - size.width / 2 + n, y: screen.maxY - size.height - 60 - n, width: size.width, height: size.height)
        let l = LittleArcController(app: self, url: url, spaceID: sid, frame: frame)
        Telemetry.shared.record(.featureUsed(.littleArcOpen(url == nil ? .shortcut : .link)))
        littleArcs.append(l)
        bringForward(l.window)
        // Chromium's dialog anchor, attached right after, would send it behind the browser window.
        l.staysInFrontOfTheEngine()
        return l
    }

    func littleArcClosed(_ l: LittleArcController) { littleArcs.removeAll { $0 === l } }

    func littleArc(for window: NSWindow?) -> LittleArcController? { littleArcs.first { $0.window === window } }

    private func bringForward(_ w: NSWindow) {
        if options.isAutomated { w.orderFront(nil) } else { w.makeKeyAndOrderFront(nil); NSApp.activate() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { onboarding == nil }

    private var awaitingDownloadQuitAnswer = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if awaitingDownloadQuitAnswer { return .terminateLater }
        let library = MediaLibrary.shared
        guard let downloads = library.downloads, !downloads.engine.asksBeforeClosingWithDownloads,
              downloads.runningCount > 0, let confirm = downloads.engine.downloadsCloseConfirmation else { return .terminateNow }
        awaitingDownloadQuitAnswer = true
        confirm(downloads.runningCount) { [weak self] quit in
            self?.awaitingDownloadQuitAnswer = false
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? store?.flush()
        AppTelemetry.shared.willTerminate()
        if options.ephemeral, AppPaths.mayDeleteEphemeral(AppPaths.dataDirectory) {
            try? FileManager.default.removeItem(at: AppPaths.dataDirectory)
        }
    }
}
