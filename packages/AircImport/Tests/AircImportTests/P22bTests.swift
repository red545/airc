// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import AircImport

/// P22b: what the engine takes beyond website passwords (HTTP authentication, federated sign-ins), Android logins for
/// the websites Arc linked to their app, and sites' localStorage read from Chromium's own LevelDB. Synthetic data only:
/// the Local Storage fixture was written by a real Chrome 156 (headless, on synthetic loopback pages; a Snappy table
/// from its first session and a log from its second, which removes and replaces some keys).
extension ArcImportAcceptanceTests {
    var chromeLocalStorage: URL { Bundle.module.url(forResource: "ChromeLocalStorage", withExtension: nil, subdirectory: "Fixtures")! }
    func ls(_ origin: String, _ key: String) -> Data { Data("_\(origin)".utf8) + Data([0, 1]) + Data(key.utf8) }

    // MARK: LevelDB

    func testLevelDBReadsChromesLocalStorage() throws {
        let db = try LevelDB.read(chromeLocalStorage)
        let site = "http://127.0.0.1:46349"
        XCTAssertEqual(db[ls(site, "token")], Data([1]) + Data("synthetic-token-1".utf8))
        XCTAssertEqual(db[ls(site, "late")], Data([1]) + Data("in the log".utf8), "the log's newer write")
        XCTAssertEqual(db[ls(site, "replaced")], Data([1]) + Data("second".utf8), "the newest of two writes")
        XCTAssertNil(db[ls(site, "gone")], "a deletion in the log hides the table's value")
        XCTAssertNil(db[ls(site, "fill1")])
        XCTAssertEqual(db[ls(site, "big")], Data([1]) + Data(String(repeating: "abcdefgh", count: 4096).utf8) + Data("tail".utf8),
                       "a value from the table's Snappy blocks")
        // UTF-16 (format byte 0) where the text isn't Latin-1.
        XCTAssertEqual(db[ls(site, "wide")], Data([0]) + "Grüße · 東京 · ✓".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(db[ls("http://localhost:46349", "other")], Data([1]) + Data("second-site".utf8))
        XCTAssertEqual(db.count, 11)
        let sites = ArcSiteStorage.sites(db)
        XCTAssertEqual(Set(sites.keys), [site, "http://localhost:46349"])
        XCTAssertEqual(sites[site]?.map { String(decoding: $0.key.dropFirst(), as: UTF8.self) }, ["big", "late", "replaced", "token", "wide"])
    }

    func testLevelDBTornLogTailAndDamage() throws {
        let copy = root.appendingPathComponent("torn")
        try FileManager.default.copyItem(at: chromeLocalStorage, to: copy)
        // Arc stopped mid-write: the log's last record (the second session's one batch) is cut short, so that write
        // never happened, as LevelDB itself would read it. Everything before it still reads.
        let log = copy.appendingPathComponent("000004.log")
        let data = try Data(contentsOf: log)
        try data.prefix(data.count - 5).write(to: log)
        let db = try LevelDB.read(copy)
        let site = "http://127.0.0.1:46349"
        XCTAssertEqual(db.count, 14)
        XCTAssertEqual(db[ls(site, "replaced")], Data([1]) + Data("first".utf8))
        XCTAssertNil(db[ls(site, "late")])
        XCTAssertNotNil(db[ls(site, "gone")])
        XCTAssertEqual(db[ls(site, "token")], Data([1]) + Data("synthetic-token-1".utf8), "the table's values stay")
        XCTAssertEqual(db[ls("http://localhost:46349", "other")], Data([1]) + Data("second-site".utf8), "the log's first batch stays")
        // A damaged table fails the read rather than giving part of it.
        let table = copy.appendingPathComponent("000005.ldb")
        var t = try Data(contentsOf: table)
        t[100] ^= 0xff
        try t.write(to: table)
        XCTAssertThrowsError(try LevelDB.read(copy))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("CURRENT"))
        XCTAssertThrowsError(try LevelDB.read(copy))
    }

    func testDamagedLengthAndMissingLiveTableAreErrors() throws {
        var cursor = LevelDB.Cursor(Data(repeating: 0xff, count: 10))
        XCTAssertThrowsError(try cursor.varint())
        var length = LevelDB.Cursor(Data([0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]))
        XCTAssertThrowsError(try length.length())
        var bytes = LevelDB.Cursor(Data([0]))
        _ = try bytes.byte()
        XCTAssertThrowsError(try bytes.bytes(Int.max))
        XCTAssertThrowsError(try LevelDB.snappy([1, 0x08, 0x61, 0x62, 0x63]))
        let copy = root.appendingPathComponent("missing-table")
        try FileManager.default.copyItem(at: chromeLocalStorage, to: copy)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("000005.ldb"))
        XCTAssertThrowsError(try LevelDB.read(copy))
    }

    func testSnappyLiteralsAndOverlappingCopies() throws {
        // "abcabcabcabc" as a literal "abc" and a 9-byte copy at offset 3 (copy-1: 4 + 5 extra in the tag).
        XCTAssertEqual(try LevelDB.snappy([12, 0x08, 0x61, 0x62, 0x63, 0x15, 0x03]), Array("abcabcabcabc".utf8))
        // A copy before any output, and a length that doesn't match, are damage.
        XCTAssertThrowsError(try LevelDB.snappy([4, 0x01, 0x01]))
        XCTAssertThrowsError(try LevelDB.snappy([5, 0x08, 0x61, 0x62, 0x63]))
    }

    // MARK: Logins the engine takes

    func loginRows() throws -> [String] {
        [
            "'https://web.example/','','https://web.example/','web',X'\(try encrypted("pw-web"))',0,0,''",
            "'https://basic.example/','','https://basic.example/Members','basic',X'\(try encrypted("pw-basic"))',0,1,''",
            "'https://digest.example:8443/','','https://digest.example:8443/Staff','digest',X'\(try encrypted("pw-digest"))',0,2,''",
            "'http://proxy.example:3128/','','proxy.example:3128/Proxy','proxy',X'00',0,1,''",
            "'https://fed.example/','','federation://fed.example/accounts.google.com','fed',X'',0,0,'https://accounts.google.com'",
            "'android://hash@com.linked.example/','','android://hash@com.linked.example/','linked',X'\(try encrypted("pw-app"))',0,0,''",
            "'android://other@com.alone.example/','','android://other@com.alone.example/','alone',X'00',0,0,''",
        ]
    }
    func affiliationDatabase(_ profile: URL) throws {
        _ = try sqlite(profile.appendingPathComponent("Affiliation Database"), """
            CREATE TABLE eq_classes(id INTEGER PRIMARY KEY, last_update_time INTEGER);
            CREATE TABLE eq_class_members(id INTEGER PRIMARY KEY, facet_uri LONGVARCHAR UNIQUE NOT NULL, facet_display_name VARCHAR,
              facet_icon_url VARCHAR, set_id INTEGER NOT NULL);
            INSERT INTO eq_classes VALUES(1, 0);
            INSERT INTO eq_class_members VALUES(1, 'android://hash@com.linked.example', 'Linked', '', 1);
            INSERT INTO eq_class_members VALUES(2, 'https://linked.example', 'Linked', '', 1);
            INSERT INTO eq_class_members VALUES(3, 'https://www.linked.example', 'Linked', '', 1);
            """)
    }

    /// An engine with the P22b kinds gets HTTP authentication with its scheme and realm, federated sign-ins with their
    /// provider and no password; Android logins come over for the websites Arc linked to their app, after the website
    /// logins; a proxy's sign-in and an app with no linked website are skipped with what they are, never decrypted.
    func testLoginsAnEngineWithP22bTakes() async throws {
        let profile = root.appendingPathComponent("Default")
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable(try loginRows()))
        try affiliationDatabase(profile)
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, kinds: .all, tempRoot: root)
        XCTAssertEqual(c.logins.map(\.username), ["web", "basic", "digest", "fed", "linked", "linked"])
        XCTAssertEqual(c.logins.map(\.scheme), ["", "basic", "digest", "", "", ""])
        XCTAssertEqual(c.logins[1].signonRealm, "https://basic.example/Members")
        XCTAssertEqual(c.logins[2].password, "pw-digest")
        XCTAssertEqual(c.logins[3].federationOrigin, "https://accounts.google.com")
        XCTAssertEqual(c.logins[3].password, "")
        XCTAssertEqual(c.logins[3].signonRealm, "federation://fed.example/accounts.google.com")
        XCTAssertEqual(c.logins.suffix(2).map(\.origin), ["https://linked.example/", "https://www.linked.example/"])
        XCTAssertEqual(c.logins.suffix(2).map(\.signonRealm), ["https://linked.example/", "https://www.linked.example/"])
        XCTAssertEqual(c.logins.suffix(2).map(\.androidApp), ["com.linked.example", "com.linked.example"])
        XCTAssertEqual(c.logins.last?.password, "pw-app")
        XCTAssertEqual(c.failedLogins, 0, "the proxy's and the unlinked app's blobs were never decrypted")
        let why = Dictionary(uniqueKeysWithValues: c.notes.map { ($0.username, $0.reason) })
        XCTAssertEqual(why["proxy"], "A proxy server's sign-in (HTTP authentication): Airc takes websites' only")
        XCTAssertEqual(why["alone"], "An Android app's login (com.alone.example): no website is linked to the app, so it can't be imported")
        XCTAssertEqual(c.notes.count, 2)
    }

    /// The same Arc into an engine without the P22b kinds: HTTP authentication and federated sign-ins are skipped with
    /// why (the federated one names its provider for the "sign in again" list); the linked app's login still comes over.
    func testLoginsAnOlderEngineSkips() async throws {
        let profile = root.appendingPathComponent("Default")
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable(try loginRows()))
        try affiliationDatabase(profile)
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, tempRoot: root)
        XCTAssertEqual(c.logins.map(\.username), ["web", "linked", "linked"])
        let notes = Dictionary(uniqueKeysWithValues: c.notes.map { ($0.username, $0) })
        XCTAssertEqual(notes["basic"]?.reason, "A password for the browser's own sign-in box (HTTP authentication): Airc can't import these yet")
        XCTAssertEqual(notes["fed"]?.provider, "accounts.google.com")
        XCTAssertEqual(notes["fed"]?.reason.hasPrefix("Signs in through another account"), true)
        XCTAssertEqual(c.skippedLogins, 5)
    }

    // MARK: Sites' storage

    /// The most visited sites' localStorage (Arc's history ranks them), each IndexedDB site among them listed, the rest
    /// one line; a site that isn't HTTP(S) or first-party never comes over.
    func testSiteDataRanksSitesAndListsIndexedDB() async throws {
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: chromeLocalStorage, to: profile.appendingPathComponent("Local Storage/leveldb"))
        for name in ["http_127.0.0.1_46349.indexeddb.leveldb", "https_offline.example_0.indexeddb.leveldb",
                     "https_rare.example_0.indexeddb.leveldb", "chrome-extension_abc_0.indexeddb.leveldb"] {
            try FileManager.default.createDirectory(at: profile.appendingPathComponent("IndexedDB/" + name), withIntermediateDirectories: true)
        }
        _ = try sqlite(profile.appendingPathComponent("History"), """
            CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            INSERT INTO urls VALUES('http://localhost:46349/a','',9,0,0,0);
            INSERT INTO urls VALUES('http://localhost:46349/b','',3,0,0,0);
            INSERT INTO urls VALUES('https://offline.example/','',7,0,0,0);
            INSERT INTO urls VALUES('http://127.0.0.1:46349/','',5,0,0,0);
            """)
        var out = ImportedCredentials()
        try ArcCredentialImporter.readSiteData(profile, tempRoot: root, into: &out, limit: 3)
        XCTAssertEqual(out.siteData.map(\.origin), ["http://localhost:46349", "http://127.0.0.1:46349"], "most visited first")
        XCTAssertEqual(out.siteData.last?.items.count, 5)
        XCTAssertEqual(out.siteData.last?.items.first { $0.key == Data([1]) + Data("token".utf8) }?.value, Data([1]) + Data("synthetic-token-1".utf8))
        let notes = out.notes.map { "\($0.site) · \($0.detail) · \($0.count) · \($0.reason)" }
        XCTAssertEqual(notes, [
            "https://offline.example · offline data · 1 · Its offline data (IndexedDB) stays in Arc: Airc can't import it",
            "http://127.0.0.1:46349 · offline data · 1 · Its offline data (IndexedDB) stays in Arc: Airc can't import it",
            "1 other site ·  · 1 · Not among the 3 sites you visit most: their storage stays in Arc",
        ])
        XCTAssertTrue(out.failedDatabases.isEmpty)
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).contains { $0.hasPrefix("AircImport-") },
                       "the private copy is deleted")
    }

    func testSiteDataDamagedDatabaseFailsAlone() async throws {
        let profile = root.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Local Storage"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: chromeLocalStorage, to: profile.appendingPathComponent("Local Storage/leveldb"))
        let table = profile.appendingPathComponent("Local Storage/leveldb/000005.ldb")
        var t = try Data(contentsOf: table)
        t[200] ^= 0xff
        try t.write(to: table)
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeLogins: false, includeCookies: false,
                                                     includeSiteData: true, kinds: .all, tempRoot: root)
        XCTAssertEqual(c.failedDatabases, ["Local Storage"])
        XCTAssertEqual(c.databaseReasons["Local Storage"], "It's damaged, or isn't the kind of database Arc writes.")
        XCTAssertTrue(c.siteData.isEmpty)
    }

    func testStorageKeysAndIndexedDBFolders() {
        XCTAssertEqual(ArcSiteStorage.origin(storageKey: "https://Example.com"), "https://example.com")
        XCTAssertEqual(ArcSiteStorage.origin(storageKey: "https://example.com:443"), "https://example.com")
        XCTAssertEqual(ArcSiteStorage.origin(storageKey: "http://localhost:8080"), "http://localhost:8080")
        XCTAssertNil(ArcSiteStorage.origin(storageKey: "https://embed.example/^0https://top.example"), "partitioned keys stay")
        XCTAssertNil(ArcSiteStorage.origin(storageKey: "chrome-extension://abc"))
        XCTAssertNil(ArcSiteStorage.origin(storageKey: "file://"))
        XCTAssertEqual(ArcSiteStorage.origin(indexedDBFolder: "https_mail.example_0.indexeddb.leveldb"), "https://mail.example")
        XCTAssertEqual(ArcSiteStorage.origin(indexedDBFolder: "http_localhost_3000.indexeddb.leveldb"), "http://localhost:3000")
        XCTAssertNil(ArcSiteStorage.origin(indexedDBFolder: "https_mail.example_0.indexeddb.blob"))
        XCTAssertEqual(ImportKinds(names: ["localStorage", "federatedLogins", "somethingNew"]), [.localStorage, .federatedLogins])
    }
}

extension ArcImportAcceptanceTests {
    /// The synthetic fixture writer (the app's acceptance check uses it) reads back through the same reader, also
    /// when a value spans the log's 32 KiB blocks.
    func testLevelDBFixtureRoundTrip() throws {
        let dir = root.appendingPathComponent("fixture")
        let big = Data(repeating: 0x61, count: 70_000)
        try LevelDBFixture.write([(Data("VERSION".utf8), Data("1".utf8)), (ls("https://a.example", "k"), Data([1]) + big),
                                  (ls("https://a.example", "gone"), Data([1, 0x62])), (ls("https://a.example", "gone"), nil)], to: dir)
        let db = try LevelDB.read(dir)
        XCTAssertEqual(db.count, 2)
        XCTAssertEqual(db[ls("https://a.example", "k")], Data([1]) + big)
        XCTAssertNil(db[ls("https://a.example", "gone")])
    }
}
