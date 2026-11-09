// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class ClearArchiveTests: XCTestCase {
    private func archived(_ s: SpacesStore, space: String) throws -> ArchiveEntry {
        let t = try s.openTab(url: "https://example.com", inSpace: space)
        _ = try s.closeTab(t.id)
        return try XCTUnwrap(s.archivedEntries.first { $0.tab.id == t.id })
    }

    func testScopesCountAndBackupBeforeDeletion() throws {
        let s = try makeStore()
        let first = s.selectedSpace.id
        let second = try s.createSpace(name: "Second").id
        let profile = try s.createProfile(name: "Separate", emoji: "🌱")
        let third = try s.createSpace(name: "Third", profileID: profile.id).id
        let a = try archived(s, space: first), b = try archived(s, space: second), c = try archived(s, space: third)
        var snapshots: [Data] = []
        XCTAssertEqual(try s.clearArchive(scope: .space(first)) {
            XCTAssertEqual(s.state.archive.count, 3)
            snapshots.append(try s.exportJSON())
        }, 1)
        XCTAssertNil(s.state.archive[a.id])
        XCTAssertNotNil(s.state.archive[b.id]); XCTAssertNotNil(s.state.archive[c.id])
        XCTAssertEqual(try s.clearArchive(scope: .profile(s.defaultProfile.id)) { snapshots.append(try s.exportJSON()) }, 1)
        XCTAssertEqual(Set(s.state.archive.keys), [c.id])
        XCTAssertEqual(try s.clearArchive { snapshots.append(try s.exportJSON()) }, 1)
        XCTAssertEqual(try s.clearArchive { XCTFail("Empty archive must not write a backup") }, 0)
        let recovered = try makeStore()
        try recovered.restore(fromBackup: snapshots[0])
        XCTAssertEqual(Set(recovered.state.archive.keys), [a.id, b.id, c.id])
    }

    func testFailedBackupKeepsArchiveAndUndo() throws {
        let s = try makeStore(), a = try archived(s, space: s.selectedSpace.id)
        let undoCount = s.undoStack.count
        XCTAssertThrowsError(try s.clearArchive { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertNotNil(s.state.archive[a.id])
        XCTAssertEqual(s.undoStack.count, undoCount)
    }

    func testUnwritableDestinationFailsClosedAndDeletionPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-persist-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("store.sqlite").path
        let s = try SpacesStore(path: path)
        let a = try archived(s, space: s.selectedSpace.id)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: blocked)
        XCTAssertThrowsError(try s.clearArchive {
            try s.writeBackup(to: blocked, purpose: .archiveRemoval)
        })
        XCTAssertNotNil(s.state.archive[a.id])
        let directory = root.appendingPathComponent("backups")
        XCTAssertEqual(try s.clearArchive {
            try s.writeBackup(to: directory, purpose: .archiveRemoval)
        }, 1)
        let reopened = try SpacesStore(path: path)
        XCTAssertTrue(reopened.state.archive.isEmpty)
        XCTAssertFalse(reopened.canUndo)
    }

    func testConfirmedIDsAndSingleRemovalDoNotRemoveLaterArrivals() throws {
        let s = try makeStore(), a = try archived(s, space: s.selectedSpace.id)
        let b = try archived(s, space: s.selectedSpace.id)
        XCTAssertEqual(try s.clearArchive(entryIDs: [a.id]) {}, 1)
        XCTAssertEqual(Set(s.state.archive.keys), [b.id])
        // An unrelated Close Tab remains undoable; the removed entry's Close Tab does not.
        XCTAssertNotNil(try s.undo())
        XCTAssertNil(try s.undo())
        XCTAssertNil(s.tab(a.tab.id))
        XCTAssertTrue(s.state.archive.isEmpty)
    }

    func testFreshBackupSurvivesDailyRetentionAndRestoresRemovedArchive() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.backupIfNeeded(to: dir)
        let a = try archived(s, space: s.selectedSpace.id)
        var backup: URL?
        XCTAssertEqual(try s.clearArchive {
            backup = try s.writeBackup(to: dir, purpose: .archiveRemoval)
        }, 1)
        XCTAssertFalse(s.canUndo)
        XCTAssertNil(try s.undo())
        clock.advance(86400)
        try s.backupIfNeeded(to: dir, keep: 1)
        let url = try XCTUnwrap(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let newer = try s.writeBackup(to: dir, purpose: .archiveRemoval)
        XCTAssertNotEqual(url, newer)
        try s.restore(fromBackup: Data(contentsOf: url))
        XCTAssertNotNil(s.state.archive[a.id])
    }
}
