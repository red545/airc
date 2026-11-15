// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// LIB-2: Clear Archive by age, its one Undo, and that nothing cleared comes back (auto-archive, retention, sync).
final class ClearArchiveAgeTests: XCTestCase {
    private func archive(_ s: SpacesStore, _ url: String, space: String? = nil) throws -> ArchiveEntry {
        let t = try s.openTab(url: url, inSpace: space ?? s.selectedSpace.id)
        _ = try s.closeTab(t.id)
        return try XCTUnwrap(s.archivedEntries.first { $0.tab.id == t.id })
    }

    /// Entries archived 40, 10 and 1 day(s) before the clock's "now".
    private func aged(_ clock: TestClock, _ s: SpacesStore) throws -> (old: ArchiveEntry, week: ArchiveEntry, new: ArchiveEntry) {
        let old = try archive(s, "https://example.com/old")
        clock.advance(30 * 86400)
        let week = try archive(s, "https://example.com/week")
        clock.advance(9 * 86400)
        let new = try archive(s, "https://example.com/new")
        clock.advance(86400)
        return (old, week, new)
    }

    func testAgesPickOnlyOlderEntries() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let e = try aged(clock, s)
        let thirty = try s.clearArchive(age: .olderThan30Days) {}
        XCTAssertEqual(thirty.entries.map(\.id), [e.old.id])
        XCTAssertEqual(Set(s.state.archive.keys), [e.week.id, e.new.id])
        let seven = try s.clearArchive(age: .olderThan7Days) {}
        XCTAssertEqual(seven.entries.map(\.id), [e.week.id])
        XCTAssertEqual(Set(s.state.archive.keys), [e.new.id])
        XCTAssertEqual(try s.clearArchive(age: .olderThan7Days) { XCTFail("nothing to clear: no backup") }.count, 0)
        XCTAssertEqual(try s.clearArchive(age: .everything) {}.count, 1)
        XCTAssertTrue(s.state.archive.isEmpty)
    }

    func testBoundaryIsStrictlyOlder() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let e = try archive(s, "https://example.com/edge")
        clock.advance(7 * 86400)
        XCTAssertFalse(ArchiveClearAge.olderThan7Days.includes(e, now: clock.date), "exactly 7 days is not older than 7 days")
        clock.advance(1)
        XCTAssertTrue(ArchiveClearAge.olderThan7Days.includes(e, now: clock.date))
        XCTAssertTrue(ArchiveClearAge.everything.includes(e, now: .distantPast))
    }

    func testUndoPutsBackExactlyWhatWasCleared() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let e = try aged(clock, s)
        let before = s.state.archive
        var backups = 0
        let cleared = try s.clearArchive(age: .olderThan7Days) { backups += 1 }
        XCTAssertEqual(backups, 1, "a recovery backup comes first")
        XCTAssertEqual(cleared.count, 2)
        // Something archived while the toast showed stays; Undo adds the cleared ones back around it.
        let later = try archive(s, "https://example.com/later")
        XCTAssertEqual(try s.restoreCleared(cleared), 2)
        var expected = before; expected[later.id] = later
        XCTAssertEqual(s.state.archive, expected, "same ids, dates and tabs")
        XCTAssertEqual(try s.restoreCleared(cleared), 0, "a second Undo doubles nothing")
        // The restored entries still restore as tabs.
        let tab = try s.restoreArchived(e.old.id, fallbackSpaceID: s.selectedSpace.id)
        XCTAssertEqual(tab.url, "https://example.com/old")
    }

    func testUndoIsNotACommandZStep() throws {
        let clock = TestClock(), s = try makeStore(clock)
        _ = try aged(clock, s)
        let a = try archive(s, "https://example.com/recent")
        _ = try s.clearArchive(age: .everything) {}
        // ⌘Z can't bring an archived tab back from nothing: the cleared Close Tab steps are dropped.
        while try s.undo() != nil {}
        XCTAssertNil(s.tab(a.tab.id))
        XCTAssertTrue(s.state.archive.isEmpty)
    }

    func testUndoSkipsEntriesOfADeletedProfile() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let p = try s.createProfile(name: "Other", emoji: "🌱")
        let space = try s.createSpace(name: "Other", profileID: p.id)
        let mine = try archive(s, "https://example.com/mine"), theirs = try archive(s, "https://example.com/theirs", space: space.id)
        let cleared = try s.clearArchive(age: .everything) {}
        try s.deleteSpace(space.id)
        try s.deleteProfile(p.id)
        XCTAssertEqual(try s.restoreCleared(cleared), 1)
        XCTAssertEqual(Set(s.state.archive.keys), [mine.id])
        XCTAssertNil(s.state.archive[theirs.id])
    }

    func testConfirmedSnapshotKeepsLaterArrivals() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let e = try aged(clock, s)
        let snapshot = Set(s.archivedEntries.filter { ArchiveClearAge.olderThan7Days.includes($0, now: clock.date) }.map(\.id))
        clock.advance(20 * 86400)  // e.new is now older than 7 days too, but wasn't in the confirmed list
        let cleared = try s.clearArchive(age: .olderThan7Days, entryIDs: snapshot) {}
        XCTAssertEqual(Set(cleared.entries.map(\.id)), [e.old.id, e.week.id])
        XCTAssertEqual(Set(s.state.archive.keys), [e.new.id])
    }

    func testFailedBackupClearsNothing() throws {
        let clock = TestClock(), s = try makeStore(clock)
        _ = try aged(clock, s)
        XCTAssertThrowsError(try s.clearArchive(age: .everything) { throw CocoaError(.fileWriteNoPermission) })
        XCTAssertEqual(s.state.archive.count, 3)
    }

    /// The Archive's own clean-up still works around a Clear Archive: auto-archive keeps filling it, retention
    /// (90 days) keeps pruning it, and an Undo doesn't resurrect what retention would remove anyway forever.
    func testAutoArchiveAndRetentionStillWork() throws {
        let clock = TestClock(), s = try makeStore(clock)
        _ = try aged(clock, s)
        let cleared = try s.clearArchive(age: .olderThan30Days) {}
        XCTAssertEqual(cleared.count, 1)
        // Auto-archive: an idle Today tab still goes to the Archive after its profile's interval.
        let idle = try s.openTab(url: "https://example.com/idle", inSpace: s.selectedSpace.id, activate: false)
        clock.advance(s.defaultProfile.archiveAfter.seconds + 60)
        XCTAssertEqual(try s.autoArchive(), [idle.id])
        XCTAssertTrue(s.state.archive.values.contains { $0.tab.id == idle.id && $0.reason == .auto })
        XCTAssertEqual(try s.restoreCleared(cleared), 1)
        // Retention: past 90 days the restored entry is pruned as before.
        clock.advance(91 * 86400)
        XCTAssertGreaterThanOrEqual(try s.pruneArchive(), 1)
        XCTAssertNil(s.state.archive[cleared.entries[0].id])
    }

    /// Cleared entries never come back through iCloud sync: the Archive isn't synced, clearing sends nothing, and a
    /// record another Mac marks archived doesn't materialize into this Mac's Archive.
    func testSyncNeitherSendsNorResurrectsClearedEntries() throws {
        let clock = TestClock(), s = try makeStore(clock)
        let space = s.selectedSpace.id
        let pinned = try s.openTab(url: "https://example.com/pinned", inSpace: space)
        try s.move(.tab(pinned.id), to: .pinned(spaceID: space, parentID: nil, index: 0))
        var adapter = SyncStoreAdapter(includeToday: true), replica = SyncReplica()
        try adapter.capture(s.state, into: &replica, now: 1)
        let item = try XCTUnwrap(s.tab(pinned.id)?.itemID)
        try s.move(.item(item), to: .today(spaceID: space, index: 0))
        _ = try s.closeTab(pinned.id)
        try adapter.capture(s.state, into: &replica, now: 2)
        _ = try aged(clock, s)
        let cleared = try s.clearArchive(age: .everything) {}
        XCTAssertGreaterThanOrEqual(cleared.count, 4)
        XCTAssertTrue(try adapter.capture(s.state, into: &replica, now: 3).isEmpty, "clearing the Archive sends nothing")
        // Another Mac's replica (with the archived record) applied here: the Archive stays empty.
        var other = SyncReplica()
        try other.receive(replica.log, now: 4)
        _ = try s.applySync(other, adapter: &adapter)
        XCTAssertTrue(s.state.archive.isEmpty)
        // A fresh Mac receiving the same records gets no Archive either.
        let fresh = try makeStore()
        var freshAdapter = SyncStoreAdapter(includeToday: true)
        _ = try fresh.applySync(other, adapter: &freshAdapter)
        XCTAssertTrue(fresh.state.archive.isEmpty)
    }
}
