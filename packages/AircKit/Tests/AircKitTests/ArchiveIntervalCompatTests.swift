// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// archivenever: an auto-archive interval a newer Airc writes ("never", say) must read on every build, act as the
/// default where it's unknown, and survive both the store and Settings sync unchanged. Synthetic profiles only.

/// The ArchiveInterval every Airc up to 0.1.47 shipped, copied as it was (Model.swift before archivenever): the enum
/// and its tolerant `init(from:)`. It plays the older build in these tests.
private enum ShippedArchiveInterval: String, Codable, Hashable, CaseIterable {
    case twelveHours, twentyFourHours, sevenDays, thirtyDays

    init(from decoder: Decoder) throws {
        self = ShippedArchiveInterval(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .twelveHours
    }
}

/// The JSON SettingsSync sends and stores (sorted keys, no escaped slashes).
private func json<T: Encodable>(_ v: T) -> String {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try! e.encode(v), as: UTF8.self)
}

private func decode<T: Decodable>(_ t: T.Type, _ s: String) throws -> T { try JSONDecoder().decode(t, from: Data(s.utf8)) }

final class ArchiveIntervalCompatTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-archivenever-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Decoding and encoding

    func testEveryKnownIntervalRoundTrips() throws {
        for v in ArchiveInterval.known {
            XCTAssertEqual(try decode(ArchiveInterval.self, json(v)), v)
            XCTAssertEqual(json(v), "\"\(v.rawValue)\"")
            XCTAssertTrue(v.isKnown)
            XCTAssertEqual(v.effective, v)
        }
        // The raw values older builds stored keep their meaning.
        XCTAssertEqual(try decode(ArchiveInterval.self, #""twelveHours""#).seconds, 12 * 3600)
        XCTAssertEqual(try decode(ArchiveInterval.self, #""twentyFourHours""#).seconds, 24 * 3600)
        XCTAssertEqual(try decode(ArchiveInterval.self, #""sevenDays""#).seconds, 7 * 86400)
        XCTAssertEqual(try decode(ArchiveInterval.self, #""thirtyDays""#).seconds, 30 * 86400)
        XCTAssertEqual(Profile(name: "").archiveAfter, .twelveHours, "the default is unchanged")
    }

    func testAnUnknownIntervalReadsActsAsTheDefaultAndEncodesUnchanged() throws {
        let v = try decode(ArchiveInterval.self, #""fortnightAndADay""#)
        XCTAssertFalse(v.isKnown)
        XCTAssertEqual(v.rawValue, "fortnightAndADay")
        XCTAssertEqual(v.effective, .default)
        XCTAssertEqual(v.seconds, ArchiveInterval.default.seconds, "acts as today's default: 12 hours")
        XCTAssertEqual(json(v), #""fortnightAndADay""#, "written back as it came, never as its fallback")
        XCTAssertNotEqual(v, .twelveHours)
        // The picker shows it (as what a newer Airc set) instead of a wrong choice.
        XCTAssertEqual(ArchiveInterval.choices(current: v), ArchiveInterval.allCases + [v])
        XCTAssertEqual(ArchiveInterval.choices(current: .sevenDays), ArchiveInterval.allCases)
        // Not even a damaged value fails the profile.
        XCTAssertEqual(try decode([ArchiveInterval].self, "[5]"), [.default])
    }

    func testAProfileWithAnUnknownIntervalDecodesAndRoundTrips() throws {
        let p = Profile(id: "P1", name: "Work", engineDirectory: "Profile-P1", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        var o = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        o["archiveAfter"] = "someNewInterval"
        let row = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        let read = try JSONDecoder().decode(Profile.self, from: row)
        XCTAssertEqual(read.name, "Work")
        XCTAssertEqual(read.archiveAfter.rawValue, "someNewInterval")
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any])
        XCTAssertEqual(again["archiveAfter"] as? String, "someNewInterval")
    }

    // MARK: The new values (Never, 1 hour, 6 hours)

    func testTheNewValuesDecodeAndAct() throws {
        XCTAssertEqual(try decode(ArchiveInterval.self, #""never""#), .never)
        XCTAssertEqual(try decode(ArchiveInterval.self, #""oneHour""#), .oneHour)
        XCTAssertEqual(try decode(ArchiveInterval.self, #""sixHours""#), .sixHours)
        for v in [ArchiveInterval.never, .oneHour, .sixHours] {
            XCTAssertTrue(v.isKnown)
            XCTAssertEqual(json(v), "\"\(v.rawValue)\"")
        }
        XCTAssertEqual(ArchiveInterval.oneHour.seconds, 3600)
        XCTAssertEqual(ArchiveInterval.sixHours.seconds, 6 * 3600)
        XCTAssertEqual(ArchiveInterval.never.seconds, .infinity)
        XCTAssertFalse(ArchiveInterval.never.archives)
        XCTAssertTrue(ArchiveInterval.oneHour.archives && ArchiveInterval(rawValue: "someNewInterval").archives)
        XCTAssertEqual([ArchiveInterval.oneHour, .sixHours, .never].map(\.label), ["1 hour", "6 hours", "Never"])
    }

    func testThePickersOfferTheNewValuesOnlyWithTheFlag() {
        defer { ArchiveInterval.moreChoicesOverride = nil }
        XCTAssertFalse(ArchiveInterval.moreChoicesByDefault, "on only in the release after the round-trip fix")
        ArchiveInterval.moreChoicesOverride = false
        XCTAssertEqual(ArchiveInterval.allCases, [.twelveHours, .twentyFourHours, .sevenDays, .thirtyDays])
        // Set elsewhere (a Mac with the flag on), it shows as set and acts, flag or not.
        XCTAssertEqual(ArchiveInterval.choices(current: .never), ArchiveInterval.original + [.never])
        ArchiveInterval.moreChoicesOverride = true
        XCTAssertEqual(ArchiveInterval.allCases, [.oneHour, .sixHours, .twelveHours, .twentyFourHours, .sevenDays, .thirtyDays, .never])
        XCTAssertEqual(ArchiveInterval.choices(current: .never), ArchiveInterval.allCases)
    }

    func testNeverKeepsTodayTabsAndOneHourArchivesAfterAnHour() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sid = s.selectedSpace.id, pid = s.defaultProfile.id
        try s.updateProfile(pid) { $0.archiveAfter = .never }
        let a = try s.openTab(url: "https://a.example/", inSpace: sid, activate: false)
        let b = try s.openTab(url: "https://b.example/", inSpace: sid, activate: false)
        clock.advance(400 * 86400)
        XCTAssertEqual(s.dueForAutoArchive(), [])
        XCTAssertNil(s.nextAutoArchiveDate(), "no timer waits for Never")
        XCTAssertEqual(try s.autoArchive(), [])
        XCTAssertNotNil(s.tab(a.id))
        // Clear still clears, and Undo brings them back (unchanged).
        XCTAssertEqual(Set(try s.clearToday(inSpace: sid, keeping: nil)), [a.id, b.id])
        XCTAssertNil(s.tab(a.id))
        XCTAssertNotNil(try s.undo())
        XCTAssertNotNil(s.tab(a.id)); XCTAssertNotNil(s.tab(b.id))
        XCTAssertEqual(s.dueForAutoArchive(), [], "restored tabs don't auto-archive either")

        try s.updateProfile(pid) { $0.archiveAfter = .oneHour }
        let fresh = try s.openTab(url: "https://c.example/", inSpace: sid, activate: false)
        XCTAssertEqual(s.nextAutoArchiveDate(), s.tab(a.id).map { $0.lastActiveAt.addingTimeInterval(3600) })
        clock.advance(59 * 60)
        XCTAssertFalse(s.dueForAutoArchive().contains(fresh.id))
        clock.advance(2 * 60)
        XCTAssertEqual(try s.autoArchive().contains(fresh.id), true)
        XCTAssertNil(s.tab(fresh.id))
        XCTAssertTrue(s.state.archive.values.contains { $0.tab.id == fresh.id && $0.reason == .auto })

        try s.updateProfile(pid) { $0.archiveAfter = .sixHours }
        let six = try s.openTab(url: "https://d.example/", inSpace: sid, activate: false)
        clock.advance(5 * 3600)
        XCTAssertFalse(s.dueForAutoArchive().contains(six.id))
        clock.advance(3600 + 1)
        XCTAssertTrue(s.dueForAutoArchive().contains(six.id))
    }

    // MARK: The store

    func testTheStoreKeepsANewerIntervalThroughWritesAndRelaunch() throws {
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var pid = ""
        do {
            let s = try SpacesStore(path: path)
            pid = try s.createProfile(name: "Work").id
            try s.flush()
        }
        // A newer Airc's row, written behind the store's back.
        do {
            let db = try Database(path: path)
            let body = try XCTUnwrap(db.query("SELECT body FROM entities WHERE kind='profile' AND id=?", [.text(pid)]).first?.first as? String)
            var o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            o["archiveAfter"] = "someNewInterval"
            let future = String(decoding: try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
            try db.run("UPDATE entities SET body=? WHERE kind='profile' AND id=?", [.text(future), .text(pid)])
        }
        do {
            let s = try SpacesStore(path: path)
            XCTAssertEqual(s.profile(pid)?.archiveAfter.rawValue, "someNewInterval")
            XCTAssertEqual(s.profile(pid)?.archiveAfter.seconds, 12 * 3600)
            try s.updateProfile(pid) { $0.name = "Work 2" }   // an unrelated write
            try s.flush()
        }
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.profile(pid)?.name, "Work 2")
        XCTAssertEqual(s.profile(pid)?.archiveAfter.rawValue, "someNewInterval")
    }

    func testAnUnknownIntervalArchivesAtTheDefault() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let pid = s.defaultProfile.id
        try s.updateProfile(pid) { $0.archiveAfter = ArchiveInterval(rawValue: "someNewInterval") }
        let t = try s.openTab(url: "https://idle.example/", inSpace: s.selectedSpace.id, activate: false)
        clock.advance(11 * 3600)
        XCTAssertFalse(s.dueForAutoArchive().contains(t.id))
        clock.advance(2 * 3600)
        XCTAssertTrue(s.dueForAutoArchive().contains(t.id))
    }

    // MARK: The old-format fixture (the reason for the flag)

    /// A synced setting record as a newer Airc writes it: the value "never" in a SettingSyncPayload.
    private let neverRecord = #"{"changed":1800000000000,"format":1,"json":"\"never\""}"#

    func testTheShippedDecoderLosesNeverAndTheCurrentOneKeepsIt() throws {
        let payload = try decode(SettingSyncPayload.self, neverRecord)
        XCTAssertTrue(payload.isReadable && payload.isValid)
        // Before: it reads, but as 12 hours, and that's what it writes back.
        let shipped = try decode(ShippedArchiveInterval.self, payload.json)
        XCTAssertEqual(shipped, .twelveHours)
        XCTAssertNotEqual(json(shipped), payload.json, "the shipped decoder doesn't round-trip \"never\"")
        // After: the same record reads back unchanged.
        let current = try decode(ArchiveInterval.self, payload.json)
        XCTAssertEqual(current.rawValue, "never")
        XCTAssertEqual(json(current), payload.json)
    }

    /// Two Macs over the mock cloud: A sets "never", B is the shipped build (`shipped: true`) or this one.
    @MainActor
    func testOverSyncAShippedBuildOverwritesNeverAndThisBuildDoesNot() async throws {
        let shippedB = try await neverAfterSync(bShipped: true)
        XCTAssertEqual(shippedB.a, "twelveHours", "the shipped build sends its fallback back and replaces A's choice")
        XCTAssertEqual(shippedB.b, "twelveHours")
        let currentB = try await neverAfterSync(bShipped: false)
        XCTAssertEqual(currentB.a, "never", "this build never sends back a value it didn't change")
        XCTAssertEqual(currentB.b, "never", "and keeps the value as it came")
    }

    @MainActor
    private func neverAfterSync(bShipped: Bool) async throws -> (a: String, b: String) {
        let clock = TestClock()
        let db = SyncMockCloudDatabase()
        let root = dir.appendingPathComponent(bShipped ? "shipped" : "current")
        let a = try ArchiveMac("A", db: db, root: root, clock: clock, shipped: false)
        let b = try ArchiveMac("B", db: db, root: root, clock: clock, shipped: bShipped)
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        if case .choosing = b.engine.status { try await b.engine.choose(.merge) }
        XCTAssertEqual(b.engine.status, .upToDate)

        a.settings.time = 5_000
        a.settings.set(ArchiveInterval(rawValue: "never"))
        for mac in [a, b, b, a, b, a] {
            try await Task.sleep(nanoseconds: 5_000_000); clock.advance(1)
            await mac.sync()
        }
        return (a.raw, b.raw)
    }
}

/// One Mac's "Archive Today tabs after" as SettingsSync handles it: the store's value as the setting's JSON, a ledger,
/// and apply. `shipped` plays the app before archivenever: it decodes with the shipped enum, applies whatever that
/// gives, and adopts what it then reads (SettingsSync.apply up to 0.1.47); otherwise this build's apply, which waits on
/// a value that doesn't read back.
private final class ArchiveSettings {
    let store: SpacesStore
    let shipped: Bool
    var ledger = SyncSettingsLedger()
    var time: Int64 = 1_000

    init(_ store: SpacesStore, shipped: Bool) { self.store = store; self.shipped = shipped }

    var key: String { "profile.archiveAfter@" + store.defaultProfile.id }

    /// The setting's JSON as this build reads its store.
    var current: [String: String] {
        let v = store.defaultProfile.archiveAfter
        return [key: shipped ? json(ShippedArchiveInterval(rawValue: v.rawValue) ?? .twelveHours) : json(v)]
    }

    var defaults: [String: String] { [key: json(ArchiveInterval.default)] }

    func observe() { ledger.observe(current, defaults: defaults, now: time) }

    func set(_ v: ArchiveInterval) {
        try? store.updateProfile(store.defaultProfile.id) { $0.archiveAfter = v }
        observe()
    }

    var source: SyncSettingsSource {
        SyncSettingsSource(explicit: { [unowned self] in
            self.observe()
            return self.ledger.explicit(self.current)
        }, apply: { [unowned self] changes in
            var done = Set<String>()
            for (key, entry) in changes where key == self.key {
                if self.shipped {
                    guard let v = try? decode(ShippedArchiveInterval.self, entry.json) else { continue }
                    try? self.store.updateProfile(self.store.defaultProfile.id) { $0.archiveAfter = ArchiveInterval(rawValue: v.rawValue) }
                } else {
                    guard let v = try? decode(ArchiveInterval.self, entry.json), json(v) == entry.json else { continue }
                    try? self.store.updateProfile(self.store.defaultProfile.id) { $0.archiveAfter = v }
                }
                done.insert(key)
            }
            // As SettingsSync: adopt what this Mac now reads, with the other Mac's time, then look again.
            let now = self.current
            for key in done { if let entry = changes[key] { self.ledger.adopt(key, SyncSettingEntry(json: now[key] ?? entry.json, changed: entry.changed)) } }
            self.ledger.observe(now, defaults: self.defaults, now: self.time)
            return done
        })
    }
}

@MainActor
private final class ArchiveMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let settings: ArchiveSettings
    var engine: SyncEngine!

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock, shipped: Bool) throws {
        store = try makeStore(clock)
        let store = store, folder = root.appendingPathComponent(name)
        settings = ArchiveSettings(store, shipped: shipped)
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

    /// The stored interval's raw value.
    var raw: String { store.defaultProfile.archiveAfter.rawValue }
    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
}
