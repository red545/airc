// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircKit

/// Code review H4: a row this build can't read never costs data. It stays on disk byte for byte, is hidden in memory,
/// and nothing that hangs off it is deleted or moved.
final class ForwardCompatTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("spaces.sqlite").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-fc-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rows() throws -> [String: String] {
        let db = try Database(path: path)
        var out: [String: String] = [:]
        for r in try db.query("SELECT kind, id, body FROM entities") {
            out["\(r[0] as! String)/\(r[1] as! String)"] = r[2] as? String
        }
        return out
    }

    private func object(_ body: String?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(body).utf8)) as? [String: Any])
    }

    func testCorruptAndFutureRowsSurviveRelaunchWithNoDataLost() throws {
        // A Work profile with a Space (pinned folder with a tab inside, a Today tab) and a Home Space with a pinned tab.
        var ids: [String: String] = [:]
        do {
            let s = try SpacesStore(path: path)
            let work = try s.createProfile(name: "Work")
            let ws = try s.createSpace(name: "Work", profileID: work.id)
            let home = try s.createSpace(name: "Home")
            let pin = try s.openTab(url: "https://home.example/", inSpace: home.id)
            try s.move(.tab(pin.id), to: .pinned(spaceID: home.id, parentID: nil, index: 0))
            let folder = try s.createFolder(named: "Docs", inSpace: ws.id)
            let doc = try s.openTab(url: "https://docs.example/", inSpace: ws.id)
            try s.move(.tab(doc.id), to: .pinned(spaceID: ws.id, parentID: folder.id, index: 0))
            let today = try s.openTab(url: "https://news.example/", inSpace: ws.id)
            try s.flush()
            ids = ["work": work.id, "ws": ws.id, "home": home.id, "pin": s.tab(pin.id)!.itemID!, "pinTab": pin.id,
                   "folder": folder.id, "docItem": s.tab(doc.id)!.itemID!, "docTab": doc.id, "today": today.id]
        }

        // Damage and future data, written behind the store's back.
        let homeBody = try XCTUnwrap(try rows()["space/\(ids["home"]!)"])
        var workProfile = try object(try rows()["profile/\(ids["work"]!)"])
        workProfile["searchEngine"] = "perplexity"
        workProfile["syncAccount"] = "someone@example.com"
        let futureProfile = String(decoding: try JSONSerialization.data(withJSONObject: workProfile, options: [.sortedKeys]),
                                   as: UTF8.self)
        let futureItem = #"{"container":{"pinned":{"spaceID":"\#(ids["ws"]!)"}},"createdAt":1800000000,"id":"easel-1","isCollapsed":false,"kind":"easel","order":9}"#
        let futureTab = #"{"createdAt":1800000000,"id":"easel-tab","isMuted":false,"itemID":"easel-1","lastActiveAt":1800000000,"order":0,"profileID":"\#(ids["work"]!)","spaceID":"\#(ids["ws"]!)","title":"","url":"https://easel.example/"}"#
        do {
            let db = try Database(path: path)
            try db.run("UPDATE entities SET body=? WHERE kind='space' AND id=?", [.text(String(homeBody.dropLast(9))), .text(ids["home"]!)])
            try db.run("UPDATE entities SET body=? WHERE kind='profile' AND id=?", [.text(futureProfile), .text(ids["work"]!)])
            try db.run("INSERT INTO entities(kind, id, body, ts) VALUES('item', 'easel-1', ?, 0)", [.text(futureItem)])
            try db.run("INSERT INTO entities(kind, id, body, ts) VALUES('tab', 'easel-tab', ?, 0)", [.text(futureTab)])
            try db.run("INSERT INTO entities(kind, id, body, ts) VALUES('group', 'g-1', '{\"name\":\"Group\"}', 0)")
            try db.run("UPDATE meta SET value='2' WHERE key='schema'")
        }
        let before = try rows()

        // Relaunch on the damaged store.
        do {
            let s = try SpacesStore(path: path)
            let hiddenIDs = Set(s.unreadableRows.map(\.id))
            XCTAssertEqual(hiddenIDs, [ids["home"]!, ids["pin"]!, ids["pinTab"]!, "easel-1", "easel-tab", "g-1"])
            XCTAssertEqual(s.newerSchemaVersion, 2)
            // The future profile reads, keeps its Space, and nothing moved to the default profile.
            XCTAssertEqual(s.profile(ids["work"]!)?.searchEngine, .google)
            XCTAssertEqual(s.space(ids["ws"]!)?.profileID, ids["work"]!)
            XCTAssertEqual(s.tab(ids["docTab"]!)?.profileID, ids["work"]!)
            XCTAssertNotNil(s.item(ids["folder"]!))
            XCTAssertNil(s.space(ids["home"]!))
            XCTAssertEqual(try rows(), before, "opening the store changed or deleted rows")

            // Use the store: rename the profile, open a tab, delete the Work Space's Today tab, then quit.
            try s.updateProfile(ids["work"]!) { $0.name = "Work 2" }
            _ = try s.openTab(url: "https://new.example/", inSpace: ids["ws"]!)
            _ = try s.closeTab(ids["today"]!)
            try s.flush()
        }
        let after = try rows()
        for key in ["space/\(ids["home"]!)", "item/\(ids["pin"]!)", "tab/\(ids["pinTab"]!)", "item/easel-1",
                    "tab/easel-tab", "group/g-1"] {
            XCTAssertEqual(after[key], before[key], "\(key) changed")
        }
        let written = try object(after["profile/\(ids["work"]!)"])
        XCTAssertEqual(written["name"] as? String, "Work 2")
        XCTAssertEqual(written["searchEngine"] as? String, "perplexity", "a newer build's value was overwritten")
        XCTAssertEqual(written["syncAccount"] as? String, "someone@example.com", "a newer build's field was dropped")
        XCTAssertEqual(try Database(path: path).query("SELECT value FROM meta WHERE key='schema'").first?.first as? String, "2")

        // The damaged row is fixed (or a newer build reads it): everything comes back.
        try Database(path: path).run("UPDATE entities SET body=? WHERE kind='space' AND id=?", [.text(homeBody), .text(ids["home"]!)])
        let s = try SpacesStore(path: path)
        XCTAssertEqual(s.space(ids["home"]!)?.name, "Home")
        XCTAssertEqual(s.pinnedRoots(ofSpace: ids["home"]!).map(\.savedURL), ["https://home.example/"])
        XCTAssertEqual(s.tab(ids["pinTab"]!)?.itemID, ids["pin"]!)
        XCTAssertEqual(s.profile(ids["work"]!)?.name, "Work 2")
        XCTAssertEqual(Set(s.unreadableRows.map(\.id)), ["easel-1", "easel-tab", "g-1"])
    }

    func testOrphansAreHiddenNotDeleted() throws {
        var ids: [String] = []
        do {
            let s = try SpacesStore(path: path)
            let sp = try s.createSpace(name: "B")
            let t = try s.openTab(url: "https://a.example/", inSpace: sp.id)
            try s.move(.tab(t.id), to: .pinned(spaceID: sp.id, parentID: nil, index: 0))
            ids = [sp.id, s.tab(t.id)!.itemID!, t.id]
        }
        // The Space row vanishes (a partial write, a sync bug): its pinned tab stays on disk.
        try Database(path: path).run("DELETE FROM entities WHERE kind='space' AND id=?", [.text(ids[0])])
        let before = try rows()
        let s = try SpacesStore(path: path)
        XCTAssertNil(s.item(ids[1]))
        XCTAssertEqual(Set(s.unreadableRows.map(\.id)), [ids[1], ids[2]])
        try s.flush()
        XCTAssertEqual(try rows()["item/\(ids[1])"], before["item/\(ids[1])"])
        XCTAssertEqual(try rows()["tab/\(ids[2])"], before["tab/\(ids[2])"])
    }

    func testMergeKeepsUnknownAndUnchangedValues() {
        let raw = #"{"a":1,"e":"perplexity","icon":{"sticker":{"_0":"x"}},"n":"old","opt":"v","theme":{"appearance":"sepia","grain":0.5},"x":"future"}"#
        let loaded = #"{"a":1,"e":"google","icon":{"symbol":{"_0":"circle.dashed"}},"n":"old","opt":"v","theme":{"appearance":"auto","grain":0.5}}"#
        // Renamed, cleared `opt`, changed the grain and the icon.
        let current = #"{"a":1,"e":"google","icon":{"emoji":{"_0":"🙂"}},"n":"new","theme":{"appearance":"auto","grain":0.25}}"#
        let merged = SpacesStore.merge(raw: raw, loaded: loaded, current: current)
        let o = try! JSONSerialization.jsonObject(with: Data(merged.utf8)) as! [String: Any]
        XCTAssertEqual(o["n"] as? String, "new")
        XCTAssertEqual(o["e"] as? String, "perplexity")
        XCTAssertEqual(o["x"] as? String, "future")
        XCTAssertNil(o["opt"])
        XCTAssertEqual((o["icon"] as? [String: Any])?.keys.sorted(), ["emoji"])
        let theme = o["theme"] as! [String: Any]
        XCTAssertEqual(theme["appearance"] as? String, "sepia")
        XCTAssertEqual(theme["grain"] as? Double, 0.25)
    }

    func testUnknownEnumValuesReadAsDefaults() throws {
        let d = JSONDecoder()
        XCTAssertEqual(try d.decode([SearchEngine].self, from: Data(#"["kagi","perplexity"]"#.utf8)), [.kagi, .google])
        XCTAssertEqual(try d.decode([SpaceIcon].self, from: Data(#"[{"emoji":{"_0":"🙂"}},{"sticker":{}}]"#.utf8)),
                       [.emoji("🙂"), .unknown])
    }
}

/// Code review M4 and M5.
final class StoreHygieneTests: XCTestCase {
    func testFailedWriteStaysPendingAndIsRetried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-m4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("spaces.sqlite").path
        var reported = 0
        do {
            let s = try SpacesStore(path: path)
            s.onWriteFailure = { _ in reported += 1 }
            s.failNextFlushes = 2
            XCTAssertThrowsError(try s.createSpace(name: "Kept"))
            XCTAssertNotNil(s.orderedSpaces.first { $0.name == "Kept" }, "memory keeps the change")
            XCTAssertTrue(s.hasPendingWrites)
            XCTAssertThrowsError(try s.flush())
            XCTAssertEqual(reported, 1, "reported once, not per retry")
            try s.flush()
            XCTAssertFalse(s.hasPendingWrites)
        }
        XCTAssertNotNil(try SpacesStore(path: path).orderedSpaces.first { $0.name == "Kept" }, "the retry wrote it")
    }

    func testArchiveRetention() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let sp = s.selectedSpace.id
        for i in 0..<6 {
            let t = try s.openTab(url: "https://a\(i).example/", inSpace: sp)
            try s.closeTab(t.id)
            clock.advance(40 * 86400)
        }
        XCTAssertEqual(s.archivedEntries.count, 6)
        // Closed 240, 200, 160, 120, 80 and 40 days ago: 90 days keeps the last two, and a cap of one keeps the newest.
        XCTAssertEqual(try s.pruneArchive(olderThan: 90 * 86400, maxEntries: 100), 4)
        XCTAssertEqual(try s.pruneArchive(olderThan: 90 * 86400, maxEntries: 1), 1)
        XCTAssertEqual(s.archivedEntries.map(\.url), ["https://a5.example/"])
    }

    func testPageContentChangesAreFlaggedContentOnly() throws {
        let s = try makeStore()
        let t = try s.openTab(url: "https://a.example/", inSpace: s.selectedSpace.id)
        var changes: [StoreChange] = []
        s.observe { changes.append($0) }
        s.updateTab(t.id, title: "A")
        XCTAssertEqual(changes.last?.contentOnly, true)
        _ = try s.openTab(url: "https://b.example/", inSpace: s.selectedSpace.id)
        XCTAssertEqual(changes.last?.contentOnly, false)
    }
}

/// Code review L3: empty text and BLOB values don't crash a query.
final class DatabaseValueTests: XCTestCase {
    func testEmptyTextAndBlob() throws {
        let db = try Database(path: nil)
        try db.exec("CREATE TABLE t(a TEXT, b BLOB); INSERT INTO t VALUES('', X''); INSERT INTO t VALUES('x', X'00FF')")
        let rows = try db.query("SELECT a, b FROM t ORDER BY a")
        XCTAssertEqual(rows[0][0] as? String, "")
        XCTAssertEqual(rows[0][1] as? Data, Data())
        XCTAssertEqual(rows[1][1] as? Data, Data([0x00, 0xFF]))
    }
}
