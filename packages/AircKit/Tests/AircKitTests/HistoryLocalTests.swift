// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class HistoryLocalTests: XCTestCase {
    func testMatchesPersistedFullSearchAndHighlights() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        let h = try HistoryStore(path: path)
        for (i, title) in ["Swift documentation", "Café guide", "GitHub issues", "Ａｉｒｃ notes", "Swift language"].enumerated() {
            h.recordVisit(profileID: "p", url: "https://example.com/\(i)", title: title, typed: true)
        }
        // Reopen from SQLite, so this exercises the persisted source and off-main warmup too.
        let reopened = try HistoryStore(path: path)
        let full = reopened.indexSnapshotNow(profileID: "p")
        for q in ["swift", "cafe", "airc", "ghis", "example.com/", "notes", "missing", ""] {
            XCTAssertEqual(reopened.localMatches(q, profileID: "p"), full.search(q), q)
        }
    }

    func testRemovalClearAndProfileIsolation() throws {
        let h = try HistoryStore(path: nil)
        for p in ["one", "two"] {
            h.recordVisit(profileID: p, url: "https://match.example/", title: "Match")
            _ = h.indexSnapshotNow(profileID: p)
        }
        h.remove(profileID: "one", url: "https://match.example/")
        XCTAssertTrue(h.localMatches("match", profileID: "one").isEmpty)
        _ = h.indexSnapshotNow(profileID: "one")
        XCTAssertTrue(h.localMatches("match", profileID: "one").isEmpty)
        XCTAssertEqual(h.localMatches("match", profileID: "two").count, 1)
        h.prepareIndex(profileID: "two")
        h.clear(profileID: "two")
        XCTAssertTrue(h.localMatches("match", profileID: "two").isEmpty)
        XCTAssertNil(h.indexSnapshot(profileID: "two"))
        _ = h.indexSnapshotNow(profileID: "two")
        XCTAssertTrue(h.localMatches("match", profileID: "two").isEmpty)
        XCTAssertTrue(h.entries(ofProfile: "two").isEmpty)
    }

    func testPrivateAndColdLookupNeverBuilds() throws {
        let h = try HistoryStore(path: nil)
        h.recordVisit(profileID: "p", url: "https://match.example/", title: "Match")
        XCTAssertTrue(h.localMatches("match", profileID: "p").isEmpty)
        XCTAssertNil(h.indexSnapshot(profileID: "p"))
        _ = h.indexSnapshotNow(profileID: "p")
        XCTAssertEqual(h.localMatches("match", profileID: "p").count, 1)
        XCTAssertTrue(h.localMatches("match", profileID: nil).isEmpty)
        XCTAssertTrue(h.localMatches("match", profileID: "another").isEmpty)
    }

    func testBoundsRecentFrequentAndCost() {
        let now = Date()
        var rows = (0..<20_000).map { i in
            HistoryRow(HistoryEntry(profileID: "p", url: "https://site\(i).example/page",
                                    title: "Documentation \(i)", visitCount: 20_000 - i,
                                    lastVisit: now.addingTimeInterval(Double(i))), now: now)
        }
        rows.append(HistoryRow(HistoryEntry(profileID: "p", url: "https://long.example/",
                                           title: String(repeating: "x", count: 4096), visitCount: 999999,
                                           lastVisit: now.addingTimeInterval(999999)), now: now))
        let local = HistorySnapshot.local(rows: rows, now: now)
        XCTAssertEqual(local.count, HistorySnapshot.localEntryLimit)
        XCTAssertTrue(local.rows.contains { $0.entry.url == "https://site0.example/page" })
        XCTAssertTrue(local.rows.contains { $0.entry.url == "https://site19999.example/page" })
        XCTAssertFalse(local.rows.contains { $0.entry.url == "https://long.example/" })
        XCTAssertLessThanOrEqual(local.rows.reduce(0) { $0 + $1.entry.url.utf8.count + $1.entry.title.utf8.count },
                                 HistorySnapshot.localEntryLimit * HistorySnapshot.localTextByteLimit)
        var times: [Double] = []
        for q in ["d", "doc", "site", "page", "dcmnt", "no match"] {
            for _ in 0..<10 {
                let start = Date()
                _ = local.search(q)
                times.append(Date().timeIntervalSince(start) * 1000)
            }
        }
        print("[local-history] 128 of 20000: ms all=\(times), median=\(times.sorted()[times.count / 2]), max=\(times.max()!)")
    }

    func testColdWarmupKeepsFullIndexLazyAtProfileLimit() {
        let now = Date()
        let entries = Dictionary(uniqueKeysWithValues: (0..<HistoryStore.maxEntriesPerProfile).map { i in
            let e = HistoryEntry(profileID: "p", url: "https://site\(i).example/", title: "History page \(i)",
                                 lastVisit: now.addingTimeInterval(Double(i)))
            return (e.url, e)
        })
        let indexer = HistoryIndexer()
        indexer.load(["p": entries])
        let start = Date()
        indexer.prepareLocal(profileID: "p", now: now)
        _ = indexer.snapshotNow("barrier", now: now)
        XCTAssertNil(indexer.publishedSnapshot("p"))
        XCTAssertEqual(indexer.localSnapshot("p")?.count, HistorySnapshot.localEntryLimit)
        XCTAssertEqual(indexer.localSnapshot("p")?.search("history", limit: 200).count, HistorySnapshot.localEntryLimit)
        print("[local-history-warmup] 20000 source entries, bounded-only preparation ms=\(Date().timeIntervalSince(start) * 1000)")
    }

    func testLongUnicodeTitlesUsePreparedMatching() {
        let now = Date()
        let rows = (0..<128).map { i in
            HistoryRow(HistoryEntry(profileID: "p", url: "https://example.com/\(i)",
                                    title: "Café \(i) " + String(repeating: "éxample ", count: 50),
                                    lastVisit: now.addingTimeInterval(Double(i))), now: now)
        }
        let local = HistorySnapshot.local(rows: rows, now: now)
        XCTAssertEqual(local.count, 128)
        let full = HistorySnapshot(rows: rows, now: now)
        for q in ["cafe", "exmpl", "example.com", "fé 12"] {
            XCTAssertEqual(local.search(q), full.search(q))
        }
        var times: [Double] = []
        for i in 0..<20 {
            // Evict the shared matcher cache: the local tier must not depend on it.
            for j in 0..<4100 { _ = CommandSearch.folded("evict \(i) \(j)") }
            let start = Date()
            _ = local.search("exmpl")
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        print("[local-history-unicode] cold cache ms all=\(times), row stride=\(MemoryLayout<HistoryRow>.stride)")
    }

    func testUpdatesWarmWithoutAnotherOpening() throws {
        let h = try HistoryStore(path: nil)
        h.prepareLocalIndex(profileID: nil)
        h.prepareLocalIndex(profileID: "p")
        _ = h.indexSnapshotNow(profileID: "barrier")
        XCTAssertNil(h.indexSnapshot(profileID: "p"))
        h.recordVisit(profileID: "p", url: "https://new.example/", title: "New page")
        // Drain queued work via another profile, without rebuilding the profile under test.
        _ = h.indexSnapshotNow(profileID: "barrier")
        _ = h.indexSnapshotNow(profileID: "barrier")
        XCTAssertEqual(h.localMatches("new", profileID: "p").count, 1)
        h.updateTitle(profileID: "p", url: "https://new.example/", title: "Renamed page")
        _ = h.indexSnapshotNow(profileID: "barrier")
        _ = h.indexSnapshotNow(profileID: "barrier")
        XCTAssertEqual(h.localMatches("renamed", profileID: "p").first?.entry.title, "Renamed page")
        XCTAssertNil(h.indexSnapshot(profileID: "p"))
        h.remove(profileID: "p", url: "https://new.example/")
        _ = h.indexSnapshotNow(profileID: "barrier")
        XCTAssertTrue(h.localMatches("renamed", profileID: "p").isEmpty)
        XCTAssertNil(h.indexSnapshot(profileID: "p"))
    }
}
