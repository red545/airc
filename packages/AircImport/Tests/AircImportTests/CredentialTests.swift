// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
import CArcCrypto
@testable import AircImport

final class CredentialTests: XCTestCase, @unchecked Sendable {
    func encrypt(_ data: Data, key: Data) throws -> Data {
        Data("v10".utf8) + (try ArcSafeStorage.crypt(data, key: key, operation: CCOperation(kCCEncrypt)))
    }
    func testKnownKeyAndEncryption() throws {
        let key = try ArcSafeStorage.deriveKey(password: Data("peanuts".utf8))
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "d9a09d499b4e1b7461f28e67972c6dbd")
        XCTAssertEqual(try ArcSafeStorage.decrypt(encrypt(Data("synthetic 🔑".utf8), key: key), key: key), Data("synthetic 🔑".utf8))
        XCTAssertThrowsError(try ArcSafeStorage.decrypt(Data("v11bad".utf8), key: key))
        XCTAssertThrowsError(try ArcSafeStorage.decrypt(Data("v10bad".utf8), key: key))
    }
    func testSyntheticSQLiteAndWAL() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        var loginDB: OpaquePointer?, cookieDB: OpaquePointer?
        defer { sqlite3_close(loginDB); sqlite3_close(cookieDB) }
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("Login Data").path, &loginDB), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("Cookies").path, &cookieDB), SQLITE_OK)
        func execute(_ db: OpaquePointer?, _ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
        let password = try hex(encrypt(Data("test-password".utf8), key: key))
        execute(loginDB, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE logins(origin_url TEXT, action_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER); INSERT INTO logins VALUES('https://example.test','https://example.test/login','https://example.test','test',X'\(password)',0); INSERT INTO logins VALUES('','','','',X'',1)")
        let cookie = try hex(encrypt(ArcSafeStorage.hash(".example.test") + Data("cookie-value".utf8), key: key))
        execute(cookieDB, "CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT); INSERT INTO cookies VALUES('.example.test','session','/','',X'\(cookie)',123,1,1,2,''); INSERT INTO cookies VALUES('example.test','plain','/','plain-value',X'',0,0,0,-1,'')")
        let result = try await ArcCredentialImporter.read(profileDirectory: folder, key: key)
        XCTAssertEqual(result.logins.count, 1)
        XCTAssertEqual(result.logins.first?.password, "test-password")
        XCTAssertEqual(result.cookies.map(\.value), ["cookie-value", "plain-value"])
        XCTAssertEqual(result.cookies.first?.sameSite, 2)
        XCTAssertEqual(result.cookies.first?.expiresUTC, 123)
        // Schema <24 has no domain digest prefix.
        let legacy = try hex(encrypt(Data("legacy-value".utf8), key: key))
        execute(cookieDB, "UPDATE meta SET value='23'; DELETE FROM cookies; INSERT INTO cookies VALUES('example.test','old','/','',X'\(legacy)',0,0,0,0,'')")
        let old = try await ArcCredentialImporter.read(profileDirectory: folder, key: key)
        XCTAssertEqual(old.cookies.first?.value, "legacy-value")
        execute(cookieDB, "UPDATE meta SET value='24'")
        // A schema-24 cookie must carry a matching domain digest; one that doesn't fails alone.
        let bad = try await ArcCredentialImporter.read(profileDirectory: folder, key: key)
        XCTAssertEqual(bad.cookies.count, 0)
        XCTAssertEqual(bad.failedCookies, 1)
        XCTAssertEqual(bad.problems, ["cookie: domain digest doesn't match": 1])
        XCTAssertEqual(bad.logins.count, 1, "the logins still come over")
    }

    /// Code review H2: Arc running (Login Data held with SQLite's exclusive lock, WAL not checkpointed), bad rows and a
    /// missing Cookies file. Synthetic values only.
    func testArcRunningLockedDatabaseAndBadRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-cred-\(UUID().uuidString)")
        let profile = root.appendingPathComponent("Profile 1"), temp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        let good = try hex(encrypt(Data("pass-1".utf8), key: key))
        let notUTF8 = try hex(encrypt(Data([0xFF, 0xFE, 0x00]), key: key))
        var arc: OpaquePointer?
        defer { sqlite3_close(arc) }
        XCTAssertEqual(sqlite3_open(profile.appendingPathComponent("Login Data").path, &arc), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(arc, """
            PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA locking_mode=EXCLUSIVE;
            CREATE TABLE logins(origin_url TEXT, action_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);
            INSERT INTO logins VALUES('https://a.test','https://a.test/login','https://a.test/','one',X'\(good)',0);
            INSERT INTO logins VALUES('https://never.test','','https://never.test/','',X'',1);
            INSERT INTO logins VALUES('https://b.test','','https://b.test/','two',X'763130DEADBEEF',0);
            INSERT INTO logins VALUES('https://c.test','','https://c.test/','three',X'7631310000000000000000000000000000000000',0);
            INSERT INTO logins VALUES('https://d.test','','https://d.test/','four',X'\(notUTF8)',0);
            """, nil, nil, nil), SQLITE_OK)
        // What Arc does to a direct reader: the database is locked.
        var reader: OpaquePointer?
        sqlite3_open_v2(profile.appendingPathComponent("Login Data").path, &reader, SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(sqlite3_exec(reader, "SELECT count(*) FROM logins", nil, nil, nil), SQLITE_BUSY)
        sqlite3_close(reader)

        let result = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, tempRoot: temp)
        XCTAssertEqual(result.logins.map(\.username), ["one"])
        XCTAssertEqual(result.logins.first?.password, "pass-1")
        XCTAssertEqual(result.skippedLogins, 1)
        XCTAssertEqual(result.failedLogins, 3)
        XCTAssertEqual(result.problems, ["login: couldn't decrypt": 1, "login: v11 encryption (not supported)": 1,
                                         "login: not UTF-8": 1])
        // One note per row that didn't come over, with its site and why; never a password.
        XCTAssertEqual(result.notes.map { "\($0.site) \($0.username) \($0.skipped) \($0.reason)" }, [
            "https://never.test  true Arc was set to never save passwords here",
            "https://b.test two false couldn't decrypt",
            "https://c.test three false v11 encryption (not supported)",
            "https://d.test four false not UTF-8",
        ])
        XCTAssertTrue(result.cookies.isEmpty)
        XCTAssertTrue(result.failedDatabases.isEmpty, "a missing Cookies file isn't a failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [], "the private copy is deleted")
    }

    func testPrivateCopyIsOwnerOnlyAndRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var db: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("Cookies").path, &db)
        sqlite3_exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1)", nil, nil, nil)
        sqlite3_close(db)
        var copy: DatabaseCopy? = try DatabaseCopy(root.appendingPathComponent("Cookies"), tempRoot: root)
        let folder = copy!.folder
        let perms = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700)
        XCTAssertEqual(try copy!.rows("SELECT x FROM t").count, 1)
        copy = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        // A copy a crash left behind is removed; nothing else is.
        let stale = root.appendingPathComponent("AircImport-left-behind")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        ArcCredentialImporter.removeStaleCopies(tempRoot: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Cookies").path))
    }
}
