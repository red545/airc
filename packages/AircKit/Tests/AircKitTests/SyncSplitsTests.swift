// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Pinned and Favorite splits in iCloud sync (docs/sync.md, "Splits"; P14b2): a split is a `split` row with its panes as
/// tab rows under it and its layout in a SplitSyncPayload, all in version 3 batches. Several "Macs" on the mock CloudKit
/// database, as in SyncNotesTests. Synthetic data only.
@MainActor
private final class SplitMac {
    let store: SpacesStore
    let keys = InMemorySyncKeyStore()
    let folder: URL
    let db: SyncMockCloudDatabase
    let name: String
    var engine: SyncEngine!

    init(_ name: String, db: SyncMockCloudDatabase, root: URL, clock: TestClock) throws {
        self.name = name; self.db = db
        folder = root.appendingPathComponent(name)
        store = try makeStore(clock)
        let store = store, folder = folder
        var env = SyncEngine.Environment(
            transport: { CloudKitSyncTransport(database: db, device: $0, backoff: [0, 0], sleep: { _ in }) },
            keys: keys, stateURL: folder.appendingPathComponent("sync.json"), deviceName: name + "'s Mac", machine: name,
            createProfile: { name, emoji in try store.createProfile(name: name, emoji: emoji).id },
            applyProfileChange: { space, profile in _ = try? store.setProfile(ofSpace: space, to: profile) },
            backup: { try store.writeBackup(to: folder.appendingPathComponent("Backups"), purpose: .beforeICloud) })
        env.sleep = { _ in }
        engine = SyncEngine(store: store, environment: env)
        engine.automatic = false
    }

    func turnOn() async { engine.setEnabled(true); await engine.syncNow() }
    func sync() async { await engine.syncNow() }
    func space(_ name: String) -> Space? { store.orderedSpaces.first { $0.name == name } }
    var splits: [Item] { store.state.items.values.filter { $0.kind == .split }.sorted { $0.order < $1.order } }
    func split(titled title: String) -> Item? { splits.first { $0.title == title } }
    func paneURLs(_ split: Item?) -> [String?] { split.map { store.panes(ofSplitItem: $0.id).map(\.savedURL) } ?? [] }
    /// Pinned or Favorite tabs (not panes) at `url`.
    func looseRows(_ url: String) -> [Item] {
        store.state.items.values.filter { $0.savedURL == url && store.splitItem(ofPane: $0.id) == nil }
    }

    /// A Today split of `urls` in `space`, saved into Pinned (or Favorites), named `title`.
    @discardableResult
    func saveSplit(_ urls: [String], title: String, in space: String, favorite: Bool = false, folder: String? = nil,
                   axis: SplitAxis = .horizontal, fractions: [Double]? = nil) throws -> Item {
        let tabs = try urls.map { try store.openTab(url: $0, inSpace: space) }
        let x = try store.createSplit(tabs.map(\.id), inSpace: space, axis: axis, focused: tabs[0].id)
        if let fractions { store.setSplitFractions(x.id, fractions) }
        let to: DropDestination = favorite ? .favorites(profileID: store.space(space)!.profileID, index: 0)
            : .pinned(spaceID: space, parentID: folder, index: 0)
        try store.move(.split(x.id), to: to)
        try store.renameItem(x.id, to: title)
        return store.item(x.id)!
    }
}

@MainActor
final class SyncSplitsTests: XCTestCase {
    private var root: URL!
    private let clock = TestClock()

    override func setUp() async throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/sync-splits-" + UUID().uuidString)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    /// Two Macs in one group: A made it with `seed` (in its "Work" Space), B merged.
    private func pair(_ seed: (SplitMac, String) throws -> Void = { _, _ in }) async throws -> (SplitMac, SplitMac, SyncMockCloudDatabase) {
        let db = SyncMockCloudDatabase()
        let a = try SplitMac("A", db: db, root: root, clock: clock), b = try SplitMac("B", db: db, root: root, clock: clock)
        let work = try a.store.createSpace(name: "Work")
        try seed(a, work.id)
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

    /// Lets the hybrid clocks order two edits made one after the other on two Macs.
    private func later() async throws { try await Task.sleep(nanoseconds: 5_000_000); clock.advance(1) }

    // MARK: Payload

    func testPayloadRoundTripsInASealedVersion3Batch() throws {
        var layout = SplitLayout(axis: .vertical, shares: ["p1": 0.25, "p2": 0.75], focusedItemID: "p2")
        let payload = SplitSyncPayload(layout, panes: ["p1", "p2"], record: { "item:" + $0 })
        XCTAssertEqual(payload.format, 1)
        XCTAssertEqual(payload.axis, .vertical)
        XCTAssertEqual(payload.shares, ["item:p1": 0.25, "item:p2": 0.75])
        XCTAssertEqual(try JSONDecoder().decode(SplitSyncPayload.self, from: JSONEncoder().encode(payload)), payload)
        // Back on another Mac: records mapped to its items, focus kept from its own layout (window state never syncs).
        layout.focusedItemID = "q1"
        let back = payload.layout(panes: ["q1", "q2"], local: ["item:p1": "q1", "item:p2": "q2"], current: layout)
        XCTAssertEqual(back, SplitLayout(axis: .vertical, shares: ["q1": 0.25, "q2": 0.75], focusedItemID: "q1"))

        // In a batch: sealed (no URL or name readable), version 3, and refused by a build that reads 1...2.
        let key = SyncEnvelope.newGroupKey(), group = UUID(), device = UUID()
        var replica = SyncReplica(device: device)
        let split = SyncRecordID(.row, "item:s")
        let ops = [
            try replica.edit(split, [.kind: .text("split"), .location: .location(.pinned(space: "sp")), .title: .text("Secret split"),
                                     .layout: .split(payload), .deleted: .flag(false)], now: 1),
            try replica.edit(SyncRecordID(.row, "item:p1"), [.kind: .text("tab"), .location: .location(.pinned(space: "sp")),
                                                           .parent: .text("item:s"), .url: .text("https://secret.test/"), .deleted: .flag(false)], now: 2),
        ]
        XCTAssertTrue(ops.allSatisfy { SyncSplits.isSplitOperation($0, in: replica) })
        let envelope = try SyncEnvelope.seal(ops, group: group, device: device, key: key, version: SyncSplits.envelopeVersion)
        let raw = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(raw.contains("secret") || raw.contains("Secret"))
        XCTAssertEqual(try envelope.open(group: group, key: key), ops)
        XCTAssertThrowsError(try envelope.open(group: group, key: key, accepting: 1...2)) { XCTAssertEqual($0 as? SyncError, .unsupportedVersion) }

        // Malformed payloads are refused like any malformed operation; a newer format is read as "keep yours".
        for bad in [SplitSyncPayload(axis: .horizontal, shares: ["x": .nan]),
                    SplitSyncPayload(axis: .horizontal, shares: Dictionary(uniqueKeysWithValues: (0..<20).map { ("p\($0)", 0.05) })),
                    SplitSyncPayload(format: 0, axis: .horizontal, shares: [:])] {
            XCTAssertThrowsError(try replica.edit(split, [.layout: .split(bad)], now: 3))
        }
        XCTAssertThrowsError(try replica.edit(SyncRecordID(.space, "sp"), [.layout: .split(payload)], now: 3), "only rows have a layout")
        let future = SplitSyncPayload(format: 2, axis: .vertical, shares: ["item:p1": 1])
        XCTAssertFalse(future.isReadable)
        XCTAssertEqual(future.layout(panes: ["q1"], local: ["item:p1": "q1"], current: layout), layout)
        let unknownAxis = Data(#"{"format":2,"axis":"diagonal","shares":{"a":0.5}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SplitSyncPayload.self, from: unknownAxis).axis, .horizontal)
    }

    func testTheProjectionKeepsOnlyRealSplits() throws {
        var r = SyncReplica()
        let pinned = SyncLocation.pinned(space: "sp")
        try r.edit(SyncRecordID(.space, "sp"), [.name: .text("Work"), .deleted: .flag(false)], now: 1)
        func row(_ id: String, _ kind: String, parent: String? = nil, order: [UInt16]) throws {
            try r.edit(SyncRecordID(.row, id), [.kind: .text(kind), .location: .location(pinned), .parent: parent.map(SyncValue.text) ?? .null,
                                               .order: .order(try SyncOrder(digits: order)), .deleted: .flag(false)], now: 2)
        }
        try row("s", "split", order: [5])
        try row("p1", "tab", parent: "s", order: [1])
        try row("p2", "tab", parent: "s", order: [2])
        try row("lone", "split", order: [7])
        try row("l1", "tab", parent: "lone", order: [1])
        try row("f", "folder", parent: "s", order: [3])          // never in a split
        let sidebar = Dictionary(uniqueKeysWithValues: r.sidebar.map { ($0.id.id, $0) })
        XCTAssertEqual(sidebar["p1"]?[.parent], .text("s"))
        XCTAssertEqual(sidebar["f"]?[.parent], .null)
        XCTAssertNil(sidebar["lone"], "a split of one pane isn't one")
        XCTAssertEqual(sidebar["l1"]?[.parent], .null)
        XCTAssertEqual(sidebar["l1"]?.order, try SyncOrder(digits: [7]), "its pane takes its place")
        // Five panes (two Macs adding at once): the first four stay in it, the fifth sits next to it.
        for k in 3...5 { try row("p\(k)", "tab", parent: "s", order: [UInt16(k)]) }
        let five = Dictionary(uniqueKeysWithValues: r.sidebar.map { ($0.id.id, $0) })
        XCTAssertEqual((1...4).map { five["p\($0)"]?[.parent] }, Array(repeating: .text("s"), count: 4))
        XCTAssertEqual(five["p5"]?[.parent], .null)
        XCTAssertEqual(five["p5"]?.order, try SyncOrder(digits: [5]))
    }

    // MARK: Two Macs

    func testPinnedAndFavoriteSplitsReachTheSecondMacSealedAndOutOfOlderBuilds() async throws {
        let (a, b, db) = try await pair { mac, work in
            let folder = try mac.store.createFolder(named: "Research", inSpace: work)
            try mac.saveSplit(["https://left.test/", "https://right.test/"], title: "Compare", in: work, folder: folder.id,
                              axis: .vertical, fractions: [0.3, 0.7])
            try mac.saveSplit(["https://mail.test/", "https://cal.test/", "https://docs.test/"], title: "Desk", in: work, favorite: true)
            let plain = try mac.store.openTab(url: "https://plain.test/", inSpace: work)
            try mac.store.move(.tab(plain.id), to: .pinned(spaceID: work, parentID: nil, index: 0))
        }
        let compare = try XCTUnwrap(b.split(titled: "Compare"))
        XCTAssertEqual(b.paneURLs(compare), ["https://left.test/", "https://right.test/"])
        XCTAssertEqual(b.store.item(compare.parentID)?.title, "Research")
        XCTAssertEqual(b.store.space(compare.spaceID)?.name, "Work")
        XCTAssertEqual(compare.splitLayout?.axis, .vertical)
        let fractions = try XCTUnwrap(compare.splitLayout?.fractions(b.store.panes(ofSplitItem: compare.id).map(\.id)))
        XCTAssertEqual(fractions[0], 0.3, accuracy: 1e-3)
        let desk = try XCTUnwrap(b.split(titled: "Desk"))
        XCTAssertTrue(desk.isFavorite)
        XCTAssertEqual(b.paneURLs(desk), ["https://mail.test/", "https://cal.test/", "https://docs.test/"])
        XCTAssertEqual(b.store.favorites(ofProfile: b.store.defaultProfile.id).map(\.id), [desk.id], "panes aren't Favorites of their own")
        // B opens it as a split, as on A.
        let shown = try b.store.openItem(compare.id, inSpace: compare.spaceID!)
        XCTAssertEqual(b.store.split(containing: shown.id)?.tabIDs.count, 2)
        XCTAssertEqual(b.engine.status, .upToDate)

        // iCloud: nothing readable; every split or pane operation is in a version 3 batch.
        let group = try XCTUnwrap(a.engine.groupID), key = try XCTUnwrap(a.keys.key(group: group))
        let all = await db.state.records(zone: SyncCloudSchema.zone)
        let raw = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        for secret in ["left.test", "Compare", "Desk", "mail.test", "Research"] { XCTAssertFalse(raw.contains(secret), secret) }
        let envelopes = await batches(db)
        var full = SyncReplica()
        for e in envelopes { try full.receive(e.open(group: group, key: key), now: 0) }
        let splitRecords = Set(full.records.values.filter { $0[.kind] == .text("split") }.map(\.id.id))
        XCTAssertEqual(splitRecords.count, 2)
        for e in envelopes {
            let ops = try e.open(group: group, key: key)
            let touches = ops.contains { op in
                splitRecords.contains(op.record.id) || { if case .text(let p)? = full.records[op.record]?[.parent] { splitRecords.contains(p) } else { false } }()
            }
            XCTAssertEqual(e.version == 3, touches, "batch \(e.version)")
        }

        // An older build (reads 1...2): splits and panes never reach its sidebar; the plain pinned tab does. Its
        // quarantine holds the rest, and once updated it has everything.
        var old = SyncReplica(), quarantine: [SyncEnvelope] = []
        for e in envelopes {
            do { try old.receive(e.open(group: group, key: key, accepting: 1...2), now: 0) } catch SyncError.unsupportedVersion { quarantine.append(e) }
        }
        XCTAssertFalse(quarantine.isEmpty)
        XCTAssertFalse(old.records.values.contains { $0[.kind] == .text("split") })
        XCTAssertFalse(old.records.values.contains { $0[.url] == .text("https://left.test/") })
        XCTAssertTrue(old.sidebar.contains { $0[.url] == .text("https://plain.test/") })
        for e in quarantine { try old.receive(e.open(group: group, key: key), now: 0) }
        XCTAssertEqual(old.records, full.records)
    }

    func testEditsOnTheSecondMacComeBack() async throws {
        let (a, b, db) = try await pair { mac, work in
            try mac.saveSplit(["https://one.test/", "https://two.test/"], title: "Pair", in: work)
        }
        let onB = try XCTUnwrap(b.split(titled: "Pair"))
        try b.store.renameItem(onB.id, to: "Pair, renamed")
        try b.store.setSplitAxis(onB.id, .vertical)
        let space = try XCTUnwrap(onB.spaceID)
        let third = try b.store.openTab(url: "https://three.test/", inSpace: space)
        try b.store.addToSplit(onB.id, tabID: third.id, at: 0, focus: true)
        await b.sync(); await a.sync()
        let onA = try XCTUnwrap(a.split(titled: "Pair, renamed"))
        XCTAssertEqual(onA.id, a.splits.first?.id)
        XCTAssertEqual(onA.splitLayout?.axis, .vertical)
        XCTAssertEqual(a.paneURLs(onA), ["https://three.test/", "https://one.test/", "https://two.test/"])
        XCTAssertEqual(a.splits.count, 1)

        // Moved into Favorites on A: B follows.
        try a.store.move(.item(onA.id), to: .favorites(profileID: a.store.defaultProfile.id, index: 0))
        await a.sync(); await b.sync()
        XCTAssertEqual(b.split(titled: "Pair, renamed")?.isFavorite, true)
        XCTAssertEqual(b.paneURLs(b.split(titled: "Pair, renamed")).count, 3)

        // Separate All Tabs on B: A gets three loose rows. Each is sent whole in a version 1 batch, so a build that
        // never read the split gets complete rows.
        let before = Set(await batches(db).map(\.id))
        try b.store.separateSplit(b.split(titled: "Pair, renamed")!.id)
        await b.sync(); await a.sync()
        let group = try XCTUnwrap(b.engine.groupID), key = try XCTUnwrap(b.keys.key(group: group))
        let sent = await batches(db).filter { !before.contains($0.id) }
        let v1 = try sent.filter { $0.version == 1 }.flatMap { try $0.open(group: group, key: key, accepting: 1...2) }
        let urls = Set(v1.compactMap { op -> String? in if case .text(let u)? = op.fields[.url] { u } else { nil } })
        XCTAssertEqual(urls, ["https://one.test/", "https://two.test/", "https://three.test/"])
        XCTAssertTrue(v1.filter { op in op.fields[.url] != nil }.allSatisfy { $0.fields[.kind] != nil && $0.fields[.location] != nil && $0.fields[.parent] == .null })
        XCTAssertTrue(sent.contains { $0.version == 3 }, "the split's tombstone")
        XCTAssertTrue(a.splits.isEmpty)
        for url in ["https://one.test/", "https://two.test/", "https://three.test/"] { XCTAssertEqual(a.looseRows(url).count, 1, url) }
    }

    func testConcurrentLayoutEditsLastWriterWinsAndPaneOrderMerges() async throws {
        let (a, b, _) = try await pair { mac, work in
            try mac.saveSplit(["https://one.test/", "https://two.test/", "https://three.test/"], title: "Trio", in: work)
        }
        let sa = try XCTUnwrap(a.split(titled: "Trio")), sb = try XCTUnwrap(b.split(titled: "Trio"))
        // Apart: B stacks it and adds a pane; later A turns it side by side again (vertical → horizontal is a no-op, so
        // A picks vertical first), resizes and moves its first pane to the end.
        try b.store.setSplitAxis(sb.id, .vertical)
        let four = try b.store.openTab(url: "https://four.test/", inSpace: sb.spaceID!)
        try b.store.addToSplit(sb.id, tabID: four.id, focus: false)
        try await later()
        let shown = try a.store.openItem(sa.id, inSpace: sa.spaceID!)
        _ = shown
        try a.store.moveItemSplitPane(sa.id, from: 0, to: 2)
        a.store.setSplitFractions(sa.id, [0.5, 0.25, 0.25])
        try a.store.setSplitAxis(sa.id, .vertical)
        try a.store.setSplitAxis(sa.id, .horizontal)
        await b.sync(); await a.sync(); await b.sync()

        for mac in [a, b] {
            let s = try XCTUnwrap(mac.split(titled: "Trio"), mac.name)
            XCTAssertEqual(s.splitLayout?.axis, .horizontal, "A's later layout wins on \(mac.name)")
            // Member order: A's move and B's added pane both survive.
            XCTAssertEqual(mac.paneURLs(s), ["https://two.test/", "https://three.test/", "https://one.test/", "https://four.test/"], mac.name)
        }
        XCTAssertEqual(a.splits.count, 1); XCTAssertEqual(b.splits.count, 1)
        XCTAssertEqual(a.engine.status, .upToDate); XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testDeletingASplitBeatsAConcurrentEditButKeepsAPaneAddedMeanwhile() async throws {
        let (a, b, _) = try await pair { mac, work in
            try mac.saveSplit(["https://one.test/", "https://two.test/"], title: "Doomed", in: work)
        }
        let sa = try XCTUnwrap(a.split(titled: "Doomed")), sb = try XCTUnwrap(b.split(titled: "Doomed"))
        // B edits (rename, axis, a new pane); later A deletes the split, not having seen it.
        try b.store.renameItem(sb.id, to: "Doomed, edited")
        try b.store.setSplitAxis(sb.id, .vertical)
        let added = try b.store.openTab(url: "https://added.test/", inSpace: sb.spaceID!)
        try b.store.addToSplit(sb.id, tabID: added.id, focus: false)
        try await later()
        try a.store.deleteItem(sa.id)
        await a.sync(); await b.sync(); await a.sync()
        for mac in [a, b] {
            XCTAssertTrue(mac.splits.isEmpty, "the deletion stands on \(mac.name)")
            XCTAssertTrue(mac.looseRows("https://one.test/").isEmpty, mac.name)
            // What B added that A never saw isn't lost: a pinned tab of its own.
            XCTAssertEqual(mac.looseRows("https://added.test/").count, 1, mac.name)
        }
        XCTAssertEqual(a.engine.status, .upToDate); XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testAPaneDeletedOnTheOtherMac() async throws {
        let (a, b, _) = try await pair { mac, work in
            try mac.saveSplit(["https://one.test/", "https://two.test/", "https://three.test/"], title: "Trio", in: work,
                              fractions: [0.5, 0.25, 0.25])
        }
        // A deletes one pane: B keeps a split of the other two, their sizes in proportion.
        let sa = try XCTUnwrap(a.split(titled: "Trio"))
        let one = try XCTUnwrap(a.store.panes(ofSplitItem: sa.id).first)
        try a.store.deleteItem(one.id)
        await a.sync(); await b.sync()
        let sb = try XCTUnwrap(b.split(titled: "Trio"))
        let panes = b.store.panes(ofSplitItem: sb.id)
        XCTAssertEqual(panes.map(\.savedURL), ["https://two.test/", "https://three.test/"])
        let f = sb.splitLayout!.fractions(panes.map(\.id))
        XCTAssertEqual(f[0], 0.5, accuracy: 1e-3)

        // Then each Mac deletes the other remaining pane at once (A's first is open): nothing of the split is left on
        // either Mac, and no empty split stays behind.
        let open = try a.store.openItem(a.store.panes(ofSplitItem: sa.id)[0].id, inSpace: sa.spaceID!)
        try a.store.deleteItem(a.store.panes(ofSplitItem: sa.id)[1].id)
        try b.store.deleteItem(b.store.panes(ofSplitItem: sb.id)[0].id)
        await a.sync(); await b.sync(); await a.sync()
        for mac in [a, b] {
            XCTAssertTrue(mac.splits.isEmpty, mac.name)
            XCTAssertEqual(mac.looseRows("https://two.test/").count + mac.looseRows("https://three.test/").count, 0, mac.name)
        }
        XCTAssertNil(a.store.tab(open.id), "its row went on B, so its open page closed on A")
        XCTAssertEqual(a.engine.status, .upToDate); XCTAssertEqual(b.engine.status, .upToDate)
    }

    func testAPaneLeftAloneTakesTheSplitsPlace() async throws {
        let (a, b, _) = try await pair { mac, work in
            try mac.saveSplit(["https://one.test/", "https://two.test/", "https://three.test/"], title: "Trio", in: work)
        }
        let sa = try XCTUnwrap(a.split(titled: "Trio")), sb = try XCTUnwrap(b.split(titled: "Trio"))
        // Apart, A deletes "one" and B deletes "two": "three" is left alone.
        try a.store.deleteItem(a.store.panes(ofSplitItem: sa.id)[0].id)
        try b.store.deleteItem(b.store.panes(ofSplitItem: sb.id)[1].id)
        await a.sync(); await b.sync(); await a.sync()
        for mac in [a, b] {
            XCTAssertTrue(mac.splits.isEmpty, mac.name)
            let row = try XCTUnwrap(mac.looseRows("https://three.test/").first, mac.name)
            XCTAssertNil(row.parentID)
            XCTAssertEqual(mac.looseRows("https://three.test/").count, 1)
        }
    }

    func testASplitWithALocalOnlyPaneStaysOnThisMacAndANoteInASplitSyncs() async throws {
        let (a, b, _) = try await pair { mac, work in
            let note = try mac.store.createNote(inSpace: work, pinned: false)
            mac.store.updateNote(NoteURL.noteID(note.url)!, document: NoteDocument(lines: ["Synthetic note in a split"]))
            let page = try mac.store.openTab(url: "https://page.test/", inSpace: work)
            let x = try mac.store.createSplit([note.id, page.id], inSpace: work, axis: .horizontal, focused: page.id)
            try mac.store.move(.split(x.id), to: .pinned(spaceID: work, parentID: nil, index: 0))
            try mac.store.renameItem(x.id, to: "With note")
        }
        let s = try XCTUnwrap(b.split(titled: "With note"))
        let urls = b.paneURLs(s)
        let noteID = try XCTUnwrap(urls.compactMap { NoteURL.noteID($0) }.first)
        XCTAssertEqual(b.store.note(noteID)?.document.plainText, "Synthetic note in a split")
        XCTAssertTrue(urls.contains("https://page.test/"))

        // A local-only pane (a saved URL past 16 KB, as an Easel's would be) keeps the whole split on its Mac.
        let space = try XCTUnwrap(a.space("Work")).id
        let easelTab = try a.store.openTab(url: "data:text/plain," + String(repeating: "x", count: 20_000), inSpace: space)
        let other = try a.store.openTab(url: "https://beside.test/", inSpace: space)
        let x = try a.store.createSplit([easelTab.id, other.id], inSpace: space, axis: .horizontal, focused: other.id)
        try a.store.move(.split(x.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        try a.store.renameItem(x.id, to: "Local split")
        await a.sync(); await b.sync(); await a.sync()
        XCTAssertNil(b.split(titled: "Local split"))
        XCTAssertTrue(b.looseRows("https://beside.test/").isEmpty)
        XCTAssertEqual(a.paneURLs(a.split(titled: "Local split")).count, 2, "kept whole on A")
    }
}
