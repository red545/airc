// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class BackupRestoreTests: XCTestCase {
    @MainActor
    func testAsyncRestorePendingWritesAndAtomicFailure() async throws {
        let s = try makeStore(TestClock())
        let bytes = try s.exportJSON()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try s.perform("Pending", undoable: true, deferred: true) {
            var p = s.defaultProfile; p.name = "Pending name"; s.put(p)
        }
        XCTAssertTrue(s.hasPendingWrites)
        let before = s.state, undo = s.undoStack.count
        let expectedRecovery = try SpacesStore.readBackup(s.exportJSON()).state
        s.failNextFlushes = 1
        do { _ = try await s.restoreBackup(bytes, savingCurrentTo: folder); XCTFail("Expected SQLite failure") }
        catch { }
        XCTAssertEqual(s.state, before)
        XCTAssertEqual(s.undoStack.count, undo)
        XCTAssertTrue(s.hasPendingWrites)
        XCTAssertFalse(s.isRestoring)
        try s.flush()
        var notifications = 0
        let observer = s.observe { _ in notifications += 1 }
        let recovery = try await s.restoreBackup(bytes, savingCurrentTo: folder)
        s.removeObserver(observer)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(try SpacesStore.readBackup(Data(contentsOf: recovery)).state, expectedRecovery)
        XCTAssertEqual(s.state, try SpacesStore.readBackup(bytes).state)
        XCTAssertTrue(s.undoStack.isEmpty)
        XCTAssertFalse(s.hasPendingWrites)
    }

    @MainActor
    func testAsyncRestoreRejectsOverlappingWriteAndLargeApplyIsOneFrame() async throws {
        let s = try makeStore(TestClock())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sid = s.selectedSpace.id, pid = s.defaultProfile.id
        let initial = try s.exportJSON()
        let bytes = try await Task.detached {
            var b = try SpacesStore.readBackup(initial)
            for i in 0..<5000 {
                let t = LiveTab(profileID: pid, spaceID: sid, url: "https://example.com/\(i)", title: "Tab \(i)", order: Double(i), createdAt: b.exportedAt)
                b.state.tabs[t.id] = t
            }
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            return try e.encode(b)
        }.value
        let restore = Task { try await s.restoreBackup(bytes, savingCurrentTo: folder) }
        while !s.isRestoring { await Task.yield() }
        XCTAssertThrowsError(try s.createSpace(name: "Concurrent"))
        try s.flush() // A timer flush cannot overtake the restore's transaction.
        _ = try await restore.value
        XCTAssertEqual(s.state.tabs.count, 5000)
        print("5000-tab restore apply: \(s.lastRestoreApplyDuration * 1000) ms")
        XCTAssertLessThan(s.lastRestoreApplyDuration, 0.016)
        let ops = try s.operations()
        XCTAssertEqual(ops.filter { $0.kind == .tab && $0.op == "put" }.count, 5000)
    }

    @MainActor
    func testAsyncRestoreDurabilityWithDeferredWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("store.sqlite").path
        let s = try SpacesStore(path: path)
        let bytes = try s.exportJSON()
        let persisted = try SpacesStore(path: path).state
        try s.perform(nil, deferred: true) {
            var p = s.defaultProfile; p.name = "Not flushed"; s.put(p)
        }
        let recoveryState = try SpacesStore.readBackup(s.exportJSON()).state
        s.failNextFlushes = 1
        do { _ = try await s.restoreBackup(bytes, savingCurrentTo: folder); XCTFail("Expected rollback") }
        catch { }
        XCTAssertEqual(try SpacesStore(path: path).state, persisted)
        let recovery = try await s.restoreBackup(bytes, savingCurrentTo: folder)
        XCTAssertEqual(try SpacesStore.readBackup(Data(contentsOf: recovery)).state, recoveryState)
        XCTAssertEqual(try SpacesStore(path: path).state, s.state)
        try s.flush()
        XCTAssertEqual(try SpacesStore(path: path).state, s.state, "old deferred write cannot overwrite restore")
    }

    @MainActor
    func testAsyncPreparationFailuresLeaveCurrentStateUntouched() async throws {
        let s = try makeStore(), bytes = try s.exportJSON()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let before = s.state
        for data in [bytes, Data("broken".utf8)] {
            do { _ = try await s.restoreBackup(data, savingCurrentTo: file); XCTFail("Expected failure") }
            catch { }
            XCTAssertEqual(s.state, before)
            XCTAssertFalse(s.isRestoring)
        }
    }

    func testAppliedRestoreClearsUndoEvenWhenFlushFails() throws {
        let s = try makeStore(TestClock())
        let backup = try s.exportJSON()
        try s.perform("New Space", undoable: true) { _ = try s.createSpace(name: "Later") }
        XCTAssertFalse(s.undoStack.isEmpty)
        s.failNextFlushes = 1
        XCTAssertThrowsError(try s.restore(fromBackup: backup))
        XCTAssertFalse(s.state.spaces.values.contains { $0.name == "Later" })
        XCTAssertTrue(s.undoStack.isEmpty)
        try s.flush()
    }

    func testCatalogRoundTripAndRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let s = try makeStore(clock)
        let tab = try s.openTab(url: "https://example.com", inSpace: s.selectedSpace.id, title: "Earlier")
        _ = try s.closeTab(tab.id)
        // An unloaded pinned tab still belongs in the catalog's tab count.
        try s.perform(nil) {
            s.put(Item(kind: .tab, container: .pinned(spaceID: s.selectedSpace.id),
                       savedURL: "https://example.com/pinned", title: "Pinned", createdAt: clock.date))
        }
        let oldState = try SpacesStore.readBackup(s.exportJSON()).state
        let older = try s.writeBackup(to: folder, purpose: .manual)
        clock.advance(3600)
        _ = try s.createSpace(name: "Later")
        _ = try s.writeBackup(to: folder, purpose: .manual)
        let current = s.state
        let expectedRecovery = try SpacesStore.readBackup(s.exportJSON()).state
        let rows = try SpacesStore.listBackups(in: folder)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(try XCTUnwrap(rows.first?.date) > XCTUnwrap(rows.last?.date))
        let row = try XCTUnwrap(rows.first { $0.url.lastPathComponent == older.lastPathComponent })
        XCTAssertEqual(row.spaces, oldState.spaces.count)
        XCTAssertEqual(row.tabs, 1)
        XCTAssertEqual(row.archived, 1)
        let bytes = try Data(contentsOf: older)
        XCTAssertEqual(row.size, bytes.count)
        XCTAssertEqual(row.date, try SpacesStore.readBackup(bytes).exportedAt)
        XCTAssertEqual(s.state, current, "Listing must be read-only")
        let recovery = try s.restore(fromBackup: bytes, savingCurrentTo: folder)
        XCTAssertEqual(s.state, oldState)
        XCTAssertEqual(try SpacesStore.readBackup(Data(contentsOf: recovery)).state, expectedRecovery)
        XCTAssertTrue(recovery.lastPathComponent.hasPrefix("airc-before-restore-"))
        _ = try s.backupIfNeeded(to: folder, keep: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testCorruptAndFutureBackupsLeaveStateAndUndoUntouched() throws {
        let s = try makeStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = s.state, undo = s.undoStack.count
        var future = try JSONSerialization.jsonObject(with: s.exportJSON()) as! [String: Any]
        future["version"] = 99999
        for data in [Data("broken".utf8), try JSONSerialization.data(withJSONObject: future)] {
            XCTAssertThrowsError(try s.restore(fromBackup: data, savingCurrentTo: folder))
            XCTAssertEqual(s.state, before)
            XCTAssertEqual(s.undoStack.count, undo)
        }
        try Data("broken".utf8).write(to: folder.appendingPathComponent("bad.json"))
        let rows = try SpacesStore.listBackups(in: folder)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows.first?.problem)
        XCTAssertNil(rows.first?.date)
    }

    /// A backup older than the archive interval: its Today tabs come back as just used, in their order of use, not
    /// into the Archive at the next auto-archive pass.
    func testRestoredTodayTabsAreNotDueForAutoArchive() throws {
        let clock = TestClock()
        let s = try makeStore(clock)
        let older = try s.openTab(url: "https://example.com/older", inSpace: s.selectedSpace.id, title: "Older")
        clock.advance(60)
        let newer = try s.openTab(url: "https://example.com/newer", inSpace: s.selectedSpace.id, title: "Newer")
        let bytes = try s.exportJSON()
        clock.advance(3 * 86_400)
        XCTAssertEqual(Set(s.dueForAutoArchive()), [older.id, newer.id])
        try s.restore(fromBackup: bytes)
        XCTAssertEqual(s.dueForAutoArchive(), [])
        let a = try XCTUnwrap(s.tab(older.id)), b = try XCTUnwrap(s.tab(newer.id))
        XCTAssertEqual(b.lastActiveAt, clock.date)
        XCTAssertLessThan(a.lastActiveAt, b.lastActiveAt)
        XCTAssertEqual(a.createdAt, older.createdAt)
    }

    /// Daily retention counts and removes only daily files: Back Up Now's (same prefix) stay, and today's daily file
    /// isn't removed right after it's written.
    func testDailyRetentionLeavesManualBackups() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock()
        let s = try makeStore(clock)
        let manual = try (0..<3).map { _ in try s.writeBackup(to: folder, purpose: .manual) }
        var last: URL?
        for _ in 0..<4 {
            last = try s.backupIfNeeded(to: folder, keep: 2)
            clock.advance(86_400)
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(names.filter { $0.hasPrefix("airc-backup-manual-") }, Set(manual.map(\.lastPathComponent)))
        XCTAssertEqual(names.subtracting(manual.map(\.lastPathComponent)).count, 2)
        XCTAssertTrue(names.contains(try XCTUnwrap(last).lastPathComponent))
    }

    func testRecoveryWriteFailurePreventsRestore() throws {
        let s = try makeStore(), bytes = try s.exportJSON()
        _ = try s.createSpace(name: "Keep me")
        let state = s.state
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        XCTAssertThrowsError(try s.restore(fromBackup: bytes, savingCurrentTo: file))
        XCTAssertEqual(s.state, state)
    }
}
