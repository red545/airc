// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircDesign
import AircImport
import AircKit
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
    /// Reads each profile's Google accounts from its own cookies (the accounts step).
    private var accountProbe: GoogleAccountProbe?
    private var quitMonitor: Any?
    private var quitHintTimer: Timer?
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
        model.importApp = app
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
        model.closable = mode == .rerun
        wire()
        let closable = mode == .rerun
        onMain {
            w.onEscape = { [weak self] in self?.back() }
            // ⌘W: a re-run closes (ON-3); the first run only closes by finishing (ON-5), so it does nothing there.
            w.onClose = closable ? { [weak self] in self?.requestClose() } : nil
            w.keyEquivalentHandler = Self.swallowsBrowserCommands
        }
        installQuitHint()
        observe()
        if settings.values.onboardingStartedAt == nil { settings.values.onboardingStartedAt = Date() }
    }

    deinit {
        if let quitMonitor { NSEvent.removeMonitor(quitMonitor) }
        quitHintTimer?.invalidate()
        accountProbe?.cancel()
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

    /// Starts at the import step (Airc → Import from Another Browser…, Settings → Import).
    func startAtImport() {
        startedAtImport = true
        go(.arc)
    }

    private var startedAtImport = false

    /// A re-run (ON-3) can be left from every step: its ✕, ⌘W, and Esc on its first step. While the logins are being
    /// written into the profiles it can't (the ✕ is disabled and says why); everything else is safe to leave at any
    /// point, because the Spaces are written in one step and what follows (profiles, icons) finishes by itself. The
    /// first run only closes by finishing (ON-5); ⌘Q quits either way.
    func requestClose() {
        guard model.closable, !finished else { return }
        guard model.closeBlockedReason == nil else { return NSSound.beep() }
        cancel()
    }

    private func cancel() {
        guard mode == .rerun, !finished else { return }
        finished = true
        revealTimer?.invalidate()
        signIn?.close()
        signIn = nil
        accountProbe?.cancel()
        removeQuitHint()
        let w = window
        onMain {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = AircCurve.toastOut.duration * 2
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
            // Don't rely on the fade's callback (it never comes while the display sleeps).
            DispatchQueue.main.asyncAfter(deadline: .now() + AircCurve.toastOut.duration * 2 + 0.05) { w.orderOut(nil) }
        }
        app?.onboardingDidCancel(self)
    }

    /// While the onboarding window is key, the browser's own shortcuts (⌘T, ⌘L, ⌘D…) would act on the browser window
    /// behind it through the menu; they do nothing here. ⌘W is the window's own (AircFloatingWindow), ⌘Q, ⌘H and ⌘,
    /// keep working.
    static func swallowsBrowserCommands(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.isEmpty, let key = e.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return false }
        if mods == .command, ["w", "q", "h", ","].contains(key) { return false }
        return CommandMenus.all.contains { !$0.key.isEmpty && $0.key.lowercased() == key && $0.modifiers == mods }
    }

    // MARK: ⌘Q (hold to quit, as everywhere in Airc)

    /// A ⌘Q tap in the onboarding window shows "Hold ⌘Q to Quit" there (the browser window that shows it elsewhere may
    /// not exist yet). The app's key monitor takes ⌘Q's key-down (and quits once it's held); a tap's key-up still comes
    /// by, so the hint shows as the key comes up: through an event monitor with AppKit's own application class, and at
    /// the window with Chromium's, which hands ⌘ key-ups straight to the key window. Only looks: never quits or
    /// swallows anything.
    private func installQuitHint() {
        func isQuitTap(_ e: NSEvent) -> Bool {
            e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers?.lowercased() == "q"
        }
        let w = window
        quitMonitor = onMain {
            w.onKeyUp = { [weak self] e in if isQuitTap(e) { self?.showQuitHint() } }
            return NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, event.window === self.window, isQuitTap(event) else { return event }
                self.showQuitHint()
                return event
            }
        }
    }

    func showQuitHint() {
        model.showsQuitHint = true
        quitHintTimer?.invalidate()
        quitHintTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in self?.model.showsQuitHint = false }
    }

    private func removeQuitHint() {
        if let quitMonitor { NSEvent.removeMonitor(quitMonitor) }
        quitMonitor = nil
        quitHintTimer?.invalidate()
    }

    // MARK: Wiring

    private func wire() {
        model.onNext = { [weak self] in self?.next() }
        model.onBack = { [weak self] in self?.back() }
        model.onImportEverything = { [weak self] in
            guard let self, let b = self.model.blueprint else { return }
            // Arc's "Import everything"; another browser's import takes the profiles ticked on the step.
            if self.model.isArcSource { self.model.chosenSpaces = Set(b.spaces.map(\.sourceID)) }
            guard !self.model.chosenSpaces.isEmpty else { return }
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
        model.onSwitchAccount = { [weak self] source in self?.signIn(profileSource: source, switching: true) }
        model.onClose = { [weak self] in self?.requestClose() }
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
        model.onSelectSource = { [weak self] source in self?.select(source, picked: true) }
        model.onChooseBookmarksFile = { [weak self] in self?.chooseBookmarksFile() }
        model.onChoosePasswordsFile = { [weak self] in self?.choosePasswordsFile() }
        model.onDiscardPasswordsFile = { [weak self] in self?.discardPasswordsFile() }
        model.onPasswordsDone = { [weak self] in
            guard let self else { return }
            if self.model.step == .logins { return self.go(.theme) }
            if self.startedAtImport && self.mode == .rerun { return self.requestClose() }
            self.model.onStartFresh?()
        }
    }

    private func observe() {
        model.$focusedSpace.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateWindowTheme(animated: true) }
        }.store(in: &subscriptions)
        // "Choose…": the re-import line counts the chosen Spaces (the publisher sends the new set before it's stored).
        model.$chosenSpaces.dropFirst().sink { [weak self] chosen in
            guard let self, let b = self.model.blueprint else { return }
            self.model.reimport = self.reimportSummary(b, chosen: chosen)
        }.store(in: &subscriptions)
        // Leaving while the logins are written into the profiles would cut that off half way.
        model.$logins.combineLatest(model.$passwords).sink { [weak self] logins, passwords in
            if case .reading = logins {
                self?.model.closeBlockedReason = "Airc is bringing over your logins. You can close this once they're in."
            } else if passwords == .reading {
                self?.model.closeBlockedReason = "Airc is bringing over your passwords. You can close this once they're in."
            } else {
                self?.model.closeBlockedReason = nil
            }
        }.store(in: &subscriptions)
        model.$translucency.removeDuplicates().dropFirst().sink { [weak self] t in
            self?.settings.translucency = t
            if let w = self?.window { onMain { w.background.translucency = t } }
            self?.app?.controllers.forEach { $0.applyTranslucency(t) }
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
        if step == .accounts { refreshAccounts() }
    }

    func next() {
        switch model.step {
        case .welcome: go(.arc)
        case .arc:
            if model.hasPlan { model.onImportEverything?() }
            else if model.source == .passwords, case .done = model.passwords { model.onPasswordsDone?() }
            else if model.source == .bookmarksFile || model.source == .passwords { return }
            else { model.onStartFresh?() }
        case .accounts: go(model.offersLoginsStep ? .logins : .theme)
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
        case .welcome: requestClose()
        case .arc:
            if model.choosing { model.choosing = false } else if startedAtImport { requestClose() } else { go(.welcome) }
        case .accounts: go(.arc)
        case .logins: go(.accounts)
        case .theme:
            if model.startedFresh {
                model.startedFresh = false
                go(.arc)
            } else {
                go(model.offersLoginsStep && model.logins != .skipped ? .logins : .accounts)
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
        // Other browsers (IM-4), next to Arc: only their profile lists are read now; a browser's bookmarks and history
        // when it's picked.
        Task { @MainActor [weak self] in
            let installs = await BrowserImportLocator.detect()
            self?.received(installs)
        }
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated, let directory = Self.testArcDirectory {
            load(from: directory)
            return
        }
        #endif
        if let fixture {
            model.arcLabel = "Arc 1.171"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.received(fixture) }
            return
        }
        if LaunchOptions.current.isAutomated {
            arcMissing("Automated runs never read Arc's data.")
            return
        }
        do {
            arcDirectory = try ArcImporter.locateData()
        } catch {
            arcMissing(Self.message(for: error))
            return
        }
        model.arcLabel = Self.arcVersion().map { "Arc \($0)" } ?? "Arc"
        load(from: arcDirectory!)
    }

    #if AIRC_TESTING
    static var testArcDirectory: URL?
    #endif
    private func load(from directory: URL) {
        model.arc = .searching
        Task { @MainActor [weak self] in
            do {
                let model = self?.model
                let plan = try await ArcImporter.plan(at: directory) { progress in
                    Task { @MainActor in
                        model?.arcReadProgress = progress.stage == .history ? "Reading Arc’s history" : progress.stage == .extensions ? "Reading extension lists" : "Reading Arc’s sidebar"
                    }
                }
                self?.arcDirectory = directory
                self?.received(plan)
            } catch {
                self?.arcMissing(Self.message(for: error))
            }
        }
    }

    private func received(_ plan: ImportPlan) {
        self.plan = plan
        let b = ImportAdapter.blueprint(from: plan)
        guard !b.spaces.isEmpty else {
            arcMissing("Arc is here, but its sidebar has no Spaces to bring over.")
            return
        }
        model.arcBlueprint = b
        model.arc = .found(version: nil)
        // Counts only: never a name, title or address.
        NSLog("[onboarding] plan: %ld Spaces, %ld profiles in Arc's list, %ld profile rows, %ld warnings, %ld already in Airc",
              b.spaces.count, plan.profiles.count, OnboardingModel.rows(b, spaces: b.spaces).count, plan.warnings.count,
              reimportSummary(b, chosen: Set(b.spaces.map(\.sourceID)))?.updated ?? 0)
        rebuildSources()
        // Arc comes first, unless the person already picked something else.
        if !model.pickedSource || model.source == .arc { select(.arc, picked: false) }
    }

    /// Arc isn't here (or can't be read): another browser takes the step, if one was found.
    private func arcMissing(_ why: String) {
        model.arc = .notFound(why)
        model.arcBlueprint = nil
        rebuildSources()
        if model.source == .arc || model.source == nil { select(firstBrowser, picked: false) }
    }

    private var firstBrowser: OnboardingModel.ImportSource? {
        model.sources.first { if case .browser = $0.source { true } else { false } }?.source
    }

    private func received(_ installs: [BrowserInstall]) {
        model.installs = Dictionary(installs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        browserOrder = installs.map(\.id)
        NSLog("[import] %ld other browsers with %ld profiles", installs.count, installs.reduce(0) { $0 + $1.profiles.count })
        rebuildSources()
        // Without Arc, the first browser found.
        if model.source == nil, case .notFound = model.arc { select(firstBrowser, picked: false) }
    }

    private var browserOrder: [String] = []

    /// Arc (once found), every other browser found, then a bookmarks file and a passwords file.
    private func rebuildSources() {
        var items: [OnboardingModel.SourceItem] = []
        if model.hasArc { items.append(.init(source: .arc, name: "Arc", kind: nil)) }
        for id in browserOrder {
            guard let i = model.installs[id] else { continue }
            items.append(.init(source: .browser(id), name: i.name, kind: i.kind, bundleIDs: i.bundleIDs))
        }
        items.append(.init(source: .bookmarksFile, name: "Safari", kind: .safari, bundleIDs: ["com.apple.Safari"]))
        items.append(.init(source: .passwords, name: "Passwords", kind: nil))
        model.sources = items
    }

    /// Shows `source` on the import step: its plan in the preview, its profiles to tick, or the file to choose.
    func select(_ source: OnboardingModel.ImportSource?, picked: Bool) {
        if picked { model.pickedSource = true }
        model.source = source
        model.choosing = false
        model.sourceNote = nil
        if case .browser(let id)? = source, model.browserReads[id] == nil { readBrowser(id) }
        if source == .passwords, model.passwordsProfile == nil { model.passwordsProfile = defaultPasswordsProfile }
        model.aircProfiles = store.orderedProfiles.map { ($0.id, $0.name) }
        showSource()
    }

    /// The shown source's blueprint, its choices and what it changes, and the preview's rebuild.
    private func showSource() {
        let b: ImportBlueprint?
        switch model.source {
        case .arc?:
            b = model.arcBlueprint
            model.importChanges = ImportAdapter.changes(for: plan?.warnings ?? [])
        case .browser?, .bookmarksFile?:
            b = model.selectedRead.map(BrowserImportAdapter.blueprint)
            model.importChanges = BrowserImportAdapter.changes(for: model.selectedRead?.plan.warnings ?? [])
        default:
            b = nil
            model.importChanges = []
        }
        model.blueprint = b
        model.chosenSpaces = Set(b?.spaces.map(\.sourceID) ?? [])
        model.importNote = nil
        model.reimport = b.flatMap { reimportSummary($0, chosen: model.chosenSpaces) }
        model.revealedSpaces = 0
        model.revealedFavorites = 0
        model.focusedSpace = 0
        if b != nil { reveal() } else { revealTimer?.invalidate() }
        updateWindowTheme(animated: true)
    }

    /// Reads a browser's bookmarks and history (every profile) off the main thread, once.
    private func readBrowser(_ id: String) {
        guard let install = model.installs[id], !reading.contains(id) else { return }
        reading.insert(id)
        model.readingSource = true
        Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            do {
                let r = try await BrowserImporter.read(install)
                self?.model.browserReads[id] = r
                // Counts only: never a profile's name, a title or an address.
                NSLog("[import] %@: %ld profiles, %ld bookmarks, %ld folders, %ld history entries, %ld warnings in %.0f ms",
                      install.kind.rawValue, r.profiles.count, r.bookmarks, r.folders, r.historyEntries, r.plan.warnings.count,
                      (CACurrentMediaTime() - started) * 1000)
            } catch {
                if self?.model.source == .browser(id) { self?.model.sourceNote = "\(install.name)'s bookmarks couldn't be read." }
            }
            self?.reading.remove(id)
            self?.model.readingSource = self?.reading.isEmpty == false
            if self?.model.source == .browser(id) { self?.showSource() }
        }
    }

    private var reading: Set<String> = []

    #if AIRC_TESTING
    /// Automated runs never show an open panel: the check hands its synthetic files here.
    var testFiles: [String: URL] = [:]
    #endif

    /// A file the person chooses (an open panel on the window; a check's synthetic file in automated runs).
    private func chooseFile(_ key: String, message: String, types: [UTType], _ done: @escaping (URL) -> Void) {
        #if AIRC_TESTING
        if LaunchOptions.current.isAutomated {
            if let url = testFiles[key] { done(url) }
            return
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types
        panel.message = message
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            done(url)
        }
    }

    /// "Choose File…" on the Safari source: a bookmarks HTML file (Safari's File → Export → Bookmarks…, or any browser's).
    private func chooseBookmarksFile() {
        chooseFile("bookmarks", message: "Choose a bookmarks file: Safari's File → Export → Bookmarks…, or any browser's", types: [.html]) { [weak self] url in
            self?.readBookmarksFile(url)
        }
    }

    func readBookmarksFile(_ url: URL) {
        model.readingSource = true
        model.sourceNote = nil
        Task { @MainActor [weak self] in
            do {
                let r = try await BrowserImporter.readBookmarksFile(url, kind: .safari)
                self?.model.browserReads["file"] = r
                self?.model.bookmarksFileName = url.lastPathComponent
                NSLog("[import] bookmarks file: %ld bookmarks, %ld folders, %ld warnings", r.bookmarks, r.folders, r.plan.warnings.count)
            } catch {
                self?.model.sourceNote = (error as? LocalizedError)?.errorDescription ?? "That file couldn't be read."
            }
            self?.model.readingSource = false
            if self?.model.source == .bookmarksFile { self?.showSource() }
        }
    }

    // MARK: Passwords from a CSV file (IM-4)

    /// Into the profile the import step's Passwords source shows first: the current Space's.
    private var defaultPasswordsProfile: String { store.profile(ofSpace: store.selectedSpace.id).id }

    private func choosePasswordsFile() {
        guard model.loginsAvailable else { return }
        chooseFile("passwords", message: "Choose the passwords CSV file you exported", types: [.commaSeparatedText, .plainText]) { [weak self] url in
            self?.importPasswords(from: url)
        }
    }

    /// The file's rows into the chosen profile's password store, then the counts. The file itself is offered to the
    /// Trash afterwards; nothing holds its rows.
    func importPasswords(from url: URL) {
        guard let app, model.passwords != .reading else { return }
        let profileID = model.passwordsProfile ?? defaultPasswordsProfile
        model.passwords = .reading
        model.passwordsFile = url
        model.passwordsFileName = url.lastPathComponent
        model.passwordsFileDiscarded = nil
        PasswordImport.run(file: url, profileID: profileID, sink: app.credentialSink) { [weak self] r in
            switch r {
            case .success(let o):
                self?.model.passwords = .done(o)
                NSLog("[import] passwords file (%@): %ld imported, %ld duplicates, %ld incomplete, %ld not websites, %ld failed",
                      o.format.rawValue, o.imported, o.duplicates, o.incomplete, o.notWebsite, o.failed)
            case .failure(let e):
                self?.model.passwords = .failed((e as? LocalizedError)?.errorDescription ?? "The file couldn't be read.")
            }
        }
    }

    private func discardPasswordsFile() {
        guard let url = model.passwordsFile else { return }
        PasswordImport.discard(url) { [weak self] moved in
            self?.model.passwordsFileDiscarded = moved
            if moved { self?.model.passwordsFile = nil }
        }
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

    /// What importing `b` does to the Spaces Airc has now (merge by Arc ID, IM-1), or nil on an empty Airc.
    private func reimportSummary(_ b: ImportBlueprint, chosen: Set<String>) -> ReimportSummary? {
        let pristine = store.orderedSpaces.count == 1 && store.orderedSpaces[0].sourceID == nil
            && store.pinnedRoots(ofSpace: store.orderedSpaces[0].id).isEmpty && store.todayTabs(ofSpace: store.orderedSpaces[0].id).isEmpty
        guard !pristine else { return nil }
        var r = ReimportSummary(existing: store.orderedSpaces.count)
        let mine = Set(store.orderedSpaces.filter { $0.sourceID == nil }.map { $0.name.lowercased() })
        for s in b.spaces where chosen.contains(s.sourceID) {
            if store.space(sourceID: s.sourceID) != nil {
                r.updated += 1
            } else {
                r.added += 1
                if mine.contains(s.name.lowercased()) { r.sameName += 1 }
            }
        }
        return r
    }

    /// The blueprint as it goes into the store.
    ///   - Re-importing into a Space that came over before keeps its Today as the user left it: a Today tab from the
    ///     earlier import that they closed since (it's in the archive) doesn't come back.
    ///   - Today tabs start their archive clock now, most recent first, in Arc's order of use. With Arc's own times, a
    ///     move made a day after Arc was last used would send every Today tab to the archive the moment the browser
    ///     opens (Airc archives Today tabs after 12 hours by default; importux, 2026-11-06).
    static func blueprintToApply(_ b: ImportBlueprint, store: SpacesStore, now: Date = Date()) -> ImportBlueprint {
        let archived = Set(store.archivedEntries.compactMap(\.tab.sourceID))
        var b = b
        for i in b.spaces.indices {
            if store.space(sourceID: b.spaces[i].sourceID) != nil {
                b.spaces[i].today.removeAll { archived.contains($0.sourceID) }
            }
            let byUse = b.spaces[i].today.indices.sorted {
                (b.spaces[i].today[$0].lastActiveAt ?? .distantPast) > (b.spaces[i].today[$1].lastActiveAt ?? .distantPast)
            }
            for (rank, j) in byUse.enumerated() { b.spaces[i].today[j].lastActiveAt = now.addingTimeInterval(-Double(rank)) }
        }
        return b
    }

    private func runImport() {
        guard let b = model.blueprint, !model.isImporting else { return }
        let options = ImportOptions(spaces: model.chosenSpaces, includeToday: true, includeFavorites: model.includeFavorites)
        let browser = model.selectedRead
        model.importState = .running(browser == nil ? "Importing Spaces" : "Importing bookmarks", 0.15)
        let result: ImportResult
        do {
            result = try store.applyImport(Self.blueprintToApply(b, store: store), options: options)
        } catch {
            model.importState = .idle
            model.importNote = "The import stopped: \(error.localizedDescription)"
            if let browser {
                Telemetry.shared.record(.importBrowser(.init(source: BrowserImportAdapter.telemetrySource(browser), result: .failed)))
            } else {
                Telemetry.shared.record(.importArc(.init(result: .failed, spaces: 0, tabs: 0, profiles: 0, logins: false)))
            }
            return
        }
        model.result = result
        model.importedSource = model.source
        model.logins = .idle
        model.passwords = .idle
        if let browser { importHistory(browser, result: result) }
        else if let plan {
            let chosen = Set(b.spaces.filter { model.chosenSpaces.contains($0.sourceID) }.map(\.profileSourceID))
            let mapped = result.profileIDs.filter { chosen.contains($0.key) }
            model.importState = .running("Importing history and extension checklist", 0.25)
            let visits = model.includeHistory ? ImportAdapter.visits(plan, profileIDs: mapped) : []
            app?.history.importVisits(visits)
            model.historyImported = visits.count
            ArcExtensionChecklist.shared.merge(plan, profileIDs: mapped)
        }
        // Profiles: load each new one's engine profile (a real Chromium profile with the Chromium engine).
        let created = result.profilesCreated
        var loaded = 0
        // Another browser's bookmarks can be thousands of sites: the first ones' icons now, the rest as they show.
        let favicons = Array(Self.faviconURLs(store: store, spaces: Array(result.spaceIDs.values)).prefix(browser == nil ? .max : 120))
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

    /// Another browser's history, into the profiles its Spaces went into (⌘T suggestions), and the import's counts for
    /// telemetry (ranges only, never a page).
    private func importHistory(_ r: BrowserImport, result: ImportResult) {
        let chosen = Set(model.blueprint?.spaces.filter { model.chosenSpaces.contains($0.sourceID) }.map(\.profileSourceID) ?? [])
        let profiles = r.profiles.filter { chosen.contains($0.sourceKey) }
        var added = 0
        if model.includeHistory, let history = app?.history {
            let visits = BrowserImportAdapter.visits(r, profileIDs: result.profileIDs.filter { chosen.contains($0.key) })
            let merged = history.importVisits(visits)
            added = merged.added + merged.updated
            model.historyImported = visits.count
        } else {
            model.historyImported = 0
        }
        NSLog("[import] %@: %ld profiles, %ld Spaces, %ld pinned tabs, %ld folders, %ld history entries (%ld new or changed)",
              r.kind?.rawValue ?? "file", profiles.count, result.spacesCreated + result.spacesUpdated, result.pinnedTabs, result.folders,
              model.historyImported, added)
        Telemetry.shared.record(.importBrowser(.init(source: BrowserImportAdapter.telemetrySource(r), result: .success, profiles: profiles.count,
                                                     bookmarks: result.pinnedTabs, folders: result.folders, history: model.historyImported)))
        // The passwords file goes into the first of them by default.
        if let first = model.blueprint?.spaces.first(where: { model.chosenSpaces.contains($0.sourceID) }), let pid = result.profileIDs[first.profileSourceID] {
            model.passwordsProfile = pid
        }
        model.aircProfiles = store.orderedProfiles.map { ($0.id, $0.name) }
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

    /// The accounts step appeared: each profile shows whether it's signed in to Google. What Airc knew (a sign-in from
    /// an earlier session) shows at once; then the profile's own cookies say (GoogleAccountProbe). A profile the import
    /// just made has no cookies yet, so it isn't asked.
    private func refreshAccounts() {
        guard let result = model.result else { return }
        for row in model.profileRows {
            let source = row.profile.sourceID
            guard let pid = result.profileIDs[source], let profile = store.profile(pid) else { continue }
            if model.accounts[source] == nil, let email = profile.googleAccount { model.accounts[source] = GoogleAccount(email: email) }
            if !result.profilesCreated.contains(pid) { checkAccount(source: source, profileID: pid) }
        }
    }

    /// Reads `source`'s Google accounts from its profile's cookies and shows the primary one.
    func checkAccount(source: String, profileID pid: String) {
        guard let app, GoogleAccountProbe.listAccountsURL != nil, !model.checkingAccounts.contains(source) else { return }
        model.checkingAccounts.insert(source)
        app.profiles.whenLoaded(pid, { [weak self] engineProfile in
            guard let self, !self.finished else { return }
            let probe = self.accountProbe ?? GoogleAccountProbe(engine: app.engine)
            self.accountProbe = probe
            probe.read(engineProfile) { [weak self] accounts in
                guard let self else { return }
                self.model.checkingAccounts.remove(source)
                // No answer (offline, a timeout): keep what was known.
                if let accounts { self.show(accounts.first, source: source, profileID: pid) }
            }
        }, failed: { [weak self] in self?.model.checkingAccounts.remove(source) })
    }

    /// Shows `account` on the profile's row and keeps its email in the profile (Settings, the profile menu). Local only.
    private func show(_ account: GoogleAccount?, source: String, profileID pid: String) {
        model.accounts[source] = account
        model.accountPhotos[source] = nil
        if store.profile(pid)?.googleAccount != account?.email {
            try? store.updateProfile(pid) { $0.googleAccount = account?.email }
        }
        GoogleAccountPhoto.load(account?.photoURL) { [weak self] image in
            guard let self, let image, self.model.accounts[source]?.email == account?.email else { return }
            self.model.accountPhotos[source] = image
        }
    }

    private func signIn(profileSource: String, switching: Bool = false) {
        guard let app, let pid = model.result?.profileIDs[profileSource] ?? (model.startedFresh ? store.defaultProfile.id : nil),
              let profile = store.profile(pid) else { return }
        model.signingIn = profileSource
        app.profiles.whenLoaded(pid) { [weak self] engineProfile in
            guard let self, !self.finished else { return }
            let s = SignInWindowController(engine: app.engine, profile: engineProfile, profileName: profile.name, switching: switching)
            self.signIn = s
            s.onFinish = { [weak self] account in
                guard let self else { return }
                self.model.signingIn = nil
                self.signIn = nil
                if let account { self.show(account, source: profileSource, profileID: pid) }
                // However the window ended (Google's account page, a passkey offer, closed by hand), the profile's
                // cookies say who's signed in now.
                self.checkAccount(source: profileSource, profileID: pid)
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
        accountProbe?.cancel()
        removeQuitHint()
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
