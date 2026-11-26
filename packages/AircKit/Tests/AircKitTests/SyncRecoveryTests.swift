// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import XCTest
@testable import AircKit

/// One "Mac" (as in SyncEngineTests): its own store, fake keychain, state file and engine, on a shared mock database.
@MainActor
private final class RecoveryMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let folder: URL
    let db: SyncMockCloudDatabase
    let name: String
    var engine: SyncEngine!
    var backupFails = false
    private(set) var backups = 0

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name; self.db = db
        folder = root.appendingPathComponent(name)
        store = try makeStore(clock)
        relaunch()
    }

    func relaunch() {
        let store = store, folder = folder, db = db
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: name + "'s Mac", machine: name,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { [unowned self] in
                if backupFails { throw CocoaError(.fileWriteNoPermission) }
                backups += 1
                return try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud)
            })
        env.sleep = { _ in }
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    var spaceNames: [String] { store.orderedSpaces.map(\.name).sorted() }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    var savedURLs: Set<String> { Set(store.state.items.values.compactMap(\.savedURL)) }

    func pin(_ url: String, in space: String) throws {
        let id = try XCTUnwrap(self.space(space)).id
        let tab = try store.openTab(url: url, inSpace: id)
        try store.move(.tab(tab.id), to: .pinned(spaceID: id, parentID: nil, index: 0))
    }

    /// The key is gone from this Mac (Keychain reset, a restore without iCloud Keychain), and the app started again.
    func loseKey() throws {
        for group in keys.groups { try keys.removeUnused(group: group) }
        relaunch()
    }
}

@MainActor
final class SyncRecoveryTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-recovery-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func seedWork(_ mac: RecoveryMac) throws {
        let work = try mac.store.createSpace(name: "Work", icon: .emoji("💼"))
        for url in ["https://example.com/a", "https://example.com/b"] {
            let tab = try mac.store.openTab(url: url, inSpace: work.id)
            try mac.store.move(.tab(tab.id), to: .pinned(spaceID: work.id, parentID: nil, index: 0))
        }
        let fav = try mac.store.openTab(url: "https://mail.example.com", inSpace: work.id)
        try mac.store.move(.tab(fav.id), to: .favorites(profileID: mac.store.defaultProfile.id, index: 0))
    }

    private func groupRecord(_ db: SyncMockCloudDatabase) async -> SyncGroupRecord? {
        await db.state.records(zone: SyncCloudSchema.zone).first { $0.name == SyncCloudSchema.groupRecordName }
            .flatMap(SyncCloudSchema.group)
    }

    /// A and B synced with each other (B merged), both up to date.
    private func twoSyncedMacs(_ db: SyncMockCloudDatabase) async throws -> (RecoveryMac, RecoveryMac) {
        let a = try RecoveryMac("A", db: db, root: root, clock: clock), b = try RecoveryMac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        await b.turnOn()
        b.keys.copy(from: a.keys)
        await b.engine.syncNow()
        try await b.engine.choose(.merge)
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertEqual(a.spaceNames, b.spaceNames)
        return (a, b)
    }

    // MARK: The key

    func testRecoveryKeyRoundTripsAndForgivesHowItIsTyped() throws {
        let key = SymmetricKey(size: .bits256)
        let text = SyncRecoveryKey.format(key)
        let groups = text.split(separator: "-")
        XCTAssertEqual(groups.count, 14)
        XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
        XCTAssertFalse(text.contains { "ILOU".contains($0) }, "Crockford base32: no I, L, O or U")
        let raw = key.withUnsafeBytes { Data($0) }
        for typed in [text, text.lowercased(), text.replacingOccurrences(of: "-", with: " "),
                      text.replacingOccurrences(of: "-", with: ""), "  " + text + "\n",
                      text.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")] {
            XCTAssertEqual(try SyncRecoveryKey.parse(typed).withUnsafeBytes { Data($0) }, raw, typed)
        }
        // One character wrong, one missing, one extra, a character outside the alphabet: all typos.
        var chars = Array(text)
        let i = chars.firstIndex { $0 != "-" }!
        chars[i] = chars[i] == "A" ? "B" : "A"
        for bad in [String(chars), String(text.dropLast()), text + "A", text.replacingCharacters(in: text.startIndex...text.startIndex, with: "U"), ""] {
            XCTAssertThrowsError(try SyncRecoveryKey.parse(bad), bad) { XCTAssertEqual($0 as? SyncRecoveryKey.ParseError, .malformed) }
        }
    }

    // MARK: Pairing without iCloud Keychain

    func testAMacWithoutICloudKeychainJoinsWithTheRecoveryKey() async throws {
        let db = SyncMockCloudDatabase()
        let a = try RecoveryMac("A", db: db, root: root, clock: clock), b = try RecoveryMac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID)
        let text = try XCTUnwrap(try a.engine.recoveryKey())
        XCTAssertNil(try b.engine.recoveryKey(), "no key, nothing to show")

        _ = try b.store.createSpace(name: "Laptop")
        try b.pin("https://example.org/laptop", in: "Laptop")
        await b.turnOn()
        XCTAssertEqual(b.engine.status, .waitingForKeychain, "iCloud Keychain is off here: the key never comes")

        // A typo, then another sync's key: refused, nothing changes.
        do { try await b.engine.useRecoveryKey("ABCD-EFGH"); XCTFail("a typo") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .malformed) }
        do { try await b.engine.useRecoveryKey(SyncRecoveryKey.format(SymmetricKey(size: .bits256))); XCTFail("another key") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .otherGroup) }
        XCTAssertEqual(b.keys.groups, [])
        XCTAssertEqual(b.engine.status, .waitingForKeychain)

        try await b.engine.useRecoveryKey(text.lowercased().replacingOccurrences(of: "-", with: " "))
        XCTAssertEqual(b.keys.groups, [group], "kept in this Mac's keychain, like iCloud Keychain's")
        await b.engine.syncNow()
        guard case .choosing(let preview) = b.engine.status else { return XCTFail("expected the first-sync screen, got \(b.engine.status)") }
        XCTAssertFalse(preview.restartedElsewhere)
        XCTAssertEqual(b.backups, 0, "nothing changed yet")
        try await b.engine.choose(.merge)
        XCTAssertEqual(b.backups, 1, "the first sync's backup, as always")
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertTrue(b.savedURLs.isSuperset(of: ["https://example.com/a", "https://example.com/b", "https://example.org/laptop"]))
        XCTAssertEqual(try b.engine.recoveryKey(), text, "the same key on both Macs")

        await a.engine.syncNow()
        XCTAssertTrue(a.savedURLs.contains("https://example.org/laptop"))

        // Not waiting any more: the key isn't asked for again.
        do { try await b.engine.useRecoveryKey(text); XCTFail("not waiting") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .notWaiting) }
    }

    func testAMacThatLostItsKeyResumesWithTheRecoveryKeyAndSendsWhatItDidMeanwhile() async throws {
        let db = SyncMockCloudDatabase()
        let (a, b) = try await twoSyncedMacs(db)
        let text = try XCTUnwrap(try a.engine.recoveryKey())
        try b.loseKey()
        try b.pin("https://example.com/while-locked-out", in: "Work")
        let batches = await db.state.batchCount
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.status, .waitingForKeychain)
        XCTAssertTrue(b.engine.hasJoined, "it stays in its sync")
        let after = await db.state.batchCount
        XCTAssertEqual(after, batches, "nothing goes up without the key")
        XCTAssertTrue(b.savedURLs.contains("https://example.com/while-locked-out"), "and nothing changes here")

        try await b.engine.useRecoveryKey(text)
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertEqual(b.backups, 1, "no new first sync: only the first one's backup")
        await a.engine.syncNow()
        XCTAssertTrue(a.savedURLs.contains("https://example.com/while-locked-out"))
        XCTAssertEqual(a.spaceNames, b.spaceNames)
    }

    // MARK: Starting over

    func testStartOverWithAFailedBackupChangesNothing() async throws {
        let db = SyncMockCloudDatabase()
        let a = try RecoveryMac("A", db: db, root: root, clock: clock), b = try RecoveryMac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        let before = await groupRecord(db)
        let batches = await db.state.batchCount
        await b.turnOn()
        b.backupFails = true
        do { try await b.engine.startOver(); XCTFail("no backup, no start over") }
        catch { XCTAssertTrue(error is SyncFirstSyncBackupFailure, "\(error)") }
        XCTAssertEqual(b.engine.status, .waitingForKeychain)
        XCTAssertEqual(b.keys.groups, [], "no key made")
        let group = await groupRecord(db)
        XCTAssertEqual(group, before, "iCloud's group stays")
        let after = await db.state.batchCount
        XCTAssertEqual(after, batches, "nothing of this Mac went up")
        XCTAssertFalse(b.engine.hasJoined)

        // And never while this Mac has the key.
        b.backupFails = false
        b.keys.copy(from: a.keys)
        do { try await b.engine.startOver(); XCTFail("it has the key") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .notWaiting) }
        await a.engine.syncNow()
        do { try await a.engine.startOver(); XCTFail("up to date") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .notWaiting) }
        let still = await groupRecord(db)
        XCTAssertEqual(still, before)
    }

    func testStartOverAndTheOtherMacRejoinsKeepingEverything() async throws {
        let db = SyncMockCloudDatabase()
        let (a, b) = try await twoSyncedMacs(db)
        let old = try XCTUnwrap(a.engine.groupID)
        let spacesBefore = a.spaceNames
        // The key is lost on B; A is off somewhere with edits that never reached iCloud.
        try b.loseKey()
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.status, .waitingForKeychain)
        try b.pin("https://example.com/b-after-restart", in: "Work")
        let backup = try await b.engine.startOver()
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(b.engine.status, .upToDate)
        let new = try XCTUnwrap(b.engine.groupID)
        XCTAssertNotEqual(new, old)
        let record = await groupRecord(db)
        XCTAssertEqual(record?.group, new)
        XCTAssertEqual(b.keys.groups, [new])
        let oldBatches = await db.state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.envelope).filter { $0.group == old }
        XCTAssertFalse(oldBatches.isEmpty, "nothing in iCloud is deleted")
        XCTAssertEqual(b.engine.unreadableBatches, 0, "the old group's records aren't this sync's, and aren't 'unreadable'")
        XCTAssertNotNil(try b.engine.recoveryKey())

        try a.pin("https://example.com/a-offline", in: "Work")
        try a.store.updateSpace(a.space("Work")!.id) { $0.name = "Work (A)" }
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .waitingForKeychain, "A rejoins the new sync and waits for its key")
        XCTAssertFalse(a.engine.hasJoined)
        XCTAssertEqual(a.engine.groupID, nil)
        XCTAssertTrue(a.savedURLs.contains("https://example.com/a-offline"), "its sidebar stays as it is")
        XCTAssertEqual(a.keys.groups, [old], "the old key stays (deleting it would delete it everywhere)")

        a.keys.copy(from: b.keys)   // iCloud Keychain (or B's recovery key)
        await a.engine.syncNow()
        guard case .choosing(let preview) = a.engine.status else { return XCTFail("expected the first-sync screen, got \(a.engine.status)") }
        XCTAssertTrue(preview.restartedElsewhere)
        XCTAssertEqual(preview.profiles, [])
        try await a.engine.choose(.merge)
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(a.spaceNames, spacesBefore.map { $0 == "Work" ? "Work (A)" : $0 }.sorted(),
                       "the same Spaces, nothing twice, and A's rename made while it was away wins (it's later)")
        XCTAssertTrue(a.savedURLs.isSuperset(of: ["https://example.com/a-offline", "https://example.com/b-after-restart"]))
        await b.engine.syncNow()
        XCTAssertEqual(b.spaceNames, a.spaceNames)
        XCTAssertEqual(b.savedURLs, a.savedURLs)
        XCTAssertEqual(Set(b.engine.devices.map(\.name)), ["A's Mac", "B's Mac"])
        let pinnedA = a.store.state.items.values.filter { $0.savedURL != nil }.count
        let pinnedB = b.store.state.items.values.filter { $0.savedURL != nil }.count
        XCTAssertEqual(pinnedA, pinnedB, "no duplicate rows either way")

        // A relaunch on either side changes nothing.
        a.relaunch(); b.relaunch()
        a.engine.setEnabled(true); b.engine.setEnabled(true)
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testAJoinedMacWithoutAKeyNoticesAStartOverAndCanJoinWithTheNewRecoveryKey() async throws {
        let db = SyncMockCloudDatabase()
        let (a, b) = try await twoSyncedMacs(db)
        // Both lost the key: nobody can read the sync.
        try a.loseKey(); try b.loseKey()
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(a.engine.status, .waitingForKeychain)
        try await b.engine.startOver()
        let text = try XCTUnwrap(try b.engine.recoveryKey())
        // A is still waiting for the old key; its next check sees the new group and rejoins it.
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .waitingForKeychain)
        XCTAssertFalse(a.engine.hasJoined)
        try await a.engine.useRecoveryKey(text)
        await a.engine.syncNow()
        guard case .choosing(let preview) = a.engine.status else { return XCTFail("expected the first-sync screen, got \(a.engine.status)") }
        XCTAssertTrue(preview.restartedElsewhere)
        try await a.engine.choose(.merge)
        await b.engine.syncNow()
        XCTAssertEqual(a.spaceNames, b.spaceNames)
        XCTAssertEqual(a.savedURLs, b.savedURLs)
    }

    func testARecoveryKeyFromBeforeAStartOverIsRefused() async throws {
        let db = SyncMockCloudDatabase()
        let (a, b) = try await twoSyncedMacs(db)
        let oldText = try XCTUnwrap(try a.engine.recoveryKey())
        try b.loseKey()
        await b.engine.syncNow()
        try await b.engine.startOver()
        let c = try RecoveryMac("C", db: db, root: root, clock: clock)
        await c.turnOn()
        XCTAssertEqual(c.engine.status, .waitingForKeychain)
        do { try await c.engine.useRecoveryKey(oldText); XCTFail("the old sync's key") }
        catch { XCTAssertEqual(error as? SyncRecoveryFailure, .otherGroup) }
        try await c.engine.useRecoveryKey(XCTUnwrap(try b.engine.recoveryKey()))
        await c.engine.syncNow()
        guard case .choosing(let preview) = c.engine.status else { return XCTFail("expected the first-sync screen, got \(c.engine.status)") }
        XCTAssertFalse(preview.restartedElsewhere, "a new Mac: the usual screen")
    }

    func testAStartOverThatLosesTheRaceJoinsTheWinner() async throws {
        let db = SyncMockCloudDatabase()
        let a = try RecoveryMac("A", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        let first = try XCTUnwrap(a.engine.groupID)
        // The transport refuses to replace a group that isn't the one it was asked to replace.
        let t = CloudKitSyncTransport(database: db, device: UUID(), backoff: [0], sleep: { _ in })
        try await t.prepare()
        let other = UUID(), key = SymmetricKey(size: .bits256)
        let lost = try await t.replaceGroup(try SyncGroupRecord.make(group: other, key: key, created: Date()), replacing: UUID())
        XCTAssertEqual(lost.group, first, "someone else's group is on the server: it stays")
        let won = try await t.replaceGroup(try SyncGroupRecord.make(group: other, key: key, created: Date()), replacing: first)
        XCTAssertEqual(won.group, other)
        // A had the first group: its next read sees the other one and rejoins (never stops, never wipes).
        let urls = a.savedURLs
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .waitingForKeychain)
        XCTAssertTrue(a.engine.isEnabled)
        XCTAssertEqual(a.savedURLs, urls)
    }

    func testAZoneResetToAnotherGroupRejoinsInsteadOfTurningSyncOff() async throws {
        let db = SyncMockCloudDatabase()
        let a = try RecoveryMac("A", db: db, root: root, clock: clock), b = try RecoveryMac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        // The zone is reset (CloudKit console) and another Mac sets up a new sync before A notices.
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }
        _ = try b.store.createSpace(name: "Fresh")
        await b.turnOn()
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertNotEqual(b.engine.groupID, a.engine.groupID)
        let urls = a.savedURLs
        await a.engine.syncNow()
        XCTAssertTrue(a.engine.isEnabled, "before: it turned itself off")
        XCTAssertEqual(a.engine.status, .waitingForKeychain)
        XCTAssertEqual(a.savedURLs, urls)
        a.keys.copy(from: b.keys)
        await a.engine.syncNow()
        guard case .choosing(let preview) = a.engine.status else { return XCTFail("expected the first-sync screen, got \(a.engine.status)") }
        XCTAssertTrue(preview.restartedElsewhere)
        try await a.engine.choose(.merge)
        await b.engine.syncNow()
        XCTAssertTrue(b.savedURLs.isSuperset(of: urls))
        XCTAssertTrue(a.spaceNames.contains("Fresh"))
    }
}
