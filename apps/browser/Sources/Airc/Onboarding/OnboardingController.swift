// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircImport
import AircKit
import AppKit
import Combine
import SwiftUI

/// Runs the first-run flow (spec §2.13, ON-1…5) in an `AircFloatingWindow`: welcome, Arc import with a live sidebar
/// preview, Spaces and accounts, the Keychain step for logins, theme, default browser, and the member card, then grows
/// into the first browser window. Re-runnable from Settings (ON-3).
final class OnboardingController {
    enum Mode { case firstRun, rerun }

    let model: OnboardingModel
    let window: AircFloatingWindow
    let mode: Mode
    private weak var app: AppDelegate?
    private let store: SpacesStore
    private let settings: AppSettings
    /// A synthetic plan for automated runs (`--script onboarding`); never the owner's real Arc data.
    private let fixture: ImportPlan?
    private var arcDirectory: URL?
    private var plan: ImportPlan?
    private var discoveryStarted = false
    private var subscriptions: Set<AnyCancellable> = []
    private var revealTimer: Timer?
    private var signIn: SignInWindowController?
    private var finished = false
    /// Set by the snapshot scenario: the browser window's frame to expand into.
    var onFinished: ((WindowController) -> Void)?

    init(app: AppDelegate, mode: Mode, fixture: ImportPlan?) {
        self.app = app
        self.mode = mode
        self.fixture = fixture
        store = app.store
        settings = app.settings
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        model = OnboardingModel(systemDark: dark)
        model.translucency = settings.translucency
        model.memberName = Self.memberName(settings: settings)
        model.memberNumber = Self.memberNumber(deviceID: store.deviceID)
        model.loginsAvailable = app.credentialSink.acceptsCredentials
        let browser = DefaultBrowser.shared
        browser.refresh()
        model.offersDefaultBrowser = browser.canAsk && !browser.isDefault
        model.currentBrowser = browser.currentName ?? "Safari"
        let translucency = settings.translucency
        let w = onMain { AircFloatingWindow(theme: DesignTheme.default.resolved(systemIsDark: false), translucency: translucency) }
        window = w
        let host = OnboardingHost(model: model)
        onMain {
            w.setContent(host)
        }
        wire()
        onMain { w.onEscape = { [weak self] in self?.back() } }
        observe()
        if settings.values.onboardingStartedAt == nil { settings.values.onboardingStartedAt = Date() }
    }

    func present(focus: Bool) {
        updateWindowTheme(animated: false)
        let w = window
        onMain {
            if focus {
                w.present()
            } else {
                // Automated runs: on screen for rendering, but never take focus on the owner's Mac.
                w.centerOnActiveScreen()
                w.orderFront(nil)
            }
        }
    }

    /// Starts at the import step (Settings → Import → "Import from Arc…").
    func startAtImport() {
        startedAtImport = true
        go(.arc)
    }

    private var startedAtImport = false

    /// A re-run (ON-3) can be left: Esc on its first step closes it. The first run only closes by finishing (ON-5).
    private func cancel() {
        guard mode == .rerun, !finished else { return }
        finished = true
        revealTimer?.invalidate()
        let w = window
        onMain {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = AircCurve.toastOut.duration * 2
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }
        app?.onboardingDidCancel(self)
    }

    // MARK: Wiring

    private func wire() {
        model.onNext = { [weak self] in self?.next() }
        model.onBack = { [weak self] in self?.back() }
        model.onImportEverything = { [weak self] in
            guard let self, let b = self.model.blueprint else { return }
            self.model.chosenSpaces = Set(b.spaces.map(\.sourceID))
            self.model.choosing = false
            self.runImport()
            self.go(.accounts)
        }
        model.onImportChosen = { [weak self] in
            self?.runImport()
            self?.go(.accounts)
        }
        model.onStartFresh = { [weak self] in
            guard let self else { return }
            self.model.startedFresh = true
            self.model.choosing = false
            self.model.focusedSpace = 0
            self.go(.theme)
        }
        model.onBackUpArc = { [weak self] in self?.backUpArc() }
        model.onLocateArc = { [weak self] in self?.locateArc() }
        model.onSignIn = { [weak self] source in self?.signIn(profileSource: source) }
        model.onImportLogins = { [weak self] in self?.importLogins() }
        model.onSkipLogins = { [weak self] in
            self?.model.logins = .skipped
            self?.go(.theme)
        }
        model.onThemeChange = { [weak self] in self?.updateWindowTheme(animated: true) }
        model.onMakeDefault = { [weak self] in self?.makeDefault() }
        model.onDefaultNotNow = { [weak self] in
            self?.answerDefaultBrowser(.notNow)
            self?.go(.done)
        }
        model.onOpen = { [weak self] in self?.finish() }
        model.onShareCard = { [weak self] in self?.shareCard() }
    }

    private func observe() {
        model.$focusedSpace.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateWindowTheme(animated: true) }
        }.store(in: &subscriptions)
        model.$translucency.removeDuplicates().dropFirst().sink { [weak self] t in
            self?.settings.translucency = t
            if let w = self?.window { onMain { w.background.translucency = t } }
            self?.app?.controller?.applyTranslucency(t)
        }.store(in: &subscriptions)
    }

    /// The window's theme for the current step: the bloom's light default on welcome, otherwise the Space in the
    /// preview (so the window re-tints live), and the first Space on the card, which is what it expands into.
    var windowTheme: ResolvedTheme {
        switch model.step {
        case .welcome: DesignTheme.default.resolved(systemIsDark: false)
        case .done: model.resolved(model.previewSpaces[0])
        default: model.focusedTheme
        }
    }

    private func updateWindowTheme(animated: Bool) {
        let w = window, t = windowTheme
        onMain { w.setTheme(t, animated: animated) }
    }

    // MARK: Steps

    private func go(_ step: OnboardingStep) {
        AppTelemetry.onboardingStep(from: model.step, to: step, model: model, settings: settings)
        model.direction = step >= model.step ? 1 : -1
        if step == .done {
            model.focusedSpace = 0
            writeThemes()
        }
        model.step = step
        updateWindowTheme(animated: true)
        if step == .arc { discover() }
    }

    func next() {
        switch model.step {
        case .welcome: go(.arc)
        case .arc: model.hasArc ? model.onImportEverything?() : model.onStartFresh?()
        case .accounts: go(model.includeLogins && model.hasArc ? .logins : .theme)
        case .logins: go(.theme)
        case .theme: go(afterTheme)
        case .defaultBrowser: go(.done)
        case .done: finish()
        }
    }

    /// Esc and "Back" (ON-5).
    func back() {
        guard !finished else { return }
        switch model.step {
        case .welcome: cancel()
        case .arc:
            if model.choosing { model.choosing = false } else if startedAtImport { cancel() } else { go(.welcome) }
        case .accounts: go(.arc)
        case .logins: go(.accounts)
        case .theme:
            if model.startedFresh {
                model.startedFresh = false
                go(.arc)
            } else {
                go(model.includeLogins && model.hasArc && model.logins != .skipped ? .logins : .accounts)
            }
        case .defaultBrowser: go(.theme)
        case .done: go(model.offersDefaultBrowser && !DefaultBrowser.shared.isDefault ? .defaultBrowser : .theme)
        }
    }

    // MARK: Default browser (step 5)

    /// Default browser while Airc isn't the default; skipped (and noted) when it is. Never in automated runs on the
    /// real system.
    private var afterTheme: OnboardingStep {
        let browser = DefaultBrowser.shared
        guard browser.canAsk else { return .done }
        browser.refresh()
        if browser.isDefault {
            if settings.values.defaultBrowser.answer == nil { answerDefaultBrowser(.alreadyDefault) }
            return .done
        }
        return model.offersDefaultBrowser ? .defaultBrowser : .done
    }

    private func answerDefaultBrowser(_ answer: DefaultBrowserState.Answer) {
        settings.values.defaultBrowser.answer = answer
    }

    /// The macOS confirmation, then on to the card whatever the answer. "Not now" stays possible while it's up.
    private func makeDefault() {
        guard !model.askingDefault else { return }
        model.askingDefault = true
        DefaultBrowser.shared.makeDefault { [weak self] ok in
            guard let self else { return }
            self.model.askingDefault = false
            if ok {
                self.answerDefaultBrowser(.madeDefault)
            } else if self.settings.values.defaultBrowser.answer != .notNow {
                self.answerDefaultBrowser(.declined)
            }
            if self.model.step == .defaultBrowser { self.go(.done) }
        }
    }

    // MARK: Finding Arc

    private func discover() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        if let fixture {
            model.arcLabel = "Arc 1.171"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.received(fixture) }
            return
        }
        if LaunchOptions.current.isAutomated {
            model.arc = .notFound("Automated runs never read Arc's data.")
            return
        }
        do {
            arcDirectory = try ArcImporter.locateData()
        } catch {
            model.arc = .notFound(Self.message(for: error))
            return
        }
        model.arcLabel = Self.arcVersion().map { "Arc \($0)" } ?? "Arc"
        load(from: arcDirectory!)
    }

    private func load(from directory: URL) {
        model.arc = .searching
        Task { @MainActor [weak self] in
            do {
                let plan = try await ArcImporter.plan(at: directory)
                self?.arcDirectory = directory
                self?.received(plan)
            } catch {
                self?.model.arc = .notFound(Self.message(for: error))
            }
        }
    }

    private func received(_ plan: ImportPlan) {
        self.plan = plan
        let b = ImportAdapter.blueprint(from: plan)
        guard !b.spaces.isEmpty else {
            model.arc = .notFound("Arc is here, but its sidebar has no Spaces to bring over.")
            return
        }
        model.blueprint = b
        model.chosenSpaces = Set(b.spaces.map(\.sourceID))
        model.importNote = ImportAdapter.note(for: plan.warnings)
        model.arc = .found(version: nil)
        model.revealedSpaces = 0
        model.revealedFavorites = 0
        reveal()
    }

    /// The live rebuild: Spaces slide into the Space bar one by one, the window taking each one's colour as it
    /// arrives, then the first Space's Favorites fill in. A rare path, so it may perform (design principle 8).
    private func reveal() {
        revealTimer?.invalidate()
        let n = model.previewSpaces.count
        let favs = model.favorites(of: model.previewSpaces[0]).count
        if onMain({ AircMotion.prefersReducedMotion }) {
            model.revealedSpaces = n
            model.revealedFavorites = favs
            model.focusedSpace = 0
            return
        }
        var tick = 0
        revealTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            tick += 1
            if tick <= n {
                self.model.revealedSpaces = tick
                self.model.focusedSpace = tick - 1
            } else if tick == n + 1 {
                self.model.focusedSpace = 0
            } else if self.model.revealedFavorites < favs {
                self.model.revealedFavorites += 1
            } else {
                t.invalidate()
            }
        }
        RunLoop.main.add(revealTimer!, forMode: .common)
    }

    static func message(for error: Error) -> String {
        switch error as? ImportError {
        case .arcNotInstalled?: "Arc isn't on this Mac, so you'll start with one calm, empty Space."
        case .noData?: "Arc is installed, but it has no data to bring over yet."
        case .permissionDenied?: "macOS didn't let Airc read Arc's folder. Allow it in System Settings → Privacy & Security → Files & Folders, or find the folder yourself."
        case let e?: e.errorDescription ?? "Arc's data couldn't be read."
        case nil: "Arc's data couldn't be read."
        }
    }

    static func arcVersion() -> String? {
        guard let b = Bundle(path: "/Applications/Arc.app") else { return nil }
        return b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func locateArc() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose Arc's folder: Library › Application Support › Arc"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.load(from: url)
        }
    }

    // MARK: Import (ON-1: in the background, with the pill)

    private func runImport() {
        guard let b = model.blueprint, !model.isImporting else { return }
        let options = ImportOptions(spaces: model.chosenSpaces, includeToday: true, includeFavorites: model.includeFavorites)
        model.importState = .running("Importing Spaces", 0.15)
        let result: ImportResult
        do {
            result = try store.applyImport(b, options: options)
        } catch {
            model.importState = .idle
            model.importNote = "The import stopped: \(error.localizedDescription)"
            Telemetry.shared.record(.importArc(.init(result: .failed, spaces: 0, tabs: 0, profiles: 0, logins: false)))
            return
        }
        model.result = result
        // Profiles: load each new one's engine profile (a real Chromium profile with the Chromium engine).
        let created = result.profilesCreated
        var loaded = 0
        let favicons = Self.faviconURLs(store: store, spaces: Array(result.spaceIDs.values))
        func icons() {
            guard !favicons.isEmpty else { return done() }
            var fetched = 0
            for u in favicons {
                FaviconCache.shared.load(u) { [weak self] _ in
                    fetched += 1
                    self?.model.importState = .running("Fetching icons", 0.55 + 0.45 * Double(fetched) / Double(favicons.count))
                    if fetched == favicons.count { done() }
                }
            }
        }
        func done() {
            model.importState = .running("Imported", 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.model.importState = .done }
        }
        if created.isEmpty {
            model.importState = .running("Fetching icons", 0.55)
            icons()
        } else {
            model.importState = .running("Preparing profiles", 0.3)
            for id in created {
                app?.profiles.whenLoaded(id) { [weak self] _ in
                    loaded += 1
                    self?.model.importState = .running("Preparing profiles", 0.3 + 0.25 * Double(loaded) / Double(created.count))
                    if loaded == created.count { icons() }
                }
            }
        }
    }

    /// Favicons of everything imported, fetched now so the first window has them.
    static func faviconURLs(store: SpacesStore, spaces: [String]) -> [String] {
        var pages: [String] = []
        for sid in spaces {
            pages += store.pinnedRows(ofSpace: sid).compactMap { $0.item?.savedURL }
            pages += store.todayTabs(ofSpace: sid).map(\.url)
            pages += store.favorites(ofProfile: store.profile(ofSpace: sid).id).compactMap(\.savedURL)
        }
        var seen = Set<String>()
        return pages.compactMap(FaviconCache.guess(for:)).filter { seen.insert($0).inserted }
    }

    // MARK: Accounts

    private func signIn(profileSource: String) {
        guard let app, let pid = model.result?.profileIDs[profileSource] ?? (model.startedFresh ? store.defaultProfile.id : nil),
              let profile = store.profile(pid) else { return }
        model.signingIn = profileSource
        app.profiles.whenLoaded(pid) { [weak self] engineProfile in
            guard let self else { return }
            let s = SignInWindowController(engine: app.engine, profile: engineProfile, profileName: profile.name)
            self.signIn = s
            s.onFinish = { [weak self] email in
                guard let self else { return }
                self.model.signingIn = nil
                self.signIn = nil
                if let email {
                    self.model.accounts[profileSource] = email
                    try? self.store.updateProfile(pid) { $0.googleAccount = email }
                }
            }
            s.show(over: self.window)
        }
    }

    // MARK: Logins (IM-2): only on the explicit "Import logins" press

    private func importLogins() {
        guard let app, app.credentialSink.acceptsCredentials else {
            model.logins = .failed(CredentialImport.Unsupported().errorDescription!)
            return
        }
        guard !LaunchOptions.current.isAutomated else {
            model.logins = .failed("Automated runs never read Arc's logins.")
            return
        }
        guard let dir = arcDirectory, let result = model.result, let b = model.blueprint else {
            model.logins = .failed("Import your Spaces first; logins follow their profiles.")
            return
        }
        let map: [(directory: String, profileID: String)] = b.profiles.compactMap { p in
            guard let id = result.profileIDs[p.sourceID], p.sourceID.hasPrefix("arc-profile:") else { return nil }
            return (String(p.sourceID.dropFirst("arc-profile:".count)), id)
        }
        model.logins = .reading(0)
        CredentialImport.run(arcDirectory: dir, profiles: map, sink: app.credentialSink, progress: { [weak self] p in
            self?.model.logins = .reading(p)
        }, completion: { [weak self] r in
            switch r {
            case .success(let o): self?.model.logins = .done(o)
            case .failure(let e):
                let declined = (e as? ImportError) == .keychainDeclined
                self?.model.logins = .failed(declined
                    ? "macOS didn't unlock Arc's logins. You can bring them over later from Settings → Import."
                    : (e as? LocalizedError)?.errorDescription ?? "Arc's logins couldn't be read.")
            }
        })
    }

    // MARK: Back up Arc (IM-5)

    private func backUpArc() {
        guard !LaunchOptions.current.isAutomated, let dir = arcDirectory else { return }
        ArcBackup.run(arcDirectory: dir) { url in
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    // MARK: Finish

    /// Writes the theme step's choices into the store.
    private func writeThemes() {
        for (source, theme) in model.themes {
            let id = source == OnboardingModel.freshSpace.sourceID ? store.orderedSpaces.first?.id : model.result?.spaceIDs[source]
            if let id { try? store.updateSpace(id) { $0.theme = theme } }
        }
    }

    private func finish() {
        guard !finished, let app else { return }
        finished = true
        revealTimer?.invalidate()
        writeThemes()
        if let first = model.result?.spaceIDs[model.previewSpaces[0].sourceID] { store.selectSpace(first) }
        if settings.values.memberName == nil, !model.memberName.isEmpty, !LaunchOptions.current.isAutomated {
            settings.values.memberName = model.memberName
        }
        settings.values.onboardingCompletedAt = Date()
        AppTelemetry.onboardingFinished(model: model)
        try? store.flush()
        app.onboardingDidFinish(self)
    }

    private func shareCard() {
        let card = MemberCard(model: model, tilt: false).padding(30)
        let image: NSImage? = onMain {
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            return renderer.nsImage
        }
        guard let image, let content = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        let anchor = NSRect(x: content.bounds.midX - 90, y: 80, width: 120, height: 40)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
    }

    // MARK: Member card

    static func memberName(settings: AppSettings) -> String {
        if LaunchOptions.current.isAutomated { return "Alex" }
        if let n = settings.values.memberName { return n }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    /// A stable number per install, 1…999 999.
    static func memberNumber(deviceID: String) -> Int {
        if LaunchOptions.current.isAutomated { return 1 }
        return Int(FaviconCache.stableName(deviceID).unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % 999_999) + 1
    }
}

/// Re-reads the theme from the model so the SwiftUI environment follows the window.
private struct OnboardingHost: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        OnboardingRoot(model: model).aircTheme(theme, followsWindowActiveState: false)
    }

    private var theme: ResolvedTheme {
        switch model.step {
        case .welcome: DesignTheme.default.resolved(systemIsDark: false)
        case .done: model.resolved(model.previewSpaces[0])
        default: model.focusedTheme
        }
    }
}

/// "Back up my Arc data" (IM-5): zips Arc's sidebar, profile list and other small JSON files into Documents.
enum ArcBackup {
    static func run(arcDirectory: URL, completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let name = "Arc Backup \(f.string(from: Date()))"
            let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
            try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(at: arcDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" } ?? []
            for file in files { try? fm.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent)) }
            let localState = arcDirectory.appendingPathComponent("User Data/Local State")
            if fm.fileExists(atPath: localState.path) { try? fm.copyItem(at: localState, to: staging.appendingPathComponent("Local State")) }
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let out = docs.appendingPathComponent(name + ".zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", staging.path, out.path]
            // L2: terminationStatus raises if the process never started.
            var ok = false
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
            } catch {}
            try? fm.removeItem(at: staging.deletingLastPathComponent())
            DispatchQueue.main.async { completion(ok ? out : nil) }
        }
    }
}
