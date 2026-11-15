// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
@testable import AircKit
import XCTest

/// libpeek (L05, N07/N08): Export as Image…'s trimmed edges, Export as Web Page…'s archive (index.html and every
/// picture it names, relative), and Library › Easels › Delete Easel… (rows in one ⌘Z step, the folder to the Trash and
/// back).
final class EaselLibraryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("easel-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Export as Image…

    /// A width×height RGBA buffer with the given pixels' alpha set.
    func buffer(_ w: Int, _ h: Int, padding: Int = 0, alpha: [(Int, Int, UInt8)]) -> (bytes: [UInt8], bytesPerRow: Int) {
        let bpr = w * 4 + padding
        var b = [UInt8](repeating: 0, count: bpr * h)
        for (x, y, a) in alpha {
            b[y * bpr + x * 4] = 200
            b[y * bpr + x * 4 + 3] = a
        }
        return (b, bpr)
    }

    func bounds(_ w: Int, _ h: Int, padding: Int = 0, threshold: UInt8 = 0, _ alpha: [(Int, Int, UInt8)]) -> [Int]? {
        let (b, bpr) = buffer(w, h, padding: padding, alpha: alpha)
        return b.withUnsafeBytes { p in
            EaselTrim.opaqueBounds(p, width: w, height: h, bytesPerRow: bpr, threshold: threshold).map { [$0.x, $0.y, $0.width, $0.height] }
        }
    }

    func testTrimFindsTheSmallestBoxOfVisiblePixels() {
        XCTAssertEqual(bounds(10, 8, [(3, 2, 255), (6, 5, 10)]), [3, 2, 4, 4])
        XCTAssertEqual(bounds(10, 8, [(0, 0, 255), (9, 7, 255)]), [0, 0, 10, 8], "corners keep everything")
        XCTAssertEqual(bounds(10, 8, [(4, 4, 1)]), [4, 4, 1, 1], "one faint pixel counts")
        XCTAssertEqual(bounds(10, 8, padding: 12, [(2, 1, 255), (7, 6, 255)]), [2, 1, 6, 6], "row padding is ignored")
        XCTAssertEqual(bounds(10, 8, threshold: 20, [(2, 1, 10), (5, 5, 255)]), [5, 5, 1, 1], "below the threshold is margin")
    }

    func testTrimOfNothingIsNil() {
        XCTAssertNil(bounds(10, 8, []))
        XCTAssertNil(bounds(0, 8, []))
        let tiny = [UInt8](repeating: 255, count: 8)
        XCTAssertNil(tiny.withUnsafeBytes { EaselTrim.opaqueBounds($0, width: 4, height: 4, bytesPerRow: 16) }, "a short buffer is refused")
    }

    // MARK: Export as Web Page…

    func testTheWebPageArchiveHasEveryPictureItsPageNames() throws {
        let hex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360f8cf00000301010018dd8db40000000049454e44ae426082"
        let chars = Array(hex)
        let png = Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
        var d = EaselDocument(id: "e1", title: "Moodboard")
        let local = String(repeating: "c", count: 64) + ".png"
        d.add(EaselBlock(id: "t", frame: EaselRect(x: 0, y: 0, width: 200, height: 60),
                         content: .text(EaselText(NoteDocument(blocks: [NoteBlock(kind: .heading1, runs: [NoteRun("Ideas")])]), color: .red))))
        d.add(EaselBlock(id: "i", frame: EaselRect(x: 220, y: 0, width: 100, height: 100), content: .image(EaselImage(asset: local, pixelWidth: 1, pixelHeight: 1))))
        var (p, report) = EaselPublic.make(d)
        let name = try XCTUnwrap(EaselPublic.pictureName(png))
        p = p.settingPictures([local: .init(name: name, size: png.count)], report: &report)
        let entries = try XCTUnwrap(ZipReader.entries(try EaselExport.htmlArchive(p, pictures: [name: png])))
        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("Moodboard/index.html"))
        let html = String(decoding: try XCTUnwrap(entries.first { $0.name == "Moodboard/index.html" }).data, as: UTF8.self)
        // Every src in the page is relative and in the ZIP beside it.
        let srcs = html.components(separatedBy: "src=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        XCTAssertFalse(srcs.isEmpty)
        for s in srcs {
            XCTAssertFalse(s.contains(":") || s.hasPrefix("/"), "relative: \(s)")
            XCTAssertTrue(names.contains("Moodboard/" + s), "in the archive: \(s)")
        }
        XCTAssertTrue(html.contains("<h1>Ideas</h1>"))
        XCTAssertEqual(EaselExport.fileName(d.title), "Moodboard")
    }

    // MARK: Delete Easel…

    func testDeletingAnEaselRemovesEveryRowInOneUndoStep() throws {
        let s = try makeStore()
        let space = s.selectedSpace.id
        let pinned = try s.createEasel("e1", inSpace: space, title: "Board")
        let today = try s.reopenEasel("e1", title: "Board", inSpace: space)
        let other = try s.createEasel("e2", inSpace: space, title: "Other")
        // An archived row of it too.
        let old = try s.reopenEasel("e1", title: "Board", inSpace: space)
        _ = try s.archiveTabs([old.id], reason: .manual, label: "Archive")
        XCTAssertEqual(s.archiveEntries(ofEasel: "e1").count, 1)
        let item = try XCTUnwrap(pinned.itemID)

        let gone = try s.deleteEaselRows("e1")
        XCTAssertEqual(Set(gone), [pinned.id, today.id])
        XCTAssertTrue(s.tabs(showingEasel: "e1").isEmpty)
        XCTAssertNil(s.item(item))
        XCTAssertTrue(s.archiveEntries(ofEasel: "e1").isEmpty)
        XCTAssertFalse(s.referencedEaselIDs.contains("e1"))
        XCTAssertNotNil(s.tab(other.id), "another Easel stays")
        XCTAssertEqual(s.undoLabel, "Delete Easel")

        try s.undo()
        XCTAssertEqual(Set(s.tabs(showingEasel: "e1").map(\.id)), [pinned.id, today.id])
        XCTAssertNotNil(s.item(item))
        XCTAssertEqual(s.archiveEntries(ofEasel: "e1").count, 1)
        XCTAssertTrue(s.referencedEaselIDs.contains("e1"))
        // Nothing to delete: no step.
        XCTAssertEqual(try s.deleteEaselRows("nothing"), [])
    }

    func testTheFolderGoesToTheTrashAndComesBack() throws {
        let f = EaselFiles(root: root)
        try f.save(EaselDocument(id: "e1", title: "Board"))
        _ = try f.addAsset(Data("pic".utf8), ext: "png", to: "e1")
        let trashed: URL
        do {
            guard let t = try f.moveToTrash("e1") else { return XCTFail("no Trash URL") }
            trashed = t
        } catch {
            throw XCTSkip("no Trash on this volume: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: trashed) }
        XCTAssertFalse(f.exists("e1"))
        XCTAssertFalse(f.list().contains { $0.id == "e1" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertTrue(f.putBack("e1", from: trashed))
        XCTAssertTrue(f.exists("e1"))
        XCTAssertEqual(f.load("e1").document.title, "Board")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path), "out of the Trash again")
        XCTAssertFalse(f.putBack("e1", from: trashed), "only once")
        XCTAssertNil(try f.moveToTrash("missing"))
    }
}
