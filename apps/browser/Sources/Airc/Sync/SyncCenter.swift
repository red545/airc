// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import AircKit
import AppKit
import LocalAuthentication
import CryptoKit
import IOKit

/// iCloud sync in the app (docs/sync.md): which transport this build may use, when to sync, and what Settings → Sync
/// shows. The work is SyncEngine's (AircKit): it observes the store, so every committed action is captured.
///
/// Release builds with the iCloud entitlement use CloudKit's private database and iCloud Keychain. Every other build
/// (dev builds are ad hoc signed, release builds before the provisioning profile exists) shows "available in release
/// builds" and never touches CloudKit: creating a container without the entitlement would end the app. Test builds can
/// use a mock CloudKit database in a folder (`--sync-mock`) or the encrypted folder transport (`--sync-folder`).
/// Private windows and Little Arc never reach it: they aren't in the store.
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    enum Backend: Equatable {
        case none
        case cloudKit(container: String)
        /// Test builds only.
        case mock(URL), folder(URL)
    }

    @Published private(set) var status: SyncEngine.Status = .off
    @Published private(set) var devices: [SyncEngine.Device] = []
    @Published private(set) var lastSynced: Date?
    /// The backup the first sync saved, shown under the status.
    @Published private(set) var lastBackup: URL?
    @Published private(set) var isEnabled = false
    /// Pinned notes whose text is too large to sync (Settings → Sync says so).
    @Published private(set) var notesTooLarge = 0
    /// iCloud doesn't take notes yet (their record types aren't deployed): they wait (Settings → Sync says so).
    @Published private(set) var notesHeld = false
    /// Settings › Sync › "Sync settings" (on by default while sync is on).
    @Published private(set) var syncsSettings = true
    /// Settings › Sync › "Sync Boosts" (on by default while sync is on).
    @Published private(set) var syncsBoosts = true
    /// Clean-up with deletes off (SyncGarbage.deletesEnabled, public builds): what it would have deleted, for Settings ›
    /// Sync's diagnostics. Counts and record types only.
    @Published private(set) var cleanUpDryRun: SyncGCDryRun?
    /// Settings › Sync's recovery sheet (SyncRecovery.swift): the key shown, or the field to type one. Also how the
    /// scripted check opens it.
    @Published var recoverySheet: SyncRecoverySheet?
    /// The app's settings for the engine (SettingsSync.swift).
    private(set) var settingsSync: SettingsSync?
    private(set) var backend: Backend = .none
    private(set) var engine: SyncEngine?
    /// The real-iCloud test (test builds, `--sync-cloudkit-test-zone AircSidebarTest…`): its own zone, subscription and
    /// keychain service in the app's container, which its cleanup deletes.
    private(set) var cloudTestZone: String?
    /// The live database: made only when the engine needs a transport (sync on), released when sync goes off.
    private(set) var cloudDatabase: CloudKitSyncDatabase?
    /// How many live databases (CKContainers) this launch made: checks assert none while sync is off.
    private(set) var cloudDatabasesMade = 0
    private(set) var keyStore: SyncKeyStore?
    #if AIRC_TESTING
    /// The sync log's lines this launch (scripted checks read them).
    nonisolated(unsafe) static var loggedForTests: [String] = []
    static var testSubscription: String {
        if MainActor.assumeIsolated({ ICloudTwoMacCheck.requested }),
           let zone = MainActor.assumeIsolated({ ICloudTwoMacCheck.argument("--sync-cloudkit-test-zone") }), zone.hasPrefix("AircSidebarTest") {
            return "airc-sidebar-test-changes-" + zone
        }
        return "airc-sidebar-test-changes"
    }
    #else
    static let testSubscription = "airc-sidebar-test-changes"
    #endif
    static let testKeychainService = "Airc sidebar sync test"
    private weak var app: AppDelegate?
    private var timer: Timer?
    private var observers: [Any] = []
    /// Boost changes → the engine (lives as long as the engine; not one of the sync-on triggers).
    private var boostObserver: Any?
    private var lastActivationSync = Date.distantPast
    private var registeredForPushes = false
    private var triggers = SyncTriggers.plan(cloudKit: false, pushEntitlement: false)

    var isAvailable: Bool { engine != nil }
    /// Timer, observers or push registration installed: only while sync is on.
    var isScheduling: Bool { timer != nil || !observers.isEmpty || registeredForPushes }
    var hasTransport: Bool { engine.map { e in MainActor.assumeIsolated { e.hasTransport } } ?? false }
    var firstSync: SyncFirstSync? { if case .choosing(let f) = status { f } else { nil } }

    /// Once the store and profiles are up (AppDelegate.didOpen).
    func start(app: AppDelegate) {
        guard self.app == nil else { return }
        self.app = app
        #if AIRC_TESTING
        let twoMac = MainActor.assumeIsolated { ICloudTwoMacCheck.enabled }
        if MainActor.assumeIsolated({ ICloudTwoMacCheck.requested }) && !twoMac {
            status = .unavailable("Invalid isolated sync test configuration")
            return
        }
        #endif
        let keys: SyncKeyStore
        let transport: (UUID) -> SyncGroupTransport
        var deviceName = Host.current().localizedName ?? "Mac"
        if let test = testBackend() {
            backend = test.0
            keys = test.1
            transport = test.2
            deviceName = test.3
        } else if let container = SyncCapability.container, !app.options.isScripted || testZone() != nil {
            // Only the entitlement is read here; the CloudKit container is made when sync is on (the transport).
            let zone = testZone()
            backend = .cloudKit(container: container)
            cloudTestZone = zone
            #if AIRC_TESTING
            if twoMac {
                keys = ICloudTwoMacKeys(accessGroup: SyncCapability.keychainAccessGroup,
                    service: MainActor.assumeIsolated { ICloudTwoMacCheck.service }, root: MainActor.assumeIsolated { ICloudTwoMacCheck.root })
            } else {
                keys = zone == nil ? KeychainSyncKeyStore(accessGroup: SyncCapability.keychainAccessGroup)
                    : KeychainSyncKeyStore(accessGroup: SyncCapability.keychainAccessGroup, service: Self.testKeychainService,
                                           synchronizable: false, accessibility: .afterFirstUnlockThisDeviceOnly)
            }
            #else
            keys = zone == nil ? KeychainSyncKeyStore(accessGroup: SyncCapability.keychainAccessGroup)
                : KeychainSyncKeyStore(accessGroup: SyncCapability.keychainAccessGroup, service: Self.testKeychainService, synchronizable: false,
                                       accessibility: .afterFirstUnlockThisDeviceOnly)
            #endif
            transport = { [weak self] device in
                let database = CloudKitSyncDatabase(container: container)
                self?.cloudDatabase = database
                self?.cloudDatabasesMade += 1
                #if AIRC_TESTING
                if twoMac {
                    let wrapped = ICloudTwoMacDatabase(database, root: MainActor.assumeIsolated { ICloudTwoMacCheck.root })
                    return CloudKitSyncTransport(database: wrapped, device: device, zone: zone!, subscription: Self.testSubscription)
                }
                #endif
                return CloudKitSyncTransport(database: database, device: device, zone: zone ?? SyncCloudSchema.zone,
                                             subscription: zone == nil ? SyncCloudSchema.subscription : Self.testSubscription)
            }
            if zone != nil, let name = ProcessInfo.processInfo.environment["AIRC_SYNC_DEVICE_NAME"] { deviceName = name }
        } else {
            status = .unavailable(SyncEngine.notSetUp)
            return
        }
        keyStore = keys
        let store = app.store!
        var environment = SyncEngine.Environment(
            transport: transport, keys: keys,
            stateURL: AppPaths.dataDirectory.appendingPathComponent("Sync", isDirectory: true).appendingPathComponent("sync-state.json"),
            deviceName: deviceName, machine: Self.machine,
            createProfile: { [weak app] name, emoji in
                guard let app else { throw StoreError.notFound }
                return try app.profiles.createProfile(name: name, emoji: emoji, color: nil).id
            },
            applyProfileChange: { [weak app] space, profile in
                // As Settings → Spaces does, without its confirmation: the change was made on another Mac.
                guard let app, let reload = try? app.store.setProfile(ofSpace: space, to: profile) else { return }
                for c in app.controllers {
                    c.reloadPagesInNewProfile(reload.filter { c.store.tab($0) != nil })
                    if c.currentSpaceID == space, let p = app.profiles.engineProfile(for: profile) { c.engineWindow.activeProfile = p }
                }
            },
            backup: { [weak app] in
                // As every other backup (SET-3): a chosen folder that's gone or read-only falls back to the default one.
                // If neither can be written, choose() throws and the first sync doesn't start.
                guard let app, let url = try app.settings.backUp(store, purpose: .beforeICloud) else { throw StoreError.notFound }
                return url
            })
        // Notes' pictures: the data folder's Notes/Images (NoteImages). One that arrives shows in the open notes at once.
        environment.notePictures = SyncNotePictureFolder(folder: NoteImages.folder)
        environment.picturesArrived = { _ in NoteCenter.shared.picturesArrived() }
        // Settings (docs/sync.md, "Settings"): only the allowlisted ones a person changed.
        let settingsSync = SettingsSync(app: app)
        self.settingsSync = settingsSync
        environment.settings = settingsSync.source
        // Boosts (docs/sync.md, "Boosts"): style as it is; code from another Mac waits until it's allowed here.
        environment.boosts = SyncBoostsSource(current: { thisMac in
            BoostCenter.shared.map { SyncBoosts.payloads($0.store, thisMac: thisMac) } ?? [:]
        }, apply: { incoming in BoostCenter.shared?.applySynced(incoming) ?? [] })
        #if AIRC_TESTING
        // Scripted clean-up checks (ICloudSyncGCCheck.swift): `--sync-gc-settle SECONDS` instead of a day.
        let argv = ProcessInfo.processInfo.arguments
        if let i = argv.firstIndex(of: "--sync-gc-settle"), i + 1 < argv.count, let seconds = Double(argv[i + 1]), seconds >= 0 {
            environment.gcSettle = seconds
        }
        // `--sync-gc-dry-run`: clean-up as public builds run it (deletes off), for icloudsync-gc's dry-run variant.
        if argv.contains("--sync-gc-dry-run") { environment.gcDeletes = false }
        let systemLog = environment.log
        environment.log = { line in systemLog(line); SyncCenter.loggedForTests.append(line) }
        #endif
        let engine = MainActor.assumeIsolated { SyncEngine(store: store, environment: environment) }
        self.engine = engine
        #if AIRC_TESTING
        if twoMac && CommandLine.arguments.contains("--sync-test-cleanup") {
            MainActor.assumeIsolated { engine.setEnabled(false) }
        }
        #endif
        let cloudKit: Bool = if case .cloudKit = backend { true } else { false }
        triggers = SyncTriggers.plan(cloudKit: cloudKit, pushEntitlement: SyncCapability.receivesPushes)
        let triggers = triggers
        MainActor.assumeIsolated { engine.debounce = triggers.localChangeDelay }
        MainActor.assumeIsolated { engine.onChange = { [weak self] in self?.refresh() } }
        settingsSync.changed = { [weak engine] in if let engine { MainActor.assumeIsolated { engine.settingsChanged() } } }
        boostObserver = NotificationCenter.default.addObserver(forName: BoostCenter.didChange, object: nil, queue: .main) { [weak engine] note in
            guard note.userInfo?["domain"] != nil, let engine else { return }
            MainActor.assumeIsolated { engine.boostsChanged() }
        }
        refresh()
        if isEnabled { syncSoon() }
        #if AIRC_TESTING
        if twoMac { MainActor.assumeIsolated { ICloudTwoMacCheck.start(app: app) } }
        #endif
    }

    /// The Settings switch.
    func setEnabled(_ on: Bool) {
        guard let engine else { return }
        MainActor.assumeIsolated { engine.setEnabled(on) }
        refresh()
    }

    /// Settings › Sync › "Sync Boosts".
    func setSyncsBoosts(_ on: Bool) {
        guard let engine else { return }
        MainActor.assumeIsolated { engine.setSyncsBoosts(on) }
        refresh()
    }

    /// Settings › Sync › "Sync settings".
    func setSyncsSettings(_ on: Bool) {
        guard let engine else { return }
        MainActor.assumeIsolated { engine.setSyncsSettings(on) }
        refresh()
    }

    /// When to sync besides after each change (SyncTriggers), only while sync is on: becoming active, a CloudKit push
    /// (with the push entitlement), the account changing, and every ten minutes as the fallback (no entitlement, or a
    /// lost push). Off removes all of it, and the live database with it.
    private func updateTriggers() {
        if isEnabled {
            guard timer == nil else { return }
            let center = NotificationCenter.default, triggers = triggers
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, Date().timeIntervalSince(self.lastActivationSync) > triggers.activationInterval else { return }
                self.lastActivationSync = Date()
                #if AIRC_TESTING
                MainActor.assumeIsolated { ICloudTwoMacCheck.event("trigger.activation") }
                #endif
                self.syncSoon()
            })
            observers.append(center.addObserver(forName: Notification.Name("CKAccountChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                // End the session in flight at once; the next cycle compares the account.
                guard let engine = self?.engine else { return }
                MainActor.assumeIsolated { engine.accountDidChange() }
            })
            timer = Timer.scheduledTimer(withTimeInterval: triggers.fallbackInterval, repeats: true) { [weak self] _ in
                #if AIRC_TESTING
                MainActor.assumeIsolated { ICloudTwoMacCheck.event("trigger.fallback") }
                #endif
                self?.syncSoon()
            }
            timer?.tolerance = 60
            registerForPushes()
        } else {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            timer?.invalidate()
            timer = nil
            if registeredForPushes {
                NSApp.unregisterForRemoteNotifications()
                registeredForPushes = false
            }
            cloudDatabase = nil
        }
    }

    func syncSoon() { if let engine { MainActor.assumeIsolated { engine.syncSoon() } } }

    /// Sync Now: one cycle, then `done`.
    func syncNow(_ done: (() -> Void)? = nil) {
        guard let engine else { done?(); return }
        Task { @MainActor in await engine.syncNow(); done?() }
    }

    /// The first-sync screen's answer. `done` gets the error, if any.
    func choose(_ choice: SyncFirstSyncChoice, profiles: [String: SyncProfileChoice], done: ((Error?) -> Void)? = nil) {
        guard let engine else { return }
        Task { @MainActor in
            do {
                lastBackup = try await engine.choose(choice, profiles: profiles)
                if let app { for c in app.controllers where c.store.space(c.currentSpaceID) == nil { c.switchToSpace(c.store.selectedSpace.id, animated: false) } }
                done?(nil)
            } catch {
                NSLog("Airc sync: the first sync didn't start: %@", String(describing: error))
                done?(error)
            }
            refresh()
        }
    }

    func cancelFirstSync() {
        guard let engine else { return }
        MainActor.assumeIsolated { engine.cancelFirstSync() }
        refresh()
    }

    // MARK: Recovery (syncrecovery; the sheets are in SyncRecovery.swift)

    /// This Mac syncs with the key here: Settings offers its recovery key.
    var hasRecoveryKey: Bool {
        guard let engine else { return false }
        return MainActor.assumeIsolated { engine.isEnabled && engine.hasJoined && engine.status != .waitingForKeychain }
    }

    /// The recovery key, after the Mac's login (Touch ID or the password; scripted runs skip it). nil: none, or the
    /// person cancelled.
    func revealRecoveryKey(_ done: @escaping (String?) -> Void) {
        guard let engine else { return done(nil) }
        let reveal = { done(MainActor.assumeIsolated { (try? engine.recoveryKey()) ?? nil }) }
        if app?.options.isScripted == true { return reveal() }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show the sync recovery key") { ok, _ in
            DispatchQueue.main.async { if ok { reveal() } else { done(nil) } }
        }
    }

    /// A recovery key typed on a Mac waiting for the key. `done` gets the error, if any.
    func useRecoveryKey(_ text: String, done: ((Error?) -> Void)? = nil) {
        guard let engine else { return }
        Task { @MainActor in
            do { try await engine.useRecoveryKey(text); done?(nil) }
            catch {
                NSLog("Airc sync: the recovery key wasn't used: %@", String(describing: error))
                done?(error)
            }
            refresh()
        }
    }

    /// "Start over with this Mac's sidebar". `done` gets the error, if any.
    func startOver(done: ((Error?) -> Void)? = nil) {
        guard let engine else { return }
        Task { @MainActor in
            do {
                lastBackup = try await engine.startOver()
                done?(nil)
            } catch {
                NSLog("Airc sync: start over didn't happen: %@", String(describing: error))
                done?(error)
            }
            refresh()
        }
    }

    /// A CloudKit push (silent: no alert, nothing shown).
    func remoteNotification(_ userInfo: [String: Any]) {
        let subscription = cloudTestZone == nil ? SyncCloudSchema.subscription : Self.testSubscription
        guard SyncTriggers.isSidebarPush(userInfo, subscription: subscription) else { return }
        #if AIRC_TESTING
        MainActor.assumeIsolated { ICloudTwoMacCheck.event("trigger.push") }
        #endif
        syncSoon()
    }

    private func registerForPushes() {
        guard !registeredForPushes, triggers.registersForPushes else { return }
        registeredForPushes = true
        NSApp.registerForRemoteNotifications()
    }

    private func refresh() {
        guard let engine else { return }
        let (status, devices, lastSynced, enabled, tooLarge, held, settings) = MainActor.assumeIsolated {
            (engine.status, engine.devices, engine.lastSynced, engine.isEnabled, engine.notesTooLarge, engine.notesHeld, engine.syncsSettings)
        }
        let boosts = MainActor.assumeIsolated { engine.syncsBoosts }
        let dryRun = MainActor.assumeIsolated { engine.cleanUpDryRun }
        if cleanUpDryRun != dryRun { cleanUpDryRun = dryRun }
        if syncsSettings != settings { syncsSettings = settings }
        if syncsBoosts != boosts { syncsBoosts = boosts }
        if notesTooLarge != tooLarge { notesTooLarge = tooLarge }
        if notesHeld != held { notesHeld = held }
        if self.status != status { self.status = status }
        if self.devices != devices { self.devices = devices }
        if self.lastSynced != lastSynced { self.lastSynced = lastSynced }
        if isEnabled != enabled { isEnabled = enabled }
        updateTriggers()
        // A first sync that needs an answer while Settings is closed (iCloud Keychain brought the key over later).
        if case .choosing = status, let app, app.settingsWindow?.window.isVisible != true {
            app.showSettings(page: .sync)
        }
    }

    /// A hash of the hardware UUID: a data folder copied to another Mac gets a device ID of its own.
    static var machine: String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return SHA256.hash(data: Data(("airc-sync|" + uuid).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `--sync-cloudkit-test-zone AircSidebarTest…`: the real CloudKit container, in a zone of the test's own. Test builds
    /// only, and only names that start with AircSidebarTest.
    private func testZone() -> String? {
        #if AIRC_TESTING
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--sync-cloudkit-test-zone"), i + 1 < args.count,
              args[i + 1].hasPrefix("AircSidebarTest"), args[i + 1] != SyncCloudSchema.zone else { return nil }
        return args[i + 1]
        #else
        return nil
        #endif
    }

    /// `--sync-mock DIR` (a mock CloudKit database in DIR, shared by app instances), `--sync-folder DIR` (the encrypted
    /// folder transport), each with `--sync-keychain DIR` as this instance's keychain and `--sync-device-name NAME` (or
    /// AIRC_SYNC_DEVICE_NAME; never the Mac's own name in a test's screenshots). Test builds only.
    private func testBackend() -> (Backend, SyncKeyStore, (UUID) -> SyncGroupTransport, String)? {
        #if AIRC_TESTING
        let args = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func folder(_ name: String) -> URL? { argument(name).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        guard let keychain = folder("--sync-keychain"), let keys = try? FolderSyncKeyStore(folder: keychain) else { return nil }
        let name = argument("--sync-device-name") ?? ProcessInfo.processInfo.environment["AIRC_SYNC_DEVICE_NAME"] ?? "Test Mac"
        if let mock = folder("--sync-mock"), let database = try? SyncFolderCloudDatabase(folder: mock) {
            return (.mock(mock), keys, { CloudKitSyncTransport(database: database, device: $0, backoff: [0.2, 0.5]) }, name)
        }
        if let shared = folder("--sync-folder"), (try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)) != nil {
            return (.folder(shared), keys, { try! FolderSyncTransport(folder: shared, device: $0) }, name)
        }
        #endif
        return nil
    }
}

/// CloudKit's silent pushes for the sidebar zone's subscription. They need the push entitlement; without it the app
/// syncs when it becomes active and every ten minutes.
extension AppDelegate {
    @objc func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        SyncCenter.shared.remoteNotification(userInfo)
    }

    @objc func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if AIRC_TESTING
        MainActor.assumeIsolated { ICloudTwoMacCheck.event("push.registered") }
        #endif
    }
    @objc func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if AIRC_TESTING
        MainActor.assumeIsolated { ICloudTwoMacCheck.event("push.registration-failed", ["code": (error as NSError).code]) }
        #endif
    }
}
