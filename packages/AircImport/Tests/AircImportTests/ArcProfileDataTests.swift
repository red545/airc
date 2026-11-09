// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
import CArcCrypto
import AircKit
@testable import AircImport

final class ArcProfileDataTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arcimport2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "StorableSidebar.sample", withExtension: "json", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("StorableSidebar.json"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func file(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent("User Data/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func history(_ profile: String, locked: Bool = false) throws -> OpaquePointer? {
        try file(profile + "/History", "")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("User Data/" + profile + "/History").path, &db), SQLITE_OK)
        func time(_ days: Double) -> Int64 { Int64((now.timeIntervalSince1970 - days * 86400 + 11_644_473_600) * 1_000_000) }
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls VALUES('https://example.com/\(profile.replacingOccurrences(of: " ", with: ""))','Synthetic history',3,1,\(time(2)),0);
        INSERT INTO urls VALUES('https://example.com/boundary','Boundary',1,0,\(time(90)),0);
        INSERT INTO urls VALUES('https://example.com/old','Old',1,0,\(time(91)),0);
        INSERT INTO urls VALUES('arc://settings','Internal',1,0,\(time(1)),0);
        INSERT INTO urls VALUES('chrome://newtab','Internal',1,0,\(time(1)),0);
        INSERT INTO urls VALUES('https://example.com/hidden','Hidden',1,0,\(time(1)),1);
        """, nil, nil, nil), SQLITE_OK)
        if locked {
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
            return db
        }
        sqlite3_close(db); return nil
    }
    func testHistoryPerProfileWindowInternalURLsAndLockedCopy() async throws {
        let db = try history("Default", locked: true)
        defer { sqlite3_close(db) }
        _ = try history("Profile 1")
        let before = try Data(contentsOf: root.appendingPathComponent("User Data/Default/History"))
        let p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.history?["default"]?.map(\.url), ["https://example.com/Default", "https://example.com/boundary"])
        XCTAssertEqual(p.history?["Profile 1"]?.first?.url, "https://example.com/Profile1")
        let again = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        let mapped = p.mappedHistory(profileIDs: ["arc-profile:Default": "airc-personal", "arc-profile:Profile 1": "airc-work"])
        XCTAssertEqual(mapped["airc-personal"]?.first?.url, "https://example.com/Default")
        XCTAssertEqual(mapped["airc-work"]?.first?.url, "https://example.com/Profile1")
        XCTAssertTrue(p.mappedHistory(profileIDs: [:]).isEmpty)
        let store = try HistoryStore(path: nil)
        let visits = mapped.flatMap { pid, rows in rows.map { HistoryEntry(profileID: pid, url: $0.url, title: $0.title, visitCount: $0.visitCount, typedCount: $0.typedCount, lastVisit: $0.lastVisit) } }
        XCTAssertEqual(store.importVisits(visits).added, 4)
        let duplicate = store.importVisits(visits)
        XCTAssertEqual(duplicate.added, 0)
        XCTAssertEqual(duplicate.updated, 0)
        XCTAssertEqual(store.entries(ofProfile: "airc-work").count, 2)
        XCTAssertEqual(again.history, p.history, "reimport retains stable URL keys and counts")
        XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent("User Data/Default/History")))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }
    func testExtensionsMergeDisabledComponentsInternalAndMalformed() async throws {
        let a = String(repeating: "a", count: 32), b = String(repeating: "b", count: 32)
        let c = String(repeating: "c", count: 32), d = String(repeating: "d", count: 32)
        try file("Default/Preferences", """
        {"extensions":{"settings":{
        "\(a)":{"manifest":{"name":"Reader"},"location":1,"state":1},
        "\(b)":{"manifest":{"name":"Disabled"},"location":1,"state":0},
        "\(c)":{"manifest":{"name":"Component"},"location":5,"state":1},
        "\(d)":{"manifest":{"name":"Arc Internal Helper"},"location":1,"state":1},
        "bad/id":{"manifest":{"name":"Invalid"},"state":1}
        }}}
        """)
        try file("Default/Secure Preferences", """
        {"extensions":{"settings":{"\(a)":{"manifest":{"name":"Reader"},"location":1,"state":0}}}}
        """)
        try file("Profile 1/Preferences", "{broken")
        let p = try await ArcImporter.plan(at: root, tempRoot: root)
        XCTAssertEqual(p.extensions?["default"]?.map(\.id), [b, a])
        XCTAssertEqual(p.extensions?["default"]?.map(\.enabled), [false, false])
        XCTAssertEqual(p.extensions?["default"]?.last?.storeURL.absoluteString, "https://chromewebstore.google.com/detail/" + a)
        XCTAssertTrue(p.warnings.contains { $0.code == .unreadableExtensions })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }
    func testLocalizedExtensionNamesReachImportPlan() async throws {
        let id = String(repeating: "a", count: 32)
        try file("Default/Preferences", """
        {"extensions":{"settings":{"\(id)":{"manifest":{"name":"__MSG_title__","version":"1"},"path":"\(id)/1_0","state":1}}}}
        """)
        try file("Default/Extensions/\(id)/1_0/manifest.json", #"{"name":"__MSG_title__","default_locale":"en"}"#)
        try file("Default/Extensions/\(id)/1_0/_locales/en/messages.json", #"{"title":{"message":"Localized Reader"}}"#)
        let p = try await ArcImporter.plan(at: root, tempRoot: root)
        XCTAssertEqual(p.extensions?["default"]?.first?.name, "Localized Reader")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }

    func testUncheckpointedHistoryIsExplainedWithoutCopyingWAL() async throws {
        _ = try history("Default")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("User Data/Default/History").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE urls SET visit_count=9;", nil, nil, nil), SQLITE_OK)
        let p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertTrue(p.warnings.contains { $0.code == .historyNeedsCheckpoint })
        XCTAssertEqual(p.history?["default"]?.first?.visitCount, 3, "only checkpointed history is read")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }

    func testImmutableCopyIsReadOnlyAndCleansUpOnBadDatabase() throws {
        try file("Default/History", "not sqlite")
        XCTAssertThrowsError(try DatabaseCopy(root.appendingPathComponent("User Data/Default/History"), tempRoot: root, immutableOnly: true))
        _ = try history("Default")
        do {
            let copy = try DatabaseCopy(root.appendingPathComponent("User Data/Default/History"), tempRoot: root, immutableOnly: true)
            XCTAssertEqual(sqlite3_db_readonly(copy.db, "main"), 1)
            XCTAssertEqual(sqlite3_exec(copy.db, "DELETE FROM urls", nil, nil, nil), SQLITE_READONLY)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix("AircImport-") })
    }
}
