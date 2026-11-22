// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import AircKit

/// agentrecall: the agent's history recall on the Command Bar's index, its merge with tabs, cleaned addresses, and the
/// task picture store's caps. Made-up sites only.
final class AgentRecallTests: XCTestCase {
    let home = "profile-home"
    let work = "profile-work"

    func store(_ now: Date = Date()) throws -> HistoryStore {
        let h = try HistoryStore(path: nil)
        h.now = { now }
        return h
    }

    func testWordsFoldAndDropGlue() {
        XCTAssertEqual(AgentRecall.words("The article about Kyōto RYOKAN"), ["article", "kyoto", "ryokan"])
        XCTAssertEqual(AgentRecall.words("the"), ["the"], "a query of only glue words keeps them")
        XCTAssertEqual(AgentRecall.words("flight, booking; flight"), ["flight", "booking"], "duplicates and punctuation go")
        XCTAssertEqual(AgentRecall.words(String(repeating: "word ", count: 20)).count, 1)
        XCTAssertEqual(AgentRecall.words((1...12).map { "w\($0)" }.joined(separator: " ")).count, AgentRecall.maxWords)
    }

    func testRecallMatchesWordsInAnyOrder() throws {
        let h = try store()
        h.recordVisit(profileID: home, url: "https://travel.example/kyoto/ryokan-guide", title: "Ryokan stays in Kyoto: a quiet guide")
        h.recordVisit(profileID: home, url: "https://news.example/osaka", title: "Osaka street food")
        h.recordVisit(profileID: home, url: "https://travel.example/kyoto/temples", title: "Kyoto temples in autumn")
        let hits = h.recallNow(AgentRecall.words("kyoto ryokan"), profileID: home)
        XCTAssertEqual(hits.first?.entry.url, "https://travel.example/kyoto/ryokan-guide", "both words first, in any order")
        XCTAssertTrue(hits.contains { $0.entry.url.hasSuffix("/temples") }, "half the words still count, ranked lower")
        XCTAssertFalse(hits.contains { $0.entry.url.contains("osaka") })
        XCTAssertTrue(h.recallNow(AgentRecall.words("ktoyo"), profileID: home).isEmpty, "no loose in-order matches for a word")
    }

    func testRecallNeverCrossesProfiles() throws {
        let h = try store()
        h.recordVisit(profileID: home, url: "https://garden.example/roses", title: "Climbing roses")
        h.recordVisit(profileID: work, url: "https://intranet.example/roses-project", title: "Project Roses budget")
        let mine = h.recallNow(["roses"], profileID: home)
        XCTAssertEqual(mine.map(\.entry.url), ["https://garden.example/roses"])
        XCTAssertTrue(mine.allSatisfy { $0.entry.profileID == home })
        XCTAssertEqual(h.recallNow(["budget"], profileID: home).count, 0)
    }

    func testRecallSinceFiltersByLastVisit() throws {
        let now = Date()
        let h = try store(now)
        h.importVisits([HistoryEntry(profileID: home, url: "https://old.example/lamp", title: "Lamp repair", lastVisit: now.addingTimeInterval(-40 * 86_400)),
                        HistoryEntry(profileID: home, url: "https://new.example/lamp", title: "Lamp shades", lastVisit: now.addingTimeInterval(-2 * 86_400))])
        XCTAssertEqual(h.recallNow(["lamp"], profileID: home, since: AgentRecall.since(days: 7, now: now)).map(\.entry.url), ["https://new.example/lamp"])
        XCTAssertEqual(h.recallNow(["lamp"], profileID: home).count, 2)
        XCTAssertNil(AgentRecall.since(days: nil))
        XCTAssertNil(AgentRecall.since(days: 0))
    }

    func testRecallDoesNotCancelCommandBarSearch() throws {
        let h = try store()
        h.recordVisit(profileID: home, url: "https://shop.example/teapot", title: "Cast iron teapot")
        let bar = expectation(description: "the Command Bar's search answers")
        let agent = expectation(description: "the recall answers")
        h.search("teapot", profileID: home) { hits in XCTAssertEqual(hits.count, 1); bar.fulfill() }
        h.recall(["teapot"], profileID: home) { hits in XCTAssertEqual(hits.count, 1); agent.fulfill() }
        wait(for: [bar, agent], timeout: 5)
    }

    func testRankMergesTabsAndHistory() throws {
        let now = Date()
        let h = try store(now)
        h.recordVisit(profileID: home, url: "https://air.example/booking/ABC123", title: "Flight booking ABC123 · Air Example")
        h.recordVisit(profileID: home, url: "https://blog.example/booking-tips", title: "Booking tips")
        let words = AgentRecall.words("flight booking")
        let tabs = [AgentRecall.Tab(title: "Flight booking ABC123 · Air Example", url: "https://air.example/booking/ABC123", place: .openTab, lastUsed: now),
                    AgentRecall.Tab(title: "Weather", url: "https://weather.example/", place: .pinnedTab),
                    AgentRecall.Tab(title: "Flight status", url: "airc://internal", place: .openTab)]
        let hits = AgentRecall.rank(words, history: h.recallNow(words, profileID: home), tabs: tabs, now: now)
        XCTAssertEqual(hits.first?.url, "https://air.example/booking/ABC123")
        XCTAssertEqual(hits.first?.place, .openTab, "the open tab wins the merge")
        XCTAssertEqual(hits.first?.visits, 1, "… keeping history's visit count")
        XCTAssertEqual(hits.filter { $0.url == "https://air.example/booking/ABC123" }.count, 1, "one row per page")
        XCTAssertFalse(hits.contains { $0.url.hasPrefix("airc:") }, "web pages only")
        XCTAssertFalse(hits.contains { $0.site == "weather.example" })
        XCTAssertEqual(AgentRecall.rank(words, history: [], tabs: tabs, limit: 0).count, 0)
        XCTAssertTrue(AgentRecall.rank([], history: [], tabs: tabs).isEmpty)
    }

    func testCleanDropsSecrets() {
        XCTAssertEqual(AgentRecall.clean("https://ada:pw@mail.example/inbox?tab=all&session_id=1#msg"), "https://mail.example/inbox?tab=all")
        XCTAssertEqual(AgentRecall.clean("https://a.example/cb?code=xyz&state=abc"), "https://a.example/cb")
        XCTAssertEqual(AgentRecall.clean("https://a.example/v?id=0123456789abcdef0123456789abcdef01"), "https://a.example/v")
        XCTAssertEqual(AgentRecall.clean("https://video.example/watch?v=dQ12&t=30"), "https://video.example/watch?v=dQ12&t=30")
        XCTAssertEqual(AgentRecall.clean("https://a.example/x?access_token=1&page=2"), "https://a.example/x?page=2")
    }

    func testCaption() {
        XCTAssertEqual(AgentRecall.caption(query: "kyoto ryokan", count: 4), "Searched your history: ‘kyoto ryokan’ · 4 results")
        XCTAssertEqual(AgentRecall.caption(query: "x", count: 1), "Searched your history: ‘x’ · 1 result")
        XCTAssertEqual(AgentRecall.caption(query: "ada@mail.example", count: 0), "Searched your history · no results", "no addresses in a caption")
        XCTAssertEqual(AgentActionKind.of(tool: "search_history"), .recall)
        XCTAssertFalse(AgentActionKind.recall.isActing)
    }

    func testEntryKeepsFoundAndKeyThroughCoding() throws {
        var r = AgentTaskRecord(title: "t", spaceID: "s", profileID: home, provider: "p")
        let found = (0..<12).map { AgentTaskRecord.Entry.Found(title: "Page \($0)", url: "https://p\($0).example/", place: .history) }
        r.entries = [.init(kind: .step, text: "Searched your history: ‘x’ · 12 results", key: UUID().uuidString, found: found)]
        let back = try JSONDecoder().decode(AgentTaskRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.entries?.first?.found?.count, AgentTaskRecord.foundLimit)
        XCTAssertEqual(back.entries?.first?.key, r.entries?.first?.key)
        // An older record (no key, no found) still reads.
        let old = #"{"kind":"step","text":"Opening a.example","host":"a.example"}"#
        let e = try JSONDecoder().decode(AgentTaskRecord.Entry.self, from: Data(old.utf8))
        XCTAssertNil(e.key)
        XCTAssertNil(e.found)
    }

    // MARK: Pictures

    func folder() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("airc-test-pictures-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }

    func jpeg(_ size: Int) -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 7, count: max(0, size - 4)) }

    func testPictureStoreSavesLoadsDeletes() throws {
        let s = AgentTaskPictureStore(folder: folder())
        let task = UUID().uuidString, step = UUID().uuidString
        XCTAssertTrue(s.save(jpeg(1000), task: task, key: step))
        XCTAssertTrue(s.save(jpeg(800), task: task, key: AgentTaskPictureStore.card))
        XCTAssertEqual(s.load(task: task, key: step)?.count, 1000)
        XCTAssertEqual(Set(s.keys(task: task)), [step, "card"])
        let perms = try FileManager.default.attributesOfItem(atPath: s.file(task: task, key: step)!.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        s.delete(task: task)
        XCTAssertTrue(s.keys(task: task).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent(task).path))
    }

    func testPictureStoreRefusesBadInput() {
        let s = AgentTaskPictureStore(folder: folder())
        let task = UUID().uuidString
        XCTAssertFalse(s.save(jpeg(1000), task: "../etc", key: "card"), "ids are UUIDs only")
        XCTAssertFalse(s.save(jpeg(1000), task: task, key: "../../x"))
        XCTAssertFalse(s.save(Data(repeating: 1, count: 100), task: task, key: "card"), "not a JPEG")
        XCTAssertFalse(s.save(jpeg(s.maxPictureBytes + 1), task: task, key: "card"), "too big")
        XCTAssertTrue(s.keys(task: task).isEmpty)
    }

    func testPictureStorePerTaskCapKeepsCardAndNewest() {
        var s = AgentTaskPictureStore(folder: folder())
        s.maxPerTask = 4
        let task = UUID().uuidString
        XCTAssertTrue(s.save(jpeg(100), task: task, key: "card"))
        var steps: [String] = []
        for _ in 0..<6 {
            let k = UUID().uuidString
            steps.append(k)
            XCTAssertTrue(s.save(jpeg(100), task: task, key: k))
            Thread.sleep(forTimeInterval: 0.02)   // distinct modification times
        }
        let kept = Set(s.keys(task: task))
        XCTAssertEqual(kept.count, 4)
        XCTAssertTrue(kept.contains("card"), "the card stays")
        XCTAssertEqual(kept.subtracting(["card"]), Set(steps.suffix(3)), "the newest steps stay")
    }

    func testPictureStoreTotalCapEvictsOldestTasks() {
        var s = AgentTaskPictureStore(folder: folder())
        s.maxTotalBytes = 2500
        let tasks = (0..<4).map { _ in UUID().uuidString }
        for t in tasks {
            XCTAssertTrue(s.save(jpeg(1000), task: t, key: "card"))
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertLessThanOrEqual(s.totalBytes(), 2500)
        XCTAssertFalse(s.keys(task: tasks[3]).isEmpty, "the task just written keeps its picture")
        XCTAssertTrue(s.keys(task: tasks[0]).isEmpty, "the oldest task's pictures go first")
        s.prune(keeping: [tasks[3]])
        XCTAssertEqual(s.totalBytes(), 1000)
        XCTAssertTrue(s.keys(task: tasks[2]).isEmpty, "prune removes tasks that no longer exist")
    }
}
