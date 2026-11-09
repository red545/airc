// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
import CArcCrypto
import AircKit
@testable import AircImport

/// P22 (E11): Arc import acceptance on synthetic Arc folders only — never the owner's Arc profile, never the Keychain.
/// Source permutations, WAL-only history and importing again, malformed, locked, busy and unreadable sources, the
/// Keychain's answers, a wrong key, logins of kinds Airc doesn't take, and where extensions came from.
final class ArcImportAcceptanceTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = try! ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("arcaccept-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        // Unreadable fixtures first get their permissions back, so the folder can go.
        if let e = FileManager.default.enumerator(atPath: root.path) {
            for case let p as String in e { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(p).path) }
        }
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Fixture helpers

    /// Two Spaces: "Home" in Default, "Work" in Profile 1.
    func sidebar(_ at: URL? = nil) throws {
        let spaces: [Any] = [
            ["id": "s-home", "title": "Home", "profile": ["default": [:]], "containerIDs": ["pinned", "P-1"]],
            ["id": "s-work", "title": "Work", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]], "containerIDs": ["pinned", "P-2"]],
        ]
        let items: [Any] = [
            ["id": "P-1", "childrenIds": ["T-1"], "data": ["itemContainer": [:]]],
            ["id": "T-1", "parentID": "P-1", "data": ["tab": ["savedURL": "https://home.example/", "savedTitle": "Home page"]]],
            ["id": "P-2", "childrenIds": ["T-2"], "data": ["itemContainer": [:]]],
            ["id": "T-2", "parentID": "P-2", "data": ["tab": ["savedURL": "https://work.example/", "savedTitle": "Work page"]]],
        ]
        try write("StorableSidebar.json", JSONSerialization.data(withJSONObject: ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": items]]]]), at: at)
    }
    func write(_ path: String, _ data: Data, at: URL? = nil) throws {
        let url = (at ?? root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func localState(_ names: [String: String]) throws {
        try write("User Data/Local State", JSONSerialization.data(withJSONObject: ["profile": ["info_cache": names.mapValues { ["name": $0] }]]))
    }
    func folder(_ profile: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("User Data/" + profile), withIntermediateDirectories: true)
    }
    func chromeTime(daysAgo: Double) -> Int64 { Int64((now.timeIntervalSince1970 - daysAgo * 86400 + 11_644_473_600) * 1_000_000) }
    @discardableResult
    func sqlite(_ url: URL, _ sql: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }
    func historySQL(_ name: String) -> String {
        """
        CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls VALUES('https://\(name).example/visited','Synthetic \(name)',4,1,\(chromeTime(daysAgo: 1)),0);
        """
    }
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    func encrypted(_ s: String, key: Data? = nil) throws -> String { hex(try ArcSafeStorage.encryptForTests(Data(s.utf8), key: key ?? self.key)) }
    func noCopiesLeft() throws -> Bool {
        !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("AircImport-") }
    }

    // MARK: Source permutations

    /// Arc's folder in every shape a real one comes in: complete, the sidebar alone, no profile list, a damaged one, a
    /// profile list naming a folder that isn't there, a folder no Space uses, and no or a damaged sidebar.
    func testSourcePermutations() async throws {
        try sidebar()
        // The sidebar alone: both Spaces come over; their profiles are placeholders, each said once.
        var p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.spaces.map(\.name), ["Home", "Work"])
        XCTAssertEqual(p.profiles.map(\.directory), ["Default", "Profile 1"])
        XCTAssertEqual(p.profiles.map(\.isAvailable), [false, false])
        XCTAssertEqual(p.warnings.filter { $0.code == .missingProfile }.count, 2)
        XCTAssertTrue((p.history ?? [:]).isEmpty && (p.extensions ?? [:]).isEmpty)

        // Folders but no profile list: profiles named after their folders; an unused one comes along unused.
        try folder("Default"); try folder("Profile 1"); try folder("Profile 2")
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.profiles.map(\.name), ["Default", "Profile 1", "Profile 2"])
        XCTAssertTrue(p.profiles.allSatisfy(\.isAvailable))
        XCTAssertFalse(p.warnings.contains { $0.code == .missingProfile || $0.code == .unreadableProfileList })

        // The profile list with names; one it names has no folder.
        try localState(["Default": "Synthetic Home", "Profile 1": "Synthetic Work", "Profile 9": "Gone"])
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.profiles.map(\.name), ["Synthetic Home", "Synthetic Work", "Profile 2", "Gone"])
        XCTAssertEqual(p.profiles.first { $0.directory == "Profile 9" }?.isAvailable, false)
        XCTAssertEqual(p.warnings.filter { $0.code == .missingProfile }.count, 1)

        // A damaged profile list doesn't stop the import (it used to): folders and the sidebar still give the profiles.
        try write("User Data/Local State", Data("{\"profile\": {".utf8))
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.spaces.count, 2)
        XCTAssertEqual(p.profiles.map(\.directory), ["Default", "Profile 1", "Profile 2"])
        XCTAssertEqual(p.warnings.filter { $0.code == .unreadableProfileList }.count, 1)
        XCTAssertThrowsError(try ArcImporter.discoverProfiles(at: root), "the public discovery still says it's damaged")
        // A profile list naming a folder outside Arc's: that name is dropped as damage.
        try write("User Data/Local State", JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["../Elsewhere": ["name": "x"], "Default": ["name": "Synthetic Home"]]]]))
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertFalse(p.profiles.contains { $0.directory.contains("..") })
        XCTAssertEqual(p.profiles.first?.name, "Synthetic Home")
        XCTAssertTrue(p.warnings.contains { $0.code == .unreadableProfileList })

        // No sidebar, or a damaged one: nothing to import, said as such.
        try FileManager.default.removeItem(at: root.appendingPathComponent("StorableSidebar.json"))
        do { _ = try await ArcImporter.plan(at: root, tempRoot: root); XCTFail("no sidebar") }
        catch { XCTAssertEqual(error as? ImportError, .noData) }
        try write("StorableSidebar.json", Data("[1, 2".utf8))
        do { _ = try await ArcImporter.plan(at: root, tempRoot: root); XCTFail("damaged sidebar") }
        catch { XCTAssertEqual(error as? ImportError, .invalidSidebar) }
        XCTAssertTrue(try noCopiesLeft())
    }

    /// A profile folder that is a link to somewhere outside Arc's folder: its Spaces come over, nothing is read through
    /// the link, and the import says so.
    func testLinkedProfileFolderIsNotFollowed() async throws {
        try sidebar()
        let outside = root.appendingPathComponent("outside/Profile 1")
        try sqlite(outside.appendingPathComponent("History"), historySQL("outside"))
        try folder("Default")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("User Data/Profile 1"), withDestinationURL: outside)
        let p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.spaces.count, 2)
        XCTAssertNil(p.history?["Profile 1"])
        XCTAssertEqual(p.warnings.filter { $0.code == .profileOutsideArc }.count, 1)
    }

    // MARK: WAL-only history and importing again

    /// Arc open: the History database lives only in its write-ahead log (an empty main file). The import says Arc must
    /// quit, never "damaged"; once Arc quits (the log is checkpointed), importing again brings the visits, once.
    func testWALOnlyHistoryThenReimportWithoutDuplicates() async throws {
        try sidebar(); try folder("Default")
        let history = root.appendingPathComponent("User Data/Profile 1/History")
        let arc = try sqlite(history, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + historySQL("work"), keepOpen: true)
        let wal = (try? root.appendingPathComponent("User Data/Profile 1/History-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        XCTAssertGreaterThan(wal, 32, "the fixture's rows are only in the log")

        var p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertTrue(p.warnings.contains { $0.code == .historyNeedsCheckpoint })
        XCTAssertFalse(p.warnings.contains { $0.code == .unreadableHistory }, "a log-only database isn't damaged")
        XCTAssertNil(p.history?["Profile 1"])
        let store = try HistoryStore(path: nil)
        func visits(_ plan: ImportPlan) -> [HistoryEntry] {
            plan.mappedHistory(profileIDs: ["arc-profile:Profile 1": "airc-work"]).flatMap { pid, rows in
                rows.map { HistoryEntry(profileID: pid, url: $0.url, title: $0.title, visitCount: $0.visitCount, typedCount: $0.typedCount, lastVisit: $0.lastVisit) }
            }
        }
        XCTAssertEqual(store.importVisits(visits(p)).added, 0)

        // Arc quits: SQLite checkpoints the log into the main file and removes it.
        sqlite3_close(arc)
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertFalse(p.warnings.contains { $0.code == .historyNeedsCheckpoint })
        XCTAssertEqual(p.history?["Profile 1"]?.map(\.url), ["https://work.example/visited"])
        XCTAssertEqual(store.importVisits(visits(p)).added, 1)
        // And again: nothing new, nothing doubled.
        let again = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(again.history, p.history)
        let merged = store.importVisits(visits(again))
        XCTAssertEqual(merged.added + merged.updated, 0)
        XCTAssertEqual(store.entries(ofProfile: "airc-work").map(\.visitCount), [4])
        XCTAssertTrue(try noCopiesLeft())
    }

    /// The log without its main file, a log of only its header, and a main file that isn't SQLite.
    func testHistoryLogWithoutMainFileAndDamagedHistory() async throws {
        try sidebar(); try folder("Default"); try folder("Profile 1")
        try write("User Data/Profile 1/History-wal", Data(repeating: 7, count: 4096))
        var p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertEqual(p.warnings.filter { $0.code == .historyNeedsCheckpoint }.count, 1)
        try write("User Data/Profile 1/History-wal", Data(repeating: 0, count: 32))
        try write("User Data/Profile 1/History", Data("not sqlite".utf8))
        p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        XCTAssertFalse(p.warnings.contains { $0.code == .historyNeedsCheckpoint }, "a header-only log holds nothing")
        XCTAssertEqual(p.warnings.filter { $0.code == .unreadableHistory }.count, 1)
        XCTAssertEqual(p.spaces.count, 2, "the Spaces still come over")
    }

    // MARK: Locked, busy, unreadable and damaged credential sources

    func loginsTable(_ rows: [String]) -> String {
        """
        CREATE TABLE logins(origin_url TEXT, action_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB,
          blacklisted_by_user INTEGER, scheme INTEGER, federation_url TEXT);
        \(rows.map { "INSERT INTO logins VALUES(\($0));" }.joined(separator: "\n"))
        """
    }
    func cookiesTable(_ rows: [String]) -> String {
        """
        CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24');
        CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER,
          is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT);
        \(rows.map { "INSERT INTO cookies VALUES(\($0));" }.joined(separator: "\n"))
        """
    }
    func cookieRow(_ host: String, _ value: String, partition: String = "") throws -> String {
        "'\(host)','c','/','',X'\(hex(try ArcSafeStorage.encryptForTests(ArcSafeStorage.digest(host) + Data(value.utf8), key: key)))',\(chromeTime(daysAgo: -30)),1,0,1,'\(partition)'"
    }

    /// Arc writing to a database during every copy attempt: that database fails with "Arc kept writing", the other one
    /// still comes over; when Arc stops, reading again brings it (the library side of "Try again").
    func testBusyDatabaseFailsAloneThenComesOverOnRetry() async throws {
        let profile = root.appendingPathComponent("Profile 1"), temp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable(["'https://a.example/','','https://a.example/','one',X'\(try encrypted("pw-1"))',0,0,''"]))
        try sqlite(profile.appendingPathComponent("Cookies"), cookiesTable([try cookieRow("a.example", "v")]))
        // A writer that keeps changing the log beside Login Data for two seconds (longer than every copy attempt).
        let journal = profile.appendingPathComponent("Login Data-journal")
        FileManager.default.createFile(atPath: journal.path, contents: Data())
        let stop = Date().addingTimeInterval(2.5)
        let writer = Thread {
            let h = try? FileHandle(forWritingTo: journal)
            while Date() < stop { h?.seekToEndOfFile(); h?.write(Data([1])) }
            try? h?.close()
        }
        writer.start()
        let busy = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, tempRoot: temp)
        XCTAssertEqual(busy.failedDatabases, ["Login Data"])
        XCTAssertEqual(busy.databaseReasons["Login Data"], "Arc kept writing to it while Airc copied it. Quit Arc and try again.")
        XCTAssertTrue(busy.logins.isEmpty)
        XCTAssertEqual(busy.cookies.count, 1, "the other database still comes over")
        while Date() < stop.addingTimeInterval(0.1) { try await Task.sleep(nanoseconds: 50_000_000) }
        try FileManager.default.removeItem(at: journal)
        let again = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, tempRoot: temp)
        XCTAssertEqual(again.logins.map(\.username), ["one"])
        XCTAssertTrue(again.cookies.isEmpty, "a retry reads only what it asks for")
        XCTAssertTrue(again.failedDatabases.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    /// A database macOS won't let Airc read, and one that isn't SQLite: each said precisely, neither stops the other.
    func testUnreadableAndDamagedDatabases() async throws {
        let profile = root.appendingPathComponent("Default"), temp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable(["'https://a.example/','','https://a.example/','one',X'\(try encrypted("pw-1"))',0,0,''"]))
        try write("Default/Cookies", Data("not a database".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profile.appendingPathComponent("Login Data").path)
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, tempRoot: temp)
        XCTAssertEqual(Set(c.failedDatabases), ["Login Data", "Cookies"])
        XCTAssertEqual(c.databaseReasons["Login Data"], "macOS didn't let Airc read it.")
        XCTAssertEqual(c.databaseReasons["Cookies"], "It's damaged, or isn't the kind of database Arc writes.")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: profile.appendingPathComponent("Login Data").path)
        let fixed = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, tempRoot: temp)
        XCTAssertEqual(fixed.logins.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    // MARK: Keychain

    /// Every answer the Keychain can give, through the real lookup's handling (a stand-in lookup, never the Keychain).
    func testKeychainAnswersArePrecise() throws {
        func read(_ status: OSStatus, _ data: Data? = Data("synthetic".utf8)) -> Result<Data, ImportError> {
            do {
                return .success(try ArcSafeStorage.readPassword { query, result in
                    let q = query as NSDictionary
                    XCTAssertEqual(q[kSecAttrService as String] as? String, "Arc Safe Storage")
                    XCTAssertEqual(q[kSecAttrAccount as String] as? String, "Arc")
                    if status == errSecSuccess, let data { result?.pointee = data as CFData }
                    return status
                })
            } catch { return .failure(error as! ImportError) }
        }
        XCTAssertEqual(read(errSecSuccess), .success(Data("synthetic".utf8)))
        XCTAssertEqual(read(errSecUserCanceled), .failure(.keychainDeclined))
        XCTAssertEqual(read(errSecAuthFailed), .failure(.keychainDeclined))
        XCTAssertEqual(read(errSecInteractionNotAllowed), .failure(.keychainLocked))
        XCTAssertEqual(read(errSecItemNotFound), .failure(.keychainNotFound))
        XCTAssertEqual(read(errSecNoSuchKeychain), .failure(.keychainNotFound))
        XCTAssertEqual(read(errSecParam), .failure(.keychainUnavailable))
        XCTAssertEqual(read(errSecSuccess, Data()), .failure(.keychainUnavailable), "an empty item is no key")
        let messages = [ImportError.keychainDeclined, .keychainLocked, .keychainNotFound, .keychainUnavailable].compactMap(\.errorDescription)
        XCTAssertEqual(Set(messages).count, 4, "each answer says something different")
        XCTAssertTrue(messages.allSatisfy { $0.contains("Arc Safe Storage") || $0.contains("keychain") })
    }

    /// A key that isn't the one Arc encrypted with (the Keychain item was reset, or the folder came from another Mac):
    /// nothing decrypts, and the read says it's the key, not the data.
    func testWrongKeyIsReportedAsAKeyMismatch() async throws {
        let profile = root.appendingPathComponent("Default")
        let other = try ArcSafeStorage.deriveKey(password: Data("another-mac".utf8))
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable([
            "'https://a.example/','','https://a.example/','one',X'\(try encrypted("pw-1", key: other))',0,0,''",
            "'https://b.example/','','https://b.example/','two',X'\(try encrypted("pw-2", key: other))',0,0,''",
        ]))
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, tempRoot: root)
        XCTAssertTrue(c.logins.isEmpty)
        XCTAssertEqual(c.failedLogins, 2)
        XCTAssertTrue(c.keyMismatch)
        let right = try await ArcCredentialImporter.read(profileDirectory: profile, key: other, includeCookies: false, tempRoot: root)
        XCTAssertEqual(right.logins.count, 2)
        XCTAssertFalse(right.keyMismatch)
    }

    // MARK: What can't be imported, precisely

    /// Logins Airc doesn't take are skipped with what they are, and never decrypted: Android apps, federated sign-ins,
    /// HTTP authentication, username-only entries; an empty password; Chromium's "v11" encryption fails as such.
    func testLoginsOfKindsAircDoesntTake() async throws {
        let profile = root.appendingPathComponent("Default")
        try sqlite(profile.appendingPathComponent("Login Data"), loginsTable([
            "'https://ok.example/','','https://ok.example/','web',X'\(try encrypted("pw"))',0,0,''",
            "'android://hash@com.example.app/','','android://hash@com.example.app/','app',X'\(try encrypted("pw"))',0,0,''",
            "'https://fed.example/','','federation://fed.example/accounts.example','fed',X'',0,0,'https://accounts.example'",
            "'https://basic.example/','','https://basic.example/Members','basic',X'\(try encrypted("pw"))',0,1,''",
            "'https://name.example/','','https://name.example/','nameonly',X'',0,4,''",
            "'https://empty.example/','','https://empty.example/','empty',X'',0,0,''",
            "'https://v11.example/','','https://v11.example/','v11',X'7631310000000000000000000000000000000000',0,0,''",
        ]))
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeCookies: false, tempRoot: root)
        XCTAssertEqual(c.logins.map(\.username), ["web"])
        XCTAssertEqual(c.skippedLogins, 5)
        XCTAssertEqual(c.failedLogins, 1)
        let why = Dictionary(uniqueKeysWithValues: c.notes.map { ($0.username, $0.reason) })
        XCTAssertEqual(why["app"], "An Android app's login: Airc takes website logins only")
        XCTAssertEqual(why["fed"], "Signs in through another account (such as Google), so Arc had no password for it: use that sign-in on the site")
        XCTAssertEqual(why["basic"], "A password for the browser's own sign-in box (HTTP authentication): Airc can't import these yet")
        XCTAssertEqual(why["nameonly"], "Arc saved a username here but no password")
        XCTAssertEqual(why["empty"], "Arc saved a username here but no password")
        XCTAssertEqual(why["v11"], "encrypted in a way Airc can't read (Chromium's “v11”, not the Mac's “v10”)")
        XCTAssertFalse(c.keyMismatch)
    }

    /// Partitioned cookies keep their partition key in the metadata the engine checks (it refuses them by name; the
    /// app words it). Cookies decrypt and keep every column except their values out of the metadata.
    func testPartitionedCookiesCarryTheirPartition() async throws {
        let profile = root.appendingPathComponent("Default")
        try sqlite(profile.appendingPathComponent("Network/Cookies"), cookiesTable([
            try cookieRow("a.example", "first"), try cookieRow("b.example", "third", partition: "https://top.example"),
        ]))
        let c = try await ArcCredentialImporter.read(profileDirectory: profile, key: key, includeLogins: false, tempRoot: root)
        XCTAssertEqual(c.cookies.map(\.value), ["first", "third"])
        XCTAssertEqual(c.cookies.map { $0.metadata["top_frame_site_key"] ?? "" }, ["", "https://top.example"])
        XCTAssertTrue(c.cookies.allSatisfy { $0.metadata["encrypted_value"] == nil && $0.metadata["value"] == nil })
    }

    // MARK: Extensions

    /// Where each extension came from decides whether the Web Store can reinstall it.
    func testExtensionProvenance() async throws {
        try sidebar()
        let id = { (c: Character) in String(repeating: c, count: 32) }
        try write("User Data/Default/Preferences", JSONSerialization.data(withJSONObject: ["extensions": ["settings": [
            id("a"): ["manifest": ["name": "Store", "update_url": "https://clients2.google.com/service/update2/crx"], "location": 1, "state": 1, "from_webstore": true],
            id("b"): ["manifest": ["name": "Unpacked"], "location": 4, "state": 1],
            id("c"): ["manifest": ["name": "Elsewhere", "update_url": "https://updates.vendor.example/crx"], "location": 1, "state": 1],
            id("d"): ["manifest": ["name": "Managed", "update_url": "https://clients2.google.com/service/update2/crx"], "location": 9, "state": 1],
            id("e"): ["manifest": ["name": "Legacy"], "location": 1, "state": 0],
        ]]]))
        let p = try await ArcImporter.plan(at: root, tempRoot: root, now: now)
        let byName = Dictionary(uniqueKeysWithValues: (p.extensions?["default"] ?? []).map { ($0.name, $0) })
        XCTAssertEqual(byName["Store"]?.install, .webStore)
        XCTAssertEqual(byName["Unpacked"]?.install, .unpacked)
        XCTAssertEqual(byName["Elsewhere"]?.install, .otherSource)
        XCTAssertEqual(byName["Managed"]?.install, .managed)
        XCTAssertEqual(byName["Legacy"]?.install, .webStore, "nothing says otherwise")
        XCTAssertEqual(byName.values.filter(\.reinstallsFromWebStore).map(\.name).sorted(), ["Legacy", "Managed", "Store"])
        // A checklist saved before (no install field) still decodes, as a Web Store extension.
        let old = try JSONDecoder().decode(ImportedExtension.self, from: Data(#"{"id":"\#(id("a"))","name":"Old","enabled":true}"#.utf8))
        XCTAssertNil(old.install)
        XCTAssertTrue(old.reinstallsFromWebStore)
    }
}
