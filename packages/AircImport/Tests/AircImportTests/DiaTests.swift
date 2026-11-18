// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
import CArcCrypto
import Security
@testable import AircImport

/// diaimport: Dia as a source, on a synthetic Dia only: a fake home folder with Dia's layout (`Dia/User Data`), its
/// bookmarks in `EncryptedBookmarks2` locked with a made-up Safe Storage secret, Chromium's own schemas for History,
/// Login Data and Cookies, and Preferences listing extensions. Never a real Dia profile or the real Keychain.
final class DiaTests: XCTestCase, @unchecked Sendable {
    var home: URL!
    /// Made up for this test; stands in for the value of "Dia Safe Storage".
    let secret = "synthetic-dia-secret"
    var support: URL { home.appendingPathComponent("Library/Application Support") }
    var userData: URL { support.appendingPathComponent("Dia/User Data") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("airc-dia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    func key() throws -> Data { try ArcSafeStorage.deriveKey(password: Data(secret.utf8)) }

    func write(_ data: Data, _ path: String) throws {
        let url = userData.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func json(_ object: Any, _ path: String) throws { try write(try JSONSerialization.data(withJSONObject: object), path) }

    func sqlite(_ path: String, _ sql: String) throws {
        let url = userData.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        sqlite3_close(db)
    }

    func bookmarks(_ title: String, _ url: String, guid: String) -> [String: Any] {
        ["version": 1, "checksum": "0", "roots": [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": [
                ["type": "url", "name": title, "url": url, "guid": guid, "id": "1"],
            ]],
            "other": ["type": "folder", "name": "Other bookmarks", "children": []],
            "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
        ]]
    }

    func setMTime(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: userData.appendingPathComponent(path).path)
    }

    /// Default ("Synthetic Home") with locked bookmarks, a stale plain `Bookmarks`, history and two extensions (one
    /// from the Web Store, one of Dia's own); Profile 1 ("Synthetic Work") with only a fresh plain `Bookmarks`.
    func writeDia() throws {
        try json(["profile": ["info_cache": ["Default": ["name": "Synthetic Home"], "Profile 1": ["name": "Synthetic Work"]],
                              "profiles_order": ["Default", "Profile 1"]]], "Local State")
        let plain = try JSONSerialization.data(withJSONObject: bookmarks("Old", "https://old.example/", guid: "g-old"))
        try write(plain, "Default/Bookmarks")
        let locked = try JSONSerialization.data(withJSONObject: bookmarks("Docs", "https://docs.example/", guid: "g-docs"))
        try write(try ArcSafeStorage.encryptForTests(locked, key: key()), "Default/EncryptedBookmarks2")
        try setMTime("Default/Bookmarks", Date(timeIntervalSinceNow: -86400 * 60))
        try sqlite("Default/History", """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES(1,'https://docs.example/a','A doc',3,1,\(Int64((Date().timeIntervalSince1970 - 3600 + 11_644_473_600) * 1_000_000)),0);
            """)
        let store = String(repeating: "a", count: 32), own = String(repeating: "b", count: 32)
        try json(["extensions": ["settings": [
            store: ["location": 1, "state": 1, "from_webstore": true, "manifest": ["name": "Synthetic Reader", "update_url": "https://clients2.google.com/service/update2/crx"]],
            own: ["location": 1, "state": 1, "path": "/Applications/Dia.app/Contents/Resources/x", "manifest": ["name": "Dia Helper"]],
        ]]], "Default/Preferences")
        try write(try JSONSerialization.data(withJSONObject: bookmarks("Work", "https://work.example/", guid: "g-work")), "Profile 1/Bookmarks")
    }

    func testDiaItemAndSource() throws {
        XCTAssertEqual(ArcSafeStorage.Item.dia, .init(service: "Dia Safe Storage", account: "Dia"))
        XCTAssertEqual(BrowserKind.dia.credentialSource, .dia)
        XCTAssertEqual(CredentialSource.dia.name, "Dia")
        XCTAssertNil(BrowserKind.chrome.credentialSource)
        XCTAssertNil(BrowserKind.helium.credentialSource)
        // The Keychain lookup asks for Dia's item (never Arc's), through the same handling: Deny is "declined".
        var asked: [String: Any] = [:]
        XCTAssertThrowsError(try ArcSafeStorage.readPassword(item: .dia) { query, _ in
            asked = query as? [String: Any] ?? [:]
            return errSecAuthFailed
        }) { XCTAssertEqual($0 as? ImportError, .keychainDeclined) }
        XCTAssertEqual(asked[kSecAttrService as String] as? String, "Dia Safe Storage")
        XCTAssertEqual(asked[kSecAttrAccount as String] as? String, "Dia")
    }

    func testDetectsDiaWithOnlyEncryptedBookmarks() throws {
        try json(["profile": ["info_cache": ["Default": ["name": "Synthetic Home"]]]], "Local State")
        try write(try ArcSafeStorage.encryptForTests(Data("{}".utf8), key: key()), "Default/EncryptedBookmarks2")
        let dia = BrowserImporter.detect(home: home).first { $0.kind == .dia }
        XCTAssertEqual(dia?.id, "dia")
        XCTAssertEqual(dia?.bundleIDs, ["company.thebrowser.dia"])
        XCTAssertEqual(dia?.folder.lastPathComponent, "User Data")
        XCTAssertEqual(dia?.profiles.map(\.name), ["Synthetic Home"])
        XCTAssertTrue(DiaBookmarks.isLocked(profile: userData.appendingPathComponent("Default")))
    }

    func testWithoutKeyBookmarksWaitHistoryAndExtensionsComeOver() async throws {
        try writeDia()
        let dia = try XCTUnwrap(BrowserImporter.detect(home: home).first { $0.kind == .dia })
        let r = try await BrowserImporter.read(dia, tempRoot: home)
        let homeSummary = try XCTUnwrap(r.profiles.first { $0.profileID == "Default" })
        XCTAssertTrue(homeSummary.lockedBookmarks)
        XCTAssertEqual(homeSummary.bookmarks, 0, "the stale plain Bookmarks isn't used when EncryptedBookmarks2 is newer")
        XCTAssertEqual(homeSummary.history, 1)
        XCTAssertEqual(r.lockedProfiles, ["dia-profile:Default"])
        XCTAssertEqual(r.plan.warnings.filter { $0.code == .lockedBookmarks }.count, 1)
        // Profile 1 has only a plain Bookmarks file: read as before.
        XCTAssertEqual(r.profiles.first { $0.profileID == "Profile 1" }?.bookmarks, 1)
        XCTAssertFalse(r.profiles.first { $0.profileID == "Profile 1" }?.lockedBookmarks ?? true)
        // The Web Store extension, not Dia's own.
        XCTAssertEqual(r.plan.extensions?["dia-profile:Default"]?.map(\.name), ["Synthetic Reader"])
        XCTAssertEqual(r.plan.extensions?["dia-profile:Default"]?.first?.reinstallsFromWebStore, true)
        XCTAssertEqual(homeSummary.extensions, 1)
    }

    func testKeyOpensEncryptedBookmarks() async throws {
        try writeDia()
        let dia = try XCTUnwrap(BrowserImporter.detect(home: home).first { $0.kind == .dia })
        let r = try await BrowserImporter.read(dia, includeHistory: false, bookmarksKey: try key(), tempRoot: home)
        let space = try XCTUnwrap(r.plan.spaces.first { $0.profileID == "dia-profile:Default" })
        guard case .tab(let t)? = space.pinned.first else { return XCTFail("the decrypted bookmark is the Space's first pinned tab") }
        XCTAssertEqual(t.url, "https://docs.example/")
        XCTAssertEqual(t.id, "dia-item:Default/g-docs")
        XCTAssertFalse(r.profiles.first { $0.profileID == "Default" }?.lockedBookmarks ?? true)
        XCTAssertTrue(r.plan.warnings.filter { $0.code == .lockedBookmarks }.isEmpty)
    }

    func testWrongKeyIsUnreadableNotLocked() async throws {
        try writeDia()
        let dia = try XCTUnwrap(BrowserImporter.detect(home: home).first { $0.kind == .dia })
        let wrong = try ArcSafeStorage.deriveKey(password: Data("another-made-up-secret".utf8))
        let r = try await BrowserImporter.read(dia, includeHistory: false, bookmarksKey: wrong, tempRoot: home)
        let s = try XCTUnwrap(r.profiles.first { $0.profileID == "Default" })
        XCTAssertEqual(s.unreadable, ["bookmarks"])
        XCTAssertEqual(s.bookmarks, 0)
    }

    func testNewerPlainBookmarksWin() async throws {
        try writeDia()
        try setMTime("Default/Bookmarks", Date())
        try setMTime("Default/EncryptedBookmarks2", Date(timeIntervalSinceNow: -86400))
        XCTAssertFalse(DiaBookmarks.isLocked(profile: userData.appendingPathComponent("Default")))
        let dia = try XCTUnwrap(BrowserImporter.detect(home: home).first { $0.kind == .dia })
        let r = try await BrowserImporter.read(dia, includeHistory: false, tempRoot: home)
        XCTAssertEqual(r.profiles.first { $0.profileID == "Default" }?.bookmarks, 1)
        XCTAssertTrue(r.lockedProfiles.isEmpty)
    }

    /// Dia's logins and cookies go through the Arc reader unchanged: same folder layout, same v10 encryption, the
    /// cookie value's SHA-256 host prefix (schema 24).
    func testCredentialsReadWithDiasKey() async throws {
        try writeDia()
        let k = try key()
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        try sqlite("Default/Login Data", """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR); INSERT INTO meta VALUES('version','43');
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
              password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL,
              blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, password_type INTEGER, times_used INTEGER, form_data BLOB,
              display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR, skip_zero_click INTEGER, generation_upload_status INTEGER,
              possible_username_pairs BLOB, id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0,
              moving_blocked_for BLOB, date_password_modified INTEGER NOT NULL DEFAULT 0,
              UNIQUE (origin_url, username_element, username_value, password_element, signon_realm));
            INSERT INTO logins(origin_url, action_url, username_element, username_value, password_element, password_value, signon_realm, date_created, blacklisted_by_user, scheme)
              VALUES('https://docs.example/','https://docs.example/','username','dia-user','password',X'\(hex(try ArcSafeStorage.encryptForTests(Data("dia-pw".utf8), key: k)))','https://docs.example/',13300000000000000,0,0);
            """)
        let later = Int64((Date().timeIntervalSince1970 + 86400 * 30 + 11_644_473_600) * 1_000_000)
        let blob = hex(try ArcSafeStorage.encryptForTests(ArcSafeStorage.digest("docs.example") + Data("dia-cookie".utf8), key: k))
        try sqlite("Default/Network/Cookies", """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version','24'); INSERT INTO meta VALUES('last_compatible_version','24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL,
              value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL,
              is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,
              priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
              last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL, has_cross_site_ancestor INTEGER NOT NULL);
            INSERT INTO cookies VALUES(13300000000000000,'docs.example','','sid','',X'\(blob)','/',\(later),1,1,13300000000000000,1,1,1,1,2,443,13300000000000000,0,0);
            """)
        let c = try await ArcCredentialImporter.read(profileDirectory: userData.appendingPathComponent("Default"), key: k,
                                                     includeSiteData: false)
        XCTAssertEqual(c.logins.map(\.username), ["dia-user"])
        XCTAssertEqual(c.logins.first?.password, "dia-pw")
        XCTAssertEqual(c.cookies.map(\.value), ["dia-cookie"])
        XCTAssertFalse(c.keyMismatch)
    }
}
