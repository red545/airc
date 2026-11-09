// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import CryptoKit
import XCTest
@testable import AircKit

/// One "Mac": its own store, fake keychain, state file and engine, on a shared mock CloudKit database.
@MainActor
private final class Mac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let folder: URL
    let db: SyncMockCloudDatabase
    let name: String
    var machine: String
    var engine: SyncEngine!

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name; self.db = db
        folder = root.appendingPathComponent(name)
        machine = name
        store = try makeStore(clock)
        relaunch()
    }

    /// A new engine on the same state file (the app quit and started again).
    func relaunch() {
        let store = store, folder = folder, db = db
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: name + "'s Mac", machine: machine,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    var spaceNames: Set<String> { Set(store.orderedSpaces.map(\.name)) }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    func pinnedURLs(_ space: String) -> Set<String> {
        Set(store.state.items.values.filter { $0.spaceID == self.space(space)?.id }.compactMap(\.savedURL))
    }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-engine-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func seedWork(_ mac: Mac) throws {
        let work = try mac.store.createSpace(name: "Work", icon: .emoji("💼"))
        let folder = try mac.store.createFolder(named: "Docs", inSpace: work.id)
        for (i, url) in ["https://example.com/a", "https://example.com/b"].enumerated() {
            let tab = try mac.store.openTab(url: url, inSpace: work.id)
            try mac.store.move(.tab(tab.id), to: .pinned(spaceID: work.id, parentID: i == 0 ? folder.id : nil, index: 0))
        }
        let fav = try mac.store.openTab(url: "https://mail.example.com", inSpace: work.id)
        try mac.store.move(.tab(fav.id), to: .favorites(profileID: mac.store.defaultProfile.id, index: 0))
    }

    /// Every operation any Mac sent, decrypted.
    private func uploaded(_ db: SyncMockCloudDatabase, key: SymmetricKey, group: UUID) async throws -> String {
        let records = await db.state.records(zone: SyncCloudSchema.zone)
        var all: [SyncOperation] = []
        for r in records { if let e = SyncCloudSchema.envelope(r) { all += try e.open(group: group, key: key) } }
        return String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
    }

    func testFirstMacUploadsSecondWaitsForKeychainThenMergesBothWays() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        XCTAssertEqual(a.engine.status, .upToDate)
        let group = try XCTUnwrap(a.engine.groupID)
        XCTAssertEqual(a.keys.groups, [group])
        let awaited23 = await db.state.batchCount
        XCTAssertGreaterThan(awaited23, 0)
        XCTAssertEqual(a.engine.devices.map(\.name), ["A's Mac"])

        let laptop = try b.store.createSpace(name: "Laptop")
        let t = try b.store.openTab(url: "https://example.org/laptop", inSpace: laptop.id)
        try b.store.move(.tab(t.id), to: .pinned(spaceID: laptop.id, parentID: nil, index: 0))
        await b.turnOn()
        XCTAssertEqual(b.engine.status, .waitingForKeychain, "the group is in iCloud, its key isn't on this Mac yet")
        XCTAssertEqual(b.spaceNames, ["Personal", "Laptop"], "nothing changes while waiting")

        b.keys.copy(from: a.keys)   // iCloud Keychain brought it over
        await b.engine.syncNow()
        guard case .choosing(let preview) = b.engine.status else { return XCTFail("expected the first-sync screen, got \(b.engine.status)") }
        XCTAssertEqual(Set(preview.iCloud.spaces), ["Personal", "Work"])
        XCTAssertEqual(preview.iCloud.pinned, 2)
        XCTAssertEqual(preview.iCloud.favorites, 1)
        XCTAssertEqual(preview.thisMac.spaces, ["Personal", "Laptop"])
        XCTAssertEqual(preview.profiles, [], "default profile maps to default profile")

        let backup = try await b.engine.choose(.merge)
        XCTAssertTrue(String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains("Laptop"))
        XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertEqual(b.store.orderedSpaces.map(\.name).sorted(), ["Laptop", "Personal", "Personal", "Work"],
                       "merge keeps both Macs' Spaces, both default ones too")
        XCTAssertEqual(b.pinnedURLs("Work"), ["https://example.com/a", "https://example.com/b"])
        let docs = try XCTUnwrap(b.store.state.items.values.first { $0.title == "Docs" })
        XCTAssertEqual(b.store.state.items.values.first { $0.savedURL == "https://example.com/a" }?.parentID, docs.id)
        XCTAssertEqual(b.store.favorites(ofProfile: b.store.defaultProfile.id).compactMap(\.savedURL), ["https://mail.example.com"])
        XCTAssertEqual(b.store.space(b.space("Work")?.id)?.profileID, b.store.defaultProfile.id)
        XCTAssertEqual(b.engine.pendingUploads, 0)

        // Back on the first Mac: B's Space arrives, in A's own default profile.
        await a.engine.syncNow()
        XCTAssertEqual(a.store.orderedSpaces.map(\.name).sorted(), ["Laptop", "Personal", "Personal", "Work"])
        XCTAssertEqual(a.pinnedURLs("Laptop"), ["https://example.org/laptop"])
        XCTAssertEqual(a.space("Laptop")?.profileID, a.store.defaultProfile.id)
        XCTAssertEqual(Set(a.engine.devices.map(\.name)), ["A's Mac", "B's Mac"])

        // Edits both ways, and the same field edited on both: one winner everywhere.
        try a.store.updateSpace(a.space("Work")!.id) { $0.name = "Work (A)" }
        try b.store.renameItem(docs.id, to: "Papers")
        clock.advance(1)
        try b.store.updateSpace(b.space("Laptop")!.id) { $0.name = "Laptop (B)" }
        try a.store.updateSpace(a.space("Laptop")!.id) { $0.name = "Laptop (A)" }
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.spaceNames, b.spaceNames)
        XCTAssertTrue(a.spaceNames.contains("Work (A)"))
        XCTAssertTrue(a.store.state.items.values.contains { $0.title == "Papers" })
        XCTAssertEqual(a.store.orderedSpaces.map(\.id), b.store.orderedSpaces.map(\.id), "one order everywhere")

        // Applying remote changes sends nothing back: a quiet cycle adds no batches.
        let batches = await db.state.batchCount
        await a.engine.syncNow(); await b.engine.syncNow()
        let awaited24 = await db.state.batchCount
        XCTAssertEqual(awaited24, batches)
    }

    func testReplaceTakesICloudSidebarAfterABackupAndSendsNothingOfThisMac() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        let old = try b.store.createSpace(name: "Old")
        let pinned = try b.store.openTab(url: "https://old.example/pinned", inSpace: old.id)
        try b.store.move(.tab(pinned.id), to: .pinned(spaceID: old.id, parentID: nil, index: 0))
        let today = try b.store.openTab(url: "https://old.example/today", inSpace: old.id)
        let profiles = b.store.state.profiles
        b.keys.copy(from: a.keys)
        await b.turnOn()
        guard case .choosing = b.engine.status else { return XCTFail("\(b.engine.status)") }
        let backup = try await b.engine.choose(.replace)

        XCTAssertEqual(Set(b.store.orderedSpaces.map(\.id)), Set(a.store.orderedSpaces.map(\.id)))
        XCTAssertNil(b.space("Old"))
        XCTAssertTrue(b.store.state.archive.values.contains { $0.tab.id == today.id }, "its Today tabs go to the Archive")
        XCTAssertEqual(b.store.state.profiles.keys.sorted(), profiles.keys.sorted(), "profiles are never removed")
        XCTAssertTrue(String(decoding: try Data(contentsOf: backup), as: UTF8.self).contains("old.example\\/pinned"))
        let sent = try await uploaded(db, key: XCTUnwrap(a.keys.key(group: XCTUnwrap(a.engine.groupID))), group: a.engine.groupID!)
        XCTAssertFalse(sent.contains("old.example"))
        XCTAssertFalse(sent.contains(old.id))
        await a.engine.syncNow()
        XCTAssertEqual(a.spaceNames, ["Personal", "Work"], "Replace on B changes nothing on A")
    }

    func testProfilesMapToChoicesAndLaterOnesArriveEmpty() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        let work = try a.store.createProfile(name: "Work", emoji: "💼")
        let code = try a.store.createSpace(name: "Code", profileID: work.id)
        let fav = try a.store.openTab(url: "https://code.example", inSpace: code.id)
        try a.store.move(.tab(fav.id), to: .favorites(profileID: work.id, index: 0))
        await a.turnOn()
        let bWork = try b.store.createProfile(name: "work")
        b.keys.copy(from: a.keys)
        await b.turnOn()
        guard case .choosing(let preview) = b.engine.status else { return XCTFail("\(b.engine.status)") }
        XCTAssertEqual(preview.profiles.map(\.name), ["Work"])
        XCTAssertEqual(preview.profiles.first?.emoji, "💼")
        XCTAssertEqual(preview.profiles.first?.spaces, ["Code"])
        XCTAssertEqual(preview.profiles.first?.suggestion, bWork.id, "same name offered, not used by itself")
        try await b.engine.choose(.merge, profiles: [work.id: .use(bWork.id)])
        XCTAssertEqual(b.space("Code")?.profileID, bWork.id)
        XCTAssertEqual(b.store.favorites(ofProfile: bWork.id).compactMap(\.savedURL), ["https://code.example"])
        XCTAssertEqual(b.store.state.profiles.count, 2)

        // A profile made on A later: B gets an empty one with its name, and the Space uses it.
        let studio = try a.store.createProfile(name: "Studio", emoji: "🎨")
        _ = try a.store.createSpace(name: "Art", profileID: studio.id)
        await a.engine.syncNow(); await b.engine.syncNow()
        let art = try XCTUnwrap(b.space("Art"))
        XCTAssertEqual(b.store.profile(art.profileID)?.name, "Studio")
        XCTAssertNotEqual(art.profileID, studio.id)
        XCTAssertNil(b.store.profile(art.profileID)?.googleAccount)
        // B moves Code to its own new profile: A learns it as a new profile and makes it too.
        let mine = try b.store.createProfile(name: "Laptop only")
        _ = try b.store.setProfile(ofSpace: b.space("Code")!.id, to: mine.id)
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.profile(a.space("Code")?.profileID)?.name, "Laptop only")
        XCTAssertEqual(a.store.profile(work.id)?.name, "Work", "A's own profile stays")
    }

    func testCreateChoiceMakesAnEmptyProfileWithAFreeName() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        let work = try a.store.createProfile(name: "Work")
        _ = try a.store.createSpace(name: "Code", profileID: work.id)
        await a.turnOn()
        _ = try b.store.createProfile(name: "Work")
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.merge, profiles: [work.id: .create])
        XCTAssertEqual(b.store.profile(b.space("Code")?.profileID)?.name, "Work 2")
    }

    func testPrivateAndLocalOnlyDataIsNeverSent() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock)
        try seedWork(a)
        _ = try a.store.openTab(url: "https://today.example/reading", inSpace: a.space("Work")!.id, title: "Today title")
        let blank = try a.store.createBlankWindowSpace()
        _ = try a.store.openTab(url: "https://blank.example", inSpace: blank.id)
        a.store.updateTab(a.store.state.tabs.values.first { $0.url == "https://example.com/b" }!.id,
                          url: "https://example.com/b/navigated", title: "Page title")
        await a.turnOn()
        try a.store.updateProfile(a.store.defaultProfile.id) { $0.googleAccount = "someone@example.com" }
        await a.engine.syncNow()
        let group = try XCTUnwrap(a.engine.groupID)
        let sent = try await uploaded(db, key: XCTUnwrap(a.keys.key(group: group)), group: group)
        XCTAssertTrue(sent.contains("https:\\/\\/example.com\\/a"))
        for secret in ["today.example", "Today title", "blank.example", blank.id, "navigated", "Page title", "someone@example.com", "Default"] {
            XCTAssertFalse(sent.contains(secret), secret)
        }
    }

    /// Notes stay on this Mac (docs/sync.md): nothing about them reaches iCloud, and the other Mac gets none of their rows.
    func testNotesStayOnThisMac() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        let work = try XCTUnwrap(a.space("Work")).id
        let pinned = try a.store.createNote(inSpace: work)
        let today = try a.store.createNote(inSpace: work, pinned: false)
        a.store.updateNote(NoteURL.noteID(pinned.url)!, document: NoteDocument(lines: ["Pinned secret"]))
        a.store.updateNote(NoteURL.noteID(today.url)!, document: NoteDocument(lines: ["Today secret"]))
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.merge)
        a.store.updateNote(NoteURL.noteID(pinned.url)!, document: NoteDocument(lines: ["Pinned secret, edited"]))
        await a.engine.syncNow()
        await b.engine.syncNow()
        let group = try XCTUnwrap(a.engine.groupID)
        let sent = try await uploaded(db, key: XCTUnwrap(a.keys.key(group: group)), group: group)
        XCTAssertTrue(sent.contains("https:\\/\\/example.com\\/a"))
        for secret in ["airc-note", "Pinned secret", "Today secret", "New Note", NoteURL.noteID(pinned.url)!, NoteURL.noteID(today.url)!] {
            XCTAssertFalse(sent.contains(secret), secret)
        }
        XCTAssertEqual(b.pinnedURLs("Work"), ["https://example.com/a", "https://example.com/b"])
        XCTAssertTrue(b.store.state.notes.isEmpty)
        XCTAssertFalse(b.store.state.tabs.values.contains { NoteURL.isNote($0.url) })
        XCTAssertFalse(b.store.state.items.values.contains { NoteURL.isNote($0.savedURL) })
        XCTAssertNotNil(a.store.item(pinned.itemID))
        XCTAssertNotNil(a.store.tab(today.id))
        XCTAssertEqual(a.store.note(forTab: pinned.id)?.document.title, "Pinned secret, edited")
    }

    func testUserDeletedDataStopsAndKeepsTheKey() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock)
        await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID)
        await db.change { $0.deleteZoneAsUser(SyncCloudSchema.zone) }
        _ = try a.store.createSpace(name: "After")
        await a.engine.syncNow()
        guard case .stopped = a.engine.status else { return XCTFail("\(a.engine.status)") }
        XCTAssertFalse(a.engine.isEnabled)
        XCTAssertEqual(a.keys.groups, [group], "turning off never deletes the shared key")
        let awaited25 = await db.state.zones[SyncCloudSchema.zone]
        XCTAssertNil(awaited25)
        // On again, by the person: a new group with this Mac's sidebar.
        await a.turnOn()
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertNotEqual(a.engine.groupID, group)
        let awaited26 = await db.state.batchCount
        XCTAssertGreaterThan(awaited26, 0)
    }

    func testAccountChangeStopsAndOtherFailuresRetry() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock)
        await a.turnOn()
        await db.fail(.fetchChanges, with: .network(retryAfter: nil), .network(retryAfter: nil), .network(retryAfter: nil))
        _ = try a.store.createSpace(name: "Offline edit")
        await a.engine.syncNow()
        guard case .retrying = a.engine.status else { return XCTFail("\(a.engine.status)") }
        XCTAssertTrue(a.engine.isEnabled)
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .upToDate)
        await db.change { $0.account = .noAccount }
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .unavailable("Sign in to iCloud in System Settings to sync."))
        await db.change { $0.account = .available; $0.identity = "_someone-else" }
        await a.engine.syncNow()
        guard case .stopped = a.engine.status else { return XCTFail("\(a.engine.status)") }
        XCTAssertFalse(a.engine.isEnabled)
        XCTAssertNil(a.engine.groupID)
        XCTAssertTrue(a.spaceNames.contains("Offline edit"), "the sidebar itself is never touched")
    }

    func testOutboxSurvivesFailuresAndARelaunch() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.merge)
        await db.fail(.save, with: .network(retryAfter: nil), .network(retryAfter: nil), .network(retryAfter: nil))
        _ = try a.store.createSpace(name: "Queued")
        await a.engine.syncNow()
        XCTAssertGreaterThan(a.engine.pendingUploads, 0)
        a.relaunch()
        XCTAssertTrue(a.engine.isEnabled)
        XCTAssertGreaterThan(a.engine.pendingUploads, 0, "the outbox is on disk")
        await a.engine.syncNow()
        XCTAssertEqual(a.engine.pendingUploads, 0)
        await b.engine.syncNow()
        XCTAssertTrue(b.spaceNames.contains("Queued"))
    }

    func testRemoteDeletesMovesAndUnpinsApply() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        let home = try a.store.createSpace(name: "Home")
        await a.turnOn()
        b.keys.copy(from: a.keys)
        await b.turnOn()
        try await b.engine.choose(.replace)
        XCTAssertEqual(b.pinnedURLs("Work"), ["https://example.com/a", "https://example.com/b"])
        // B has the pinned tab open.
        let bItem = try XCTUnwrap(b.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let open = try b.store.openItem(bItem.id, inSpace: b.space("Work")!.id)

        let docs = try XCTUnwrap(a.store.state.items.values.first { $0.title == "Docs" })
        try a.store.deleteItem(docs.id)
        let bOnA = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        try a.store.move(.item(bOnA.id), to: .today(spaceID: a.space("Work")!.id, index: 0))
        let fav = try XCTUnwrap(a.store.favorites(ofProfile: a.store.defaultProfile.id).first)
        try a.store.move(.item(fav.id), to: .pinned(spaceID: home.id, parentID: nil, index: 0))
        try a.store.deleteSpace(a.space("Personal")!.id)
        await a.engine.syncNow(); await b.engine.syncNow()

        XCTAssertNil(b.store.state.items.values.first { $0.title == "Docs" })
        XCTAssertNil(b.store.state.items.values.first { $0.savedURL == "https://example.com/a" }, "deleted with its folder")
        XCTAssertNil(b.store.item(bItem.id), "unpinned")
        XCTAssertEqual(b.store.tab(open.id)?.isToday, true, "its open page stays, as a Today tab")
        XCTAssertEqual(b.pinnedURLs("Home"), ["https://mail.example.com"])
        XCTAssertTrue(b.store.favorites(ofProfile: b.store.defaultProfile.id).isEmpty)
        XCTAssertEqual(b.spaceNames, ["Work", "Home"])
        XCTAssertEqual(b.store.orderedSpaces.map(\.id), a.store.orderedSpaces.map(\.id))
    }

    func testZoneResetPutsEverythingBack() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        b.keys.copy(from: a.keys)
        _ = try b.store.createSpace(name: "From B")
        await b.turnOn()
        try await b.engine.choose(.merge)
        await a.engine.syncNow()
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }   // the CloudKit console's reset
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(a.engine.status, .upToDate)
        XCTAssertEqual(b.engine.status, .upToDate)
        // A third Mac still gets both Macs' Spaces.
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: a.keys)
        await c.turnOn()
        try await c.engine.choose(.replace)
        XCTAssertEqual(c.spaceNames, ["Personal", "Work", "From B"])
    }

    func testConcurrentFirstSetupJoinsOneGroupAndNeverOverwritesAKey() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        a.engine.setEnabled(true); b.engine.setEnabled(true)
        async let first: Void = a.engine.syncNow()
        async let second: Void = b.engine.syncNow()
        _ = await (first, second)
        let groups = Set([a.engine.groupID, b.engine.groupID].compactMap { $0 })
        XCTAssertEqual(groups.count, 1)
        let winner = try XCTUnwrap(groups.first)
        let loser = a.engine.groupID == winner ? b : a
        XCTAssertEqual(loser.engine.status, .waitingForKeychain)
        XCTAssertTrue(loser.keys.groups.isEmpty, "the losing Mac removed the key nobody uses")
        let found = try await CloudKitSyncTransport(database: db, device: UUID()).group()
        let record = try XCTUnwrap(found)
        XCTAssertEqual(record.group, winner)
        XCTAssertTrue(record.verifies(try XCTUnwrap((a.engine.groupID == winner ? a : b).keys.key(group: winner))))
    }

    func testCopiedDataFolderGetsItsOwnDeviceID() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock)
        await a.turnOn()
        let device = a.engine.deviceID, records = a.engine.replica.records
        a.machine = "another Mac"
        a.relaunch()
        XCTAssertNotEqual(a.engine.deviceID, device)
        XCTAssertEqual(a.engine.replica.records, records)
        XCTAssertTrue(a.engine.isEnabled)
    }
}

// icloudsync's tests for the review's fixes beyond its regressions (H3, H4, M2 and the record size).
extension SyncEngineTests {
    func testUnreadableBatchIsKeptReportedAndBlocksReplace() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.merge)
        // A batch from "a newer Airc" (version 2, which this build can't open), then an ordinary edit.
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        var newer = SyncReplica()
        try newer.edit(.init(.space, "from-newer"), [.name: .text("From a newer Airc"), .profile: .text(a.store.defaultProfile.id)], now: 5)
        let sealed = try SyncEnvelope.seal(newer.log, group: group, device: newer.clock.device, key: key)
        let unreadable = SyncEnvelope(version: 2, group: group, device: sealed.device, id: sealed.id, sealed: sealed.sealed)
        await db.change { try! $0.seed([SyncCloudSchema.record(unreadable)], zone: SyncCloudSchema.zone) }
        _ = try a.store.createSpace(name: "Kept")
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertTrue(b.spaceNames.contains("Kept"), "the readable changes still apply")
        guard case .incomplete = b.engine.status else { return XCTFail("must not claim up to date: \(b.engine.status)") }
        XCTAssertEqual(b.engine.unreadableBatches, 1)
        b.relaunch()
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.unreadableBatches, 1, "kept across a relaunch, not checkpointed away")
        guard case .incomplete = b.engine.status else { return XCTFail("\(b.engine.status)") }
        // A new Mac sees an incomplete iCloud sidebar: Replace is refused, Merge works.
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: a.keys)
        await c.turnOn()
        guard case .choosing(let preview) = c.engine.status else { return XCTFail("\(c.engine.status)") }
        XCTAssertFalse(preview.complete)
        do { try await c.engine.choose(.replace); XCTFail("Replace with an incomplete snapshot") }
        catch { XCTAssertEqual(error as? SyncError, .incompleteSnapshot) }
        try await c.engine.choose(.merge)
        XCTAssertTrue(c.spaceNames.contains("Kept"))
    }

    func testAppliedButUnsavedCheckpointDoesNotDuplicateAfterRestart() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let tab = try a.store.openTab(url: "https://unique.example/applied", inSpace: a.store.selectedSpace.id)
        await a.engine.syncNow()
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: a.store.selectedSpace.id, parentID: nil, index: 0))
        await a.engine.syncNow()
        let file = b.folder.appendingPathComponent("sync.json")
        let before = try Data(contentsOf: file)
        await b.engine.syncNow()   // the store now has the pin
        XCTAssertEqual(b.engine.status, .upToDate)
        // A crash right after the store's commit: the checkpoint on disk is the one from before.
        try before.write(to: file)
        b.relaunch()
        await b.engine.syncNow(); await a.engine.syncNow()
        for mac in [a, b] {
            XCTAssertEqual(mac.store.state.items.values.filter { $0.savedURL == "https://unique.example/applied" }.count, 1, mac.name)
            XCTAssertEqual(mac.engine.replica.sidebar.filter { $0[.url] == .text("https://unique.example/applied") }.count, 1, mac.name)
        }
    }

    func testBatchesStayUnderTheRecordLimitAndHugeURLsStayLocal() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        let space = a.store.selectedSpace.id
        let title = String(repeating: "Ä long title ", count: 400)   // ~5 KB, cut to 2 KB
        for i in 0..<300 {
            let t = try a.store.openTab(url: "https://example.com/\(i)", inSpace: space, activate: false)
            try a.store.move(.tab(t.id), to: .pinned(spaceID: space, parentID: nil, index: i))
            try a.store.renameItem(try XCTUnwrap(a.store.tab(t.id)?.itemID), to: title)
        }
        let huge = "https://example.com/?" + String(repeating: "a", count: 300_000)
        let h = try a.store.openTab(url: huge, inSpace: space, activate: false)
        try a.store.move(.tab(h.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        await a.turnOn()
        XCTAssertEqual(a.engine.status, .upToDate)
        let batches = await db.state.records(zone: SyncCloudSchema.zone).filter { $0.type == SyncCloudSchema.batch }
        XCTAssertGreaterThanOrEqual(batches.count, 2)
        for record in batches { XCTAssertLessThanOrEqual(record.bytes("sealed")?.count ?? .max, SyncEngine.maxBatchBytes + 1024) }
        b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let pins = b.store.state.items.values.filter { $0.savedURL?.hasPrefix("https://example.com/") == true }
        XCTAssertEqual(pins.count, 300, "every ordinary pin arrives; the 300 KB URL stays on its Mac")
        XCTAssertTrue(pins.allSatisfy { ($0.title?.utf8.count ?? 0) <= SyncStoreAdapter.maxTextBytes })
    }

    func testNoTransportWhileSyncIsOff() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore()
        let store = try makeStore(clock)
        final class Count: @unchecked Sendable { var n = 0 }
        let made = Count()
        let engine = SyncEngine(store: store, environment: .init(
            transport: { made.n += 1; return CloudKitSyncTransport(database: db, device: $0, backoff: []) },
            keys: keys, stateURL: root.appendingPathComponent("off.json"), deviceName: "Off Mac",
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { _, _ in }, backup: { try store.writeBackup(to: self.root, purpose: .beforeICloud) }))
        engine.automatic = false
        await engine.syncNow()
        _ = try store.createSpace(name: "Edit while off")
        XCTAssertEqual(made.n, 0, "no transport (no CloudKit objects) while off")
        XCTAssertFalse(engine.hasTransport)
        engine.setEnabled(true); await engine.syncNow()
        XCTAssertEqual(made.n, 1)
        XCTAssertEqual(engine.status, .upToDate)
        engine.setEnabled(false)
        XCTAssertFalse(engine.hasTransport, "dropped when switched off")
        await engine.syncNow()
        XCTAssertEqual(made.n, 1)
        let calls = await db.calls.count
        await engine.syncNow()
        let after = await db.calls.count
        XCTAssertEqual(calls, after, "no CloudKit calls while off")
    }
}

// Review-only regressions: assertions express the required safe behavior.
extension SyncEngineTests {
    func testReviewResetWithPendingEditPreservesFullHistory() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock)
        try seedWork(a)
        await a.turnOn()
        await db.change { $0.deleteZone(SyncCloudSchema.zone) }
        _ = try a.store.createSpace(name: "After reset")
        await a.engine.syncNow()
        let records = await db.state.records(zone: SyncCloudSchema.zone)
        XCTAssertTrue(records.contains { $0.type == SyncCloudSchema.group }, "recovery must restore the group")
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: a.keys)
        await c.turnOn()
        if case .choosing = c.engine.status { try await c.engine.choose(.replace) }
        XCTAssertEqual(c.engine.groupID, a.engine.groupID, "reset must not fork the group")
        XCTAssertTrue(c.spaceNames.contains("Work"), "old history must survive reset with pending edits")
    }

    func testReviewAccountChangeWhileChoosingDoesNotUpload() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn()
        _ = try b.store.createSpace(name: "Private to original account")
        b.keys.copy(from: a.keys)
        await b.turnOn()
        guard case .choosing = b.engine.status else { return XCTFail("expected preview") }
        await db.change { $0.identity = "_different-account"; $0.deleteZone(SyncCloudSchema.zone) }
        await b.engine.syncNow() // account notification while sheet is displayed
        _ = try? await b.engine.choose(.merge)
        let count = await db.state.batchCount
        XCTAssertEqual(count, 0, "must not send original account's data to a new Apple ID")
        XCTAssertFalse(b.engine.isEnabled)
    }

    func testReviewFailedCheckpointDoesNotDuplicateImportedPinAfterRestart() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let tab = try a.store.openTab(url: "https://unique.example/pin", inSpace: a.store.selectedSpace.id)
        await a.engine.syncNow() // track the Today identity before it is pinned
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: a.store.selectedSpace.id, parentID: nil, index: 0))
        await a.engine.syncNow()
        let file = b.folder.appendingPathComponent("sync.json")
        let old = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true) // write failure
        await b.engine.syncNow()
        XCTAssertNotEqual(b.engine.status, .upToDate, "a failed checkpoint cannot be called synced")
        try FileManager.default.removeItem(at: file)
        try old.write(to: file)
        b.relaunch()
        await b.engine.syncNow()
        XCTAssertEqual(b.store.state.items.values.filter { $0.savedURL == "https://unique.example/pin" }.count, 1,
                       "old checkpoint plus materialized store must not duplicate a pin")
    }

    func testReviewMultipleRemoteProfilesMappedToOneLocalRemainMapped() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        let work = try a.store.createProfile(name: "Work")
        _ = try a.store.createSpace(name: "Work space", profileID: work.id)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn()
        try await b.engine.choose(.replace, profiles: [work.id: .use(b.store.defaultProfile.id)])
        XCTAssertEqual(b.space("Work space")?.profileID, b.store.defaultProfile.id)
        XCTAssertEqual(b.space("Personal")?.profileID, b.store.defaultProfile.id)
        XCTAssertEqual(b.store.state.profiles.count, 1, "must honor both mappings offered by the UI")
    }
}

private struct ReviewHookDatabase: SyncCloudDatabase {
    let base: SyncMockCloudDatabase
    var beforeStatus: (@Sendable () async throws -> Void)? = nil
    var beforeRead: (@Sendable () async throws -> Void)? = nil
    func accountStatus() async throws -> SyncCloudAccount { try await beforeStatus?(); return try await base.accountStatus() }
    func accountIdentity() async throws -> String { try await base.accountIdentity() }
    func createZone(_ zone: String) async throws { try await base.createZone(zone) }
    func fetchChanges(zone: String, since token: Data?) async throws -> SyncCloudChanges {
        try await beforeRead?(); return try await base.fetchChanges(zone: zone, since: token)
    }
    func save(_ records: [SyncCloudRecord], zone: String, mode: SyncSaveMode) async throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        try await base.save(records, zone: zone, mode: mode)
    }
    func fetch(_ names: [String], zone: String) async throws -> [SyncCloudRecord] { try await base.fetch(names, zone: zone) }
    func subscribe(zone: String, id: String) async throws { try await base.subscribe(zone: zone, id: id) }
}
@MainActor private final class ReviewEngineBox { var engine: SyncEngine? }

extension SyncEngineTests {
    private func reviewEngine(_ store: SpacesStore, _ database: any SyncCloudDatabase, keys: InMemorySyncKeyStore) -> SyncEngine {
        let engine = SyncEngine(store: store, environment: .init(
            transport: { CloudKitSyncTransport(database: database, device: $0, backoff: []) },
            keys: keys, stateURL: root.appendingPathComponent("hook.json"), deviceName: "Review Mac",
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: self.root, purpose: .beforeICloud) }))
        engine.automatic = false
        return engine
    }

    func testReviewFirstMacDoesNotAcknowledgeUnmergedConcurrentChanges() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore()
        let store = try makeStore(clock), profile = store.defaultProfile.id
        let remoteID = "review-concurrent-space"
        let hook = ReviewHookDatabase(base: db, beforeRead: {
            guard await db.count(.fetchChanges) == 0 else { return }
            let group = try XCTUnwrap(keys.groups.first), key = try XCTUnwrap(keys.key(group: group))
            var remote = SyncReplica()
            try remote.edit(SyncRecordID(.space, remoteID), [.name: .text("Concurrent space"), .profile: .text(profile)], now: 1000)
            let envelope = try SyncEnvelope.seal(remote.log, group: group, device: remote.clock.device, key: key)
            await db.change { try! $0.seed([SyncCloudSchema.record(envelope)], zone: SyncCloudSchema.zone) }
        })
        let engine = reviewEngine(store, hook, keys: keys)
        engine.setEnabled(true)
        await engine.syncNow()
        await engine.syncNow()
        XCTAssertNotNil(store.space(remoteID), "first upload must merge every record before acknowledging its token")
        XCTAssertNotNil(engine.replica.records[SyncRecordID(.space, remoteID)])
    }

    func testReviewSwitchingOffDuringCycleStopsUpload() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), box = ReviewEngineBox()
        let store = try makeStore(clock)
        let hook = ReviewHookDatabase(base: db, beforeStatus: { await box.engine?.setEnabled(false) })
        let engine = reviewEngine(store, hook, keys: keys)
        box.engine = engine
        engine.setEnabled(true)
        await engine.syncNow()
        let batches = await db.state.batchCount
        XCTAssertEqual(batches, 0, "off during an await must prevent subsequent uploads")
        XCTAssertEqual(engine.status, .off)
    }
}

// icloudsync's tests for syncreview2's limits (the quarantine budget) and R3's other cases.
extension SyncEngineTests {
    func testQuarantineRetryWorkIsBoundedPerCycle() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.merge)
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        var records: [SyncCloudRecord] = []
        for i in 0..<100 {
            var r = SyncReplica()
            try r.edit(.init(.space, "unreadable-\(i)"), [.name: .text("U\(i)")], now: 5)
            let e = try SyncEnvelope.seal(r.log, group: group, device: r.clock.device, key: key)
            records.append(SyncCloudSchema.record(SyncEnvelope(version: 2, group: group, device: e.device, id: e.id, sealed: e.sealed)))
        }
        let seeded = records
        await db.change { try! $0.seed(seeded, zone: SyncCloudSchema.zone) }
        await b.engine.syncNow()
        XCTAssertEqual(b.engine.unreadableBatches, 100)
        for _ in 0..<4 {
            await b.engine.syncNow()
            XCTAssertLessThanOrEqual(b.engine.lastQuarantineRetries, SyncEngine.quarantineRetryCount)
            XCTAssertEqual(b.engine.unreadableBatches, 100, "still kept, still reported")
        }
    }

    func testOversizeURLsStayLocalAndSyncAgainWhenTheyFit() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a)
        let space = try XCTUnwrap(a.space("Work")).id
        let huge = "https://example.com/?" + String(repeating: "y", count: 20_000)
        let t = try a.store.openTab(url: huge, inSpace: space, activate: false)
        try a.store.move(.tab(t.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        let born = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == huge })
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        XCTAssertFalse(b.store.state.items.values.contains { $0.savedURL == huge }, "an oversize URL never leaves its Mac")
        // A remote rename of a pin that then becomes oversize locally doesn't touch the local one.
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/a" })
        let bItem = try XCTUnwrap(b.store.state.items.values.first { $0.savedURL == "https://example.com/a" })
        try a.store.perform(nil) { var c = item; c.savedURL = huge + "2"; a.store.put(c) }
        try b.store.renameItem(bItem.id, to: "Renamed on B")
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, huge + "2", "kept, not overwritten or deleted")
        XCTAssertNotNil(b.store.item(bItem.id), "no tombstone reached B")
        // Back to a URL that fits: it syncs again as the same record.
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.com/a-again")
        try a.store.replaceSavedURL(ofItem: born.id, with: "https://example.com/born-small")
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(b.store.item(bItem.id)?.savedURL, "https://example.com/a-again")
        XCTAssertTrue(b.store.state.items.values.contains { $0.savedURL == "https://example.com/born-small" })
        XCTAssertEqual(b.store.state.items.values.filter { $0.savedURL?.hasPrefix("https://example.com/a") == true }.count, 1)
    }
}

// syncreview2: added only to the isolated test tree.
private struct Review2Database: SyncCloudDatabase {
    let base: SyncMockCloudDatabase
    var before: @Sendable (SyncMockCloudDatabase.Call, [SyncCloudRecord]) async throws -> Void = { _, _ in }
    var after: @Sendable (SyncMockCloudDatabase.Call, [SyncCloudRecord]) async throws -> Void = { _, _ in }
    func accountStatus() async throws -> SyncCloudAccount {
        try await before(.accountStatus, []); let r = try await base.accountStatus(); try await after(.accountStatus, []); return r
    }
    func accountIdentity() async throws -> String {
        try await before(.accountIdentity, []); let r = try await base.accountIdentity(); try await after(.accountIdentity, []); return r
    }
    func createZone(_ z: String) async throws { try await before(.createZone, []); try await base.createZone(z); try await after(.createZone, []) }
    func subscribe(zone: String, id: String) async throws { try await before(.subscribe, []); try await base.subscribe(zone: zone, id: id); try await after(.subscribe, []) }
    func fetch(_ n: [String], zone: String) async throws -> [SyncCloudRecord] {
        try await before(.fetch, []); let r = try await base.fetch(n, zone: zone); try await after(.fetch, r); return r
    }
    func fetchChanges(zone: String, since token: Data?) async throws -> SyncCloudChanges {
        try await before(.fetchChanges, []); let r = try await base.fetchChanges(zone: zone, since: token); try await after(.fetchChanges, r.changed); return r
    }
    func save(_ r: [SyncCloudRecord], zone: String, mode: SyncSaveMode) async throws -> [String: Result<SyncCloudRecord, SyncCloudFailure>] {
        try await before(.save, r); let result = try await base.save(r, zone: zone, mode: mode); try await after(.save, r); return result
    }
}
private actor Review2Gate {
    var armed = false
    var count = 0
    func arm() { armed = true; count = 0 }
    func fire(_ nth: Int = 1) -> Bool { guard armed else { return false }; count += 1; if count == nth { armed = false; return true }; return false }
}

extension SyncEngineTests {
    func testReview2AccountChangesDuringGroupBatchAndDeviceUpload() async throws {
        for phase in [SyncCloudSchema.group, SyncCloudSchema.batch, SyncCloudSchema.device] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
            let store = try makeStore(clock)
            // Enough separate operations to need at least two batches.
            for i in 0..<510 { _ = try store.createSpace(name: "Private \(i)") }
            await gate.arm()
            let hook = Review2Database(base: db, after: { call, records in
                if call == .save, records.first?.type == phase, await gate.fire() {
                    await db.change { $0.identity = "_new-account"; $0.deleteZone(SyncCloudSchema.zone) }
                    // The app's account notification requests a rerun; it does not invalidate the current session.
                }
            })
            let engine = reviewEngine(store, hook, keys: keys)
            engine.setEnabled(true); await engine.syncNow()
            let leaked = await db.state.batchCount
            XCTAssertEqual(leaked, 0, "account changed after \(phase): subsequent batches must not reach the new account")
            XCTAssertFalse(engine.isEnabled, "must notice account change in \(phase), before reporting success")
            engine.setEnabled(false)
            try? FileManager.default.removeItem(at: root.appendingPathComponent("hook.json"))
        }
    }

    func testReview2DisableDuringUploadRetryDoesNotStartAnotherSave() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate(), box = ReviewEngineBox()
        let store = try makeStore(clock)
        await gate.arm()
        let hook = Review2Database(base: db, before: { call, records in
            if call == .save, records.first?.type == SyncCloudSchema.batch, await gate.fire() {
                await box.engine?.setEnabled(false)
                throw SyncCloudFailure.network(retryAfter: 0)
            }
        })
        let engine = SyncEngine(store: store, environment: .init(
            transport: { CloudKitSyncTransport(database: hook, device: $0, backoff: [0], sleep: { _ in }) },
            keys: keys, stateURL: root.appendingPathComponent("retry.json"), deviceName: "Retry",
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { _, _ in }, backup: { self.root }))
        engine.automatic = false; box.engine = engine
        engine.setEnabled(true); await engine.syncNow()
        let count = await db.state.batchCount
        XCTAssertEqual(count, 0, "a failed attempt committed nothing; retry initiated after Off must not upload")
        XCTAssertEqual(engine.status, .off)
    }

    func testReview2DisableDuringPrepareStopsSubsequentRequests() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), box = ReviewEngineBox()
        let hook = Review2Database(base: db, after: { call, _ in
            if call == .accountStatus { await box.engine?.setEnabled(false) }
        })
        let engine = reviewEngine(try makeStore(clock), hook, keys: keys); box.engine = engine
        engine.setEnabled(true); await engine.syncNow()
        let creates = await db.count(.createZone), subscriptions = await db.count(.subscribe)
        XCTAssertEqual(creates, 0, "must not create zone after Off")
        XCTAssertEqual(subscriptions, 0, "must not subscribe after Off")
        XCTAssertEqual(engine.status, .off)
    }

    func testReview2DisableDuringDownloadAndFirstSyncCompletion() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), box = ReviewEngineBox(), gate = Review2Gate()
        let a = try Mac("A", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); keys.copy(from: a.keys)
        let store = try makeStore(clock)
        let hook = Review2Database(base: db, after: { call, _ in
            if call == .fetchChanges, await gate.fire() { await box.engine?.setEnabled(false) }
        })
        let engine = reviewEngine(store, hook, keys: keys); box.engine = engine
        engine.setEnabled(true); await gate.arm(); await engine.syncNow()
        XCTAssertEqual(engine.status, .off)
        XCTAssertFalse(store.orderedSpaces.contains { $0.name == "Work" }, "download completing after Off must not apply")
        engine.setEnabled(true); await engine.syncNow()
        guard case .choosing = engine.status else { return XCTFail("expected choice") }
        await gate.arm()
        _ = try? await engine.choose(.merge)
        XCTAssertEqual(engine.status, .off, "first-sync completion must not overwrite Off")
    }

    func testReview2FailedCheckpointStillBlocksUploadOnSecondCycle() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: SyncMockCloudDatabase(), root: root, clock: clock)
        _ = db // the Mac owns its database
        await a.turnOn()
        _ = try a.store.createSpace(name: "Never durably captured")
        let file = a.folder.appendingPathComponent("sync.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let before = await a.db.state.batchCount
        await a.engine.syncNow(); await a.engine.syncNow()
        let after = await a.db.state.batchCount
        XCTAssertEqual(after, before, "a second cycle must not upload an outbox whose checkpoint still cannot be saved")
    }

    func testReview2ResetBetweenPagesAndAfterAnotherDeviceRecreatesZone() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
        let store = try makeStore(clock)
        _ = try store.createSpace(name: "Full history")
        let hook = Review2Database(base: db, after: { call, _ in
            if call == .fetchChanges, await gate.fire() { await db.change { $0.deleteZone(SyncCloudSchema.zone) } }
        })
        let engine = reviewEngine(store, hook, keys: keys)
        engine.setEnabled(true); await engine.syncNow()
        let group = try XCTUnwrap(engine.groupID), key = try XCTUnwrap(keys.key(group: group))
        // Force a multi-page full read; lose the zone between its first and second pages.
        await db.change { $0.pageSize = 1; $0.expireTokens(SyncCloudSchema.zone) }
        await gate.arm(); await engine.syncNow(); await engine.syncNow()
        XCTAssertFalse(engine.needsRecovery)
        XCTAssertEqual(engine.status, .upToDate)
        // Another device recreates the zone and restores the same group before A sees it.
        let g = try SyncGroupRecord.make(group: group, key: key, created: Date())
        await db.change { $0.deleteZone(SyncCloudSchema.zone); try! $0.seed([SyncCloudSchema.record(g)], zone: SyncCloudSchema.zone) }
        await engine.syncNow()
        XCTAssertFalse(engine.needsRecovery)
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: keys); await c.turnOn(); try await c.engine.choose(.replace)
        XCTAssertTrue(c.spaceNames.contains("Full history")); XCTAssertEqual(c.engine.groupID, group)
    }

    func testReview2MalformedRecordCanRecoverAfterRepairAndRestart() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: SyncMockCloudDatabase(), root: root, clock: clock)
        _ = db
        await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        var remote = SyncReplica()
        try remote.edit(.init(.space, "repaired"), [.name: .text("Repaired"), .profile: .text(a.store.defaultProfile.id)], now: 10)
        let envelope = try SyncEnvelope.seal(remote.log, group: group, device: remote.clock.device, key: key)
        let good = SyncCloudSchema.record(envelope)
        var bad = good; bad.fields["sealed"] = .string("broken")
        let damaged = bad
        await a.db.change { try! $0.seed([damaged], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow(); XCTAssertEqual(a.engine.unreadableBatches, 1)
        await a.db.change { try! $0.seed([good], zone: SyncCloudSchema.zone) }
        a.relaunch(); await a.engine.syncNow(); await a.engine.syncNow()
        XCTAssertTrue(a.spaceNames.contains("Repaired"))
        XCTAssertEqual(a.engine.unreadableBatches, 0, "repaired record must clear durable malformed marker")
        XCTAssertEqual(a.engine.status, .upToDate)
    }

    func testReview2UnreadableCreationThenValidEditAndRepair() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: SyncMockCloudDatabase(), root: root, clock: clock)
        _ = db
        await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        var remote = SyncReplica()
        let creation = try remote.edit(.init(.space, "damaged-create"), [.name: .text("Initial"), .profile: .text(a.store.defaultProfile.id)], now: 10)
        let good = try SyncEnvelope.seal([creation], group: group, device: remote.clock.device, key: key)
        let bad = SyncEnvelope(version: 2, group: group, device: good.device, id: good.id, sealed: good.sealed)
        let edit = try remote.edit(.init(.space, "damaged-create"), [.name: .text("Renamed")], now: 20)
        let later = try SyncEnvelope.seal([edit], group: group, device: remote.clock.device, key: key)
        await a.db.change { try! $0.seed([SyncCloudSchema.record(bad), SyncCloudSchema.record(later)], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow(); a.relaunch(); await a.engine.syncNow()
        XCTAssertEqual(a.engine.unreadableBatches, 1)
        XCTAssertNil(a.store.space("damaged-create"), "name-only edit cannot materialize missing profile")
        await a.db.change { try! $0.seed([SyncCloudSchema.record(good)], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow()
        XCTAssertEqual(a.store.space("damaged-create")?.name, "Renamed")
        XCTAssertEqual(a.engine.status, .upToDate)
    }

    func testReview2PreviouslySyncedURLBecomingOversizeStaysLocal() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let huge = "https://example.com/?" + String(repeating: "x", count: 20_000)
        // Use the store's public item-update API to change the saved URL.
        try a.store.perform(nil) { var changed = item; changed.savedURL = huge; a.store.put(changed) }
        _ = try b.store.createSpace(name: "Unrelated remote edit"); await b.engine.syncNow()
        await a.engine.syncNow()
        XCTAssertTrue(a.store.item(item.id)?.savedURL == huge, "oversize URL is local-only, not deleted when a remote edit triggers apply")
    }

    func testReview2PersistedStoreReplaysActualApplyJournal() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), keys = InMemorySyncKeyStore()
        await a.turnOn(); keys.copy(from: a.keys)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("persisted.sqlite").path
        let store = try SpacesStore(path: path)
        let engine = reviewEngine(store, db, keys: keys)
        engine.setEnabled(true); await engine.syncNow(); try await engine.choose(.replace)
        let tab = try a.store.openTab(url: "https://journal.example", inSpace: a.store.selectedSpace.id)
        await a.engine.syncNow()
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: a.store.selectedSpace.id, parentID: nil, index: 0))
        await a.engine.syncNow()
        let file = root.appendingPathComponent("hook.json")
        var journal: Data?
        let observer = store.observe { _ in
            if store.state.items.values.contains(where: { $0.savedURL == "https://journal.example" }) {
                journal = try? Data(contentsOf: file)
            }
        }
        await engine.syncNow(); store.removeObserver(observer); try store.flush()
        let captured = try XCTUnwrap(journal)
        let state = try JSONDecoder().decode(SyncEngine.State.self, from: captured)
        XCTAssertEqual(state.applyMode, .merge, "capture the actual journal at store commit, not the pre-cycle checkpoint")
        try captured.write(to: file)
        let reopened = try SpacesStore(path: path)
        let restarted = reviewEngine(reopened, db, keys: keys)
        await restarted.syncNow()
        XCTAssertEqual(reopened.state.items.values.filter { $0.savedURL == "https://journal.example" }.count, 1)
        XCTAssertEqual(restarted.status, .upToDate)
    }
}

extension SyncEngineTests {
    func testReview2LateNetworkFailureDoesNotOverwriteOff() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), box = ReviewEngineBox()
        let hook = Review2Database(base: db, before: { call, _ in
            if call == .fetchChanges {
                await box.engine?.setEnabled(false)
                throw SyncCloudFailure.network(retryAfter: nil)
            }
        })
        let engine = reviewEngine(try makeStore(clock), hook, keys: keys); box.engine = engine
        engine.setEnabled(true); await engine.syncNow()
        XCTAssertFalse(engine.isEnabled)
        XCTAssertEqual(engine.status, .off, "an old session's error must not replace Off with Retrying")
    }

    func testReview2PartialLaterPageRedeliversAfterEngineRelaunch() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        _ = try a.store.createSpace(name: "First page"); await a.engine.syncNow()
        _ = try a.store.createSpace(name: "Failed page"); await a.engine.syncNow()
        let records = await db.state.records(zone: SyncCloudSchema.zone)
        let key = try XCTUnwrap(a.keys.key(group: XCTUnwrap(a.engine.groupID)))
        let failed = try XCTUnwrap(records.first { r in
            guard let e = SyncCloudSchema.envelope(r), let ops = try? e.open(group: a.engine.groupID!, key: key) else { return false }
            return ops.contains { $0.fields[.name] == .text("Failed page") }
        })
        await db.change { $0.pageSize = 1 }
        await db.failRecords([failed.name], with: .other("per-record failure"))
        await b.engine.syncNow()
        XCTAssertNotEqual(b.engine.status, .upToDate)
        b.relaunch(); await db.clearRecordFaults(); await b.engine.syncNow()
        XCTAssertTrue(b.spaceNames.contains("First page")); XCTAssertTrue(b.spaceNames.contains("Failed page"))
        XCTAssertEqual(b.engine.status, .upToDate)
    }
}

extension SyncEngineTests {
    func testReview2ResetBetweenUploadBatchesRestoresAllHistory() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
        let store = try makeStore(clock)
        _ = try store.createSpace(name: "Old history")
        let hook = Review2Database(base: db, after: { call, records in
            if call == .save, records.first?.type == SyncCloudSchema.batch, await gate.fire() {
                await db.change { $0.deleteZone(SyncCloudSchema.zone) }
            }
        })
        let engine = reviewEngine(store, hook, keys: keys)
        engine.setEnabled(true); await engine.syncNow()
        for i in 0..<510 { _ = try store.createSpace(name: "Queued \(i)") }
        await gate.arm(); await engine.syncNow(); await engine.syncNow()
        XCTAssertFalse(engine.needsRecovery); XCTAssertEqual(engine.status, .upToDate)
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: keys); await c.turnOn(); try await c.engine.choose(.replace)
        XCTAssertEqual(c.spaceNames.count, 512)
        XCTAssertTrue(c.spaceNames.contains("Old history")); XCTAssertEqual(c.engine.groupID, engine.groupID)
    }
}


// icloudsync: the excluded-row rule for every remote removal (unpin, folder deletion, Space deletion) and re-entry.
extension SyncEngineTests {
    func testExcludedRowsSurviveEveryRemoteRemovalAndComeBackWhole() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let inDocs = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/a" })
        let atRoot = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let work = try XCTUnwrap(a.space("Work")).id
        let long = "https://example.test/" + String(repeating: "q", count: 20_000)
        try a.store.replaceSavedURL(ofItem: inDocs.id, with: long + "a")
        try a.store.replaceSavedURL(ofItem: atRoot.id, with: long + "b")
        await a.engine.syncNow()
        // B unpins one and deletes the other's folder, then the whole Space.
        try b.store.move(.item(atRoot.id), to: .today(spaceID: work, index: 0))
        try b.store.deleteItem(try XCTUnwrap(b.store.state.items.values.first { $0.title == "Docs" }).id)
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(inDocs.id)?.savedURL, long + "a", "a folder deleted elsewhere never erases a local-only row")
        XCTAssertNil(a.store.item(inDocs.id)?.parentID, "it moves to its Space's root")
        XCTAssertEqual(a.store.item(atRoot.id)?.savedURL, long + "b", "an unpin elsewhere never erases it either")
        try b.store.deleteSpace(work)
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertNotNil(a.store.space(work), "the Space stays here while it holds local-only rows")
        XCTAssertNotNil(a.store.item(inDocs.id)); XCTAssertNotNil(a.store.item(atRoot.id))
        // Both fit again: re-created under their records, and their Space with them.
        try a.store.replaceSavedURL(ofItem: inDocs.id, with: "https://example.test/a-back")
        try a.store.replaceSavedURL(ofItem: atRoot.id, with: "https://example.test/b-back")
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertNotNil(b.store.space(work), "the Space comes back with them")
        XCTAssertEqual(b.store.item(inDocs.id)?.savedURL, "https://example.test/a-back")
        XCTAssertEqual(b.store.item(atRoot.id)?.savedURL, "https://example.test/b-back")
        XCTAssertEqual(b.store.item(atRoot.id)?.spaceID, work)
        await a.engine.syncNow()
        XCTAssertEqual(a.store.item(atRoot.id)?.savedURL, "https://example.test/b-back", "and stays on the Mac it came from")
    }
}


// icloudsync: a kept Space comes back only by a local edit, once per edit, never by itself (T1's no-ping-pong rule).
extension SyncEngineTests {
    func testKeptSpaceComesBackOnlyByALocalEditAndSurvivesASecondDeletion() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let excluded = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let work = try XCTUnwrap(excluded.spaceID)
        try a.store.replaceSavedURL(ofItem: excluded.id, with: "https://example.test/" + String(repeating: "k", count: 20_000))
        await a.engine.syncNow()
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertNotNil(a.store.space(work)); XCTAssertNil(b.store.space(work))
        // A local edit in the kept Space (a new pin) brings it back, once.
        let tab = try a.store.openTab(url: "https://example.test/first", inSpace: work)
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: work, parentID: nil, index: 0))
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertNotNil(b.store.space(work))
        XCTAssertTrue(b.store.state.items.values.contains { $0.savedURL == "https://example.test/first" })
        // B deletes it again: A keeps it again for the local-only pin, and it stays quiet.
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertNotNil(a.store.space(work))
        XCTAssertFalse(a.store.state.items.values.contains { $0.savedURL == "https://example.test/first" }, "B's deletion of the pin applies")
        XCTAssertNil(b.store.space(work))
        let quiet = await db.state.batchCount
        for _ in 0..<4 { await a.engine.syncNow(); await b.engine.syncNow() }
        let after = await db.state.batchCount
        XCTAssertEqual(after, quiet, "no resurrection without a local edit: no ping-pong")
        XCTAssertNil(b.store.space(work))
        // Renaming the kept Space is a local edit too: back again, with the new name.
        try a.store.updateSpace(work) { $0.name = "Work, again" }
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(b.store.space(work)?.name, "Work, again")
        XCTAssertNil(b.store.state.items.values.first { $0.id == excluded.id }, "the local-only pin itself never leaves A")
    }
}

// icloudsync: U1's rule, checked on the source. Every `await` in SyncEngine.swift is followed at once by its session
// check, so an obsolete cycle that resumes changes nothing: `; try live(gen)` as the next statement, `, isLive(gen)` in
// the same condition list, or a next code line that starts with `try live(gen)` or `guard (self.)isLive(gen)`. The
// exceptions return, or say why on the line (`// await-ok: <why>`). A line check, not a proof: it keeps an edit from
// dropping a check.
private func awaitsWithoutSessionCheck(_ source: String) -> (awaits: Int, exempt: Int, missing: [String]) {
    let lines = source.components(separatedBy: "\n")
    // A line without its `//` comment (outside string literals).
    func code(_ line: String) -> String {
        var inString = false, previous: Character = " ", result = ""
        for c in line {
            if c == "\"" && previous != "\\" { inString.toggle() }
            if !inString && c == "/" && previous == "/" { result.removeLast(); return result }
            result.append(c); previous = c
        }
        return result
    }
    func isWord(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
    var awaits = 0, exempt = 0, missing: [String] = []
    for (i, line) in lines.enumerated() {
        let text = code(line)
        var from = text.startIndex
        while let r = text.range(of: "await", range: from..<text.endIndex) {
            from = r.upperBound
            guard !isWord(r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil),
                  !isWord(r.upperBound < text.endIndex ? text[r.upperBound] : nil) else { continue }
            awaits += 1
            let head = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let reason = line.components(separatedBy: "// await-ok:").dropFirst().first?.trimmingCharacters(in: .whitespaces)
            if reason?.isEmpty == false || ["return", "return try", "return try?"].contains(where: head.hasSuffix) {
                exempt += 1
                continue
            }
            let statement = text[r.upperBound...].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if statement[0].contains(", isLive(gen)") || statement[0].contains(", self.isLive(gen)") { continue }
            if statement.count == 2 {
                if statement[1].trimmingCharacters(in: .whitespaces).hasPrefix("try live(gen)") { continue }
            } else if let next = lines[(i + 1)...].lazy.map({ code($0).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
                      ["try live(gen)", "guard isLive(gen)", "guard self.isLive(gen)"].contains(where: next.hasPrefix) {
                continue
            }
            missing.append("SyncEngine.swift:\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
    return (awaits, exempt, missing)
}

extension SyncEngineTests {
    func testEveryAwaitInTheEngineIsFollowedByItsSessionCheck() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AircKit/Sync/SyncEngine.swift")
        let found = awaitsWithoutSessionCheck(try String(contentsOf: url, encoding: .utf8))
        XCTAssertEqual(found.missing, [], "an await without its session check right after it (see SyncEngine.isLive)")
        XCTAssertGreaterThan(found.awaits, 40, "read the engine's source")
        XCTAssertLessThanOrEqual(found.exempt, 10, "a new exception needs a reason, and this number raised on purpose")
    }

    func testTheAwaitCheckFindsAMissingOrLateSessionCheck() {
        // U1 as it was: the bind's completion went on to the key and status without a check.
        let u1 = """
                        await t.bind(account: identity)
                    }
                    guard let key = try key ?? env.keys.key(group: group) else {
            """
        XCTAssertEqual(awaitsWithoutSessionCheck(u1).missing.count, 1)
        // A change before the check on the same line, a check two lines on, a comment that only looks like one.
        let late = """
            let envelopes = try await t.read(); state.malformed = []; try live(gen)
            await t.acknowledge()
            state.checkpoint = nil
            try live(gen)
            await t.restore(checkpoint: nil) // try live(gen)
            """
        XCTAssertEqual(awaitsWithoutSessionCheck(late).missing.count, 3)
        let good = """
            let envelopes = try await t.read(); try live(gen)
            if let identity = try? await t.accountIdentity(), isLive(gen), let expected = pending?.account {
            let records = await t.devices
            guard isLive(gen) else { return }
            return try await join(t, gen)
            """
        XCTAssertEqual(awaitsWithoutSessionCheck(good).missing, [])
    }
}


// syncreview3: reviewer additions, frozen production code untouched.
private actor Review3Pause {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

extension SyncEngineTests {
    private func review3Engine(_ store: SpacesStore, _ database: any SyncCloudDatabase, keys: InMemorySyncKeyStore,
                               file: String, sleep: @escaping @Sendable (Double) async -> Void = { _ in }) -> SyncEngine {
        let e = SyncEngine(store: store, environment: .init(
            transport: { CloudKitSyncTransport(database: database, device: $0, backoff: [0, 0, 0], sleep: sleep) },
            keys: keys, stateURL: root.appendingPathComponent(file), deviceName: "Review 3",
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { _, _ in }, backup: { self.root }))
        e.automatic = false
        return e
    }

    func testReview3AccountChangeInRecoveryPageAndRetrySleep() async throws {
        for phase in ["recovery", "page", "sleep"] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
            let store = try makeStore(clock)
            for i in 0..<130 { _ = try store.createSpace(name: "Historical \(i)") }
            let hook = Review2Database(base: db, after: { call, records in
                let hit = phase == "recovery" ? (call == .save && records.first?.type == SyncCloudSchema.batch) : (phase == "page" && call == .fetchChanges)
                if hit, await gate.fire() { await db.change { $0.identity = "changed"; $0.deleteZone(SyncCloudSchema.zone) } }
            })
            let e = review3Engine(store, hook, keys: keys, file: "account-\(phase).json", sleep: { _ in
                if phase == "sleep", await gate.fire() { await db.change { $0.identity = "changed"; $0.deleteZone(SyncCloudSchema.zone) } }
            })
            e.setEnabled(true); await e.syncNow()
            if phase == "recovery" { await db.change { $0.deleteZone(SyncCloudSchema.zone) } }
            if phase == "page" { await db.change { $0.pageSize = 1; $0.expireTokens(SyncCloudSchema.zone) } }
            if phase == "sleep" {
                _ = try store.createSpace(name: "Queued private edit")
                await db.fail(.save, with: .network(retryAfter: 0))
            }
            await gate.arm(); await e.syncNow()
            let count = await db.state.batchCount
            XCTAssertEqual(count, 0, phase)
            XCTAssertFalse(e.isEnabled, phase)
        }
    }

    func testReview3QuickOffOnAtPrepareAndEveryReadPage() async throws {
        // Three full-read pages: group, own batch, device. Quick toggle inside each suspended call.
        for (phase, nth) in [("create", 1), ("subscribe", 1), ("page", 1), ("page", 2), ("page", 3)] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate(), box = ReviewEngineBox()
            let hook = Review2Database(base: db, after: { call, _ in
                let hit = (phase == "create" && call == .createZone) || (phase == "subscribe" && call == .subscribe) || (phase == "page" && call == .fetchChanges)
                if hit, await gate.fire(nth) {
                    await MainActor.run { box.engine?.setEnabled(false); box.engine?.setEnabled(true) }
                }
            })
            let e = review3Engine(try makeStore(clock), hook, keys: keys, file: "toggle-\(phase)-\(nth).json"); box.engine = e
            if phase == "page" {
                e.setEnabled(true); await e.syncNow()
                await db.change { $0.pageSize = 1; $0.expireTokens(SyncCloudSchema.zone) }
            }
            await gate.arm(); e.setEnabled(true); await e.syncNow()
            XCTAssertEqual(e.status, .connecting, "old cycle must not overwrite new session: \(phase) \(nth)")
            let afterOld = await db.count(.fetchChanges)
            if phase == "page" { XCTAssertEqual(afterOld, 2 + nth, "initial read + expired token + nth page, no later old pages") }
            if phase == "create" { let count = await db.count(.subscribe); XCTAssertEqual(count, 0) }
            if phase != "page" { let count = await db.state.batchCount; XCTAssertEqual(count, 0) }
            await e.syncNow()
            XCTAssertEqual(e.status, .upToDate, "fresh session must work: \(phase) \(nth)")
            e.setEnabled(false)
        }
    }

    func testReview3QuickOffOnAtEachRetrySleep() async throws {
        for nth in 1...3 {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate(), box = ReviewEngineBox()
            let store = try makeStore(clock)
            let e = review3Engine(store, db, keys: keys, file: "retry-\(nth).json", sleep: { _ in
                if await gate.fire(nth) { await MainActor.run { box.engine?.setEnabled(false); box.engine?.setEnabled(true) } }
            }); box.engine = e
            e.setEnabled(true); await e.syncNow()
            let before = await db.state.batchCount
            _ = try store.createSpace(name: "New edit")
            await db.fail(.save, with: .network(retryAfter: 0), .network(retryAfter: 0), .network(retryAfter: 0))
            await gate.arm(); await e.syncNow()
            let after = await db.state.batchCount
            XCTAssertEqual(after, before, "old retry \(nth) must not save after Off")
            await e.syncNow(); XCTAssertEqual(e.status, .upToDate)
            let recovered = await db.state.batchCount; XCTAssertGreaterThan(recovered, before)
            e.setEnabled(false)
        }
    }

    func testReview3NewSessionProgressDoesNotWaitForOldRetrySleep() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), pause = Review3Pause()
        let store = try makeStore(clock)
        let e = review3Engine(store, db, keys: keys, file: "held-sleep.json", sleep: { _ in await pause.wait() })
        e.setEnabled(true); await e.syncNow()
        _ = try store.createSpace(name: "New session edit")
        await db.fail(.save, with: .network(retryAfter: 3600))
        let old = Task { await e.syncNow() }
        while !(await pause.entered) { await Task.yield() }
        e.setEnabled(false); e.setEnabled(true)
        var finished = false
        let fresh = Task { await e.syncNow(); finished = true }
        // A new session should finish while the obsolete retry-after sleeper is still held.
        // Bound observation to 0.25s; release the controlled sleeper even on failure, never hang the suite.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(finished, "new session is blocked by old retry-after (3600s in this scenario)")
        await pause.release(); await old.value; await fresh.value
        XCTAssertEqual(e.status, .upToDate, "it only recovers after the obsolete sleeper returns")
    }

    func testReview3ExcludedMoveRenameRemoteEditAndReturn() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let target = try a.store.createSpace(name: "Destination")
        let huge = "https://example.test/" + String(repeating: "z", count: 20000)
        try a.store.replaceSavedURL(ofItem: item.id, with: huge)
        try a.store.renameItem(item.id, to: "Local excluded rename")
        try a.store.move(.item(item.id), to: .pinned(spaceID: target.id, parentID: nil, index: 0))
        await a.engine.syncNow(); await b.engine.syncNow()
        try b.store.renameItem(item.id, to: "Remote rename")
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, huge)
        XCTAssertEqual(a.store.item(item.id)?.title, "Local excluded rename")
        XCTAssertEqual(a.store.item(item.id)?.spaceID, target.id)
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/returned")
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(b.store.item(item.id)?.title, "Local excluded rename")
        XCTAssertEqual(b.store.item(item.id)?.spaceID, target.id)
        XCTAssertEqual(b.store.item(item.id)?.savedURL, "https://example.test/returned")
    }

    func testReview3ExcludedPinRemoteDeletionThenSmallURL() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/" + String(repeating: "z", count: 20000))
        await a.engine.syncNow()
        try b.store.perform(nil) { b.store.remove(Item.self, item.id) }
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertNotNil(a.store.item(item.id), "remote tombstone must not delete excluded pin")
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/restored")
        await a.engine.syncNow(); await b.engine.syncNow()
        _ = try b.store.createSpace(name: "Trigger materialization"); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, "https://example.test/restored", "becoming supported must not delete local pin")
        XCTAssertEqual(b.store.item(item.id)?.savedURL, "https://example.test/restored", "supported pin should sync again")
    }

    func testReview3RepeatedPersistenceFailureRecoveryAndPostUploadFailure() async throws {
        for afterUpload in [false, true] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
            let store = try makeStore(clock), file = root.appendingPathComponent("save-\(afterUpload).json")
            let hook = Review2Database(base: db, after: { call, records in
                if afterUpload, call == .save, records.first?.type == SyncCloudSchema.batch, await gate.fire() {
                    try FileManager.default.removeItem(at: file)
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
                }
            })
            let e = review3Engine(store, hook, keys: keys, file: file.lastPathComponent)
            e.setEnabled(true); await e.syncNow()
            for i in 0..<210 { _ = try store.createSpace(name: "Unsaved \(i)") }
            let before = await db.state.batchCount
            if afterUpload { await gate.arm() } else {
                try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            }
            for _ in 0..<4 { await e.syncNow() }
            let during = await db.state.batchCount
            XCTAssertEqual(during, before + (afterUpload ? 1 : 0), "no subsequent batch while checkpoint is broken")
            try FileManager.default.removeItem(at: file)
            await e.syncNow(); XCTAssertEqual(e.status, .upToDate); XCTAssertEqual(e.pendingUploads, 0)
            let peer = try Mac("Peer-\(afterUpload)", db: db, root: root, clock: clock)
            peer.keys.copy(from: keys); await peer.turnOn(); try await peer.engine.choose(.replace)
            XCTAssertEqual(peer.spaceNames.count, 211)
        }
    }

    func testReview3MalformedDeletionReplacementAndFullRead() async throws {
        let a = try Mac("A", db: SyncMockCloudDatabase(), root: root, clock: clock); await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        var r = SyncReplica(); try r.edit(.init(.space, "replacement"), [.name: .text("Replacement"), .profile: .text(a.store.defaultProfile.id)], now: 30)
        let good = SyncCloudSchema.record(try SyncEnvelope.seal(r.log, group: group, device: r.clock.device, key: key))
        var bad = good; bad.fields["sealed"] = .string("bad"); let malformed = bad
        await a.db.change { try! $0.seed([malformed], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow(); XCTAssertEqual(a.engine.unreadableBatches, 1)
        await a.db.change { $0.seq += 1; $0.zones[SyncCloudSchema.zone]?.records[good.name] = nil; $0.zones[SyncCloudSchema.zone]?.deletions[good.name] = $0.seq }
        a.relaunch(); await a.engine.syncNow(); XCTAssertEqual(a.engine.unreadableBatches, 0)
        await a.db.change { try! $0.seed([good], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow(); XCTAssertEqual(a.store.space("replacement")?.name, "Replacement"); XCTAssertEqual(a.engine.status, .upToDate)
        await a.db.change { try! $0.seed([malformed], zone: SyncCloudSchema.zone) }
        await a.engine.syncNow(); XCTAssertEqual(a.engine.unreadableBatches, 1)
        await a.db.change { $0.zones[SyncCloudSchema.zone]?.records[good.name] = nil; $0.expireTokens(SyncCloudSchema.zone) }
        await a.engine.syncNow(); XCTAssertEqual(a.engine.unreadableBatches, 0, "full-read absence clears marker")
    }

    func testReview3QuarantineRotationEventuallyRetriesEveryOldItem() async throws {
        let a = try Mac("A", db: SyncMockCloudDatabase(), root: root, clock: clock); await a.turnOn()
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        let file = a.folder.appendingPathComponent("sync.json")
        var s = try JSONDecoder().decode(SyncEngine.State.self, from: Data(contentsOf: file))
        // Model an upgraded client: now-readable envelopes already in the persisted quarantine, with no new cloud events.
        // Include one over the retry-byte budget to test that it does not starve items behind it.
        let oversized = SyncEnvelope(version: 2, group: group, device: UUID(), id: UUID(), sealed: Data(repeating: 1, count: SyncEngine.quarantineRetryBytes + 1))
        s.quarantine = [oversized]
        for i in 0..<99 {
            var r = SyncReplica(); try r.edit(.init(.space, "old-\(i)"), [.name: .text("Old \(i)"), .profile: .text(a.store.defaultProfile.id)], now: 50)
            s.quarantine.append(try SyncEnvelope.seal(r.log, group: group, device: r.clock.device, key: key))
        }
        try JSONEncoder().encode(s).write(to: file); a.relaunch()
        for i in 0..<6 {
            let new = SyncEnvelope(version: 2, group: group, device: UUID(), id: UUID(), sealed: Data([1]))
            await a.db.change { try! $0.seed([SyncCloudSchema.record(new)], zone: SyncCloudSchema.zone) }
            await a.engine.syncNow()
            XCTAssertLessThanOrEqual(a.engine.lastQuarantineRetries, 32)
            if i == 2 { a.relaunch() }
        }
        XCTAssertEqual(a.store.orderedSpaces.filter { $0.id.hasPrefix("old-") }.count, 99, "all old batches must eventually get their turn despite new arrivals/relaunch")
        XCTAssertEqual(a.engine.unreadableBatches, 7)
    }
}

extension SyncEngineTests {
    func testReview3MalformedRepairedOrDeletedBetweenPages() async throws {
        for repair in [false, true] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate()
            let store = try makeStore(clock)
            // Test hook only acts on the page containing the bad record, not the initial sync.
            let hook = Review2Database(base: db, after: { call, records in
                if call == .fetchChanges, let bad = records.first(where: { $0.fields["sealed"] == .string("broken") }), await gate.fire() {
                    await db.change { state in
                        if repair {
                            var good = bad
                            good.fields["sealed"] = good.fields["savedSealed"]
                            good.fields["savedSealed"] = nil
                            try! state.seed([good], zone: SyncCloudSchema.zone)
                        } else {
                            state.seq += 1
                            state.zones[SyncCloudSchema.zone]?.records[bad.name] = nil
                            state.zones[SyncCloudSchema.zone]?.deletions[bad.name] = state.seq
                        }
                    }
                }
            })
            let e = review3Engine(store, hook, keys: keys, file: "pages-\(repair).json")
            e.setEnabled(true); await e.syncNow()
            let group = try XCTUnwrap(e.groupID), key = try XCTUnwrap(keys.key(group: group))
            var r = SyncReplica(); try r.edit(.init(.space, "page-repair"), [.name: .text("Page repaired"), .profile: .text(store.defaultProfile.id)], now: 30)
            let good = SyncCloudSchema.record(try SyncEnvelope.seal(r.log, group: group, device: r.clock.device, key: key))
            var bad = good; bad.fields["savedSealed"] = bad.fields["sealed"]; bad.fields["sealed"] = .string("broken"); let damaged = bad
            let filler = SyncCloudRecord(name: "irrelevant", type: "Other", fields: [:])
            await db.change { $0.pageSize = 1; try! $0.seed([damaged, filler], zone: SyncCloudSchema.zone) }
            await gate.arm(); await e.syncNow(); await e.syncNow()
            if repair { XCTAssertEqual(store.space("page-repair")?.name, "Page repaired") }
            XCTAssertEqual(e.unreadableBatches, 0, "later page \(repair ? "repair" : "deletion") supersedes malformed entry from earlier page")
            XCTAssertEqual(e.status, .upToDate)
        }
    }

    func testReview3RemoteSpaceDeletionDoesNotEraseExcludedPin() async throws {
        let db = SyncMockCloudDatabase(), a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let huge = "https://example.test/" + String(repeating: "x", count: 20000)
        try a.store.replaceSavedURL(ofItem: item.id, with: huge); await a.engine.syncNow()
        try b.store.deleteSpace(try XCTUnwrap(b.space("Work")).id)
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, huge, "excluded local-only data must survive remote parent deletion")
    }
}

// syncreview4: isolated reviewer tests; predecessor bytes are unchanged.
extension SyncEngineTests {
    private func review4Pair() async throws -> (Mac, Mac) {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        try seedWork(a); await a.turnOn(); b.keys.copy(from: a.keys); await b.turnOn(); try await b.engine.choose(.replace)
        return (a, b)
    }
    private var review4Huge: String { "https://example.test/" + String(repeating: "x", count: 20000) }

    func testReview4KeptSpaceQuietReentryAndRepeatedDeletion() async throws {
        let (a,b) = try await review4Pair()
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/a" })
        let work = try XCTUnwrap(item.spaceID)
        try a.store.replaceSavedURL(ofItem: item.id, with: review4Huge); await a.engine.syncNow()
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.state.items.values.filter { $0.spaceID == work }.count, 1)
        XCTAssertNotNil(a.store.space(work)); XCTAssertNil(b.store.space(work))
        let before = await a.db.state.batchCount
        for _ in 0..<6 { await a.engine.syncNow(); await b.engine.syncNow() }
        let after = await a.db.state.batchCount
        XCTAssertEqual(before, after, "kept Space must not resurrect or fight without a local edit")
        a.relaunch(); await a.engine.syncNow()
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/back")
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(b.store.item(item.id)?.savedURL, "https://example.test/back")
        XCTAssertEqual(a.store.orderedSpaces.map(\.id).sorted(), b.store.orderedSpaces.map(\.id).sorted())
        XCTAssertEqual(b.store.orderedSpaces.filter { $0.id == work }.count, 1)
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertNil(a.store.space(work)); XCTAssertNil(a.store.item(item.id))
    }

    func testReview4SameIDSpaceRecreatedRemotelyWhileExcluded() async throws {
        let (a,b) = try await review4Pair()
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let work = try XCTUnwrap(item.spaceID), saved = try XCTUnwrap(b.store.space(work))
        try a.store.replaceSavedURL(ofItem: item.id, with: review4Huge); await a.engine.syncNow()
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        try b.store.perform(nil) { var restored = saved; restored.name = "Restored elsewhere"; b.store.put(restored) }
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, review4Huge)
        XCTAssertEqual(a.store.space(work)?.name, "Restored elsewhere")
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/restored")
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(b.store.item(item.id)?.savedURL, "https://example.test/restored")
        XCTAssertEqual(a.store.orderedSpaces.map(\.id).sorted(), b.store.orderedSpaces.map(\.id).sorted())
    }

    func testReview4ExcludedFolderMoveThenRemoteParentDeletion() async throws {
        let (a,b) = try await review4Pair()
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/a" })
        let work = try XCTUnwrap(item.spaceID)
        let folder = try a.store.createFolder(named: "New folder", inSpace: work)
        await a.engine.syncNow(); await b.engine.syncNow()
        try a.store.replaceSavedURL(ofItem: item.id, with: review4Huge)
        try a.store.move(.item(item.id), to: .pinned(spaceID: work, parentID: folder.id, index: 0))
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertNotEqual(b.store.item(item.id)?.parentID, folder.id)
        try b.store.renameItem(item.id, to: "Elsewhere"); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.parentID, folder.id)
        try b.store.deleteItem(folder.id); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, review4Huge); XCTAssertNil(a.store.item(item.id)?.parentID)
        let f2 = try a.store.createFolder(named: "Final folder", inSpace: work)
        try a.store.move(.item(item.id), to: .pinned(spaceID: work, parentID: f2.id, index: 0))
        await a.engine.syncNow(); a.relaunch(); await a.engine.syncNow()
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/folder-back")
        await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(b.store.item(item.id)?.parentID, f2.id)
        XCTAssertEqual(b.store.item(item.id)?.savedURL, "https://example.test/folder-back")
    }

    func testReview4TwoExcludedMacsReturnIndependently() async throws {
        let (a,b) = try await review4Pair()
        let c = try Mac("C", db: a.db, root: root, clock: clock)
        c.keys.copy(from: a.keys); await c.turnOn(); try await c.engine.choose(.replace)
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" }), work = try XCTUnwrap(item.spaceID)
        try a.store.replaceSavedURL(ofItem: item.id, with: review4Huge + "A")
        try b.store.replaceSavedURL(ofItem: item.id, with: review4Huge + "B")
        await a.engine.syncNow(); await b.engine.syncNow()
        try c.store.deleteSpace(work); await c.engine.syncNow(); await a.engine.syncNow(); await b.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, review4Huge + "A")
        XCTAssertEqual(b.store.item(item.id)?.savedURL, review4Huge + "B")
        try a.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/from-a")
        await a.engine.syncNow(); await b.engine.syncNow(); await c.engine.syncNow()
        XCTAssertEqual(b.store.item(item.id)?.savedURL, review4Huge + "B")
        XCTAssertEqual(c.store.item(item.id)?.savedURL, "https://example.test/from-a")
        try b.store.replaceSavedURL(ofItem: item.id, with: "https://example.test/from-b")
        await b.engine.syncNow(); await a.engine.syncNow(); await c.engine.syncNow()
        for m in [a,b,c] {
            XCTAssertEqual(m.store.item(item.id)?.savedURL, "https://example.test/from-b")
            XCTAssertEqual(m.store.orderedSpaces.filter { $0.id == work }.count, 1)
        }
    }

    func testReview4StormAndAccountChangeInFreshCycle() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate(), pause = Review3Pause()
        let store = try makeStore(clock)
        let hook = Review2Database(base: db, after: { call, _ in
            if call == .fetchChanges, await gate.fire() {
                await db.change { $0.identity = "another-account"; $0.deleteZone(SyncCloudSchema.zone) }
            }
        })
        let e = review3Engine(store, hook, keys: keys, file: "storm.json", sleep: { _ in await pause.wait() })
        e.setEnabled(true); await e.syncNow()
        _ = try store.createSpace(name: "Pending")
        await db.fail(.save, with: .network(retryAfter: 3600))
        let old = Task { await e.syncNow() }
        while !(await pause.entered) { await Task.yield() }
        let start = Date()
        for _ in 0..<10 { e.setEnabled(false); e.setEnabled(true) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        await gate.arm(); await e.syncNow()
        XCTAssertFalse(e.isEnabled)
        let count = await db.state.batchCount; XCTAssertEqual(count, 0)
        let status = e.status
        await pause.release(); await old.value
        XCTAssertEqual(e.status, status)
    }

    func testReview4SyncSoonDuringHeldCycleDrainsEditAndReleasesEngine() async throws {
        let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review2Gate(), pause = Review3Pause()
        let hook = Review2Database(base: db, after: { call, _ in
            if call == .fetchChanges, await gate.fire() { await pause.wait() }
        })
        let store = try makeStore(clock)
        var e: SyncEngine? = review3Engine(store, hook, keys: keys, file: "soon.json")
        e!.setEnabled(true); await e!.syncNow()
        await gate.arm()
        let active = Task { await e!.syncNow() }
        while !(await pause.entered) { await Task.yield() }
        _ = try store.createSpace(name: "During read")
        e!.automatic = true
        for _ in 0..<20 { e!.syncSoon() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await pause.release(); await active.value
        XCTAssertEqual(e!.pendingUploads, 0); XCTAssertEqual(e!.status, .upToDate)
        let c = try Mac("C", db: db, root: root, clock: clock)
        c.keys.copy(from: keys); await c.turnOn(); try await c.engine.choose(.replace)
        XCTAssertTrue(c.spaceNames.contains("During read"))
        e!.setEnabled(false)
        weak var weakEngine = e
        e = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(weakEngine, "completed and cancelled cycle tasks should release the engine")
    }

    func testReview4MalformedValidMalformedInOneReadAndPreview() async throws {
        for preview in [false,true] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore()
            let store = try makeStore(clock)
            let a = try Mac("Source-\(preview)", db: db, root: root, clock: clock); await a.turnOn()
            keys.copy(from: a.keys)
            let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(keys.key(group: group))
            var replica = SyncReplica(); try replica.edit(.init(.space, "three-events"), [.name: .text("Transient valid"), .profile: .text(a.store.defaultProfile.id)], now: 100)
            let good = SyncCloudSchema.record(try SyncEnvelope.seal(replica.log, group: group, device: replica.clock.device, key: key))
            var damaged = good; damaged.fields["sealed"] = .string("broken"); let bad = damaged
            let counter = Review4Counter()
            let transitions = Review2Database(base: db, after: { call, records in
                guard call == .fetchChanges, records.contains(where: { $0.name == good.name }) else { return }
                let n = await counter.next()
                if n == 1 { await db.change { try! $0.seed([good, SyncCloudRecord(name: "filler2", type: "Other", fields: [:])], zone: SyncCloudSchema.zone) } }
                if n == 2 { await db.change { try! $0.seed([bad], zone: SyncCloudSchema.zone) } }
            })
            let e = review3Engine(store, transitions, keys: keys, file: "three-\(preview).json")
            if !preview { e.setEnabled(true); await e.syncNow(); try await e.choose(.replace) }
            await db.change { $0.pageSize = 1; try! $0.seed([bad, SyncCloudRecord(name: "filler1", type: "Other", fields: [:])], zone: SyncCloudSchema.zone) }
            e.setEnabled(true); await e.syncNow()
            if preview {
                guard case .choosing(let p) = e.status else { return XCTFail("missing preview") }
                XCTAssertFalse(p.complete)
            } else {
                XCTAssertEqual(e.unreadableBatches, 1); XCTAssertNotEqual(e.status, .upToDate)
                await e.syncNow(); XCTAssertEqual(e.unreadableBatches, 1)
            }
        }
    }
}
private actor Review4Counter { var n = 0; func next() -> Int { n += 1; return n } }

private actor Review4Barrier {
    var waits: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    var opened = false
    func wait() async {
        calls += 1
        if !opened { await withCheckedContinuation { waits.append($0) } }
    }
    func release() { opened = true; let done = waits; waits = []; for w in done { w.resume() } }
}
extension SyncEngineTests {
    func testReview4CancelledBeforeChildStartsCannotAdoptNewSession() async throws {
        for turnBackOn in [false,true] {
            let db = SyncMockCloudDatabase(), keys = InMemorySyncKeyStore(), gate = Review4Barrier()
            let store = try makeStore(clock)
            let hook = Review2Database(base: db, before: { call, _ in
                if call == .accountStatus { await gate.wait() }
            })
            let e = review3Engine(store, hook, keys: keys, file: "startup-\(turnBackOn).json")
            e.setEnabled(true)
            // FIFO MainActor jobs: run() installs the child, then this toggle supersedes it before that child starts.
            let old = Task { await e.syncNow() }
            let toggle = Task { e.setEnabled(false); if turnBackOn { e.setEnabled(true) } }
            await toggle.value
            let fresh = Task { if turnBackOn { await e.syncNow() } }
            try await Task.sleep(nanoseconds: 100_000_000)
            let calls = await gate.calls
            XCTAssertEqual(calls, turnBackOn ? 1 : 0, "cancelled child must not start a cycle under the current generation")
            if !turnBackOn { XCTAssertEqual(e.status, .off); XCTAssertFalse(e.hasTransport) }
            await gate.release(); await old.value; await fresh.value
            if !turnBackOn { XCTAssertEqual(e.status, .off); XCTAssertFalse(e.hasTransport) }
            e.setEnabled(false)
        }
    }

    func testReview4NormalNewPinInKeptSpaceIsNotSilentlyWithheld() async throws {
        let (a,b) = try await review4Pair()
        let item = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" }), work = try XCTUnwrap(item.spaceID)
        try a.store.replaceSavedURL(ofItem: item.id, with: review4Huge); await a.engine.syncNow()
        try b.store.deleteSpace(work); await b.engine.syncNow(); await a.engine.syncNow()
        let tab = try a.store.openTab(url: "https://example.test/new-normal", inSpace: work)
        try a.store.move(.tab(tab.id), to: .pinned(spaceID: work, parentID: nil, index: 0))
        await a.engine.syncNow(); await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.engine.status, .upToDate); XCTAssertEqual(b.engine.status, .upToDate)
        XCTAssertTrue(b.store.state.items.values.contains { $0.savedURL == "https://example.test/new-normal" }, "a normal local pin must sync, or status must explain why its container is local-only")
        let other = try XCTUnwrap(a.store.orderedSpaces.first { $0.id != work })
        try a.store.move(.item(item.id), to: .pinned(spaceID: other.id, parentID: nil, index: 0))
        await a.engine.syncNow()
        _ = try b.store.createSpace(name: "Unrelated remote change")
        await b.engine.syncNow(); await a.engine.syncNow()
        XCTAssertEqual(a.store.item(item.id)?.savedURL, review4Huge)
        XCTAssertTrue(a.store.state.items.values.contains { $0.savedURL == "https://example.test/new-normal" }, "moving the excluded pin away must not erase a different newly saved normal pin")
    }
}

// syncreview5: focused session-boundary and kept-Space checks.
private struct Review5BindTransport: SyncGroupTransport {
    let base: CloudKitSyncTransport
    let gate: Review3Pause
    func cancel() { base.cancel() }
    func bind(account: String) async { await base.bind(account: account); await gate.wait() }
    func verifyAccount() async throws { try await base.verifyAccount() }
    func prepare() async throws { try await base.prepare() }
    func accountIdentity() async throws -> String? { try await base.accountIdentity() }
    func group() async throws -> SyncGroupRecord? { try await base.group() }
    func createGroup(_ record: SyncGroupRecord) async throws -> SyncGroupRecord { try await base.createGroup(record) }
    func publish(_ device: SyncDeviceRecord) async throws { try await base.publish(device) }
    var devices: [SyncDeviceRecord] { get async { await base.devices } }
    func acknowledge() async { await base.acknowledge() }
    var checkpoint: Data? { get async { await base.checkpoint } }
    func restore(checkpoint: Data?) async { await base.restore(checkpoint: checkpoint) }
    func takeReadReport() async -> SyncReadReport { await base.takeReadReport() }
    func append(_ envelope: SyncEnvelope) async throws { try await base.append(envelope) }
    func read() async throws -> [SyncEnvelope] { try await base.read() }
}

extension SyncEngineTests {
    func testReview5OffAtBindCannotWriteReplicaOutboxOrStatus() async throws {
        for missingKey in [false, true] {
            let db = SyncMockCloudDatabase(), gate = Review3Pause()
            let a = try Mac("bind-\(missingKey)", db: db, root: root, clock: clock)
            await a.turnOn()
            a.engine.setEnabled(false)
            let keys = InMemorySyncKeyStore()
            if !missingKey { keys.copy(from: a.keys) }
            let file = a.folder.appendingPathComponent("sync.json")
            let env = SyncEngine.Environment(
                transport: { Review5BindTransport(base: CloudKitSyncTransport(database: db, device: $0, backoff: []), gate: gate) },
                keys: keys, stateURL: file, deviceName: "bind", machine: a.machine,
                createProfile: { name, emoji in try a.store.createProfile(name: name, emoji: emoji).id },
                applyProfileChange: { _, _ in }, backup: { file })
            let e = SyncEngine(store: a.store, environment: env)
            e.automatic = false
            e.setEnabled(true)
            let old = Task { await e.syncNow() }
            while !(await gate.entered) { await Task.yield() }
            e.setEnabled(false)
            _ = try a.store.createSpace(name: "Edited while Off")
            let beforeLog = e.replica.log
            let beforeUploads = e.pendingUploads
            let beforeDisk = try Data(contentsOf: file)
            let beforeBatches = await db.state.batchCount
            await gate.release(); await old.value
            XCTAssertEqual(e.status, .off, "obsolete bind completion must not replace Off with waitingForKeychain")
            XCTAssertEqual(e.replica.log, beforeLog, "obsolete bind completion must not capture an Off edit")
            XCTAssertEqual(e.pendingUploads, beforeUploads, "obsolete bind completion must not append outbox")
            XCTAssertEqual(try Data(contentsOf: file), beforeDisk, "obsolete bind completion must not write durable state")
            let afterBatches = await db.state.batchCount
            XCTAssertEqual(afterBatches, beforeBatches)
            XCTAssertFalse(e.isEnabled); XCTAssertFalse(e.hasTransport)
        }
    }

    func testReview5TwoKeptSpaceEditsConvergeWithOrderProfileAndNestedFolders() async throws {
        let db = SyncMockCloudDatabase()
        let a = try Mac("A", db: db, root: root, clock: clock), b = try Mac("B", db: db, root: root, clock: clock)
        let c = try Mac("C", db: db, root: root, clock: clock)
        try seedWork(a)
        let work = try XCTUnwrap(a.space("Work")?.id)
        let profile = try a.store.createProfile(name: "Work profile", emoji: "W")
        _ = try a.store.setProfile(ofSpace: work, to: profile.id)
        _ = try a.store.createSpace(name: "After")
        let order = a.store.orderedSpaces.map(\.id)
        await a.turnOn()
        for m in [b,c] { m.keys.copy(from: a.keys); await m.turnOn(); try await m.engine.choose(.replace) }
        let bProfile = try XCTUnwrap(b.store.space(work)?.profileID)
        let cProfile = try XCTUnwrap(c.store.space(work)?.profileID)
        let excluded = try XCTUnwrap(a.store.state.items.values.first { $0.savedURL == "https://example.com/b" })
        let huge = "https://example.test/" + String(repeating: "x", count: 20000)
        for m in [a,b] { try m.store.replaceSavedURL(ofItem: excluded.id, with: huge + m.name); await m.engine.syncNow() }
        try c.store.deleteSpace(work); await c.engine.syncNow()
        for m in [a,b] { await m.engine.syncNow(); XCTAssertNotNil(m.store.space(work)) }
        // Both edits are made against the observed tombstone before either learns of the other's re-creation.
        var folders: [(String,String,String)] = []
        for m in [a,b] {
            let f = try m.store.createFolder(named: m.name + " outer", inSpace: work)
            let nested = try m.store.createFolder(named: m.name + " inner", inSpace: work, parentID: f.id)
            let tab = try m.store.openTab(url: "https://example.test/" + m.name, inSpace: work)
            try m.store.move(.tab(tab.id), to: .pinned(spaceID: work, parentID: nested.id, index: 0))
            folders.append((f.id,nested.id,"https://example.test/" + m.name))
        }
        for _ in 0..<3 { for m in [a,b,c] { await m.engine.syncNow() } }
        for m in [a,b,c] {
            XCTAssertEqual(m.store.orderedSpaces.map(\.id), order)
            XCTAssertEqual(m.store.orderedSpaces.filter { $0.id == work }.count, 1)
            for (outer, inner, url) in folders {
                XCTAssertEqual(m.store.item(inner)?.parentID, outer)
                XCTAssertEqual(m.store.state.items.values.first { $0.savedURL == url }?.parentID, inner)
            }
            XCTAssertEqual(m.engine.status, .upToDate)
        }
        XCTAssertEqual(a.store.space(work)?.profileID, profile.id)
        XCTAssertEqual(b.store.space(work)?.profileID, bProfile)
        XCTAssertEqual(c.store.space(work)?.profileID, cProfile)
        XCTAssertEqual(a.store.item(excluded.id)?.savedURL, huge + "A")
        XCTAssertEqual(b.store.item(excluded.id)?.savedURL, huge + "B")
        XCTAssertNil(c.store.item(excluded.id))
        let before = await db.state.batchCount
        for _ in 0..<3 { for m in [a,b,c] { await m.engine.syncNow() } }
        let after = await db.state.batchCount
        XCTAssertEqual(before, after)
    }
}
