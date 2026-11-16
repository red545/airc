// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// A Mac's app settings as the engine sees them: flat keys → canonical JSON, a ledger of what the person changed, and a
/// clock for "when". Plays the app's SettingsSync bridge. Synthetic values only.
private final class FakeSettings {
    var values: [String: String]
    let defaults: [String: String]
    var ledger = SyncSettingsLedger()
    var time: Int64 = 1_000
    /// Keys this Mac's app can't read (a value from a newer build): apply refuses them.
    var unreadable: Set<String> = []
    private(set) var applied: [[String: SyncSettingEntry]] = []

    init(_ defaults: [String: String]) { self.defaults = defaults; values = defaults }

    func observe() { ledger.observe(values, defaults: defaults, now: time) }
    /// The person changes a setting (Settings), at `time`.
    func set(_ key: String, _ json: String) { values[key] = json; observe() }

    var source: SyncSettingsSource {
        SyncSettingsSource(explicit: { [unowned self] in
            self.observe()
            return self.ledger.explicit(self.values)
        }, apply: { [unowned self] changes in
            self.applied.append(changes)
            var done = Set<String>()
            for (key, entry) in changes where self.values[key] != nil && !self.unreadable.contains(key) {
                self.values[key] = entry.json
                self.ledger.adopt(key, entry)
                done.insert(key)
            }
            return done
        })
    }
}

@MainActor
private final class SettingsMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let settings: FakeSettings
    var engine: SyncEngine!

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock, extra: [String: String] = [:]) throws {
        store = try makeStore(clock)
        let store = store, folder = root.appendingPathComponent(name)
        let p = store.defaultProfile.id
        settings = FakeSettings([
            "app.defaultAppearance": #""auto""#, "app.translucency": #""default""#, "app.shortcuts": "{}",
            "app.siteSearch@" + p: "null", "app.backupFolder": "null", "app.developerAutomatic": "true",
            "window.sidebarOnRight": "false", "app.tidyTitles": "false",
        ].merging(extra) { $1 })
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: name + "'s Mac", machine: name,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        env.settings = settings.source
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    var profile: String { store.defaultProfile.id }
    func value(_ key: String) -> String? { settings.values[key] }
    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
}

@MainActor
final class SyncSettingsTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-settings-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func pair(prepare: (SettingsMac, SettingsMac) throws -> Void = { _, _ in }) async throws -> (SettingsMac, SettingsMac, SyncMockCloudDatabase) {
        let db = SyncMockCloudDatabase()
        let a = try SettingsMac("A", db: db, root: root, clock: clock), b = try SettingsMac("B", db: db, root: root, clock: clock)
        _ = try a.store.createSpace(name: "Work")
        try prepare(a, b)
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        if case .choosing = b.engine.status { try await b.engine.choose(.merge) }
        XCTAssertEqual(b.engine.status, .upToDate)
        return (a, b, db)
    }

    private func batches(_ db: SyncMockCloudDatabase) async -> [SyncEnvelope] {
        await db.state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.envelope)
    }

    /// Every setting key any Mac sent (opened with the group key).
    private func sentKeys(_ db: SyncMockCloudDatabase, _ mac: SettingsMac) async throws -> Set<String> {
        let key = try XCTUnwrap(mac.keys.key(group: XCTUnwrap(mac.engine.groupID)))
        var result = Set<String>()
        for e in await batches(db) {
            for op in try e.open(group: e.group, key: key) where op.record.kind == .setting { result.insert(op.record.id) }
        }
        return result
    }

    private func later() async throws { try await Task.sleep(nanoseconds: 5_000_000); clock.advance(1) }

    // MARK: Keys, payload and envelope

    func testTheAllowlistAndTheExcludedKeys() {
        XCTAssertTrue(SyncSettings.synced.isDisjoint(with: SyncSettings.perMac))
        for key in ["app.translucency", "app.shortcuts", "app.siteSearch@P1", "blocking@P1", "profile.archiveAfter@P1",
                    "window.sidebarOnRight", "app.littleArcGlobal", "app.whatsNewStyle", "app.tidyTitles"] {
            XCTAssertTrue(SyncSettings.isSynced(key), key)
        }
        // Per Mac: paths, Developer Mode, hardware, approvals, onboarding; anything not on the list; malformed keys.
        for key in SyncSettings.perMac.sorted() + ["app.backupFolder@P1", "agent.approvals", "agent.token", "mcp.pairedDevices",
                                                   "app.siteSearch", "app.translucency@P1", "app.passwords", "", "a@b@c",
                                                   "app.siteSearch@", "app.x y", "app.shortcuts\u{0}"] {
            XCTAssertFalse(SyncSettings.isSynced(key), key)
        }
        XCTAssertEqual(SyncSettings.mapped("app.siteSearch@P1") { $0 == "P1" ? "G1" : nil }, "app.siteSearch@G1")
        XCTAssertNil(SyncSettings.mapped("app.siteSearch@P2") { $0 == "P1" ? "G1" : nil })
        XCTAssertEqual(SyncSettings.mapped("app.shortcuts") { _ in nil }, "app.shortcuts")
    }

    func testThePayloadIsSealedInAVersion4BatchOlderBuildsCantOpen() throws {
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID()
        var replica = SyncReplica(device: device)
        let payload = SettingSyncPayload(json: #"{"focus.secretsearch":"alt+cmd+l"}"#, changed: 42)
        XCTAssertEqual(try JSONDecoder().decode(SettingSyncPayload.self, from: JSONEncoder().encode(payload)), payload)
        let op = try replica.edit(SyncRecordID(.setting, "app.shortcuts"), [.value: .setting(payload)], now: 1)
        let envelope = try SyncEnvelope.seal([op], group: group, device: device, key: key, version: SyncSettings.envelopeVersion)
        XCTAssertEqual(envelope.version, 4)
        let raw = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(raw.contains("secretsearch") || raw.contains("shortcuts"))
        XCTAssertEqual(try envelope.open(group: group, key: key), [op])
        XCTAssertThrowsError(try envelope.open(group: group, key: key, accepting: 1...3)) { XCTAssertEqual($0 as? SyncError, .unsupportedVersion) }

        // Refused like any malformed operation: too large, a bad key, a value on another kind, another field.
        let big = SettingSyncPayload(json: String(repeating: "x", count: SettingSyncPayload.maxValueBytes + 1), changed: 1)
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.setting, "app.shortcuts"), [.value: .setting(big)], now: 2))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.setting, "a b"), [.value: .setting(payload)], now: 2))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.row, "item:x"), [.value: .setting(payload)], now: 2))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.setting, "app.shortcuts"), [.name: .text("x")], now: 2))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.setting, "app.shortcuts"), [.value: .setting(SettingSyncPayload(format: 0, json: "1", changed: 1))], now: 2))
        XCTAssertFalse(SettingSyncPayload(format: 2, json: "1", changed: 1).isReadable)
        // Settings never show in the sidebar.
        XCTAssertFalse(replica.sidebar.contains { $0.id.kind == .setting })
    }

    func testTheLaterChangeWinsWhateverTheStamps() throws {
        // B's change was made earlier (while sync was off) but captured later: A's later change still wins, on both.
        var a = SyncReplica(device: UUID()), b = SyncReplica(device: UUID())
        let id = SyncRecordID(.setting, "app.defaultAppearance")
        let fromA = try a.edit(id, [.value: .setting(SettingSyncPayload(json: #""dark""#, changed: 2_000))], now: 10)
        let fromB = try b.edit(id, [.value: .setting(SettingSyncPayload(json: #""light""#, changed: 1_000))], now: 20)
        try a.receive([fromB], now: 30); try b.receive([fromA], now: 30)
        for r in [a, b] { XCTAssertEqual(r.records[id]?[.value], .setting(SettingSyncPayload(json: #""dark""#, changed: 2_000))) }
        // Same change time (both from before tracking): the later stamp.
        var c = SyncReplica(device: UUID())
        let one = try c.edit(id, [.value: .setting(SettingSyncPayload(json: #""dark""#, changed: 0))], now: 40)
        let two = try c.edit(id, [.value: .setting(SettingSyncPayload(json: #""light""#, changed: 0))], now: 50)
        var d = SyncReplica(device: UUID())
        try d.receive([two, one], now: 60)
        XCTAssertEqual(d.records[id]?[.value], .setting(SettingSyncPayload(json: #""light""#, changed: 0)))
    }

    func testTheLedgerKeepsOnlyChangedSettings() {
        var ledger = SyncSettingsLedger()
        let defaults = ["a": "1", "b": "1", "c": "1"]
        // First look: a non-default value counts as changed before tracking (0); defaults don't count.
        ledger.observe(["a": "1", "b": "2", "c": "1"], defaults: defaults, now: 100)
        XCTAssertEqual(ledger.explicit(["a": "1", "b": "2", "c": "1"]), ["b": SyncSettingEntry(json: "2", changed: 0)])
        // A change counts from now, even back to the default.
        ledger.observe(["a": "3", "b": "1", "c": "1"], defaults: defaults, now: 200)
        XCTAssertEqual(ledger.explicit(["a": "3", "b": "1", "c": "1"]),
                       ["a": SyncSettingEntry(json: "3", changed: 200), "b": SyncSettingEntry(json: "1", changed: 200)])
        // Another Mac's value keeps its time; seeing it again isn't a change here.
        ledger.adopt("c", SyncSettingEntry(json: "5", changed: 150))
        XCTAssertFalse(ledger.observe(["a": "3", "b": "1", "c": "5"], defaults: defaults, now: 300))
        XCTAssertEqual(ledger.explicit(["a": "3", "b": "1", "c": "5"])["c"], SyncSettingEntry(json: "5", changed: 150))
        // A key that's gone (its profile was deleted) is forgotten; a new one starts like the first look.
        ledger.observe(["a": "3", "b": "1", "d@P": "9"], defaults: defaults.merging(["d@P": "0"]) { $1 }, now: 400)
        XCTAssertNil(ledger.changed["c"])
        XCTAssertEqual(ledger.changed["d@P"], 0)
    }

    // MARK: Two Macs

    func testChangesOnOneMacArriveOnTheOtherAndPerMacKeysStay() async throws {
        let (a, b, db) = try await pair()
        a.settings.time = 5_000
        a.settings.set("app.defaultAppearance", #""dark""#)
        a.settings.set("app.shortcuts", #"{"focus.commandbar":"alt+cmd+k"}"#)
        let search = #"{"searches":[{"id":"own.1","keyword":"ex","name":"Example","template":"https://example.com/?q=%s"}],"spaceTriggers":false}"#
        a.settings.set("app.siteSearch@" + a.profile, search)
        a.settings.set("app.backupFolder", #""/Volumes/Backup A""#)
        a.settings.set("app.developerAutomatic", "false")
        a.engine.settingsChanged()
        await a.sync()
        await b.sync()
        XCTAssertEqual(b.value("app.defaultAppearance"), #""dark""#)
        XCTAssertEqual(b.value("app.shortcuts"), #"{"focus.commandbar":"alt+cmd+k"}"#)
        // A's default profile's Site Search lands on B's default profile.
        XCTAssertEqual(b.value("app.siteSearch@" + b.profile), search)
        // Per Mac: never sent, B keeps its own.
        XCTAssertEqual(b.value("app.backupFolder"), "null")
        XCTAssertEqual(b.value("app.developerAutomatic"), "true")
        let sent = try await sentKeys(db, a)
        XCTAssertEqual(sent, ["app.defaultAppearance", "app.shortcuts", "app.siteSearch@" + a.profile])
        XCTAssertTrue(sent.allSatisfy(SyncSettings.isSynced))
        // Setting batches are version 4 and hold nothing else; nothing of a value is readable in iCloud.
        let key = try XCTUnwrap(a.keys.key(group: XCTUnwrap(a.engine.groupID)))
        for e in await batches(db) {
            let ops = try e.open(group: e.group, key: key)
            XCTAssertEqual(ops.contains { $0.record.kind == .setting }, e.version == 4)
            if e.version == 4 { XCTAssertTrue(ops.allSatisfy { $0.record.kind == .setting }) }
            XCTAssertFalse(String(decoding: e.sealed, as: UTF8.self).contains("example.com"))
        }
        // B applied it (no echo): its next sync sends nothing back.
        let count = await batches(db).count
        b.settings.time = 6_000
        await b.sync()
        let after = await batches(db).count
        XCTAssertEqual(count, after)
        XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testAMacThatNeverChangedASettingTakesItAndDefaultsNeverTravel() async throws {
        // B changed its theme before sync (before tracking); A never touched it: A's default never overwrites B's.
        let (a, b, db) = try await pair { _, b in b.settings.values["app.defaultAppearance"] = #""light""# }
        XCTAssertEqual(b.value("app.defaultAppearance"), #""light""#)
        await a.sync()
        XCTAssertEqual(a.value("app.defaultAppearance"), #""light""#, "A never changed it: it takes B's")
        let sent = try await sentKeys(db, a)
        XCTAssertEqual(sent, ["app.defaultAppearance"], "only B's change; no defaults")
        // A changes it later: that wins on both.
        a.settings.time = 9_000
        a.settings.set("app.defaultAppearance", #""dark""#)
        await a.sync(); await b.sync()
        XCTAssertEqual(a.value("app.defaultAppearance"), #""dark""#)
        XCTAssertEqual(b.value("app.defaultAppearance"), #""dark""#)
    }

    func testConflictTheLaterChangeWinsOnBothMacs() async throws {
        let (a, b, _) = try await pair()
        // B changes first (offline), A later; B syncs last. A's later change wins on both.
        b.settings.time = 7_000
        b.settings.set("app.translucency", #""off""#)
        a.settings.time = 8_000
        a.settings.set("app.translucency", #""more""#)
        await a.sync()
        try await later()
        await b.sync()
        await a.sync()
        XCTAssertEqual(a.value("app.translucency"), #""more""#)
        XCTAssertEqual(b.value("app.translucency"), #""more""#)
        // Different settings changed on each Mac both stay.
        a.settings.time = 10_000; a.settings.set("app.tidyTitles", "true")
        b.settings.time = 10_001; b.settings.set("window.sidebarOnRight", "true")
        await a.sync(); await b.sync(); await a.sync()
        for mac in [a, b] {
            XCTAssertEqual(mac.value("app.tidyTitles"), "true")
            XCTAssertEqual(mac.value("window.sidebarOnRight"), "true")
        }
    }

    func testTheSwitchOffSendsAndAppliesNothingAndOnCatchesUp() async throws {
        let (a, b, db) = try await pair()
        XCTAssertTrue(b.engine.syncsSettings)
        b.engine.setSyncsSettings(false)
        a.settings.time = 2_000; a.settings.set("app.defaultAppearance", #""dark""#)
        b.settings.time = 2_500; b.settings.set("app.shortcuts", #"{"x":"cmd+j"}"#)
        await a.sync(); await b.sync()
        XCTAssertEqual(b.value("app.defaultAppearance"), #""auto""#, "off: not applied")
        var sent = try await sentKeys(db, a)
        XCTAssertFalse(sent.contains("app.shortcuts"), "off: not sent")
        // The sidebar still syncs while settings are off.
        let space = try a.store.createSpace(name: "Shared")
        await a.sync(); await b.sync()
        XCTAssertNotNil(b.store.space(space.id))
        // On again: it takes what changed elsewhere and sends what changed here meanwhile (with when it changed).
        b.engine.setSyncsSettings(true)
        await b.sync(); await a.sync()
        XCTAssertEqual(b.value("app.defaultAppearance"), #""dark""#)
        XCTAssertEqual(a.value("app.shortcuts"), #"{"x":"cmd+j"}"#)
        sent = try await sentKeys(db, a)
        XCTAssertTrue(sent.contains("app.shortcuts"))
        // The switch survives a relaunch (it's in the state file).
        b.engine.setSyncsSettings(false)
        let again = try SettingsMac("B", db: db, root: root, clock: clock)
        XCTAssertFalse(again.engine.syncsSettings)
    }

    func testAValueThisMacCantReadWaitsAndAProfileItLacksToo() async throws {
        let (a, b, _) = try await pair()
        b.settings.unreadable = ["app.shortcuts"]
        a.settings.time = 3_000
        a.settings.set("app.shortcuts", #"{"x":"cmd+j"}"#)
        let other = try a.store.createProfile(name: "Second", emoji: "")
        a.settings.values["app.siteSearch@" + other.id] = "null"
        a.settings.set("app.siteSearch@" + other.id, #"{"searches":[],"spaceTriggers":true}"#)
        await a.sync(); await b.sync()
        XCTAssertEqual(b.value("app.shortcuts"), "{}", "unreadable here: keeps its own")
        XCTAssertEqual(b.engine.status, .upToDate)
        // Once it reads (after an update), the waiting value applies.
        b.settings.unreadable = []
        await b.sync()
        XCTAssertEqual(b.value("app.shortcuts"), #"{"x":"cmd+j"}"#)
        // The second profile isn't on B (no Space uses it): nothing for it applied.
        XCTAssertFalse(b.settings.applied.flatMap(\.keys).contains { $0.hasPrefix("app.siteSearch@") && $0 != "app.siteSearch@" + b.profile })
    }

    func testAnOlderBuildKeepsSettingBatchesUnread() async throws {
        let (a, _, db) = try await pair()
        a.settings.time = 4_000
        a.settings.set("app.defaultAppearance", #""dark""#)
        await a.sync()
        let key = try XCTUnwrap(a.keys.key(group: XCTUnwrap(a.engine.groupID)))
        let v4 = await batches(db).filter { $0.version == 4 }
        XCTAssertEqual(v4.count, 1)
        // A build that reads 1...3 refuses it (and keeps it in its quarantine, as for splits).
        XCTAssertThrowsError(try v4[0].open(group: v4[0].group, key: key, accepting: 1...3))
    }
}
