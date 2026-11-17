// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// A Mac with a store, a Boost store in memory and a sync engine on the shared mock CloudKit database. Synthetic sites and
/// code only.
@MainActor
private final class BoostMac {
    let store: SpacesStore
    let boosts = BoostStore(url: nil)
    let keys = InMemorySyncKeyStore()
    let name: String
    var engine: SyncEngine!
    /// Sites the app refuses to apply right now (tests the retry).
    var refuse: Set<String> = []

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name + "'s Mac"
        store = try makeStore(clock)
        let store = store, folder = root.appendingPathComponent(name), boosts = boosts
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: self.name, machine: name,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        env.boosts = SyncBoostsSource(current: { SyncBoosts.payloads(boosts, thisMac: $0) }, apply: { [unowned self] incoming in
            SyncBoosts.apply(incoming.filter { !self.refuse.contains($0.key) }, to: boosts)
        })
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    func boost(_ site: String) -> Boost? { boosts.boost(domain: site) }
}

@MainActor
final class SyncBoostsTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()
    private let code = "document.body.dataset.boosted = 'yes';"
    private var previousSuffixes: PublicSuffixList!

    override func setUp() async throws {
        // Sites and hosts as the app keys them (a test run alone has no list unless one is installed).
        previousSuffixes = PublicSuffixList.shared
        TestSuffixes.install()
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-boosts-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        PublicSuffixList.use(previousSuffixes)
    }

    private func pair(prepare: (BoostMac, BoostMac) throws -> Void = { _, _ in }) async throws -> (BoostMac, BoostMac, SyncMockCloudDatabase) {
        let db = SyncMockCloudDatabase()
        let a = try BoostMac("A", db: db, root: root, clock: clock), b = try BoostMac("B", db: db, root: root, clock: clock)
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

    private func opened(_ db: SyncMockCloudDatabase, _ mac: BoostMac) async throws -> [(version: Int, ops: [SyncOperation])] {
        let key = try XCTUnwrap(mac.keys.key(group: XCTUnwrap(mac.engine.groupID)))
        var result: [(Int, [SyncOperation])] = []
        for e in await batches(db) { result.append((e.version, try e.open(group: e.group, key: key))) }
        return result
    }

    /// Boosts' change times are whole seconds: the next change is a second later.
    private func later() async throws { try await Task.sleep(nanoseconds: 1_100_000_000) }

    // MARK: Payload, envelope and merge

    func testThePayloadRoundTripsInWholeSecondsAndKeepsItsLimits() throws {
        var b = Boost(domain: "example.com", colors: BoostColors(tint: 0.4, invert: true), font: BoostFont(family: .georgia, size: 1),
                      zaps: [BoostZap(id: "z1", selector: "#ad", label: "Ad", created: Date(timeIntervalSince1970: 1_800_000_000.75))],
                      css: "body { margin: 0 }", js: code, scriptHost: "www.example.com",
                      created: Date(timeIntervalSince1970: 1_700_000_000.5), modified: Date(timeIntervalSince1970: 1_800_000_123.9))
        b.name = "Calm"
        let p = BoostSyncPayload(b, thisMac: "A's Mac")
        XCTAssertEqual(p.changed, 1_800_000_123_000)
        XCTAssertEqual(p.created, 1_700_000_000_000)
        XCTAssertEqual(p.zaps[0].created, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(p.allowedOn, "A's Mac", "code that runs on a Mac is vouched for by it")
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(try JSONDecoder().decode(BoostSyncPayload.self, from: JSONEncoder().encode(p)), p)
        // `allowedOn` only words the confirm: not a change.
        var other = p
        other.allowedOn = "B's Mac"
        XCTAssertEqual(other.content, p.content)
        other.css = "body { margin: 1px }"
        XCTAssertNotEqual(other.content, p.content)
        // Installed from someone else's file and never switched on: no vouch (the next Mac shows the full review).
        var installed = b
        installed.enabled = false
        installed.origin = BoostOrigin(id: "x", revision: 1, kind: .installed, digest: "d")
        XCTAssertNil(BoostSyncPayload(installed, thisMac: "A's Mac").allowedOn)
        installed.enabled = true
        XCTAssertEqual(BoostSyncPayload(installed, thisMac: "A's Mac").allowedOn, "A's Mac")
        // Without code: no vouch.
        b.js = ""
        XCTAssertNil(BoostSyncPayload(b, thisMac: "A's Mac").allowedOn)
        // Limits: too large, a bad zap, a removal that carries content; a newer format isn't read.
        XCTAssertFalse(BoostSyncPayload(changed: 1, css: String(repeating: "x", count: BoostSyncPayload.maxBytes)).isValid)
        XCTAssertFalse(BoostSyncPayload(changed: 1, zaps: [BoostZap(selector: "a{}", label: "x")]).isValid)
        XCTAssertFalse(BoostSyncPayload(removed: true, changed: 1, js: code).isValid)
        XCTAssertTrue(BoostSyncPayload.removal(at: Date()).isValid)
        XCTAssertFalse(BoostSyncPayload(format: 2, changed: 1).isReadable)
        XCTAssertFalse(SyncBoosts.isValidSite("Example.com"))
        XCTAssertFalse(SyncBoosts.isValidSite("a b"))
        XCTAssertTrue(SyncBoosts.isValidSite("192.0.2.1"))
    }

    func testBoostsAndUsesAreSealedInVersion5BatchesOlderBuildsCantOpen() throws {
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID()
        var replica = SyncReplica(device: device)
        let p = BoostSyncPayload(changed: 1_000, css: "body { color: teal }", js: "secretcode()", allowedOn: "A's Mac")
        let op = try replica.edit(SyncRecordID(.boost, "example.com"), [.value: .boost(p)], now: 1)
        let use = try replica.edit(SyncRecordID(.row, "item:x"), [.used: .time(1_800_000_000_000)], now: 2)
        let envelope = try SyncEnvelope.seal([op, use], group: group, device: device, key: key, version: SyncBoosts.envelopeVersion)
        XCTAssertEqual(envelope.version, 5)
        let raw = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(raw.contains("example.com") || raw.contains("secretcode") || raw.contains("teal"))
        XCTAssertEqual(try envelope.open(group: group, key: key), [op, use])
        // A build from before Boosts synced (1...4) keeps it unread in its quarantine.
        XCTAssertThrowsError(try envelope.open(group: group, key: key, accepting: 1...4)) { XCTAssertEqual($0 as? SyncError, .unsupportedVersion) }

        // Refused like any malformed operation.
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.boost, "Not A Site"), [.value: .boost(p)], now: 3))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.row, "item:x"), [.value: .boost(p)], now: 3))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.boost, "example.com"), [.name: .text("x")], now: 3))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.space, "s"), [.used: .time(1)], now: 3))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.row, "item:x"), [.used: .time(-1)], now: 3))
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.boost, "example.com"), [.value: .boost(BoostSyncPayload(format: 0, changed: 1))], now: 3))
        // Boosts never show in the sidebar.
        XCTAssertFalse(replica.sidebar.contains { $0.id.kind == .boost })
    }

    func testTheLaterChangeWinsAndTheLaterUseWins() throws {
        var a = SyncReplica(device: UUID()), b = SyncReplica(device: UUID())
        let id = SyncRecordID(.boost, "example.com")
        let fromA = try a.edit(id, [.value: .boost(BoostSyncPayload(changed: 2_000, css: "a"))], now: 10)
        let fromB = try b.edit(id, [.value: .boost(BoostSyncPayload.removal(at: Date(timeIntervalSince1970: 1)))], now: 20)
        try a.receive([fromB], now: 30); try b.receive([fromA], now: 30)
        for r in [a, b] { XCTAssertEqual(r.records[id]?[.value], .boost(BoostSyncPayload(changed: 2_000, css: "a"))) }
        // Uses: the later one, whichever Mac said it last.
        let row = SyncRecordID(.row, "item:x")
        let late = try a.edit(row, [.used: .time(9_000)], now: 40)
        let early = try b.edit(row, [.used: .time(5_000)], now: 50)
        try a.receive([early], now: 60); try b.receive([late], now: 60)
        for r in [a, b] { XCTAssertEqual(r.records[row]?[.used], .time(9_000)) }
    }

    // MARK: Consent

    func testCodeFromAnotherMacIsHeldUntilAllowedHere() throws {
        let p = BoostSyncPayload(changed: 1_000, css: "a", js: code, scriptHost: "www.example.com", allowedOn: "A's Mac")
        // New here: style taken, code held, naming the Mac it was allowed on.
        let fresh = p.boost(domain: "example.com", existing: nil)
        XCTAssertEqual(fresh.css, "a")
        XCTAssertEqual(fresh.js, "")
        XCTAssertEqual(fresh.heldCode, BoostHeldCode(js: code, scriptHost: "www.example.com", allowedOn: "A's Mac"))
        XCTAssertFalse(fresh.scriptRuns(onHost: "www.example.com"))
        XCTAssertFalse(fresh.isEmpty, "held code alone keeps a Boost")
        // Already allowed here, byte for byte, same host: keeps running.
        let running = Boost(domain: "example.com", js: code, scriptHost: "www.example.com")
        let kept = p.boost(domain: "example.com", existing: running)
        XCTAssertEqual(kept.js, code)
        XCTAssertNil(kept.heldCode)
        // Another host, or other code: the old code stops and the new one waits.
        let moved = BoostSyncPayload(changed: 1_000, js: code, scriptHost: "app.example.com", allowedOn: "A's Mac")
        XCTAssertEqual(moved.boost(domain: "example.com", existing: running).js, "")
        XCTAssertNotNil(moved.boost(domain: "example.com", existing: running).heldCode)
        // The same held code stays held, still naming the first Mac that vouched.
        let again = BoostSyncPayload(changed: 2_000, css: "b", js: code, scriptHost: "www.example.com", allowedOn: "C's Mac")
        XCTAssertEqual(again.boost(domain: "example.com", existing: fresh).heldCode?.allowedOn, "A's Mac")
        // No Mac vouched: held without a name (the full review).
        XCTAssertNil(BoostSyncPayload(changed: 1, js: code).boost(domain: "example.com", existing: nil).heldCode?.allowedOn)
        // A site that is one exact host: no host.
        XCTAssertNil(BoostSyncPayload(changed: 1, js: code, scriptHost: "192.0.2.1").boost(domain: "192.0.2.1", existing: nil).heldCode?.scriptHost)
        // Without a suffix list every site is one exact host: code allowed here for a host still counts as the same code.
        PublicSuffixList.use(PublicSuffixList(text: ""))
        XCTAssertEqual(p.boost(domain: "example.com", existing: running).js, code)
        XCTAssertNil(p.boost(domain: "example.com", existing: running).heldCode)
        TestSuffixes.install()

        // The store: allowing runs it; a held Boost sends its held code with the first Mac's name.
        let store = BoostStore(url: nil)
        store.applySynced(fresh)
        XCTAssertEqual(SyncBoosts.payloads(store, thisMac: "B's Mac")["example.com"]?.allowedOn, "A's Mac")
        XCTAssertEqual(SyncBoosts.payloads(store, thisMac: "B's Mac")["example.com"]?.js, code)
        XCTAssertTrue(store.allowHeldCode(domain: "example.com"))
        XCTAssertTrue(store.boost(domain: "example.com")!.scriptRuns(onHost: "www.example.com"))
        XCTAssertEqual(SyncBoosts.payloads(store, thisMac: "B's Mac")["example.com"]?.allowedOn, "B's Mac")
        XCTAssertFalse(store.allowHeldCode(domain: "example.com"))
    }

    func testAnOlderBuildNeverRunsHeldCodeAndTombstonesPersist() throws {
        let folder = root.appendingPathComponent("file")
        let url = folder.appendingPathComponent("Boosts.json")
        let store = BoostStore(url: url)
        store.applySynced(BoostSyncPayload(changed: 1_000, js: code, allowedOn: "A's Mac").boost(domain: "example.com", existing: nil))
        store.update(domain: "other.example") { $0.css = "x" }
        store.remove(domain: "other.example")
        XCTAssertTrue(store.flush())
        // This build reads both back.
        let again = BoostStore(url: url)
        XCTAssertEqual(again.boost(domain: "example.com")?.heldCode?.js, code)
        XCTAssertNotNil(again.removed["other.example"])
        XCTAssertEqual(SyncBoosts.payloads(again, thisMac: "B's Mac")["other.example"]?.removed, true)
        // An older build reads the Boost without `heldCode` (it doesn't know the key): nothing runs.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var list = try XCTUnwrap(json["boosts"] as? [[String: Any]])
        for i in list.indices { list[i]["heldCode"] = nil }
        json["boosts"] = list
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let older = try XCTUnwrap(BoostStore(url: url).boost(domain: "example.com"))
        XCTAssertNil(older.heldCode)
        XCTAssertFalse(older.scriptRuns(onHost: "example.com"))
        XCTAssertFalse(older.scriptRuns(onHost: "www.example.com"))
    }

    // MARK: Two Macs

    func testABoostFromOneMacArrivesWithItsCodeWaitingForAOneClickConfirm() async throws {
        let (a, b, db) = try await pair()
        a.boosts.update(domain: "example.com") { $0.colors.tint = 0.5; $0.css = "body { color: teal }"; $0.js = self.code; $0.scriptHost = "www.example.com" }
        a.boosts.update(domain: "example.org") { $0.colors.invert = true }
        a.engine.boostsChanged()
        await a.sync(); await b.sync()

        let got = try XCTUnwrap(b.boost("example.com"))
        XCTAssertEqual(got.colors.tint, 0.5)
        XCTAssertEqual(got.css, "body { color: teal }")
        XCTAssertEqual(got.js, "", "code from another Mac never runs by itself")
        XCTAssertEqual(got.heldCode, BoostHeldCode(js: code, scriptHost: "www.example.com", allowedOn: "A's Mac"))
        XCTAssertFalse(got.scriptRuns(onHost: "www.example.com"))
        XCTAssertEqual(b.boost("example.org")?.colors.invert, true)
        // Version 5 batches only; nothing readable in iCloud.
        let all = try await opened(db, a)
        XCTAssertEqual(Set(all.filter { $0.ops.contains { $0.record.kind == .boost } }.map(\.version)), [5])
        XCTAssertFalse(all.contains { $0.version != 5 && $0.ops.contains { $0.record.kind == .boost } })
        for e in await batches(db) {
            let raw = String(decoding: e.sealed, as: UTF8.self)
            XCTAssertFalse(raw.contains("example") || raw.contains("teal"))
        }
        // No echo: B sends nothing back for what it applied.
        let before = await batches(db).count
        await b.sync(); await a.sync()
        let after = await batches(db).count
        XCTAssertEqual(before, after)

        // B allows it: it runs on B. Nothing changes on A, whose code is the same.
        XCTAssertTrue(b.boosts.allowHeldCode(domain: "example.com"))
        b.engine.boostsChanged()
        await b.sync(); await a.sync()
        XCTAssertTrue(try XCTUnwrap(b.boost("example.com")).scriptRuns(onHost: "www.example.com"))
        XCTAssertTrue(try XCTUnwrap(a.boost("example.com")).scriptRuns(onHost: "www.example.com"))
        XCTAssertNil(a.boost("example.com")?.heldCode)

        // A changes the style only: B's allowed code keeps running.
        try await later()
        a.boosts.update(domain: "example.com") { $0.colors.tint = 0.2 }
        a.engine.boostsChanged()
        await a.sync(); await b.sync()
        XCTAssertEqual(b.boost("example.com")?.colors.tint, 0.2)
        XCTAssertTrue(try XCTUnwrap(b.boost("example.com")).scriptRuns(onHost: "www.example.com"))
        // A changes the code: B stops the old code and asks again.
        try await later()
        a.boosts.update(domain: "example.com") { $0.js = "console.log('v2')" }
        a.engine.boostsChanged()
        await a.sync(); await b.sync()
        XCTAssertEqual(b.boost("example.com")?.js, "")
        XCTAssertEqual(b.boost("example.com")?.heldCode?.js, "console.log('v2')")

        // B deletes one: gone on A too, and an older copy doesn't bring it back.
        try await later()
        b.boosts.remove(domain: "example.org")
        b.engine.boostsChanged()
        await b.sync(); await a.sync()
        XCTAssertNil(a.boost("example.org"))
        XCTAssertNotNil(a.boosts.removed["example.org"])
    }

    func testTheSwitchAndAValueThisMacCantApplyYet() async throws {
        let (a, b, _) = try await pair()
        b.engine.setSyncsBoosts(false)
        XCTAssertFalse(b.engine.syncsBoosts)
        a.boosts.update(domain: "example.com") { $0.css = "a" }
        b.boosts.update(domain: "example.net") { $0.css = "b" }
        a.engine.boostsChanged(); b.engine.boostsChanged()
        await a.sync(); await b.sync(); await a.sync()
        XCTAssertNil(b.boost("example.com"), "off: nothing applied")
        XCTAssertNil(a.boost("example.net"), "off: nothing sent")
        // On again: both ways. A site the app can't take now waits and is tried again.
        b.refuse = ["example.com"]
        b.engine.setSyncsBoosts(true)
        await b.sync(); await a.sync()
        XCTAssertEqual(a.boost("example.net")?.css, "b")
        XCTAssertNil(b.boost("example.com"))
        b.refuse = []
        await b.sync()
        XCTAssertEqual(b.boost("example.com")?.css, "a")
    }

    func testAnOlderBuildKeepsBoostBatchesUnread() async throws {
        let (a, _, db) = try await pair()
        a.boosts.update(domain: "example.com") { $0.css = "a" }
        a.engine.boostsChanged()
        await a.sync()
        let key = try XCTUnwrap(a.keys.key(group: XCTUnwrap(a.engine.groupID)))
        let v5 = await batches(db).filter { $0.version == 5 }
        XCTAssertEqual(v5.count, 1)
        XCTAssertThrowsError(try v5[0].open(group: v5[0].group, key: key, accepting: 1...4))
        // Every other batch still opens there: the sidebar keeps syncing with an older build.
        for e in await batches(db) where e.version < 5 { XCTAssertNoThrow(try e.open(group: e.group, key: key, accepting: 1...4)) }
    }

    // MARK: Archive timing

    func testATabUnpinnedElsewhereContinuesItsArchiveTimerFromTheLastUse() async throws {
        let (a, b, db) = try await pair { a, _ in
            let work = a.space("Work")!
            let t = try a.store.openTab(url: "https://example.com/doc", inSpace: work.id)
            try a.store.togglePin(t.id, inSpace: work.id)
        }
        let item = try XCTUnwrap(b.store.state.items.values.first { $0.savedURL == "https://example.com/doc" })
        // B opens the pinned tab now (t0); A uses it two hours later (t1), then unpins it.
        let onB = try b.store.openItem(item.id, inSpace: b.space("Work")!.id)
        let t0 = try XCTUnwrap(b.store.tab(onB.id)).lastActiveAt
        clock.advance(2 * 3600)
        let aItem = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/doc" })
        let onA = try XCTUnwrap(a.store.liveTab(forItem: aItem.id))
        try a.store.activate(onA.id, inSpace: a.space("Work")!.id)
        let t1 = try XCTUnwrap(a.store.tab(onA.id)).lastActiveAt
        XCTAssertGreaterThan(t1, t0)
        clock.advance(600)
        try a.store.togglePin(onA.id, inSpace: a.space("Work")!.id)
        await a.sync(); await b.sync()

        let tab = try XCTUnwrap(b.store.tab(onB.id))
        XCTAssertTrue(tab.isToday, "its page stays on B as a Today tab")
        XCTAssertEqual(tab.lastActiveAt.timeIntervalSince1970, t1.timeIntervalSince1970, accuracy: 0.01,
                       "the timer continues from A's later use, not B's")
        let after = b.store.profile(tab.profileID)!.archiveAfter.seconds
        XCTAssertEqual(try XCTUnwrap(b.store.nextAutoArchiveDate()).timeIntervalSince1970, t1.addingTimeInterval(after).timeIntervalSince1970, accuracy: 0.01)
        // The time went in a version 5 batch of its own; the unpin itself in a version 1 batch, which an older build reads.
        let all = try await opened(db, a)
        XCTAssertEqual(Set(all.filter { $0.ops.contains { $0.fields[.used] != nil } }.map(\.version)), [5])
        XCTAssertTrue(all.contains { $0.version == 1 && $0.ops.contains { $0.fields[.location] == .location(.archived) } })

        // A use on B later than A's is never moved back.
        clock.advance(60)
        try b.store.activate(onB.id, inSpace: b.space("Work")!.id)
        let mine = try XCTUnwrap(b.store.tab(onB.id)).lastActiveAt
        await b.sync()
        XCTAssertEqual(b.store.tab(onB.id)?.lastActiveAt, mine)
    }

    func testAUseFromAMacWhoseClockRunsAheadIsCappedAtNow() throws {
        let store = try makeStore(clock)
        let space = store.orderedSpaces[0]
        let t = try store.openTab(url: "https://example.com/", inSpace: space.id)
        var adapter = SyncStoreAdapter()
        var replica = SyncReplica()
        try adapter.capture(store.state, into: &replica, now: 1)
        let record = try XCTUnwrap(adapter.record(forTab: t.id))
        try replica.edit(SyncRecordID(.row, record), [.used: .time(Int64((clock.date.timeIntervalSince1970 + 86_400) * 1000))], now: 2)
        clock.advance(10)
        XCTAssertTrue(try store.applySyncedUses(replica, adapter: adapter))
        XCTAssertEqual(store.tab(t.id)?.lastActiveAt, clock.date)
        XCTAssertFalse(try store.applySyncedUses(replica, adapter: adapter), "nothing later to take")
    }
}
