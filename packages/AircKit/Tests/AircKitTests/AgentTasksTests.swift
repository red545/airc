// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import AircKit

final class AgentTasksTests: XCTestCase {
    func testTitleShortensAtAWord() {
        XCTAssertEqual(AgentTaskTitle.make("Reorder last week's groceries"), "Reorder last week's groceries")
        let long = "Find a dentist near the office with a free slot next week, ideally in the morning before nine"
        let t = AgentTaskTitle.make(long)
        XCTAssertTrue(t.hasSuffix("…"))
        XCTAssertLessThanOrEqual(t.count, AgentTaskTitle.limit + 1)
        XCTAssertEqual(t, "Find a dentist near the office with a free slot…")
        XCTAssertEqual(AgentTaskTitle.make("  \n "), "New task")
        // The attached page (a second paragraph) never becomes the title.
        XCTAssertEqual(AgentTaskTitle.make("Summarize this page\n\nThe page I'm looking at: “X” — https://example.com"), "Summarize this page")
        // One long word is cut, not dropped.
        XCTAssertEqual(AgentTaskTitle.make(String(repeating: "a", count: 60)).count, 49)
    }

    func testOrderingByState() {
        let now = Date()
        func rec(_ title: String, _ s: AgentTaskRecord.Status, _ ago: TimeInterval) -> AgentTaskRecord {
            var r = AgentTaskRecord(title: title, spaceID: "s", profileID: "p", provider: "x", status: s)
            r.updatedAt = now.addingTimeInterval(-ago)
            return r
        }
        let ordered = AgentTaskRecord.ordered([rec("old done", .done, 100), rec("running", .running, 50), rec("new done", .done, 1),
                                               rec("waiting", .waiting, 500), rec("stopped", .stopped, 10)])
        XCTAssertEqual(ordered.map(\.title), ["waiting", "running", "new done", "stopped", "old done"])
    }

    /// agentparallel: a queued task comes after the running ones, before finished ones, and says Queued.
    func testQueuedOrderAndLabel() throws {
        let now = Date()
        func rec(_ title: String, _ s: AgentTaskRecord.Status, _ ago: TimeInterval) -> AgentTaskRecord {
            var r = AgentTaskRecord(title: title, spaceID: "s", profileID: "p", provider: "x", status: s)
            r.updatedAt = now.addingTimeInterval(-ago)
            return r
        }
        let ordered = AgentTaskRecord.ordered([rec("done", .done, 1), rec("queued", .queued, 1), rec("running", .running, 100)])
        XCTAssertEqual(ordered.map(\.title), ["running", "queued", "done"])
        XCTAssertEqual(AgentTaskRecord.Status.queued.label, "Queued")
        XCTAssertEqual(AgentTaskRecord.Status.queued.chip, "Running")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("airc-tasks-queued-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentTaskStore(folder: dir)
        let r = rec("queued", .queued, 0)
        try store.save(r)
        XCTAssertEqual(store.load(r.id)?.status, .queued)
    }

    func testStoreRoundTripAndPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenttasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AgentTaskStore(folder: dir)
        var r = AgentTaskRecord(title: "Reorder groceries", spaceID: "s1", profileID: "p1", provider: "Anthropic API key")
        r.answer = AgentTaskRecord.answerLine("**Done.** I added 3 items.\nMore text")
        r.sites = ["shop.example.com"]
        r.steps = 7
        try store.save(r)
        XCTAssertEqual(store.load(r.id), r)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(r.answer, "Done. I added 3 items.")
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(r.id + ".json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        store.delete(r.id)
        XCTAssertNil(store.load(r.id))
    }

    func testStoreRefusesPathsThatArentIds() {
        let store = AgentTaskStore(folder: FileManager.default.temporaryDirectory)
        var r = AgentTaskRecord(title: "x", spaceID: "s", profileID: "p", provider: "x")
        r.id = "../../etc/x"
        XCTAssertThrowsError(try store.save(r))
        XCTAssertNil(store.load("../secrets"))
    }

    func testRecordKeepsNoSecretFields() throws {
        // The record's keys are fixed: nothing for page text, typed values, keys or screenshots.
        let r = AgentTaskRecord(title: "t", spaceID: "s", profileID: "p", provider: "x")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any] ?? [:]
        XCTAssertEqual(Set(json.keys).subtracting(["answer", "answerHead", "entries", "endedAt"]),
                       ["id", "title", "createdAt", "updatedAt", "spaceID", "profileID", "provider", "status", "unread", "steps", "sites"])
    }

    func testTimelineEntriesAreCappedAndOldRecordsStillLoad() throws {
        var r = AgentTaskRecord(title: "t", spaceID: "s", profileID: "p", provider: "x")
        var e = [AgentTaskRecord.Entry(kind: .prompt, text: "Find a park")]
        e += (0..<300).map { AgentTaskRecord.Entry(kind: .step, text: "Opening site\($0).example.com", host: "site\($0).example.com") }
        r.entries = AgentTaskRecord.capped(e)
        XCTAssertEqual(r.entries?.count, AgentTaskRecord.entryLimit)
        XCTAssertEqual(r.entries?.first?.kind, .prompt)
        XCTAssertEqual(r.entries?.last?.text, "Opening site299.example.com")
        XCTAssertEqual(r.lastSteps(3).map(\.host), ["site297.example.com", "site298.example.com", "site299.example.com"])
        // A long caption is cut; an answer keeps more.
        XCTAssertEqual(AgentTaskRecord.Entry(kind: .step, text: String(repeating: "a", count: 500)).text.count, AgentTaskRecord.captionLimit)
        XCTAssertEqual(AgentTaskRecord.Entry(kind: .answer, text: String(repeating: "a", count: 500)).text.count, 500)
        // A record written before entries existed decodes with none.
        let old = #"{"id":"\#(UUID().uuidString)","title":"t","createdAt":0,"updatedAt":0,"spaceID":"s","profileID":"p","provider":"x","status":"done","unread":false,"steps":2,"sites":[]}"#
        let decoded = try JSONDecoder().decode(AgentTaskRecord.self, from: Data(old.utf8))
        XCTAssertNil(decoded.entries)
        XCTAssertEqual(decoded.lastSteps(3), [])
    }

    func testAnswerHead() {
        XCTAssertEqual(AgentTaskRecord.answerHead("**Golden Gate Park** is the largest.\n\n- 1,017 acres\n- Opened 1870"),
                       "Golden Gate Park is the largest. 1,017 acres Opened 1870")
        XCTAssertEqual(AgentTaskRecord.answerHead(String(repeating: "word ", count: 100)).count, 280)
    }

    func testSearch() {
        var r = AgentTaskRecord(title: "Reorder groceries", spaceID: "s", profileID: "p", provider: "Claude Code")
        r.sites = ["shop.example.com"]
        XCTAssertTrue(r.matches("shop"))
        XCTAssertTrue(r.matches("claude"))
        XCTAssertTrue(r.matches(""))
        XCTAssertFalse(r.matches("dentist"))
    }
}

final class AgentTasksURLTests: XCTestCase {
    func testIsPage() {
        XCTAssertTrue(AgentTasksURL.isPage("airc://agents"))
        XCTAssertTrue(AgentTasksURL.isPage("airc://agents?q=x"))
        XCTAssertFalse(AgentTasksURL.isPage("airc://agentsfoo"))
        XCTAssertFalse(AgentTasksURL.isPage(nil))
        let id = UUID().uuidString
        XCTAssertTrue(AgentTasksURL.isPage(AgentTasksURL.task(id)))
        XCTAssertEqual(AgentTasksURL.taskID(AgentTasksURL.task(id)), id)
        XCTAssertEqual(AgentTasksURL.taskID(AgentTasksURL.task(id) + "?x=1"), id)
        XCTAssertNil(AgentTasksURL.taskID("airc://agents"))
        XCTAssertNil(AgentTasksURL.taskID("airc://agents/../../x"))
    }
}
