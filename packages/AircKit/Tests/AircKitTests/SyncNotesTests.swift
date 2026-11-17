// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import XCTest
@testable import AircKit

/// Notes in iCloud sync (docs/sync.md, "Notes"; P14b1): a pinned note's row syncs as a pinned tab in a version 2 batch,
/// its text, title and pictures in sealed note records and assets. Several "Macs" on the mock CloudKit database, as in
/// SyncEngineTests.
@MainActor
private final class NoteMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let folder: URL
    let pictures: SyncNotePictureFolder
    let db: SyncMockCloudDatabase
    let name: String
    var engine: SyncEngine!
    var arrived: [String] = []

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name; self.db = db
        folder = root.appendingPathComponent(name)
        pictures = SyncNotePictureFolder(folder: folder.appendingPathComponent("Notes/Images"))
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
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        env.notePictures = pictures
        env.picturesArrived = { [weak self] in self?.arrived += $0 }
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    /// The notes pinned here, by their text's first line.
    func pinnedNotes(_ space: String? = nil) -> [String] {
        store.state.items.values.filter { space == nil || $0.spaceID == self.space(space!)?.id }
            .compactMap { NoteURL.noteID($0.savedURL) }.compactMap { store.note($0)?.displayTitle }.sorted()
    }
    func note(titled title: String) -> Note? { store.state.notes.values.first { $0.displayTitle == title } }

    /// A picture's bytes kept as a note picture here, named by their SHA-256.
    func keepPicture(_ bytes: Data, ext: String = "png") throws -> NoteImage {
        let file = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "." + ext
        try pictures.save(bytes, file: file)
        return NoteImage(file: file, width: 40, height: 30)
    }
}

@MainActor
final class SyncNotesTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-notes-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func noteID(_ t: LiveTab) -> String { NoteURL.noteID(t.url)! }

    /// Two Macs in one group: A made it with `seed`, B merged.
    private func pair(_ seed: (NoteMac) throws -> Void = { _ in }) async throws -> (NoteMac, NoteMac, SyncMockCloudDatabase) {
        let db = SyncMockCloudDatabase()
        let a = try NoteMac("A", db: db, root: root, clock: clock), b = try NoteMac("B", db: db, root: root, clock: clock)
        _ = try a.store.createSpace(name: "Work")
        try seed(a)
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        if case .choosing = b.engine.status { try await b.engine.choose(.merge) }
        XCTAssertEqual(b.engine.status, .upToDate)
        return (a, b, db)
    }

    private func records(_ db: SyncMockCloudDatabase, _ type: String) async -> [SyncCloudRecord] {
        await db.state.records(zone: SyncCloudSchema.zone).filter { $0.type == type }
    }

    // MARK: Payload

    func testVectorsTellSeenFromConcurrent() {
        let a = UUID(), b = UUID()
        let v1 = SyncNoteVector().incremented(a)
        let v2 = v1.incremented(b)
        let v3 = v1.incremented(a)
        XCTAssertEqual(v2.compare(v1), .newer)
        XCTAssertEqual(v1.compare(v2), .older)
        XCTAssertEqual(v2.compare(v3), .concurrent)
        XCTAssertEqual(v2.merged(v3).compare(v2), .newer)
        XCTAssertEqual(v2.merged(v3).compare(v3), .newer)
        XCTAssertEqual(v1.compare(SyncNoteVector(v1.counts)), .same)
    }

    func testRecordsAreSealedAndBoundToTheirNameGroupAndDevice() throws {
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID(), note = newID()
        let version = SyncNoteVersion(note: note, stamp: SyncStamp(milliseconds: 5, device: device),
                                      vector: SyncNoteVector().incremented(device), removed: false, title: "Plans",
                                      document: NoteDocument(lines: ["Secret plan"]))
        let record = try SyncNoteRecord.seal(version, group: group, device: device, key: key)
        let cloud = SyncCloudSchema.record(record)
        let raw = String(decoding: try JSONEncoder().encode(cloud), as: UTF8.self)
        XCTAssertFalse(raw.contains("Secret") || raw.contains("Plans"), "only ciphertext")
        XCTAssertEqual(cloud.name, "note.\(device.uuidString).\(note)")
        XCTAssertEqual(try SyncCloudSchema.note(cloud)?.open(group: group, key: key), version)
        // Moved to another device's name, another group, or opened with another key: refused.
        var moved = cloud
        moved.name = "note.\(UUID().uuidString).\(note)"
        XCTAssertNil(SyncCloudSchema.note(moved))
        var forged = record
        forged.device = UUID()
        XCTAssertThrowsError(try forged.open(group: group, key: key))
        XCTAssertThrowsError(try record.open(group: UUID(), key: key))
        XCTAssertThrowsError(try record.open(group: group, key: SyncEnvelope.newGroupKey()))
        var future = record
        future.format = 2
        XCTAssertThrowsError(try future.open(group: group, key: key)) { XCTAssertEqual($0 as? SyncError, .unsupportedVersion) }

        // A picture: its record name says nothing about it, and it opens only as the file its bytes hash to.
        let bytes = Data("picture bytes".utf8)
        let file = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".png"
        let asset = try SyncNoteAsset.seal(bytes, file: file, group: group, key: key)
        XCTAssertFalse(asset.name.contains(String(file.prefix(16))))
        XCTAssertEqual(try asset.open(file: file, group: group, key: key), bytes)
        let other = String(repeating: "a", count: 64) + ".png"
        XCTAssertThrowsError(try asset.open(file: other, group: group, key: key))
        XCTAssertEqual(SyncCloudSchema.noteAsset(SyncCloudSchema.record(asset)), asset)
    }

    func testALargeNoteGoesInAnAssetAndEveryFeedKeyIsListed() throws {
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID()
        let big = NoteDocument(lines: (0..<4000).map { "Line \($0) of a long note, with enough words to fill it up." })
        let version = SyncNoteVersion(note: newID(), stamp: SyncStamp(milliseconds: 1, device: device),
                                      vector: SyncNoteVector().incremented(device), removed: false, document: big)
        let record = try SyncNoteRecord.seal(version, group: group, device: device, key: key)
        XCTAssertGreaterThan(record.sealed.count, SyncNotes.inlineBytes)
        let cloud = SyncCloudSchema.record(record)
        XCTAssertNil(cloud.bytes("sealed"))
        XCTAssertNotNil(cloud.asset("payload"), "past 256 KB the version goes in a CKAsset: a record's fields hold 1 MB at most")
        XCTAssertEqual(try SyncCloudSchema.note(cloud)?.open(group: group, key: key).document, big)
        // A change fetch asks for every field the mapping reads, except pictures.
        for record in [cloud, SyncCloudSchema.record(SyncNoteRecord.init(group: group, device: device, note: "n", sealed: Data([1])))] {
            for field in record.fields.keys { XCTAssertTrue(SyncCloudSchema.feedKeys.contains(field), field) }
        }
        XCTAssertFalse(SyncCloudSchema.feedKeys.contains("data"), "pictures are fetched by name")
    }

    // MARK: Two Macs

    func testAPinnedNoteSyncsItsTextTitlePicturesAndRowAndATodayNoteStays() async throws {
        let db = SyncMockCloudDatabase()
        let a = try NoteMac("A", db: db, root: root, clock: clock), b = try NoteMac("B", db: db, root: root, clock: clock)
        let work = try a.store.createSpace(name: "Work")
        let folder = try a.store.createFolder(named: "Plans", inSpace: work.id)
        let picture = try a.keepPicture(Data("a screenshot".utf8))
        let pinned = try a.store.createNote(inSpace: work.id, parentID: folder.id)
        a.store.updateNote(noteID(pinned), document: NoteDocument(blocks: [
            NoteBlock(kind: .heading1, runs: [NoteRun("Secret launch plan")]),
            NoteBlock(kind: .checkbox, checked: true, runs: [NoteRun("Ship it", marks: [.bold])]),
            NoteBlock(runs: [NoteRun(image: picture)]),
        ]))
        try a.store.setNoteTitle(noteID(pinned), "Launch")
        let today = try a.store.createNote(inSpace: work.id, pinned: false)
        a.store.updateNote(noteID(today), document: NoteDocument(lines: ["Today secret"]))
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.merge)
        XCTAssertEqual(b.engine.status, .upToDate)

        // The row, in its folder, and the note's text, title and picture.
        let row = try XCTUnwrap(b.store.state.items.values.first { $0.savedURL == pinned.url })
        XCTAssertEqual(b.store.item(row.parentID)?.title, "Plans")
        XCTAssertEqual(b.store.space(row.spaceID)?.name, "Work")
        let note = try XCTUnwrap(b.store.note(noteID(pinned)))
        XCTAssertEqual(note, a.store.note(noteID(pinned)).map { var n = $0; n.updatedAt = note.updatedAt; return n })
        XCTAssertEqual(note.title, "Launch")
        XCTAssertEqual(row.pageTitle, "Launch", "the row is named after the note")
        XCTAssertEqual(b.pictures.data(picture.file), Data("a screenshot".utf8))
        XCTAssertEqual(b.arrived, [picture.file])
        // The Today note stays on A.
        XCTAssertNil(b.store.note(noteID(today)))
        XCTAssertFalse(b.store.state.items.values.contains { $0.savedURL == today.url })

        // Nothing readable in iCloud: no text, title, picture or picture name.
        let all = await db.state.records(zone: SyncCloudSchema.zone)
        let raw = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        for secret in ["Secret", "Launch", "Ship it", "Today secret", "screenshot", picture.file, "airc-note"] {
            XCTAssertFalse(raw.contains(secret), secret)
        }
        let notes = await records(db, SyncCloudSchema.note)
        let assets = await records(db, SyncCloudSchema.noteAsset)
        XCTAssertEqual(notes.count, 1, "one record per note and Mac: only A has written one")
        XCTAssertEqual(assets.count, 1)
        // Its row went in a version 2 batch; no version 1 batch has a note row.
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        let envelopes = all.compactMap(SyncCloudSchema.envelope)
        for e in envelopes {
            let ops = try e.open(group: group, key: key)
            let noteRows = ops.contains { if case .text(let u)? = $0.fields[.url] { NoteURL.isNote(u) } else { false } }
            if noteRows { XCTAssertEqual(e.version, 2) }
            if e.version == 2 { XCTAssertTrue(ops.allSatisfy { $0.record.kind == .row }) }
        }
        XCTAssertTrue(envelopes.contains { $0.version == 2 })
        XCTAssertTrue(envelopes.contains { $0.version == 1 })

        // A quiet cycle on both sends nothing more.
        let before = await db.state.records(zone: SyncCloudSchema.zone).count
        await a.sync(); await b.sync(); await a.sync()
        let after = await db.state.records(zone: SyncCloudSchema.zone).count
        XCTAssertEqual(before, after)
        XCTAssertEqual(b.engine.syncedNotes, 1)
    }

    func testEditsTitlesAndPicturesGoBothWays() async throws {
        var id = ""
        let (a, b, db) = try await pair { mac in
            let t = try mac.store.createNote(inSpace: mac.space("Work")!.id)
            id = NoteURL.noteID(t.url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["First"]))
        }
        clock.advance(1)
        b.store.updateNote(id, document: NoteDocument(lines: ["First", "B adds a line"]))
        await b.sync(); await a.sync()
        XCTAssertEqual(a.store.note(id)?.document.plainText, "First\nB adds a line")
        clock.advance(1)
        try a.store.setNoteTitle(id, "Shared")
        let picture = try a.keepPicture(Data("diagram".utf8))
        a.store.updateNote(id, document: NoteDocument(blocks: a.store.note(id)!.document.blocks + [NoteBlock(runs: [NoteRun(image: picture)])]))
        await a.sync(); await b.sync()
        XCTAssertEqual(b.store.note(id)?.title, "Shared")
        XCTAssertEqual(b.store.state.items.values.first { $0.savedURL == NoteURL.make(id) }?.pageTitle, "Shared")
        XCTAssertEqual(b.pictures.data(picture.file), Data("diagram".utf8), "an added picture arrives")
        // The picture removed on B: A's note shows none; it's uploaded once, never twice.
        clock.advance(1)
        b.store.updateNote(id, document: NoteDocument(lines: ["First", "B adds a line"]))
        await b.sync(); await a.sync()
        XCTAssertEqual(a.store.note(id)?.document.imageFiles, [])
        XCTAssertEqual(a.store.note(id)?.title, "Shared")
        let assets = await records(db, SyncCloudSchema.noteAsset)
        XCTAssertEqual(assets.count, 1)
        // A second picture with the same bytes on B (pasted again) is the same file: no new asset.
        clock.advance(1)
        let again = try b.keepPicture(Data("diagram".utf8))
        b.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun(image: again)])]))
        await b.sync(); await a.sync()
        let assetsAfter = await records(db, SyncCloudSchema.noteAsset)
        XCTAssertEqual(assetsAfter.count, 1)
        XCTAssertEqual(a.store.note(id)?.document.imageFiles, [picture.file])
    }

    /// An edit is found by the digest of the note's title and whole document (pictures included), never by its time: a
    /// picture-only, a title-only and a text edit made in the same clock tick as the last sync all go.
    func testPictureOnlyTitleOnlyAndSameTickEditsAllSync() async throws {
        var id = ""
        let (a, b, _) = try await pair { mac in
            id = NoteURL.noteID(try mac.store.createNote(inSpace: mac.space("Work")!.id).url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Same words"]))
        }
        // No clock change anywhere below: every edit has the note's previous updatedAt.
        let picture = try a.keepPicture(Data("only a picture".utf8))
        a.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Same words")]), NoteBlock(runs: [NoteRun(image: picture)])]))
        XCTAssertEqual(a.store.note(id)?.document.plainText, "Same words\n", "the text is the same, only a picture is new")
        await a.sync(); await b.sync()
        XCTAssertEqual(b.store.note(id)?.document.imageFiles, [picture.file], "a picture-only edit syncs")
        XCTAssertEqual(b.pictures.data(picture.file), Data("only a picture".utf8))

        // The same picture, resized in the note: still a change of the document.
        var blocks = a.store.note(id)!.document.blocks
        blocks[1].runs[0].image?.width = 20
        a.store.updateNote(id, document: NoteDocument(blocks: blocks))
        await a.sync(); await b.sync()
        XCTAssertEqual(b.store.note(id)?.document.blocks.last?.runs.first?.image?.width, 20)

        // Only the title field, on B, then cleared again.
        try b.store.setNoteTitle(id, "Named on B")
        await b.sync(); await a.sync()
        XCTAssertEqual(a.store.note(id)?.title, "Named on B", "a title-only edit syncs")
        XCTAssertEqual(a.store.state.items.values.first { $0.savedURL == NoteURL.make(id) }?.pageTitle, "Named on B")
        try b.store.setNoteTitle(id, nil)
        await b.sync(); await a.sync()
        XCTAssertNil(a.store.note(id)?.title, "clearing the title syncs")
        XCTAssertEqual(a.store.note(id)?.displayTitle, "Same words")

        // A picture removed, the words untouched.
        a.store.updateNote(id, document: NoteDocument(lines: ["Same words"]))
        await a.sync(); await b.sync()
        XCTAssertEqual(b.store.note(id)?.document.imageFiles, [])
        XCTAssertEqual(a.store.state.notes.count, 1, "no conflicted copy: every edit saw the one before")
        XCTAssertEqual(b.store.state.notes.count, 1)
    }

    func testConcurrentEditsLastWriterWinsAndTheLoserKeepsAConflictedCopy() async throws {
        var id = ""
        let (a, b, _) = try await pair { mac in
            let t = try mac.store.createNote(inSpace: mac.space("Work")!.id)
            id = NoteURL.noteID(t.url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Shopping", "milk"]))
        }
        // Both edit without seeing each other's edit; B's is later.
        clock.advance(10)
        a.store.updateNote(id, document: NoteDocument(lines: ["Shopping", "milk", "eggs (A)"]))
        clock.advance(10)
        b.store.updateNote(id, document: NoteDocument(lines: ["Shopping", "milk", "bread (B)"]))
        await a.sync()
        await b.sync()
        XCTAssertEqual(b.store.note(id)?.document.plainText, "Shopping\nmilk\nbread (B)", "B's later edit wins on B")
        await a.sync()
        XCTAssertEqual(a.store.note(id)?.document.plainText, "Shopping\nmilk\nbread (B)", "and on A")
        let copy = try XCTUnwrap(a.note(titled: "Shopping (conflicted copy, A's Mac)"), "A's text lives on as a note of its own")
        XCTAssertEqual(copy.document.plainText, "Shopping\nmilk\neggs (A)")
        // Pinned just below the note, in the same Space.
        let rows = a.store.children(of: .pinned(spaceID: a.space("Work")!.id), parent: nil).compactMap(\.savedURL)
        XCTAssertEqual(rows.firstIndex(of: copy.url), rows.firstIndex(of: NoteURL.make(id)).map { $0 + 1 })
        await b.sync()
        XCTAssertEqual(b.store.note(copy.id)?.document.plainText, "Shopping\nmilk\neggs (A)", "the copy syncs like any note")
        XCTAssertEqual(a.pinnedNotes(), b.pinnedNotes())
        // Settled: more cycles change nothing, and no second copy appears.
        await a.sync(); await b.sync(); await a.sync()
        XCTAssertEqual(a.store.state.notes.count, 2)
        XCTAssertEqual(b.store.state.notes.count, 2)
    }

    func testThreeMacsAgreeOnOneWinnerAndOnlyTheLosersAuthorCopies() async throws {
        var id = ""
        let (a, b, db) = try await pair { mac in
            let t = try mac.store.createNote(inSpace: mac.space("Work")!.id)
            id = NoteURL.noteID(t.url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Base"]))
        }
        let c = try NoteMac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: a.keys)
        await c.turnOn()
        try await c.engine.choose(.merge)
        XCTAssertEqual(c.store.note(id)?.document.plainText, "Base")
        clock.advance(5)
        b.store.updateNote(id, document: NoteDocument(lines: ["Base", "B"]))
        clock.advance(5)
        a.store.updateNote(id, document: NoteDocument(lines: ["Base", "A"]))
        await b.sync(); await a.sync(); await c.sync(); await b.sync(); await a.sync(); await c.sync()
        for mac in [a, b, c] {
            XCTAssertEqual(mac.store.note(id)?.document.plainText, "Base\nA", mac.name)
            XCTAssertEqual(mac.store.state.notes.values.filter { $0.title?.contains("conflicted copy") == true }.map(\.document.plainText),
                           ["Base\nB"], mac.name)
        }
    }

    func testAnEditWinsOverADeletionThatDidntSeeIt() async throws {
        var id = ""
        let (a, b, _) = try await pair { mac in
            let t = try mac.store.createNote(inSpace: mac.space("Work")!.id)
            id = NoteURL.noteID(t.url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Keep me"]))
        }
        let rowA = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == NoteURL.make(id) })
        // A deletes the note; B, offline, edits it later (the stamps don't matter: the edit wins).
        clock.advance(10)
        b.store.updateNote(id, document: NoteDocument(lines: ["Keep me", "edited on B"]))
        clock.advance(10)
        try a.store.deleteItem(rowA.id)
        await a.sync()
        await b.sync()
        XCTAssertTrue(b.store.state.items.values.contains { $0.savedURL == NoteURL.make(id) }, "B keeps its edited note pinned")
        XCTAssertEqual(b.store.note(id)?.document.plainText, "Keep me\nedited on B")
        await a.sync()
        XCTAssertEqual(a.store.state.items.values.filter { $0.savedURL == NoteURL.make(id) }.map(\.spaceID), [a.space("Work")!.id],
                       "the note is back on A, in its Space")
        XCTAssertEqual(a.store.note(id)?.document.plainText, "Keep me\nedited on B")
        await b.sync(); await a.sync()
        XCTAssertEqual(a.pinnedNotes(), b.pinnedNotes())
    }

    func testADeletionThatSawTheLastEditWinsAndAnEditWinsOverAWholeSpaceDeleted() async throws {
        var id = "", other = ""
        let (a, b, _) = try await pair { mac in
            let work = mac.space("Work")!.id
            id = NoteURL.noteID(try mac.store.createNote(inSpace: work).url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Old note"]))
            let ideas = try mac.store.createSpace(name: "Ideas")
            other = NoteURL.noteID(try mac.store.createNote(inSpace: ideas.id).url)!
            mac.store.updateNote(other, document: NoteDocument(lines: ["Idea"]))
        }
        // B edits and syncs; A sees it, then deletes: the deletion wins everywhere.
        clock.advance(1)
        b.store.updateNote(id, document: NoteDocument(lines: ["Old note", "seen"]))
        await b.sync(); await a.sync()
        try a.store.deleteItem(XCTUnwrap(a.store.state.items.values.first { $0.savedURL == NoteURL.make(id) }).id)
        await a.sync(); await b.sync()
        XCTAssertFalse(b.store.state.items.values.contains { $0.savedURL == NoteURL.make(id) })
        XCTAssertFalse(a.store.state.items.values.contains { $0.savedURL == NoteURL.make(id) })

        // A deletes the whole Ideas Space while B, offline, edits its note: the Space comes back with the note.
        clock.advance(10)
        b.store.updateNote(other, document: NoteDocument(lines: ["Idea", "grown on B"]))
        try a.store.deleteSpace(XCTUnwrap(a.space("Ideas")).id)
        await a.sync(); await b.sync(); await a.sync()
        for mac in [a, b] {
            let row = mac.store.state.items.values.first { $0.savedURL == NoteURL.make(other) }
            XCTAssertEqual(mac.store.space(row?.spaceID)?.name, "Ideas", mac.name)
            XCTAssertEqual(mac.store.note(other)?.document.plainText, "Idea\ngrown on B", mac.name)
        }
    }

    func testNotesWaitWhileICloudRefusesTheirTypesAndTheSidebarStillSyncs() async throws {
        let db = SyncMockCloudDatabase()
        await db.refuse(type: SyncCloudSchema.note, with: .other("CKError 12"))
        await db.refuse(type: SyncCloudSchema.noteAsset, with: .other("CKError 12"))
        let a = try NoteMac("A", db: db, root: root, clock: clock), b = try NoteMac("B", db: db, root: root, clock: clock)
        let work = try a.store.createSpace(name: "Work")
        let picture = try a.keepPicture(Data("held".utf8))
        let n = try a.store.createNote(inSpace: work.id)
        a.store.updateNote(noteID(n), document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Waits"), NoteRun(image: picture)])]))
        await a.turnOn()
        XCTAssertEqual(a.engine.status, .upToDate, "the sidebar synced")
        XCTAssertTrue(a.engine.notesHeld)
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.merge)
        XCTAssertNotNil(b.space("Work"))
        XCTAssertNil(b.store.note(noteID(n))?.document.plainText.nilIfEmpty, "no text yet")
        // Deployed: what waited goes up.
        await db.refuse(type: SyncCloudSchema.note, with: nil)
        await db.refuse(type: SyncCloudSchema.noteAsset, with: nil)
        await a.sync()
        XCTAssertFalse(a.engine.notesHeld)
        await b.sync()
        XCTAssertEqual(b.store.note(noteID(n))?.document.plainText, "Waits")
        XCTAssertEqual(b.pictures.data(picture.file), Data("held".utf8))
    }

    func testOfflineEditsWaitAndGoUpLater() async throws {
        var id = ""
        let (a, b, db) = try await pair { mac in
            id = NoteURL.noteID(try mac.store.createNote(inSpace: mac.space("Work")!.id).url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["v1"]))
        }
        clock.advance(1)
        a.store.updateNote(id, document: NoteDocument(lines: ["v1", "typed offline"]))
        let picture = try a.keepPicture(Data("offline picture".utf8))
        let made = try a.store.createNote(inSpace: a.space("Work")!.id)
        a.store.updateNote(NoteURL.noteID(made.url)!, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("New offline"), NoteRun(image: picture)])]))
        await db.fail(.save, with: .network(retryAfter: nil), .network(retryAfter: nil), .network(retryAfter: nil))
        await a.sync()
        guard case .retrying = a.engine.status else { return XCTFail("\(a.engine.status)") }
        // A quit and a relaunch: what wasn't sent is still queued.
        a.relaunch()
        a.engine.setEnabled(true)
        await a.sync()
        XCTAssertEqual(a.engine.status, .upToDate)
        await b.sync()
        XCTAssertEqual(b.store.note(id)?.document.plainText, "v1\ntyped offline")
        XCTAssertEqual(b.store.note(NoteURL.noteID(made.url)!)?.document.title, "New offline")
        XCTAssertEqual(b.pictures.data(picture.file), Data("offline picture".utf8))
    }

    func testAPictureTooLargeStaysAndOneNotUploadedYetArrivesLater() async throws {
        var id = ""
        let big = Data(repeating: 7, count: SyncNotes.maxPictureBytes + 1)
        var bigPicture: NoteImage?
        let (a, b, _) = try await pair { mac in
            id = NoteURL.noteID(try mac.store.createNote(inSpace: mac.space("Work")!.id).url)!
            bigPicture = try mac.keepPicture(big)
            mac.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Huge"), NoteRun(image: bigPicture!)])]))
        }
        XCTAssertEqual(b.store.note(id)?.document.imageFiles, [bigPicture!.file], "the note syncs")
        XCTAssertFalse(b.pictures.has(bigPicture!.file), "its 32 MB+ picture stays on A (B shows a placeholder)")
        // B keeps asking at most a few pictures per cycle, and gets one as soon as it's up.
        clock.advance(1)
        let small = try a.keepPicture(Data("small".utf8))
        a.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Huge"), NoteRun(image: bigPicture!), NoteRun(image: small)])]))
        await a.sync(); await b.sync()
        XCTAssertEqual(b.pictures.data(small.file), Data("small".utf8))
        XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testReplaceKeepsThisMacsNotesAndSendsThem() async throws {
        let db = SyncMockCloudDatabase()
        let a = try NoteMac("A", db: db, root: root, clock: clock), b = try NoteMac("B", db: db, root: root, clock: clock)
        _ = try a.store.createSpace(name: "Work")
        await a.turnOn()
        let mine = try b.store.createSpace(name: "Mine")
        let page = try b.store.openTab(url: "https://old.example/pinned", inSpace: mine.id)
        try b.store.move(.tab(page.id), to: .pinned(spaceID: mine.id, parentID: nil, index: 0))
        let folder = try b.store.createFolder(named: "Drafts", inSpace: mine.id)
        let n = try b.store.createNote(inSpace: mine.id, parentID: folder.id)
        b.store.updateNote(noteID(n), document: NoteDocument(lines: ["B's only copy"]))
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.replace)
        XCTAssertFalse(b.store.state.items.values.contains { $0.savedURL == "https://old.example/pinned" }, "Replace took iCloud's sidebar")
        let row = try XCTUnwrap(b.store.state.items.values.first { $0.savedURL == n.url }, "but kept this Mac's note")
        XCTAssertEqual(b.store.space(row.spaceID)?.name, "Mine")
        XCTAssertEqual(b.store.item(row.parentID)?.title, "Drafts")
        await a.sync()
        let arrived = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == n.url })
        XCTAssertEqual(a.store.space(arrived.spaceID)?.name, "Mine")
        XCTAssertEqual(a.store.item(arrived.parentID)?.title, "Drafts")
        XCTAssertEqual(a.store.note(noteID(n))?.document.plainText, "B's only copy")
        XCTAssertFalse(a.store.state.items.values.contains { $0.savedURL == "https://old.example/pinned" })
    }

    func testAZoneResetSendsNotesAndPicturesAgainForAThirdMac() async throws {
        var id = ""
        var picture: NoteImage?
        let (a, b, db) = try await pair { mac in
            id = NoteURL.noteID(try mac.store.createNote(inSpace: mac.space("Work")!.id).url)!
            picture = try mac.keepPicture(Data("kept".utf8))
            mac.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Survives"), NoteRun(image: picture!)])]))
        }
        clock.advance(1)
        b.store.updateNote(id, document: NoteDocument(blocks: [NoteBlock(runs: [NoteRun("Survives, B"), NoteRun(image: picture!)])]))
        await b.sync(); await a.sync()
        let group = try XCTUnwrap(a.engine.groupID)
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }
        await a.sync(); await b.sync()
        XCTAssertFalse(a.engine.needsRecovery)
        XCTAssertFalse(b.engine.needsRecovery)
        let c = try NoteMac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: a.keys)
        await c.turnOn()
        try await c.engine.choose(.merge)
        XCTAssertEqual(c.engine.groupID, group)
        XCTAssertEqual(c.store.note(id)?.document.plainText, "Survives, B")
        XCTAssertEqual(c.pictures.data(picture!.file), Data("kept".utf8))
        XCTAssertEqual(c.pinnedNotes(), a.pinnedNotes())
    }

    func testUnreadableNoteRecordsAreReportedAndOlderBuildsSkipNoteTypes() async throws {
        var id = ""
        let (a, b, db) = try await pair { mac in
            id = NoteURL.noteID(try mac.store.createNote(inSpace: mac.space("Work")!.id).url)!
            mac.store.updateNote(id, document: NoteDocument(lines: ["Readable"]))
        }
        // A record from a newer Airc (format 2) under a third device: reported, kept trying, nothing else changes.
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        let stranger = UUID()
        let later = Int64(clock.date.timeIntervalSince1970 * 1000) + 1_000_000
        let version = SyncNoteVersion(note: id, stamp: SyncStamp(milliseconds: later, device: stranger),
                                      vector: SyncNoteVector().incremented(stranger), removed: false, document: NoteDocument(lines: ["future"]))
        var future = try SyncNoteRecord.seal(version, group: group, device: stranger, key: key)
        future.format = 2
        let newer = future
        await db.change { try! $0.seed([SyncCloudSchema.record(newer)], zone: SyncCloudSchema.zone) }
        await b.sync()
        guard case .incomplete = b.engine.status else { return XCTFail("\(b.engine.status)") }
        XCTAssertEqual(b.engine.unreadableBatches, 1)
        XCTAssertEqual(b.store.note(id)?.document.plainText, "Readable")
        // It's gone (or replaced by one this build reads): settled.
        await db.change { _ = try! $0.save([SyncCloudSchema.record(try! SyncNoteRecord.seal(version, group: group, device: stranger, key: key))],
                                            zone: SyncCloudSchema.zone, mode: .overwrite) }
        await b.sync()
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertEqual(b.store.note(id)?.document.plainText, "future", "the later version wins")

        // What an older build's transport sees: types it doesn't know are skipped, not malformed or quarantined.
        let unknown = SyncCloudRecord(name: "future.thing", type: "SyncSomethingNew", fields: ["x": .asset(Data([1]))])
        await db.change { try! $0.seed([unknown], zone: SyncCloudSchema.zone) }
        let t = CloudKitSyncTransport(database: db, device: UUID(), backoff: [0], sleep: { _ in })
        _ = try await t.read()
        let report = await t.takeReadReport()
        XCTAssertEqual(report.malformed, [])
        // A version 2 batch is refused by a build that reads version 1 only (SyncEnvelope.open's check), and a state
        // file from before notes synced still loads. (Version 3 is splits', SyncSplitsTests; 4 settings', SyncSettingsTests.)
        XCTAssertEqual(SyncEnvelope.versions, 1...4)
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: b.folder.appendingPathComponent("sync.json"))) as! [String: Any]
        var old = state
        old["notes"] = nil
        try JSONSerialization.data(withJSONObject: old).write(to: b.folder.appendingPathComponent("sync.json"))
        b.relaunch()
        XCTAssertTrue(b.engine.isEnabled)
        XCTAssertEqual(b.engine.groupID, group)
    }

    /// Today folders never sync (docs/sync.md, "Folders in Today"), notes in them included: a note put in one stays, and a
    /// pinned note dragged into one leaves the other Macs like an unpinned note, while its text stays here.
    func testANoteInATodayFolderStaysOnThisMac() async throws {
        var pinnedID = ""
        var pinnedTab = ""
        let (a, b, db) = try await pair { mac in
            let t = try mac.store.createNote(inSpace: mac.space("Work")!.id)
            pinnedID = NoteURL.noteID(t.url)!
            pinnedTab = t.id
            mac.store.updateNote(pinnedID, document: NoteDocument(lines: ["Pinned first"]))
        }
        XCTAssertEqual(b.store.note(pinnedID)?.document.plainText, "Pinned first")
        let work = try XCTUnwrap(a.space("Work")).id
        let today = try a.store.createNote(inSpace: work, pinned: false)
        a.store.updateNote(noteID(today), document: NoteDocument(lines: ["Trip plans in a Today folder"]))
        let folder = try a.store.createTodayFolder(named: "Private Trip", inSpace: work, containing: [.tab(today.id)])
        try a.store.move(.tab(pinnedTab), to: .todayFolder(folderID: folder.id, index: 0))
        XCTAssertEqual(a.store.tab(pinnedTab)?.folderID, folder.id)
        clock.advance(1)
        await a.sync(); await b.sync()

        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        let versions = await db.state.records(zone: SyncCloudSchema.zone).compactMap(SyncCloudSchema.note).compactMap { try? $0.open(group: group, key: key) }
        XCTAssertFalse(versions.contains { $0.note == noteID(today) }, "a note in a Today folder never goes up")
        XCTAssertTrue(versions.contains { $0.note == pinnedID && $0.removed }, "the pinned one left Pinned: a removal, no text")
        XCTAssertFalse(versions.contains { $0.document?.plainText.contains("Trip plans") == true })
        XCTAssertFalse(b.store.state.items.values.contains { $0.savedURL == NoteURL.make(pinnedID) }, "it left B's Pinned as an unpin does")
        XCTAssertNil(b.store.note(noteID(today)))
        XCTAssertFalse(b.store.state.items.values.contains { $0.title == "Private Trip" })
        XCTAssertEqual(a.store.note(pinnedID)?.document.plainText, "Pinned first", "A keeps it, in its Today folder")
        XCTAssertEqual(a.store.tab(pinnedTab)?.folderID, folder.id)
    }

    // MARK: The adapter and the materializer alone

    func testTheAdapterSendsPinnedNoteRowsButNotTodayOnes() throws {
        let store = try makeStore()
        let work = try store.createSpace(name: "Work")
        let pinned = try store.createNote(inSpace: work.id)
        let today = try store.createNote(inSpace: work.id, pinned: false)
        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        let ops = try adapter.capture(store.state, into: &replica, now: 1)
        let sent = String(decoding: try JSONEncoder().encode(ops), as: UTF8.self)
        XCTAssertTrue(sent.contains(pinned.url), "a pinned note's row syncs")
        XCTAssertFalse(sent.contains(today.url), "a note's Today tab never does, even with Today export on")
        XCTAssertEqual(adapter.excludedRows, [])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
