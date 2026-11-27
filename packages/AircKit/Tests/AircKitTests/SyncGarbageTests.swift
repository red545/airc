// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import XCTest
@testable import AircKit

/// Clean-up of iCloud records (syncgc, docs/sync.md "Clean-up"): three "Macs" (as in SyncEngineTests and
/// SyncNotesTests) on one mock database, with the engine's clock, horizon and settle delay under the test's control.
@MainActor
private final class GCMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let folder: URL
    let pictures: SyncNotePictureFolder
    let db: SyncMockCloudDatabase
    let name: String
    let clock: TestClock
    var engine: SyncEngine!

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name; self.db = db; self.clock = clock
        folder = root.appendingPathComponent(name)
        pictures = SyncNotePictureFolder(folder: folder.appendingPathComponent("Notes/Images"))
        store = try makeStore(clock)
        relaunch()
    }

    /// A new engine from the state file, as after a quit or a crash.
    func relaunch() {
        let store = store, folder = folder, db = db, clock = clock
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: name + "'s Mac", machine: name,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        env.now = { clock.date }
        env.notePictures = pictures
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    func row(_ note: String) -> Item? { store.state.items.values.first { $0.savedURL == NoteURL.make(note) } }

    func pictureFile(_ file: String) -> URL { folder.appendingPathComponent("Notes/Images").appendingPathComponent(file) }

    func keepPicture(_ bytes: Data) throws -> NoteImage {
        let file = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".png"
        try pictures.save(bytes, file: file)
        return NoteImage(file: file, width: 40, height: 30)
    }
}

@MainActor
final class SyncGarbageTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()
    private let settle = SyncGarbage.settle + 60

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-gc-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    // MARK: Helpers

    /// Macs in one group: the first makes it with `seed`, the others merge.
    private func group(_ names: [String], seed: (GCMac) throws -> Void = { _ in }) async throws -> ([GCMac], SyncMockCloudDatabase) {
        let db = SyncMockCloudDatabase()
        let macs = try names.map { try GCMac($0, db: db, root: root, clock: clock) }
        _ = try macs[0].store.createSpace(name: "Work")
        try seed(macs[0])
        await macs[0].turnOn()
        for mac in macs.dropFirst() {
            mac.keys.copy(from: macs[0].keys)
            await mac.turnOn()
            if case .choosing = mac.engine.status { try await mac.engine.choose(.merge) }
            XCTAssertEqual(mac.engine.status, .upToDate, mac.name)
        }
        await rounds(macs, 1)
        return (macs, db)
    }

    private func rounds(_ macs: [GCMac], _ n: Int) async {
        for _ in 0..<n { for mac in macs { await mac.sync() } }
    }

    private func records(_ db: SyncMockCloudDatabase) async -> [SyncCloudRecord] { await db.state.records(zone: SyncCloudSchema.zone) }
    private func names(_ db: SyncMockCloudDatabase) async -> Set<String> { Set(await records(db).map(\.name)) }
    private func pictureRecords(_ db: SyncMockCloudDatabase) async -> [String] {
        await records(db).filter { $0.type == SyncCloudSchema.noteAsset }.map(\.name).sorted()
    }

    /// One note in Work, written by A (with a picture), then edited on every other Mac in turn: each Mac has a text record.
    private func sharedNote(_ macs: [GCMac], picture bytes: Data = Data("a picture".utf8)) async throws -> (String, NoteImage) {
        let a = macs[0]
        let picture = try a.keepPicture(bytes)
        let id = NoteURL.noteID(try a.store.createNote(inSpace: a.space("Work")!.id).url)!
        a.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Plans"), NoteRun(image: picture)])]))
        await a.sync()
        for mac in macs.dropFirst() {
            await mac.sync()
            clock.advance(1)
            mac.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Plans, " + mac.name), NoteRun(image: picture)])]))
            await mac.sync()
        }
        await rounds(macs, 1)
        for mac in macs { XCTAssertEqual(mac.pictures.data(picture.file), bytes, mac.name) }
        return (id, picture)
    }

    private func textRecords(_ db: SyncMockCloudDatabase, note: String, key: SymmetricKey, group: UUID) async -> [String: Bool] {
        var result: [String: Bool] = [:]
        for record in await records(db) where record.type == SyncCloudSchema.note && record.name.hasSuffix("." + note) {
            result[record.name] = (try? SyncCloudSchema.note(record)?.open(group: group, key: key).removed) == false
        }
        return result
    }

    private func key(_ mac: GCMac) throws -> SymmetricKey { try XCTUnwrap(try mac.keys.key(group: XCTUnwrap(mac.engine.groupID))) }

    // MARK: Records and the older builds' view

    func testAnAckIsADeviceRecordOlderBuildsIgnoreAndItIsSealed() throws {
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID()
        var ack = SyncGCAck()
        ack.notes["n1"] = .init(vector: SyncNoteVector().incremented(device))
        ack.keep = ["noteasset.secret-looking"]
        let record = SyncDeviceRecord(group: group, device: device, sealed: try ack.seal(group: group, device: device, key: key), seen: Date())
        let cloud = SyncCloudSchema.record(ack: record)
        XCTAssertEqual(cloud.type, SyncCloudSchema.device, "an existing record type: no schema change")
        XCTAssertEqual(cloud.name, "ack." + device.uuidString)
        for field in cloud.fields.keys { XCTAssertTrue(SyncCloudSchema.feedKeys.contains(field), field) }
        XCTAssertNil(SyncCloudSchema.device(cloud), "a device mapping (every older build's) skips it")
        XCTAssertEqual(SyncCloudSchema.ack(cloud), record)
        XCTAssertNil(SyncCloudSchema.ack(SyncCloudSchema.record(record)), "a device record isn't an ack")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(cloud), as: UTF8.self).contains("n1"), "only ciphertext")
        XCTAssertEqual(SyncGCAck.open(record, group: group, key: key), ack)
        // Moved to another device, another group or key, or a newer format: not an ack anyone counts.
        var moved = record
        moved.device = UUID()
        XCTAssertNil(SyncGCAck.open(moved, group: group, key: key))
        XCTAssertNil(SyncGCAck.open(record, group: UUID(), key: key))
        XCTAssertNil(SyncGCAck.open(record, group: group, key: SyncEnvelope.newGroupKey()))
        var newer = ack
        newer.format = 2
        let future = SyncDeviceRecord(group: group, device: device, sealed: try newer.seal(group: group, device: device, key: key), seen: Date())
        XCTAssertNil(SyncGCAck.open(future, group: group, key: key))
    }

    func testTheTransportReportsAcksAndTheInventoryAndDeletes() async throws {
        let db = SyncMockCloudDatabase(), me = UUID(), other = UUID(), group = UUID()
        let t = CloudKitSyncTransport(database: db, device: me, backoff: [0], sleep: { _ in })
        try await t.prepare()
        let ack = SyncDeviceRecord(group: group, device: other, sealed: Data([1, 2]), seen: Date())
        let asset = SyncCloudRecord(name: "noteasset.ab", type: SyncCloudSchema.noteAsset, fields: ["group": .string(group.uuidString)])
        await db.change { try? $0.seed([SyncCloudSchema.record(ack: ack), asset], zone: SyncCloudSchema.zone) }
        _ = try await t.read()
        var report = await t.takeReadReport()
        XCTAssertTrue(report.full)
        XCTAssertEqual(report.records["noteasset.ab"], SyncInventoryEntry(type: SyncCloudSchema.noteAsset, group: group.uuidString))
        XCTAssertEqual(report.records["ack." + other.uuidString]?.type, SyncCloudSchema.device)
        let devices = await t.devices
        XCTAssertEqual(devices, [], "an ack isn't a device")
        await t.acknowledge()
        let acks = await t.acks
        XCTAssertEqual(acks, [ack])
        try await t.delete(["noteasset.ab", "ack." + other.uuidString, "never-there"])
        _ = try await t.read()
        report = await t.takeReadReport()
        XCTAssertEqual(report.deleted, ["noteasset.ab", "ack." + other.uuidString])
        await t.acknowledge()
        let left = await t.acks
        XCTAssertEqual(left, [])
        // A rescan reads everything again.
        await t.rescan()
        _ = try await t.read()
        report = await t.takeReadReport()
        XCTAssertTrue(report.full)
    }

    // MARK: Notes and pictures

    func testADeletedNotesTextsAndPictureGoOnceEveryMacAgreedAndTheSettleDelayPassed() async throws {
        let (macs, db) = try await group(["A", "B", "C"])
        let (a, b, c) = (macs[0], macs[1], macs[2])
        let (id, picture) = try await sharedNote(macs)
        let kept = try await sharedNote(macs, picture: Data("another".utf8))
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        var texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 3, "a text record per Mac")
        let picturesBefore = await pictureRecords(db)
        XCTAssertEqual(picturesBefore.count, 2)

        clock.advance(10)
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        await rounds(macs, 3)
        for mac in macs { XCTAssertNil(mac.row(id), mac.name) }
        texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 2, "A's record is its removal now; B's and C's texts wait")
        let early = await pictureRecords(db)
        XCTAssertEqual(early, picturesBefore, "nothing is deleted before the settle delay")
        let deletes = await db.count(.delete)
        XCTAssertEqual(deletes, 0)

        clock.advance(settle)
        await rounds(macs, 3)
        clock.advance(settle)
        await rounds(macs, 3)
        texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.count, 1, "only the removal is left (a tombstone, no text): \(texts)")
        XCTAssertEqual(texts.values.first, false)
        XCTAssertEqual(texts.keys.first, SyncCloudSchema.noteName(device: a.engine.deviceID, note: id))
        let after = await pictureRecords(db)
        XCTAssertEqual(after, [SyncNoteAsset.name(for: kept.1.file, key: key)], "the deleted note's picture went; the other note's stayed")
        XCTAssertNotEqual(picture.file, kept.1.file)
        // Everything else is as it was, and every Mac is up to date and agrees.
        for mac in macs {
            XCTAssertEqual(mac.engine.status, .upToDate, mac.name)
            XCTAssertEqual(mac.store.note(kept.0)?.document.plainText, "Plans, C", mac.name)
        }
        XCTAssertEqual(Set(b.store.orderedSpaces.map(\.name)), Set(c.store.orderedSpaces.map(\.name)))
        let batches = await db.state.batchCount
        XCTAssertGreaterThan(batches, 0, "the batch log is never cleaned up")
    }

    func testAnOfflineMacHoldsCleanUpBackUntilItComesBackAndAcks() async throws {
        let (macs, db) = try await group(["A", "B", "C"])
        let (a, b, c) = (macs[0], macs[1], macs[2])
        let (id, _) = try await sharedNote(macs)
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        // C goes offline before it hears of the deletion.
        clock.advance(10)
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        for _ in 0..<4 { await a.sync(); await b.sync(); clock.advance(settle) }
        var texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 2, "C synced within the horizon and hasn't acked: nothing goes")
        var pictures = await pictureRecords(db)
        XCTAssertEqual(pictures.count, 1)
        // Back: it hears of the deletion, acks, and the clean-up goes on.
        await c.sync()
        XCTAssertNil(c.row(id))
        for _ in 0..<3 { await rounds(macs, 2); clock.advance(settle) }
        await rounds(macs, 2)
        texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 0)
        pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [])
    }

    func testAMacThatNeverComesBackStopsHoldingItBackAndLosesNothingIfItDoes() async throws {
        let (macs, db) = try await group(["A", "B", "C"])
        let (a, b, c) = (macs[0], macs[1], macs[2])
        let (id, picture) = try await sharedNote(macs)
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        // C goes away with an edit it never sent; A deletes the note.
        clock.advance(10)
        c.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Plans, C away"), NoteRun(image: picture)])]))
        clock.advance(10)
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        for _ in 0..<3 { await a.sync(); await b.sync(); clock.advance(settle) }
        var texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 2, "within the horizon C still counts")

        // A month and a day later C hasn't synced: it stops counting, and its text record goes too (by the collector).
        clock.advance(SyncGarbage.horizon + 86400)
        for _ in 0..<4 { await a.sync(); await b.sync(); clock.advance(settle) }
        texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 0, "\(texts)")
        XCTAssertEqual(texts.count, 1, "the removal stays")
        let pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [])

        // C comes back after all: its edit wins over the removal it never saw (the kept tombstone tells it so), and its
        // picture goes up again.
        await c.sync(); await a.sync(); await b.sync(); await c.sync(); await a.sync(); await b.sync()
        for mac in macs {
            XCTAssertNotNil(mac.row(id), "\(mac.name): the note is back")
            XCTAssertEqual(mac.store.note(id)?.document.plainText, "Plans, C away", mac.name)
            XCTAssertEqual(mac.pictures.data(picture.file), Data("a picture".utf8), mac.name)
        }
        let back = await pictureRecords(db)
        XCTAssertEqual(back, [SyncNoteAsset.name(for: picture.file, key: key)])
    }

    func testALiveOlderBuildWithoutAcksBlocksEveryCleanUp() async throws {
        let (macs, db) = try await group(["A", "B"])
        let a = macs[0]
        let (id, _) = try await sharedNote(macs)
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        // An older build syncs in the group: it publishes its device record, never an ack.
        let old = UUID()
        let sealed = try SyncEngine.sealDeviceName("Old Mac", group: group, device: old, key: key)
        let device = SyncCloudSchema.record(SyncDeviceRecord(group: group, device: old, sealed: sealed, seen: clock.date))
        await db.change { try? $0.seed([device], zone: SyncCloudSchema.zone) }
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        for _ in 0..<4 { await rounds(macs, 2); clock.advance(settle) }
        let deletes = await db.count(.delete)
        XCTAssertEqual(deletes, 0, "nothing while a Mac that counts can't ack")
        let texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 1)
        let pictures = await pictureRecords(db)
        XCTAssertEqual(pictures.count, 1)
    }

    func testAPictureATodayNoteOrAnotherMacStillUsesStaysAndAReusedOneGoesUpAgain() async throws {
        let (macs, db) = try await group(["A", "B"])
        let (a, b) = (macs[0], macs[1])
        let (id, picture) = try await sharedNote(macs)
        let key = try key(a)
        // B also uses the picture in a note of its own in Today (never synced).
        let today = try b.store.createNote(inSpace: b.space("Work")!.id, pinned: false)
        b.store.updateNote(NoteURL.noteID(today.url)!, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("mine"), NoteRun(image: picture)])]))
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        for _ in 0..<4 { await rounds(macs, 2); clock.advance(settle) }
        var pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [SyncNoteAsset.name(for: picture.file, key: key)], "B keeps it")

        // B deletes its Today note: next round the picture goes. Then B pins a new note with it: it goes up again.
        let tab = try XCTUnwrap(b.store.state.tabs.values.first { $0.url == today.url })
        try b.store.forgetTab(tab.id)
        _ = try b.store.removeOrphanNotes()
        XCTAssertFalse(b.store.referencedNoteIDs.contains(NoteURL.noteID(today.url)!))
        // A picture a Mac kept isn't proposed again for a horizon.
        clock.advance(SyncGarbage.horizon + 60)
        for _ in 0..<4 { await rounds(macs, 2); clock.advance(settle) }
        pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [], "nobody uses it")
        let again = try b.store.createNote(inSpace: b.space("Work")!.id)
        b.store.updateNote(NoteURL.noteID(again.url)!, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Again"), NoteRun(image: picture)])]))
        try FileManager.default.removeItem(at: a.pictureFile(picture.file))
        await b.sync(); await a.sync()
        XCTAssertEqual(a.pictures.data(picture.file), Data("a picture".utf8), "uploaded again, not taken for 'already up'")
    }

    func testACrashMidDeleteIsFinishedAfterARelaunchAndAnnounced() async throws {
        let (macs, db) = try await group(["A", "B"])
        let (a, b) = (macs[0], macs[1])
        let one = try await sharedNote(macs, picture: Data("one".utf8))
        let two = try await sharedNote(macs, picture: Data("two".utf8))
        for id in [one.0, two.0] { try a.store.deleteItem(XCTUnwrap(a.row(id)).id) }
        for mac in [a, b] { _ = try mac.store.removeOrphanNotes() }
        await rounds(macs, 2)
        clock.advance(settle)
        // The collector's deletes stop after one record (a crash, or the network gone mid-way).
        let collector = [a, b].min { $0.engine.deviceID.uuidString < $1.engine.deviceID.uuidString }!
        let other = collector === a ? b : a
        await db.limitDeletes(1)
        await collector.sync()
        let first = await db.deleted
        XCTAssertEqual(first.count, 1, "one record went, then the delete failed")
        var pictures = await pictureRecords(db)
        XCTAssertFalse(pictures.isEmpty)
        XCTAssertEqual(collector.engine.status, .upToDate, "clean-up never fails a cycle")
        collector.relaunch()
        collector.engine.setEnabled(true)
        await collector.sync()
        pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [], "finished after the relaunch")
        // Announced: the other Mac knows both are gone, so a later use uploads them again.
        await other.sync()
        let group = try XCTUnwrap(a.engine.groupID), k = try key(a)
        let record = await db.state.records(zone: SyncCloudSchema.zone).first { $0.name == SyncCloudSchema.ackName(collector.engine.deviceID) }
        let ack = try XCTUnwrap(record.flatMap(SyncCloudSchema.ack).flatMap { SyncGCAck.open($0, group: group, key: k) })
        XCTAssertEqual(ack.gone.count, 2)
        let again = try other.store.createNote(inSpace: other.space("Work")!.id)
        other.store.updateNote(NoteURL.noteID(again.url)!, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("x"), NoteRun(image: one.1)])]))
        await other.sync()
        pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [SyncNoteAsset.name(for: one.1.file, key: k)])
        // The other Mac's own text records went in its own cycles.
        await rounds(macs, 2)
        for id in [one.0, two.0] {
            let texts = await textRecords(db, note: id, key: k, group: group)
            XCTAssertEqual(texts.values.filter { $0 }.count, 0, id)
        }
    }

    func testANoteUnpinnedToTodayAndPinnedAgainAfterCleanUpComesBackWhole() async throws {
        let (macs, db) = try await group(["A", "B"])
        let (a, b) = (macs[0], macs[1])
        let (id, picture) = try await sharedNote(macs)
        // A drags it into Today (a removal for sync; the note stays on A) and B deletes nothing.
        let row = try XCTUnwrap(a.row(id))
        let work = try XCTUnwrap(a.space("Work")).id
        try a.store.move(.item(row.id), to: .today(spaceID: work, index: 0))
        XCTAssertTrue(a.store.referencedNoteIDs.contains(id), "still in A's Today")
        for _ in 0..<4 { await rounds(macs, 2); clock.advance(settle) }
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        let texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 0, "B's text went")
        let pictures = await pictureRecords(db)
        XCTAssertEqual(pictures.count, 1, "A's Today note still uses the picture")
        // Pinned again on A: B gets text and picture.
        let tab = try XCTUnwrap(a.store.state.tabs.values.first { $0.url == NoteURL.make(id) })
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: work, parentID: nil, index: 0))
        try FileManager.default.removeItem(at: b.pictureFile(picture.file))
        await a.sync(); await b.sync()
        XCTAssertNotNil(b.row(id))
        XCTAssertEqual(b.store.note(id)?.document.plainText, "Plans, B")
        XCTAssertEqual(b.pictures.data(picture.file), Data("a picture".utf8))
    }

    func testAnInstallFromBeforeCleanUpReadsEverythingOnceAndThenCleansUp() async throws {
        let (macs, db) = try await group(["A", "B"])
        let (a, b) = (macs[0], macs[1])
        let (id, _) = try await sharedNote(macs)
        // State files as a build from before syncgc wrote them: no clean-up state, a change token in the checkpoint.
        for mac in macs {
            let url = mac.folder.appendingPathComponent("sync.json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertNotNil(json.removeValue(forKey: "gc"))
            XCTAssertNotNil(json["checkpoint"])
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            mac.relaunch()
            mac.engine.setEnabled(true)
        }
        let fetchesBefore = await db.count(.fetchChanges)
        try a.store.deleteItem(XCTUnwrap(a.row(id)).id)
        await rounds(macs, 1)
        let fetches = await db.count(.fetchChanges)
        XCTAssertGreaterThanOrEqual(fetches - fetchesBefore, 2)
        for _ in 0..<3 { await rounds(macs, 2); clock.advance(settle) }
        await rounds(macs, 2)
        let pictures = await pictureRecords(db)
        XCTAssertEqual(pictures, [], "the inventory is complete after one full read, so the picture could go")
        let key = try key(a), group = try XCTUnwrap(a.engine.groupID)
        let texts = await textRecords(db, note: id, key: key, group: group)
        XCTAssertEqual(texts.values.filter { $0 }.count, 0)
        XCTAssertEqual(b.engine.status, .upToDate)
    }

    // MARK: Start Over

    func testStartOverThenTheOldGroupGoesOnceEveryOldMacRejoinedOrIsGone() async throws {
        let (macs, db) = try await group(["A", "B", "C"])
        let (a, b, c) = (macs[0], macs[1], macs[2])
        _ = try await sharedNote(macs)
        let old = try XCTUnwrap(a.engine.groupID)
        func oldRecords() async -> [SyncCloudRecord] {
            await records(db).filter { $0.string("group") == old.uuidString && $0.type != SyncCloudSchema.group }
        }
        let before = await oldRecords()
        XCTAssertGreaterThan(before.count, 6)

        // B loses its key and starts over; A rejoins; C is away.
        for k in b.keys.groups { try b.keys.removeUnused(group: k) }
        b.relaunch()
        b.engine.setEnabled(true)
        await b.sync()
        XCTAssertEqual(b.engine.status, .waitingForKeychain)
        try await b.engine.startOver()
        let new = try XCTUnwrap(b.engine.groupID)
        await a.sync()
        a.keys.copy(from: b.keys)
        await a.sync()
        try await a.engine.choose(.merge)
        for _ in 0..<3 { await a.sync(); await b.sync(); clock.advance(settle) }
        var left = await oldRecords()
        let oldBatches = before.filter { $0.type == SyncCloudSchema.batch }.count
        XCTAssertEqual(left.filter { $0.type == SyncCloudSchema.batch }.count, oldBatches,
                       "C hasn't rejoined and synced within the horizon: the old group stays")
        XCTAssertTrue(left.contains { $0.name == SyncCloudSchema.deviceName(c.engine.deviceID) })

        // A month later C still hasn't come back: the old group goes, and nothing of the new one.
        let newBefore = await records(db).filter { $0.string("group") == new.uuidString }.count
        clock.advance(SyncGarbage.horizon + 86400)
        for _ in 0..<3 { await a.sync(); await b.sync(); clock.advance(settle) }
        left = await oldRecords()
        XCTAssertEqual(left.map(\.name), [])
        let newAfter = await records(db).filter { $0.string("group") == new.uuidString }.count
        XCTAssertGreaterThanOrEqual(newAfter, newBefore)
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(b.engine.status, .upToDate)

        // C comes back: it uploads into the old group once (a stray batch), rejoins, and loses nothing.
        try c.store.updateSpace(c.space("Work")!.id) { $0.name = "Work (C)" }
        await c.sync()
        c.keys.copy(from: b.keys)
        await c.sync()
        if case .choosing = c.engine.status { try await c.engine.choose(.merge) }
        await rounds([a, b, c], 2)
        XCTAssertEqual(a.space("Work (C)")?.name, "Work (C)")
        for _ in 0..<3 { await rounds([a, b, c], 1); clock.advance(settle) }
        left = await oldRecords()
        XCTAssertEqual(left.map(\.name), [], "the stray batch goes too")
    }

    func testStartOverAndEveryoneRejoinedTheOldGroupGoesAfterTheSettleDelay() async throws {
        let (macs, db) = try await group(["A", "B"])
        let (a, b) = (macs[0], macs[1])
        _ = try await sharedNote(macs)
        let old = try XCTUnwrap(a.engine.groupID)
        for k in b.keys.groups { try b.keys.removeUnused(group: k) }
        b.relaunch()
        b.engine.setEnabled(true)
        await b.sync()
        try await b.engine.startOver()
        await a.sync()
        a.keys.copy(from: b.keys)
        await a.sync()
        try await a.engine.choose(.merge)
        await rounds(macs, 2)
        var left = await records(db).filter { $0.string("group") == old.uuidString }
        XCTAssertFalse(left.isEmpty, "not before the settle delay")
        for _ in 0..<2 { clock.advance(settle); await rounds(macs, 2) }
        left = await records(db).filter { $0.string("group") == old.uuidString }
        XCTAssertEqual(left.map(\.name), [])
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(b.engine.unreadableBatches, 0)
    }
}
