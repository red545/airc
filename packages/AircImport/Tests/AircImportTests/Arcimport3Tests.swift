// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
import Security
@testable import AircImport

/// arcimport3 (E11): Arc's databases in Chromium 156's own schemas (the cookie store's version 24 table, the password
/// store's version 43 logins table), the Keychain item the import asks for, and what of sites' own storage is named
/// rather than imported. Synthetic data only, never the Keychain.
extension ArcImportAcceptanceTests {
    /// Chromium 156's `cookies` table (net/extras/sqlite/sqlite_persistent_cookie_store.cc, version 24), every column
    /// NOT NULL: an unpartitioned cookie has an empty `top_frame_site_key`.
    static let cookies156 = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES('version','24'); INSERT INTO meta VALUES('last_compatible_version','24');
        CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,
          name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
          is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL, last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL,
          is_persistent INTEGER NOT NULL, priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,
          source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
          has_cross_site_ancestor INTEGER NOT NULL);
        CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key, top_frame_site_key, has_cross_site_ancestor, name, path,
          source_scheme, source_port);
        """

    func cookie156(_ host: String, _ name: String, _ value: String, partition: String = "", crossSite: Bool = false,
                   secure: Bool = true, expires: Int64) throws -> String {
        let blob = hex(try ArcSafeStorage.encryptForTests(ArcSafeStorage.digest(host) + Data(value.utf8), key: key))
        return "INSERT INTO cookies VALUES(\(chromeTime(daysAgo: 2)),'\(host)','\(partition)','\(name)','',X'\(blob)','/',\(expires),"
            + "\(secure ? 1 : 0),1,\(chromeTime(daysAgo: 1)),\(expires == 0 ? 0 : 1),\(expires == 0 ? 0 : 1),1,0,2,443,"
            + "\(chromeTime(daysAgo: 1)),0,\(crossSite ? 1 : 0));"
    }

    /// A partitioned (CHIPS) cookie keeps its top-level site and cross-site bit for the engine, which stores it in that
    /// partition; the same name unpartitioned is a separate cookie; a session cookie keeps expiry 0.
    func testChromium156CookiesKeepTheirPartition() async throws {
        let profile = root.appendingPathComponent("Default")
        let later = chromeTime(daysAgo: -30)
        try sqlite(profile.appendingPathComponent("Cookies"), Self.cookies156
            + (try cookie156("widget.example", "sid", "first-party", expires: later))
            + (try cookie156("widget.example", "sid", "inside-portal", partition: "https://portal.example", crossSite: true, expires: later))
            + (try cookie156(".widget.example", "session", "until-quit", expires: 0)))
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeLogins: false, kinds: .all, tempRoot: root)
        XCTAssertEqual(c.failedCookies, 0)
        XCTAssertEqual(c.cookies.map(\.value), ["first-party", "inside-portal", "until-quit"])
        XCTAssertEqual(c.cookies.map { $0.metadata["top_frame_site_key"] }, ["", "https://portal.example", ""])
        XCTAssertEqual(c.cookies.map { $0.metadata["has_cross_site_ancestor"] }, ["0", "1", "0"])
        XCTAssertEqual(c.cookies[2].expiresUTC, 0, "a session cookie stays one")
        XCTAssertEqual(c.cookies.map(\.sameSite), [0, 0, 0])
        XCTAssertNil(c.cookies[0].metadata["encrypted_value"], "never the encrypted blob")
        XCTAssertTrue(try noCopiesLeft())
    }

    /// Chromium 156's `logins` table (login_database.cc, version 43), with a password note: the logins come over by
    /// kind as with the short fixture; the note stays in Arc (the engine's import takes no notes).
    func testChromium156LoginDataSchema() async throws {
        let profile = root.appendingPathComponent("Default")
        let columns = """
            origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR, username_value VARCHAR,
            password_element VARCHAR, password_value BLOB, submit_element VARCHAR, signon_realm VARCHAR NOT NULL,
            date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL, password_type INTEGER,
            times_used INTEGER, form_data BLOB, display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR,
            skip_zero_click INTEGER, generation_upload_status INTEGER, possible_username_pairs BLOB,
            id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0, moving_blocked_for BLOB,
            date_password_modified INTEGER NOT NULL DEFAULT 0, sender_email VARCHAR, sender_name VARCHAR,
            date_received INTEGER, sharing_notification_displayed INTEGER NOT NULL DEFAULT 0, keychain_identifier BLOB,
            sender_profile_image_url VARCHAR, date_last_filled INTEGER NOT NULL DEFAULT 0, actor_login_approved INTEGER NOT NULL DEFAULT 0,
            UNIQUE (origin_url, username_element, username_value, password_element, signon_realm)
            """
        func row(_ origin: String, _ realm: String, _ user: String, _ pw: String, scheme: Int = 0, federation: String = "", never: Bool = false) throws -> String {
            "INSERT INTO logins(origin_url, action_url, username_element, username_value, password_element, password_value, signon_realm, date_created, blacklisted_by_user, scheme, federation_url) VALUES('\(origin)','\(origin)login','user','\(user)','pass',X'\(pw.isEmpty ? "" : try encrypted(pw))','\(realm)',13300000000000000,\(never ? 1 : 0),\(scheme),'\(federation)');"
        }
        try sqlite(profile.appendingPathComponent("Login Data"), """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES('version','43');
            CREATE TABLE logins (\(columns));
            CREATE TABLE password_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER NOT NULL REFERENCES logins ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, key VARCHAR NOT NULL, value BLOB, date_created INTEGER NOT NULL, confidential INTEGER, UNIQUE (parent_id, key));
            """
            + (try row("https://web.example/", "https://web.example/", "web", "pw-web"))
            + (try row("https://intranet.example/", "https://intranet.example/Staff", "staff", "pw-basic", scheme: 1))
            + (try row("https://fed.example/", "federation://fed.example/accounts.google.com", "fed", "", federation: "https://accounts.google.com"))
            + (try row("android://h@com.only.example/", "android://h@com.only.example/", "app", "pw-app"))
            + (try row("https://never.example/", "https://never.example/", "", "", never: true))
            + "INSERT INTO password_notes(parent_id, key, value, date_created) VALUES(1, '', X'\(try encrypted("a note"))', 0);")
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, kinds: .all, tempRoot: root)
        XCTAssertEqual(c.logins.map(\.username), ["web", "staff", "fed"])
        XCTAssertEqual(c.logins.map(\.actionURL), ["https://web.example/login", "", "https://fed.example/login"])
        XCTAssertEqual(c.logins[1].scheme, "basic")
        XCTAssertEqual(c.logins[2].federationOrigin, "https://accounts.google.com")
        let why = c.notes.map { "\($0.site) \($0.reason)" }
        XCTAssertEqual(why, ["android://h@com.only.example/ An Android app's login (com.only.example): no website is linked to the app, so it can't be imported",
                             "https://never.example/ Arc was set to never save passwords here"])
        XCTAssertEqual(c.failedLogins, 0)
    }

    /// The import asks Keychain for exactly Arc's item ("Arc Safe Storage", account "Arc") unless a check names its
    /// scratch item; a search list (a scratch keychain) goes into the query; every answer maps as before.
    func testKeychainQueryNamesTheItem() throws {
        var seen: [String: Any] = [:]
        let answer: (OSStatus, Data?) -> ArcSafeStorage.Lookup = { status, data in
            { query, result in
                seen = query as NSDictionary as? [String: Any] ?? [:]
                if let data { result?.pointee = data as CFData }
                return status
            }
        }
        XCTAssertEqual(try ArcSafeStorage.readPassword(lookup: answer(errSecSuccess, Data("pw".utf8))), Data("pw".utf8))
        XCTAssertEqual(seen[kSecAttrService as String] as? String, "Arc Safe Storage")
        XCTAssertEqual(seen[kSecAttrAccount as String] as? String, "Arc")
        XCTAssertNil(seen[kSecMatchSearchList as String])
        let list = [NSObject()]
        _ = try ArcSafeStorage.readPassword(item: .init(service: "Airc Test Arc Safe Storage", account: "Arc"), searchList: list,
                                            lookup: answer(errSecSuccess, Data("pw".utf8)))
        XCTAssertEqual(seen[kSecAttrService as String] as? String, "Airc Test Arc Safe Storage")
        XCTAssertEqual((seen[kSecMatchSearchList as String] as? [NSObject])?.count, 1)
        for (status, want) in [(errSecUserCanceled, ImportError.keychainDeclined), (errSecAuthFailed, .keychainDeclined),
                               (errSecInteractionNotAllowed, .keychainLocked), (errSecItemNotFound, .keychainNotFound),
                               (errSecNoSuchKeychain, .keychainNotFound), (errSecParam, .keychainUnavailable)] {
            XCTAssertThrowsError(try ArcSafeStorage.readPassword(lookup: answer(status, nil))) { XCTAssertEqual($0 as? ImportError, want) }
        }
        XCTAssertThrowsError(try ArcSafeStorage.readPassword(lookup: answer(errSecSuccess, Data()))) {
            XCTAssertEqual($0 as? ImportError, .keychainUnavailable, "an empty item")
        }
    }

    /// Sites' storage that never comes over is named once each: partitioned localStorage (a frame's, inside another
    /// site) and service workers with their caches. First-party storage still comes over.
    func testPartitionedStorageAndServiceWorkersAreNamed() async throws {
        let profile = root.appendingPathComponent("Default")
        try LevelDBFixture.write([
            (Data("VERSION".utf8), Data("1".utf8)),
            (ls("https://site.example", "k"), Data([1, 0x76])),
            (Data("_https://widget.example/^0https://portal.example".utf8) + Data([0, 1]) + Data("k".utf8), Data([1, 0x77])),
            (Data("_https://chat.example/^0https://portal.example".utf8) + Data([0, 1]) + Data("k".utf8), Data([1, 0x78])),
            (Data("_https://chat.example/^0https://other.example".utf8) + Data([0, 1]) + Data("k".utf8), Data([1, 0x79])),
        ], to: profile.appendingPathComponent("Local Storage/leveldb"))
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Service Worker/Database"), withIntermediateDirectories: true)
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeLogins: false, includeCookies: false,
                                                     includeSiteData: true, kinds: .all, tempRoot: root)
        XCTAssertEqual(c.siteData.map(\.origin), ["https://site.example"])
        XCTAssertEqual(c.notes.map { "\($0.site) · \($0.detail) · \($0.count)" },
                       ["2 sites inside other sites · local storage · 2", "Offline caches · service workers · 1"])
        XCTAssertEqual(c.notes.map(\.reason), [ArcSiteStorage.partitionedReason, ArcSiteStorage.workersReason])
        XCTAssertTrue(c.notes.allSatisfy(\.skipped))
    }
}
