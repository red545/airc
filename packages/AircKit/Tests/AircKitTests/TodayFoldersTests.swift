// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Folders in Today (TodayFolders.swift): the rows, moves into and out of them, auto-archive, Clear and undo, sync, and
/// schema 3 (old stores open as before; a store with a Today folder is safe in an older build).
final class TodayFoldersTests: XCTestCase {
    private var clock: TestClock!
    private var s: SpacesStore!
    private var sid: String!

    override func setUpWithError() throws {
        clock = TestClock()
        s = try makeStore(clock)
        sid = s.selectedSpace.id
    }

    @discardableResult
    private func open(_ name: String, in space: String? = nil) throws -> LiveTab {
        clock.advance(1)
        return try s.openTab(url: "https://\(name).example.com/", inSpace: space ?? sid, title: name)
    }

    /// The Today list as shown: "[Folder]" for a folder, a tab's title, indented two spaces a level.
    private func shown(_ space: String? = nil) -> [String] {
        s.todayRows(ofSpace: space ?? sid).map { e in
            switch e {
            case .folder(let f, let d): String(repeating: "  ", count: d) + "[\(f.displayTitle)]"
            case .today(let t): String(repeating: "  ", count: s.todayDepth(ofTab: t.id)) + t.title
            case .split(_, let tabs): tabs.map(\.title).joined(separator: "|")
            default: "?"
            }
        }
    }

    // MARK: Rows

    func testANewFolderInTodayHoldsTabsAndFoldersAndFolds() throws {
        let a = try open("a"), b = try open("b"), c = try open("c")
        XCTAssertEqual(shown(), ["c", "b", "a"])
        let f = try s.createTodayFolder(named: "Trip", inSpace: sid, containing: [.tab(a.id), .tab(b.id)])
        XCTAssertEqual(f.container, .today(spaceID: sid))
        XCTAssertEqual(shown(), ["[Trip]", "  a", "  b", "c"])
        XCTAssertEqual(s.todayRootRows(ofSpace: sid).map(\.id), [f.id, c.id])
        // A folder inside it (Arc's sidebar tree nests in Today as in Pinned).
        let inner = try s.createTodayFolder(named: "Hotels", inSpace: sid, parentID: f.id, index: 2)
        try s.move(.tab(c.id), to: .todayFolder(folderID: inner.id, index: 0))
        XCTAssertEqual(shown(), ["[Trip]", "  a", "  b", "  [Hotels]", "    c"])
        XCTAssertTrue(s.todayTabs(ofSpace: sid).allSatisfy(\.isToday), "they're Today tabs")
        // Folding hides the rows; Clear and Archive Tabs Below still see them.
        try s.toggleFolder(f.id)
        XCTAssertEqual(shown(), ["[Trip]"])
        XCTAssertEqual(s.todayRowTabs(ofSpace: sid).map(\.title), ["a", "b", "c"])
        try s.toggleFolder(f.id)
        // Rename; a new tab opens at the top of Today, a background link from a tab in a folder next to it there.
        try s.renameItem(f.id, to: "Lisbon")
        let d = try open("d")
        let link = try s.openTab(url: "https://link.example.com/", inSpace: sid, openerID: a.id, background: true, title: "link")
        XCTAssertEqual(shown(), ["d", "[Lisbon]", "  a", "  link", "  b", "  [Hotels]", "    c"])
        XCTAssertEqual(s.tab(link.id)?.folderID, f.id)
        _ = d
    }

    func testDragIntoOutOfAndBetweenTodayFolders() throws {
        let a = try open("a"), b = try open("b")
        let f = try s.createTodayFolder(named: "F", inSpace: sid)
        XCTAssertEqual(shown(), ["[F]", "b", "a"], "an empty folder made on purpose stays")
        try s.move(.tab(a.id), to: .todayFolder(folderID: f.id, index: 0))
        try s.move(.tab(b.id), to: .todayFolder(folderID: f.id, index: 0))
        XCTAssertEqual(shown(), ["[F]", "  b", "  a"])
        // Within the folder, then out to Today's top level.
        try s.move(.tab(b.id), to: .todayFolder(folderID: f.id, index: 2))
        XCTAssertEqual(shown(), ["[F]", "  a", "  b"])
        try s.move(.tab(b.id), to: .today(spaceID: sid, index: 1))
        XCTAssertEqual(shown(), ["[F]", "  a", "b"])
        // The last tab out: the folder goes with it, in the same transaction.
        try s.move(.tab(a.id), to: .today(spaceID: sid, index: 0))
        XCTAssertEqual(shown(), ["a", "b"])
        XCTAssertNil(s.item(f.id))
        // A folder can't go inside itself.
        let outer = try s.createTodayFolder(named: "Outer", inSpace: sid, containing: [.tab(a.id)])
        let inner = try s.createTodayFolder(named: "Inner", inSpace: sid, parentID: outer.id, containing: [.tab(b.id)])
        XCTAssertThrowsError(try s.move(.item(outer.id), to: .todayFolder(folderID: inner.id, index: 0))) {
            XCTAssertEqual($0 as? StoreError, .invalidMove)
        }
        // Add to Folder › with a Today folder.
        let c = try open("c")
        try s.move([.tab(c.id)], intoFolder: inner.id)
        XCTAssertEqual(shown(), ["[Outer]", "  [Inner]", "    b", "    c", "  a"])
    }

    func testAFolderMovesBetweenTodayAndPinnedWithEverythingInside() throws {
        // Pinned: Work › (Docs, Specs › (Spec)) with Docs loaded and Spec not.
        let work = try s.createFolder(named: "Work", inSpace: sid)
        let specs = try s.createFolder(named: "Specs", inSpace: sid, parentID: work.id)
        let docs = try open("docs")
        try s.move(.tab(docs.id), to: .pinned(spaceID: sid, parentID: work.id, index: 0))
        let spec = try open("spec")
        try s.move(.tab(spec.id), to: .pinned(spaceID: sid, parentID: specs.id, index: 0))
        let specItem = try XCTUnwrap(s.tab(spec.id)?.itemID)
        _ = try s.closeTab(spec.id)   // unloads it: its row stays, without a page
        XCTAssertNil(s.liveTab(forItem: specItem))
        let loose = try open("loose")

        try s.move(.item(work.id), to: .today(spaceID: sid, index: 1))
        XCTAssertEqual(s.pinnedRoots(ofSpace: sid).count, 0)
        XCTAssertEqual(shown(), ["loose", "[Work]", "  docs", "  [Specs]", "    spec"])
        XCTAssertEqual(s.tab(docs.id)?.folderID, work.id, "a loaded page keeps its tab")
        XCTAssertNil(s.tab(docs.id)?.itemID)
        XCTAssertNil(s.item(specItem), "a pinned tab inside became a Today tab")
        XCTAssertTrue(s.todayTabs(ofSpace: sid).allSatisfy(\.isToday))

        // And back into Pinned: its tabs become its pinned tabs again.
        try s.move(.item(work.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))
        XCTAssertTrue(s.todayFolders(ofSpace: sid).isEmpty)
        XCTAssertEqual(s.pinnedRows(ofSpace: sid).map(\.item?.displayTitle), ["Work", "docs", "Specs", "spec"])
        XCTAssertEqual(s.item(s.tab(docs.id)?.itemID)?.parentID, work.id)
        XCTAssertNil(s.tab(docs.id)?.folderID)
        XCTAssertEqual(shown(), ["loose"])

        // A pinned folder holding a split can't go into Today (a split is never in a Today folder).
        let x = try open("x"), y = try open("y")
        let split = try s.createSplit([x.id, y.id], inSpace: sid)
        try s.move(.split(split.id), to: .pinned(spaceID: sid, parentID: work.id, index: 0))
        XCTAssertThrowsError(try s.move(.item(work.id), to: .today(spaceID: sid, index: 0)))
    }

    func testPinningMovingAndSplittingTakeATabOutOfItsFolder() throws {
        let a = try open("a"), b = try open("b"), c = try open("c"), d = try open("d")
        let f = try s.createTodayFolder(named: "F", inSpace: sid, containing: [.tab(a.id), .tab(b.id), .tab(c.id), .tab(d.id)])
        try s.togglePin(a.id, inSpace: sid)
        XCTAssertNil(s.tab(a.id)?.folderID)
        XCTAssertNotNil(s.tab(a.id)?.itemID)
        let other = try s.createSpace(name: "Other")
        try s.moveTab(b.id, toSpace: other.id)
        XCTAssertNil(s.tab(b.id)?.folderID)
        _ = try s.createSplit([c.id, try open("e").id], inSpace: sid)
        XCTAssertNil(s.tab(c.id)?.folderID, "a split is a row of Today's top level")
        XCTAssertEqual(s.todayFolderTabs(f.id).map(\.id), [d.id])
        // The last one pinned: the folder goes.
        try s.togglePin(d.id, inSpace: sid)
        XCTAssertNil(s.item(f.id))
    }

    // MARK: Archive, Clear, undo

    func testClosingTheLastTabRemovesTheFolderAndOneUndoBringsBothBack() throws {
        let a = try open("a"), b = try open("b")
        let outer = try s.createTodayFolder(named: "Outer", inSpace: sid)
        let inner = try s.createTodayFolder(named: "Inner", inSpace: sid, parentID: outer.id, containing: [.tab(a.id)])
        try s.move(.tab(b.id), to: .todayFolder(folderID: outer.id, index: 0))
        _ = try s.closeTab(a.id)
        XCTAssertNil(s.item(inner.id), "the emptied folder goes")
        XCTAssertNotNil(s.item(outer.id), "its parent still holds a tab")
        _ = try s.closeTab(b.id)
        XCTAssertNil(s.item(outer.id))
        XCTAssertEqual(try s.undo(), .restored(label: "Close Tab", movedTabs: []))
        XCTAssertEqual(shown(), ["[Outer]", "  b"])
        XCTAssertEqual(try s.undo(), .restored(label: "Close Tab", movedTabs: []))
        XCTAssertEqual(shown(), ["[Outer]", "  b", "  [Inner]", "    a"])
        // Reopened from the Archive, a tab goes back into its folder while that's there.
        _ = try s.closeTab(a.id)
        let entry = try XCTUnwrap(s.archivedEntries.first { $0.tab.id == a.id })
        XCTAssertEqual(entry.tab.folderID, inner.id, "the Archive keeps where it was")
        let c = try open("c")
        try s.move(.tab(c.id), to: .todayFolder(folderID: outer.id, index: 0))
        _ = try s.restoreArchived(entry.id, fallbackSpaceID: sid)
        XCTAssertNil(s.tab(a.id)?.folderID, "its folder went, so it's at the top of Today")
        XCTAssertEqual(shown().first, "a")
    }

    func testTodayFoldersAutoArchiveByTheirTabsAge() throws {
        // Default profile: 12 hours.
        let old = try open("old"), recent = try open("recent")
        let f = try s.createTodayFolder(named: "F", inSpace: sid, containing: [.tab(old.id), .tab(recent.id)])
        clock.advance(6 * 3600)
        try s.activate(recent.id, inSpace: sid)
        clock.advance(7 * 3600)
        XCTAssertEqual(s.dueForAutoArchive(), [old.id], "a tab in a folder auto-archives by its own age")
        try s.autoArchive()
        XCTAssertEqual(s.todayFolderTabs(f.id).map(\.id), [recent.id])
        XCTAssertNotNil(s.nextAutoArchiveDate())
        clock.advance(6 * 3600)
        try s.autoArchive()
        XCTAssertNil(s.item(f.id), "the folder goes with its last tab")
        XCTAssertEqual(s.archivedEntries.count, 2)
    }

    func testClearClearsTodayFoldersInOneUndo() throws {
        let a = try open("a"), b = try open("b"), c = try open("c"), shown1 = try open("shown")
        let trip = try s.createTodayFolder(named: "Trip", inSpace: sid, containing: [.tab(a.id), .tab(b.id)])
        let keep = try s.createTodayFolder(named: "Keep", inSpace: sid, containing: [.tab(shown1.id), .tab(c.id)])
        let empty = try s.createTodayFolder(named: "Empty", inSpace: sid)
        try s.toggleFolder(trip.id)   // a closed folder's tabs are cleared too
        let before = (s.state.tabs, s.state.items)
        let cleared = try s.clearToday(inSpace: sid, keeping: shown1.id)
        XCTAssertEqual(Set(cleared), [a.id, b.id, c.id])
        XCTAssertNil(s.item(trip.id))
        XCTAssertNil(s.item(empty.id), "Clear takes empty Today folders too")
        XCTAssertEqual(shown(), ["[Keep]", "  shown"], "the tab on screen keeps its folder")
        XCTAssertEqual(try s.undo(), .restored(label: "Clear Today", movedTabs: []))
        XCTAssertEqual(s.state.tabs, before.0)
        XCTAssertEqual(s.state.items, before.1)
        _ = keep
    }

    func testClearInBatchesIsOneUndoStep() throws {
        // As the app clears when pages close one after another: two transactions, joined into one ⌘Z.
        let a = try open("a"), b = try open("b"), c = try open("c")
        let f = try s.createTodayFolder(named: "F", inSpace: sid, containing: [.tab(a.id), .tab(b.id)])
        let before = (s.state.tabs, s.state.items)
        try s.archiveTabs([c.id], reason: .clear, label: "Clear Today")
        try s.archiveTabs([a.id, b.id], reason: .clear, label: "Clear Today")
        XCTAssertNil(s.item(f.id))
        XCTAssertTrue(s.joinLastUndoSteps(label: "Clear Today"))
        XCTAssertFalse(s.joinLastUndoSteps(label: "Clear Today"), "the step before is another action")
        _ = try s.undo()
        XCTAssertEqual(s.state.tabs, before.0)
        XCTAssertEqual(s.state.items, before.1)
    }

    func testDeletingAFolderArchivesItsTabsAndUngroupKeepsThem() throws {
        let a = try open("a"), b = try open("b"), c = try open("c")
        let f = try s.createTodayFolder(named: "F", inSpace: sid, containing: [.tab(a.id), .tab(b.id)])
        try s.deleteItem(f.id)
        XCTAssertNil(s.tab(a.id))
        XCTAssertEqual(Set(s.archivedEntries.map(\.tab.id)), [a.id, b.id])
        _ = try s.undo()
        XCTAssertEqual(shown(), ["[F]", "  a", "  b", "c"])
        try s.ungroupTodayFolder(f.id)
        XCTAssertEqual(shown(), ["a", "b", "c"])
        XCTAssertNil(s.item(f.id))
        _ = try s.undo()
        XCTAssertEqual(shown(), ["[F]", "  a", "  b", "c"])
        // Deleting the Space takes its Today folders, and ⌘Z brings them back.
        _ = try s.createSpace(name: "Second")
        try s.deleteSpace(sid)
        XCTAssertTrue(s.state.items.values.filter(\.isTodayFolder).isEmpty)
        _ = try s.undo()
        XCTAssertEqual(shown(), ["[F]", "  a", "  b", "c"])
        _ = c
    }

    // MARK: Sync

    func testTodayFoldersNeverEnterTheSyncPayload() throws {
        let a = try open("a")
        var adapter = SyncStoreAdapter(), replica = SyncReplica()
        try adapter.capture(s.state, into: &replica, now: 1)
        // A pinned folder that syncs, then dragged into Today: it leaves the payload; a new Today folder never enters it.
        let pinned = try s.createFolder(named: "Synced Folder", inSpace: sid)
        try adapter.capture(s.state, into: &replica, now: 2)
        let record = SyncRecordID(.row, adapter.record(forItem: pinned.id))
        XCTAssertNotNil(replica.records[record])
        try s.move(.item(pinned.id), to: .today(spaceID: sid, index: 0))
        try s.move(.tab(a.id), to: .todayFolder(folderID: pinned.id, index: 0))
        let secret = try s.createTodayFolder(named: "Private Trip Plans", inSpace: sid, containing: [.tab(try open("b").id)])
        let ops = try adapter.capture(s.state, into: &replica, now: 3)
        let sent = String(decoding: try JSONEncoder().encode(ops), as: UTF8.self)
        XCTAssertFalse(sent.contains("Private Trip Plans"))
        XCTAssertFalse(sent.contains(secret.id))
        XCTAssertFalse(replica.records.values.contains { !$0.isDeleted && $0[.location] == .location(.today(space: sid)) })
        XCTAssertEqual(replica.records[record]?.isDeleted, true, "a folder dragged out of Pinned goes on the other Macs")
        // Its record's tombstone doesn't take the Today folder away here, and Replace keeps it.
        try s.applySync(replica, adapter: &adapter)
        adapter.rebase(s.state)
        XCTAssertTrue(s.item(pinned.id)?.isTodayFolder == true)
        try s.applySync(SyncReplica(), adapter: &adapter, replace: true)
        XCTAssertTrue(s.item(pinned.id)?.isTodayFolder == true)
        XCTAssertNotNil(s.item(secret.id))
        XCTAssertEqual(s.tab(a.id)?.folderID, pinned.id)
    }

    // MARK: Schema 3

    private var dir: URL!
    private func path() -> String {
        if dir == nil { dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-tf-\(UUID().uuidString)") }
        return dir.appendingPathComponent("spaces.sqlite").path
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func mark() throws -> String? {
        try Database(path: path()).query("SELECT value FROM meta WHERE key='schema'").first?.first as? String
    }

    private func rows(_ kind: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for r in try Database(path: path()).query("SELECT id, body FROM entities WHERE kind=?", [.text(kind)]) {
            out[r[0] as! String] = r[1] as? String
        }
        return out
    }

    func testOldDataOpensAsBeforeAndKeepsItsMark() throws {
        // A schema-2 store as Airc 0.1.x wrote it (a note's mark, rows without folderID), written behind the store's back.
        var ids: [String: String] = [:]
        do {
            let st = try SpacesStore(path: path())
            let t1 = try st.openTab(url: "https://one.example/", inSpace: st.selectedSpace.id, title: "One")
            let t2 = try st.openTab(url: "https://two.example/", inSpace: st.selectedSpace.id, title: "Two")
            let folder = try st.createFolder(named: "Pinned Folder", inSpace: st.selectedSpace.id)
            try st.flush()
            ids = ["t1": t1.id, "t2": t2.id, "folder": folder.id, "space": st.selectedSpace.id]
        }
        try Database(path: path()).run("UPDATE meta SET value='2' WHERE key='schema'")
        try Database(path: path()).run("INSERT INTO ops(ts, device, kind, id, op, body) VALUES(0, 'old', 'note', 'n1', 'delete', NULL)")
        let before = try rows("tab").merging(try rows("item")) { a, _ in a }
        XCTAssertFalse(before.values.contains { $0.contains("folderID") || $0.contains("\"today\"") })

        let st = try SpacesStore(path: path())
        XCTAssertEqual(st.schemaMark, 2, "no Today folder: the mark stays what the data needs")
        XCTAssertNil(st.newerSchemaVersion)
        XCTAssertTrue(st.unreadableRows.isEmpty)
        XCTAssertEqual(st.todayRows(ofSpace: ids["space"]!).map(\.id), [ids["t2"]!, ids["t1"]!])
        XCTAssertEqual(st.pinnedRoots(ofSpace: ids["space"]!).map(\.id), [ids["folder"]!])
        try st.flush()
        XCTAssertEqual(try rows("tab").merging(try rows("item")) { a, _ in a }, before, "opening rewrote nothing")
        XCTAssertEqual(try mark(), "2")
    }

    func testTheFirstTodayFolderRaisesTheMarkToThreeAndItStays() throws {
        var space = ""
        do {
            let st = try SpacesStore(path: path())
            space = st.selectedSpace.id
            let t = try st.openTab(url: "https://one.example/", inSpace: space, title: "One")
            try st.flush()
            XCTAssertEqual(try mark(), "1")
            XCTAssertEqual(st.state.requiredSchema, 1)
            let f = try st.createTodayFolder(named: "Trip", inSpace: space, containing: [.tab(t.id)])
            XCTAssertEqual(st.schemaMark, 3)
            XCTAssertEqual(try mark(), "3", "written with the folder, in its transaction")
            XCTAssertEqual(st.state.requiredSchema, 3)
            let backup = try JSONSerialization.jsonObject(with: st.exportJSON()) as? [String: Any]
            XCTAssertEqual(backup?["version"] as? Int, 3, "an older build refuses this backup instead of losing the folder")
            // The folder goes; the mark doesn't.
            _ = try st.closeTab(t.id)
            XCTAssertNil(st.item(f.id))
            try st.flush()
        }
        XCTAssertEqual(try SpacesStore(path: path()).schemaMark, 3)
        XCTAssertEqual(try mark(), "3")
        // What every older build (schema 1 and 2) makes of it: newer data, kept and announced.
        XCTAssertTrue(SpacesStore.isNewer(3, than: 2))
        XCTAssertTrue(SpacesStore.isNewer(3, than: 1))
    }

    /// The types as schema 2 (Airc before Today folders) has them, to read rows as an older build does.
    private enum OldContainer: Codable { case pinned(spaceID: String), favorites(profileID: String) }
    private struct OldItem: Codable { var id: String; var container: OldContainer }
    private struct OldTab: Codable, Equatable {
        var id: String; var profileID: String; var spaceID: String?; var itemID: String?; var url: String; var title: String
        var order: Double; var isMuted: Bool; var createdAt: Date; var lastActiveAt: Date
    }

    func testANewFolderIsSafeInAnOlderBuild() throws {
        var ids: [String: String] = [:]
        do {
            let st = try SpacesStore(path: path())
            let created = Date().addingTimeInterval(-2 * 86400)
            st.now = { created }
            let space = st.selectedSpace.id
            let a = try st.openTab(url: "https://a.example/", inSpace: space, title: "A")
            let b = try st.openTab(url: "https://b.example/", inSpace: space, title: "B")
            let c = try st.openTab(url: "https://c.example/", inSpace: space, title: "C")
            let f = try st.createTodayFolder(named: "Trip", inSpace: space, containing: [.tab(a.id), .tab(b.id), .tab(c.id)])
            try st.flush()
            ids = ["space": space, "a": a.id, "b": b.id, "c": c.id, "f": f.id]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let folderRow = try XCTUnwrap(try rows("item")[ids["f"]!])
        // An older build can't read the folder row: it hides it and keeps it on disk (H4) ...
        XCTAssertThrowsError(try decoder.decode(OldItem.self, from: Data(folderRow.utf8)))
        // ... and reads its tabs as loose Today tabs.
        for k in ["a", "b", "c"] {
            let row = try XCTUnwrap(try rows("tab")[ids[k]!])
            XCTAssertTrue(row.contains("\"folderID\":\"\(ids["f"]!)\""))
            XCTAssertNil(try decoder.decode(OldTab.self, from: Data(row.utf8)).itemID)
        }
        // The older build uses them: it renames A's page (its write keeps fields it doesn't know, SpacesStore.merge),
        // pins B (which keeps folderID on disk the same way) and archives C.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        func oldWrite(_ id: String, _ change: (inout OldTab) -> Void) throws {
            let raw = try XCTUnwrap(try rows("tab")[id])
            var t = try decoder.decode(OldTab.self, from: Data(raw.utf8))
            let loaded = String(decoding: try encoder.encode(t), as: UTF8.self)
            change(&t)
            let merged = SpacesStore.merge(raw: raw, loaded: loaded, current: String(decoding: try encoder.encode(t), as: UTF8.self))
            try Database(path: path()).run("UPDATE entities SET body=? WHERE kind='tab' AND id=?", [.text(merged), .text(id)])
        }
        try oldWrite(ids["a"]!) { $0.title = "A, renamed" }
        XCTAssertTrue(try rows("tab")[ids["a"]!]!.contains("folderID"), "an older build keeps the tab's folder")
        let pinnedItem = #"{"container":{"pinned":{"spaceID":"\#(ids["space"]!)"}},"createdAt":1800000000,"id":"old-pin","isCollapsed":false,"kind":"tab","order":0,"savedURL":"https://b.example/"}"#
        try Database(path: path()).run("INSERT INTO entities(kind, id, body, ts) VALUES('item', 'old-pin', ?, 0)", [.text(pinnedItem)])
        try oldWrite(ids["b"]!) { $0.itemID = "old-pin" }
        try Database(path: path()).run("DELETE FROM entities WHERE kind='tab' AND id=?", [.text(ids["c"]!)])
        XCTAssertEqual(try rows("item")[ids["f"]!], folderRow, "the folder row is untouched")

        // Back in this build: A is still in the folder; B is pinned and out of it; C is gone; nothing was lost.
        let st = try SpacesStore(path: path())
        XCTAssertTrue(st.unreadableRows.isEmpty)
        XCTAssertNil(st.newerSchemaVersion)
        XCTAssertEqual(st.todayFolderTabs(ids["f"]!).map(\.title), ["A, renamed"])
        XCTAssertNil(st.tab(ids["b"]!)?.folderID, "a tab the older build pinned leaves the folder")
        XCTAssertEqual(st.tab(ids["b"]!)?.itemID, "old-pin")
        XCTAssertEqual(st.schemaMark, 3)
        // The folder's last tab archived by the older build: the empty folder (made two days ago, past the 12-hour
        // archive interval) goes at the next open.
        try Database(path: path()).run("DELETE FROM entities WHERE kind='tab' AND id=?", [.text(ids["a"]!)])
        XCTAssertNil(try SpacesStore(path: path()).item(ids["f"]!))
        XCTAssertNil(try rows("item")[ids["f"]!])
    }
}
