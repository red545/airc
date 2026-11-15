// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// P19a: Easels on disk (atomic save, .bak, recovery, assets, history across a relaunch) and their sidebar rows.
final class EaselStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("easel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func doc(_ id: String = "e1", blocks n: Int) -> EaselDocument {
        var d = EaselDocument(id: id, title: "Board")
        for i in 0..<n {
            d.add(EaselBlock(id: "b\(i)", frame: EaselRect(x: Double(i) * 20, y: 0, width: 10, height: 10), content: .shape(EaselShape(.rectangle))))
        }
        return d
    }

    func files(_ id: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: EaselFiles(root: root).folder(id).path).sorted()
    }

    func testSaveIsAtomicAndKeepsTheVersionBefore() throws {
        let f = EaselFiles(root: root)
        var d = doc(blocks: 2)
        try f.save(d)
        XCTAssertEqual(try files("e1"), ["easel.json"])
        d.add(EaselBlock(id: "b9", frame: EaselRect(x: 0, y: 0, width: 1, height: 1), content: .shape(EaselShape(.ellipse))))
        try f.save(d)
        XCTAssertEqual(try files("e1"), ["easel.json", "easel.json.bak"])
        let r = f.load("e1")
        XCTAssertEqual(r.source, .document)
        XCTAssertEqual(r.document, d)
        let bak = try EaselFiles.decoder().decode(EaselDocument.self, from: Data(contentsOf: f.backupURL("e1")))
        XCTAssertEqual(bak.blocks.count, 2)
        XCTAssertNil(r.message)
    }

    func testATruncatedFileOpensItsBackupAndIsKept() throws {
        let f = EaselFiles(root: root)
        try f.save(doc(blocks: 3))
        try f.save(doc(blocks: 4))
        // A crash or a full disk mid-write elsewhere: the file ends halfway.
        let data = try Data(contentsOf: f.documentURL("e1"))
        try data.prefix(data.count / 2).write(to: f.documentURL("e1"))
        let r = f.load("e1")
        XCTAssertEqual(r.source, .backup(partial: false))
        XCTAssertEqual(r.document.blocks.count, 3)
        XCTAssertEqual(r.document.id, "e1")
        XCTAssertNotNil(r.message)
        let kept = try XCTUnwrap(r.keptDamaged)
        XCTAssertEqual(try Data(contentsOf: kept), data.prefix(data.count / 2))
        // Saving the recovered Easel never loses the damaged file.
        try f.save(r.document)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testABadBlockIsLeftOutAndReported() throws {
        let f = EaselFiles(root: root)
        try f.save(doc(blocks: 3))
        // One block damaged (its frame isn't a frame), one of an unknown future kind (kept).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.documentURL("e1"))) as? [String: Any])
        var blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        blocks[1]["frame"] = "nonsense"
        blocks.append(["id": "fut", "frame": ["x": 0, "y": 0, "width": 1, "height": 1], "z": 9, "content": ["type": "hologram"]])
        json["blocks"] = blocks
        try JSONSerialization.data(withJSONObject: json).write(to: f.documentURL("e1"))
        let r = f.load("e1")
        XCTAssertEqual(r.source, .partialDocument)
        XCTAssertEqual(r.document.blocks.map(\.id).sorted(), ["b0", "b2", "fut"])
        XCTAssertEqual(r.issues.map(\.blockID), ["b1"])
        XCTAssertEqual(r.issues.first?.index, 1)
        XCTAssertTrue(r.message?.contains("1 item left out") == true)
        XCTAssertNotNil(r.keptDamaged)
    }

    func testAPartReadingFileWithNewerBlocksBeatsAnOlderBackup() throws {
        let f = EaselFiles(root: root)
        try f.save(doc(blocks: 1))
        try f.save(doc(blocks: 5))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.documentURL("e1"))) as? [String: Any])
        var blocks = try XCTUnwrap(json["blocks"] as? [[String: Any]])
        blocks[0]["content"] = 7
        json["blocks"] = blocks
        try JSONSerialization.data(withJSONObject: json).write(to: f.documentURL("e1"))
        let r = f.load("e1")
        XCTAssertEqual(r.source, .partialDocument)
        XCTAssertEqual(r.document.blocks.count, 4)
    }

    func testNothingReadableIsAnEmptyEaselAndBothFilesAreKept() throws {
        let f = EaselFiles(root: root)
        try FileManager.default.createDirectory(at: f.folder("e1"), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: f.documentURL("e1"))
        try Data([0, 1, 2]).write(to: f.backupURL("e1"))
        let r = f.load("e1")
        XCTAssertEqual(r.source, .unreadable)
        XCTAssertTrue(r.document.blocks.isEmpty)
        XCTAssertEqual(try files("e1").filter { $0.hasPrefix("easel.json.damaged-") }.count, 1)
        XCTAssertEqual(f.load("missing").source, .missing)
    }

    func testHistorySurvivesARelaunchOnlyForItsDocument() throws {
        let f = EaselFiles(root: root)
        var d = doc(blocks: 1)
        var h = EaselHistory()
        let before = d
        d.move(["b0"], dx: 5, dy: 0)
        h.record("Move", from: before, to: d)
        d.revision = newID()
        h.revision = d.revision
        try f.save(d)
        try f.saveHistory(h, id: d.id)
        // Relaunch.
        var loaded = f.load("e1").document
        var back = try XCTUnwrap(f.loadHistory(for: loaded))
        XCTAssertEqual(back.undoName, "Move")
        back.undo(&loaded)
        XCTAssertEqual(loaded.block("b0")?.frame.x, 0)
        // A document from another state (an older version, a .bak) drops it.
        var other = d
        other.revision = newID()
        XCTAssertNil(f.loadHistory(for: other))
    }

    func testAssetsAreNamedByTheirBytesAndCopiedBetweenEasels() throws {
        let f = EaselFiles(root: root)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let a = try f.addAsset(png, ext: "PNG", to: "e1")
        XCTAssertTrue(EaselFiles.isValidAsset(a))
        XCTAssertEqual(try f.addAsset(png, ext: "png", to: "e1"), a)
        f.copyAssets([a], from: "e1", to: "e2")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(f.assetURL("e2", a))), png)
        XCTAssertNil(f.assetURL("e1", "../../etc/passwd.png"))
        XCTAssertNil(f.assetURL("../x", a))
        XCTAssertFalse(EaselFiles.isValidID("a/b"))
        XCTAssertThrowsError(try f.save(EaselDocument(id: "../escape")))
    }

    func testListingIsNewestFirst() throws {
        let f = EaselFiles(root: root)
        var a = doc("a", blocks: 1)
        a.updatedAt = Date(timeIntervalSince1970: 100)
        var b = doc("b", blocks: 2)
        b.updatedAt = Date(timeIntervalSince1970: 200)
        b.title = ""
        try f.save(a)
        try f.save(b)
        let l = f.list()
        XCTAssertEqual(l.map(\.id), ["b", "a"])
        XCTAssertEqual(l.first?.displayTitle, EaselURL.untitled)
        XCTAssertEqual(l.first?.blockCount, 2)
    }

    // MARK: Rows

    func testNewEaselIsAPinnedRowWithItsAddressAndRenames() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let t = try s.createEasel("e1", inSpace: space)
        XCTAssertEqual(t.url, "airc-easel:e1")
        XCTAssertEqual(t.title, EaselURL.untitled)
        XCTAssertTrue(s.isEaselTab(t.id))
        XCTAssertEqual(s.easelID(forTab: t.id), "e1")
        let item = try XCTUnwrap(t.itemID.flatMap { s.item($0) })
        XCTAssertEqual(item.savedURL, "airc-easel:e1")
        XCTAssertTrue(SyncStoreAdapter.isLocalOnly(item))
        s.renameEaselRows("e1", to: "  Moodboard ")
        XCTAssertEqual(s.tab(t.id)?.title, "Moodboard")
        XCTAssertEqual(s.item(item.id)?.pageTitle, "Moodboard")
        XCTAssertEqual(s.referencedEaselIDs, ["e1"])
        XCTAssertEqual(URLRules.displayHost("airc-easel:e1"), "Easel")
        // Typing in its tab's address field opens a page in a new tab, never in the Easel's.
        let today = try s.createEasel("e2", inSpace: space, pinned: false)
        XCTAssertNil(today.itemID)
        XCTAssertEqual(s.navigationDecision(forTab: today.id), .openTodayTab)
        // Easels stay out of Favorites.
        XCTAssertThrowsError(try s.move(.tab(today.id), to: .favorites(profileID: s.defaultProfile.id, index: 0)))
        XCTAssertThrowsError(try s.createEasel("../bad", inSpace: space))
    }

    func testAnArchivedEaselRestores() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let t = try s.createEasel("e1", inSpace: space, pinned: false, title: "Board")
        _ = try s.closeTab(t.id)
        XCTAssertEqual(s.archiveEntries(ofEasel: "e1").count, 1)
        XCTAssertTrue(s.tabs(showingEasel: "e1").isEmpty)
        XCTAssertEqual(s.referencedEaselIDs, ["e1"])
        let entry = try XCTUnwrap(s.archiveEntries(ofEasel: "e1").first)
        _ = try s.restoreArchived(entry.id, fallbackSpaceID: space)
        XCTAssertEqual(s.tabs(showingEasel: "e1").first?.title, "Board")
    }
}
