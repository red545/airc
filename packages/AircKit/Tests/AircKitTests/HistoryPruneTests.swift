// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

final class HistoryPruneTests: XCTestCase {
    func testBatchRemovalKeepsRetainedLocalMatchesWhileRebuildQueueIsBlocked() {
        let queue = DispatchQueue(label: "history-prune-test")
        let index = HistoryIndexer(queue: queue)
        let now = Date()
        let entries = (0..<3).map {
            HistoryEntry(profileID: "p", url: "https://history.example/\($0)", title: "Orchid page \($0)", lastVisit: now)
        }
        index.load(["p": Dictionary(uniqueKeysWithValues: entries.map { ($0.url, $0) })])
        _ = index.snapshotNow("p", now: now)
        let blocked = expectation(description: "index queue held before rebuilding")
        let release = DispatchSemaphore(value: 0)
        queue.async {
            blocked.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        defer { release.signal() }
        wait(for: [blocked], timeout: 2)

        index.remove(profileID: "p", urls: [entries[0].url])
        index.remove(profileID: "p", urls: [entries[1].url])
        let local = index.localSnapshot("p")
        XCTAssertEqual(local?.count, 1)
        XCTAssertEqual(local?.search("orchid").map(\.entry.url), [entries[2].url])
        // Full completions stay invalid until rebuilt; removed URLs cannot leak through them.
        XCTAssertNil(index.publishedSnapshot("p"))
        index.clear(profileID: "p")
        XCTAssertNil(index.localSnapshot("p"), "explicit history clearing must still remove every cached row immediately")
    }

    func testCrossingCapPublishesOneConsistentPrunedIndexAndPersistsIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        let h = try HistoryStore(path: path)
        let now = Date()
        h.now = { now }
        h.importVisits((0..<HistoryStore.maxEntriesPerProfile).map {
            HistoryEntry(profileID: "p", url: "https://history.example/\($0)", title: "History page \($0)",
                         lastVisit: now.addingTimeInterval(-4 * 86400))
        })
        h.recordVisit(profileID: "other", url: "https://other.example/", title: "Other history")
        XCTAssertEqual(h.indexSnapshotNow(profileID: "p").count, HistoryStore.maxEntriesPerProfile)
        _ = h.indexSnapshotNow(profileID: "other")
        let start = Date()
        let added = "https://history.example/new"
        h.recordVisit(profileID: "p", url: added, title: "New history", typed: true)
        let kept = Set(h.entries(ofProfile: "p").map(\.url))
        XCTAssertEqual(kept.count, HistoryStore.maxEntriesPerProfile * 9 / 10)
        XCTAssertTrue(kept.contains(added))
        let done = expectation(description: "search after pruning a prepared full index")
        h.search("history", profileID: "p") { hits in
            XCTAssertFalse(hits.isEmpty)
            XCTAssertTrue(hits.allSatisfy { kept.contains($0.entry.url) })
            done.fulfill()
        }
        // A generous liveness bound, not a frame/performance assertion. The old per-URL
        // rebuild queues thousands of full snapshots and starves this search for minutes.
        wait(for: [done], timeout: 15)
        print("[history-prune] search after cap: \(Date().timeIntervalSince(start) * 1000) ms")
        XCTAssertEqual(h.indexSnapshot(profileID: "p")?.count, kept.count)
        let local = h.localMatches("history", profileID: "p")
        XCTAssertFalse(local.isEmpty)
        XCTAssertTrue(local.allSatisfy { kept.contains($0.entry.url) })
        XCTAssertEqual(h.localMatches("other", profileID: "other").count, 1)
        XCTAssertEqual(Set(try HistoryStore(path: path).entries(ofProfile: "p").map(\.url)), kept)
    }
}
