// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CloudKit
import CryptoKit
import XCTest
@testable import AircKit

private struct SyncRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}

/// Waits the transport asked for, without waiting.
private final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var recorded: [Double] { lock.withLock { values } }
    var sleep: @Sendable (Double) async -> Void { { [self] s in lock.withLock { values.append(s) } } }
}

final class SyncCloudTransportTests: XCTestCase {
    private func envelope(_ replica: inout SyncReplica, group: UUID, key: SymmetricKey, name: String) throws -> SyncEnvelope {
        let op = try replica.edit(.init(.space, name), [.name: .text(name)], now: 1)
        return try SyncEnvelope.seal([op], group: group, device: replica.clock.device, key: key)
    }

    private func transport(_ db: SyncMockCloudDatabase, _ device: UUID, sleeps: Sleeps = Sleeps(),
                           backoff: [Double] = [0.5, 1, 2]) -> CloudKitSyncTransport {
        CloudKitSyncTransport(database: db, device: device, backoff: backoff, sleep: sleeps.sleep)
    }

    func testRecordMappingRoundTripsAndRejectsForeignNames() throws {
        var replica = SyncReplica()
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let e = try envelope(&replica, group: group, key: key, name: "work")
        let record = SyncCloudSchema.record(e)
        XCTAssertEqual(record.type, "SyncBatch")
        XCTAssertEqual(record.name, e.device.uuidString + "." + e.id.uuidString)
        XCTAssertEqual(Set(record.fields.keys), ["group", "device", "envelope", "version", "sealed"])
        XCTAssertEqual(SyncCloudSchema.envelope(record), e)
        // A batch under another device's name, or with a field changed, is not read.
        var renamed = record; renamed.name = UUID().uuidString + "." + e.id.uuidString
        XCTAssertNil(SyncCloudSchema.envelope(renamed))
        var foreign = record; foreign.fields["device"] = .string(UUID().uuidString)
        XCTAssertNil(SyncCloudSchema.envelope(foreign))
        var broken = record; broken.fields["sealed"] = .string("x")
        XCTAssertNil(SyncCloudSchema.envelope(broken))
        // Only ciphertext and identifiers: the Space name isn't in the record.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(record), as: UTF8.self).contains("work"))

        let g = try SyncGroupRecord.make(group: group, key: key, created: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(SyncCloudSchema.group(SyncCloudSchema.record(g)), g)
        XCTAssertTrue(g.verifies(key))
        XCTAssertFalse(g.verifies(SyncEnvelope.newGroupKey()))
        let d = SyncDeviceRecord(group: group, device: UUID(), sealed: Data([1, 2]), seen: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(SyncCloudSchema.device(SyncCloudSchema.record(d)), d)
        XCTAssertEqual(SyncCloudSchema.record(d).name, "device." + d.device.uuidString)
    }

    func testCloudKitRecordAndErrorMapping() throws {
        let zone = CKRecordZone.ID(zoneName: SyncCloudSchema.zone, ownerName: CKCurrentUserDefaultName)
        var replica = SyncReplica()
        let e = try envelope(&replica, group: UUID(), key: SyncEnvelope.newGroupKey(), name: "home")
        let ck = CloudKitSyncDatabase.record(SyncCloudSchema.record(e), zone: zone)
        XCTAssertEqual(ck.recordType, "SyncBatch")
        XCTAssertEqual(ck.recordID.zoneID.zoneName, "AircSidebar")
        XCTAssertEqual(CloudKitSyncDatabase.record(ck).flatMap(SyncCloudSchema.envelope), e)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let group = try SyncGroupRecord.make(group: UUID(), key: SyncEnvelope.newGroupKey(), created: created)
        XCTAssertEqual(CloudKitSyncDatabase.record(CloudKitSyncDatabase.record(SyncCloudSchema.record(group), zone: zone))
            .flatMap(SyncCloudSchema.group), group)

        func map(_ code: CKError.Code, _ info: [String: Any] = [:]) -> SyncCloudFailure {
            CloudKitSyncDatabase.failure(CKError(code, userInfo: info))
        }
        XCTAssertEqual(map(.networkUnavailable), .network(retryAfter: nil))
        XCTAssertEqual(map(.requestRateLimited, [CKErrorRetryAfterKey: 7.0]), .network(retryAfter: 7))
        XCTAssertEqual(map(.serviceUnavailable), .network(retryAfter: nil))
        XCTAssertEqual(map(.notAuthenticated), .notSignedIn)
        XCTAssertEqual(map(.quotaExceeded), .quotaExceeded)
        XCTAssertEqual(map(.zoneNotFound), .zoneNotFound)
        XCTAssertEqual(map(.userDeletedZone), .userDeletedZone)
        XCTAssertEqual(map(.changeTokenExpired), .changeTokenExpired)
        XCTAssertEqual(map(.serverRecordChanged), .serverRecordChanged)
        XCTAssertEqual(map(.missingEntitlement), .missingEntitlement)
        XCTAssertEqual(map(.unknownItem), .notFound)
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [
            CKRecord.ID(recordName: "a"): CKError(.networkFailure),
            CKRecord.ID(recordName: "b"): CKError(.zoneNotFound),
        ]])
        XCTAssertEqual(CloudKitSyncDatabase.failure(partial), .zoneNotFound)
        XCTAssertEqual(CloudKitSyncDatabase.failure(SyncCloudFailure.quotaExceeded), .quotaExceeded)
        // A test process has no iCloud entitlement: capability detection says so, and nothing touches CloudKit.
        XCTAssertNil(SyncCapability.container)
    }

    func testChangeTokensPageResumeAndRedeliverUntilAcknowledged() async throws {
        let db = SyncMockCloudDatabase()
        await db.change { $0.pageSize = 3 }
        var a = SyncReplica()
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let ta = transport(db, a.clock.device)
        try await ta.prepare()
        for i in 0..<7 { try await ta.append(try envelope(&a, group: group, key: key, name: "s\(i)")) }
        let tb = transport(db, UUID())
        try await tb.prepare()
        let first = try await tb.read()
        XCTAssertEqual(first.count, 7, "every page, in order")
        let awaited1 = await db.count(.fetchChanges)
        XCTAssertEqual(awaited1, 3)
        // Not acknowledged: the same changes again (the engine hadn't saved its merge).
        let awaited2 = try await tb.read().count
        XCTAssertEqual(awaited2, 7)
        await tb.acknowledge()
        let awaited3 = try await tb.read().count
        XCTAssertEqual(awaited3, 0)
        await tb.acknowledge()
        for i in 7..<9 { try await ta.append(try envelope(&a, group: group, key: key, name: "s\(i)")) }
        // A relaunch restores the persisted checkpoint and reads only what's new.
        let saved = await tb.checkpoint
        let relaunched = transport(db, await tb.device)
        await relaunched.restore(checkpoint: saved)
        let later = try await relaunched.read()
        XCTAssertEqual(later.count, 2)
        // Its own batches never come back to a device.
        let awaited4 = try await ta.read().count
        XCTAssertEqual(awaited4, 0)
    }

    func testTransientFailuresRetryWithBackoffAndRetryAfter() async throws {
        let db = SyncMockCloudDatabase()
        let sleeps = Sleeps()
        var a = SyncReplica()
        let t = transport(db, a.clock.device, sleeps: sleeps)
        try await t.prepare()
        await db.fail(.save, with: .network(retryAfter: nil), .network(retryAfter: 4))
        try await t.append(try envelope(&a, group: UUID(), key: SyncEnvelope.newGroupKey(), name: "w"))
        XCTAssertEqual(sleeps.recorded, [0.5, 4])
        let awaited5 = await db.state.batchCount
        XCTAssertEqual(awaited5, 1)
        // More failures than attempts: the caller (the engine) sees it and schedules a later try.
        await db.fail(.fetchChanges, with: .network(retryAfter: nil), .network(retryAfter: nil), .network(retryAfter: nil), .network(retryAfter: nil))
        do { _ = try await t.read(); XCTFail("expected a network failure") }
        catch let f as SyncCloudFailure { XCTAssertEqual(f, .network(retryAfter: nil)) }
    }

    func testPermanentFailuresSurfaceAtOnce() async throws {
        let db = SyncMockCloudDatabase()
        var a = SyncReplica()
        let t = transport(db, a.clock.device)
        try await t.prepare()
        await db.fail(.save, with: .quotaExceeded)
        let e = try envelope(&a, group: UUID(), key: SyncEnvelope.newGroupKey(), name: "w")
        do { try await t.append(e); XCTFail("quota") } catch let f as SyncCloudFailure { XCTAssertEqual(f, .quotaExceeded) }
        let awaited6 = await db.count(.save)
        XCTAssertEqual(awaited6, 1, "no retry for a full iCloud")
        await db.change { $0.account = .noAccount }
        let fresh = transport(db, a.clock.device)
        do { try await fresh.prepare(); XCTFail("signed out") } catch let f as SyncCloudFailure { XCTAssertEqual(f, .notSignedIn) }
        await db.change { $0.account = .restricted }
        do { try await fresh.prepare(); XCTFail("restricted") } catch let f as SyncCloudFailure { XCTAssertEqual(f, .restricted) }
        // A batch uploaded twice (a retry after a lost reply) is one record and no error.
        await db.change { $0.account = .available }
        try await t.append(e)
        try await t.append(e)
        let awaited7 = await db.state.batchCount
        XCTAssertEqual(awaited7, 1)
        do { try await t.append(try SyncEnvelope.seal([], group: UUID(), device: UUID(), key: SyncEnvelope.newGroupKey())); XCTFail() } catch {}
    }

    func testMissingZoneIsCreatedAndEveryResetIsReported() async throws {
        let db = SyncMockCloudDatabase()
        var a = SyncReplica()
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let ta = transport(db, a.clock.device), tb = transport(db, UUID())
        try await ta.prepare(); try await tb.prepare()
        let one = try envelope(&a, group: group, key: key, name: "one")
        try await ta.append(one)
        let first = try await tb.read().count
        XCTAssertEqual(first, 1); await tb.acknowledge()
        _ = await ta.takeReadReport()
        // Saving into a zone that's gone recreates it and saves, and says so (until the engine takes the report).
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }
        let two = try envelope(&a, group: group, key: key, name: "two")
        try await ta.append(two)
        let afterSave = await db.state.batchCount
        XCTAssertEqual(afterSave, 1)
        _ = try await ta.read()
        let saved = await ta.takeReadReport()
        XCTAssertTrue(saved.zoneRecreated, "the save recreated the zone; a read after it doesn't clear that")
        XCTAssertTrue(saved.full, "its token belonged to the old zone")
        XCTAssertEqual(saved.own, [two.id], "one own batch survived: not proof the older ones did")
        let taken = await ta.takeReadReport()
        XCTAssertFalse(taken.zoneRecreated)
        // Another reader whose token belongs to the old zone reads everything again (a full read).
        let again = try await tb.read()
        XCTAssertEqual(again.count, 1)
        let full = await tb.takeReadReport()
        XCTAssertTrue(full.full)
        XCTAssertEqual(full.own, [])
        await tb.acknowledge()
        // Reading a zone that's gone: recreated empty, and reported.
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }
        let empty = try await tb.read().count
        XCTAssertEqual(empty, 0)
        let recreated = await tb.takeReadReport()
        XCTAssertTrue(recreated.zoneRecreated)
        let records = await db.state.records(zone: SyncCloudSchema.zone).count
        XCTAssertEqual(records, 0)
        // Expired tokens: everything again, nothing lost.
        try await ta.append(try envelope(&a, group: group, key: key, name: "three"))
        _ = try await tb.read(); await tb.acknowledge()
        await db.change { $0.expireTokens(SyncCloudSchema.zone) }
        try await ta.append(try envelope(&a, group: group, key: key, name: "four"))
        let expired = try await tb.read().count
        XCTAssertEqual(expired, 2)
    }

    func testAPageWithAFailedRecordKeepsTheTokenAndMalformedBatchesAreReported() async throws {
        let db = SyncMockCloudDatabase()
        var a = SyncReplica()
        let group = UUID(), key = SyncEnvelope.newGroupKey()
        let ta = transport(db, a.clock.device, backoff: [0, 0]), tb = transport(db, UUID(), backoff: [0, 0])
        try await ta.prepare(); try await tb.prepare()
        let e1 = try envelope(&a, group: group, key: key, name: "one"), e2 = try envelope(&a, group: group, key: key, name: "two")
        try await ta.append(e1); try await ta.append(e2)
        await db.failRecords([SyncCloudSchema.batchName(e2)], with: .other("CKError 1"))
        do { _ = try await tb.read(); XCTFail("a page with a failed record must not be returned") }
        catch let f as SyncCloudFailure { XCTAssertEqual(f, .other("CKError 1")) }
        await tb.acknowledge()
        await db.clearRecordFaults()
        let both = try await tb.read()
        XCTAssertEqual(Set(both.map(\.id)), [e1.id, e2.id], "nothing was acknowledged past the failed record")
        await tb.acknowledge()
        // A batch record that can't be parsed is reported, not silently dropped.
        await db.change { try! $0.seed([SyncCloudRecord(name: UUID().uuidString + "." + UUID().uuidString, type: SyncCloudSchema.batch,
                                                        fields: ["group": .string("not a uuid")])], zone: SyncCloudSchema.zone) }
        _ = try await tb.read()
        let report = await tb.takeReadReport()
        XCTAssertEqual(report.malformed.count, 1)
    }

    func testUserDeletedZoneStopsWithoutRecreating() async throws {
        let db = SyncMockCloudDatabase()
        var a = SyncReplica()
        let t = transport(db, a.clock.device)
        try await t.prepare()
        try await t.append(try envelope(&a, group: UUID(), key: SyncEnvelope.newGroupKey(), name: "w"))
        await db.change { $0.deleteZoneAsUser(SyncCloudSchema.zone) }
        for attempt in 0..<2 {
            do {
                if attempt == 0 { _ = try await t.read() } else { try await t.append(try envelope(&a, group: UUID(), key: SyncEnvelope.newGroupKey(), name: "x")) }
                XCTFail("must stop")
            } catch let f as SyncCloudFailure { XCTAssertEqual(f, .userDeletedZone) }
        }
        let awaited16 = await db.state.zones[SyncCloudSchema.zone]
        XCTAssertNil(awaited16, "never recreated without the person asking")
    }

    func testGroupCreationRaceHasOneWinner() async throws {
        let db = SyncMockCloudDatabase()
        let ta = transport(db, UUID()), tb = transport(db, UUID())
        try await ta.prepare(); try await tb.prepare()
        let ka = SyncEnvelope.newGroupKey(), kb = SyncEnvelope.newGroupKey()
        let ga = try SyncGroupRecord.make(group: UUID(), key: ka, created: Date())
        let gb = try SyncGroupRecord.make(group: UUID(), key: kb, created: Date())
        async let first = ta.createGroup(ga)
        async let second = tb.createGroup(gb)
        let (wa, wb) = try await (first, second)
        XCTAssertEqual(wa, wb)
        XCTAssertTrue(wa == ga || wa == gb)
        let awaited17 = try await ta.group()
        XCTAssertEqual(awaited17, wa)
    }

    /// syncspike's randomized convergence, with every exchange through CloudKit transports on one mock database:
    /// small pages, unacknowledged reads (redelivery), transient failures, an expired token.
    func testRandomizedMacsConvergeThroughTheTransport() async throws {
        for seed in 1...12 {
            var rng = SyncRandom(state: UInt64(seed))
            let db = SyncMockCloudDatabase()
            await db.change { $0.pageSize = 4 }
            let group = UUID(), key = SyncEnvelope.newGroupKey()
            var devices = (0..<(2 + seed % 2)).map { _ in SyncReplica() }
            var sent = Array(repeating: Set<UUID>(), count: devices.count)
            let transports = devices.map { transport(db, $0.clock.device, backoff: [0, 0, 0, 0]) }
            for t in transports { try await t.prepare() }
            func upload(_ i: Int) async throws {
                let ops = devices[i].log.filter { $0.stamp.device == devices[i].clock.device && !sent[i].contains($0.id) }
                guard !ops.isEmpty else { return }
                try await transports[i].append(SyncEnvelope.seal(ops, group: group, device: devices[i].clock.device, key: key))
                sent[i].formUnion(ops.map(\.id))
            }
            func download(_ i: Int, acknowledge: Bool) async throws {
                for e in try await transports[i].read() { try devices[i].receive(e.open(group: group, key: key), now: 90) }
                if acknowledge { await transports[i].acknowledge() }
            }
            for step in 0..<120 {
                let i = Int(rng.next() % UInt64(devices.count))
                let row = SyncRecordID(.row, "row-\(rng.next() % 12)")
                let fields: [SyncField: SyncValue]
                switch rng.next() % 6 {
                case 0: fields = [.title: .text(step % 2 == 0 ? "Work" : "Home")]
                case 1: fields = [.location: .location(step % 2 == 0 ? .pinned(space: "work") : .archived)]
                case 2: fields = [.deleted: .flag(step % 3 == 0)]
                case 3: fields = [.parent: .text("row-\(rng.next() % 12)"), .kind: .text("folder")]
                case 4: fields = [.order: .order(try SyncOrder.between(nil, nil))]
                default: fields = [.url: .text("https://example.com"), .kind: .text("tab")]
                }
                try devices[i].edit(row, fields, now: Int64(100 + step % 17))
                if step % 7 == 0 { try await upload(i) }
                if step % 11 == 0 {
                    if rng.next() % 3 == 0 { await db.fail(.fetchChanges, with: .network(retryAfter: nil)) }
                    try await download((i + 1) % devices.count, acknowledge: rng.next() % 4 != 0)
                }
                if step == 60 { await db.change { $0.expireTokens(SyncCloudSchema.zone) } }
            }
            for i in devices.indices { try await upload(i) }
            for i in devices.indices { try await download(i, acknowledge: true) }
            for device in devices.dropFirst() {
                XCTAssertEqual(device.records, devices[0].records, "seed \(seed)")
                XCTAssertEqual(device.sidebar, devices[0].sidebar, "seed \(seed)")
                XCTAssertEqual(device.log, devices[0].log, "seed \(seed)")
            }
        }
    }

    func testPushesOnlyWithTheEntitlementAndTheFallbacksAlways() {
        let push = SyncTriggers.plan(cloudKit: true, pushEntitlement: true)
        let noPush = SyncTriggers.plan(cloudKit: true, pushEntitlement: false)
        XCTAssertTrue(push.registersForPushes)
        XCTAssertFalse(noPush.registersForPushes, "without aps-environment the request would fail")
        XCTAssertFalse(SyncTriggers.plan(cloudKit: false, pushEntitlement: true).registersForPushes, "mock and folder backends")
        for t in [push, noPush] {
            XCTAssertEqual(t.fallbackInterval, 600)
            XCTAssertEqual(t.activationInterval, 20)
            XCTAssertEqual(t.localChangeDelay, 1.5)
        }
        let ours = SyncCloudSchema.subscription
        XCTAssertTrue(SyncTriggers.isSidebarPush(["aps": ["content-available": 1], "ck": ["ce": 2, "fet": ["sid": ours, "zid": "AircSidebar"]]], subscription: ours))
        XCTAssertTrue(SyncTriggers.isSidebarPush(["ck": ["ce": 2]], subscription: ours))
        XCTAssertFalse(SyncTriggers.isSidebarPush(["ck": ["fet": ["sid": "something-else"]]], subscription: ours))
        XCTAssertFalse(SyncTriggers.isSidebarPush(["aps": ["alert": "hi"]], subscription: ours))
    }

    func testFolderTransportIsAGroupToo() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-group-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID()
        let ta = try FolderSyncTransport(folder: root, device: a), tb = try FolderSyncTransport(folder: root, device: b)
        let key = SyncEnvelope.newGroupKey()
        let g = try SyncGroupRecord.make(group: UUID(), key: key, created: Date(timeIntervalSince1970: 1))
        let awaited18 = try await tb.group()
        XCTAssertNil(awaited18)
        let awaited19 = try await ta.createGroup(g)
        XCTAssertEqual(awaited19, g)
        let awaited20 = try await tb.createGroup(try SyncGroupRecord.make(group: UUID(), key: key, created: Date()))
        XCTAssertEqual(awaited20, g)
        try await ta.publish(SyncDeviceRecord(group: g.group, device: a, sealed: Data([1]), seen: Date(timeIntervalSince1970: 2)))
        let awaited21 = await tb.devices.map(\.device)
        XCTAssertEqual(awaited21, [a])
        // The device and group files aren't batch streams.
        let awaited22 = try await tb.read().count
        XCTAssertEqual(awaited22, 0)
    }
}
