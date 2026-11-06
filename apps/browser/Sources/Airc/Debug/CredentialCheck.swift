// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import AircKit
import AppKit
import SQLite3

/// Part of `--script events`: the credential import end to end (code review H1, H2), on synthetic data only. A fake Arc
/// folder with a `Login Data` held under SQLite's exclusive lock (as a running Arc holds it) and a `Cookies` database,
/// encrypted with a synthetic key, goes through `CredentialImport.run` into the engine. Never the Keychain, never real
/// data. On Chromium the engine's counts must match; on WebKit nothing may be read.
extension SnapshotRunner {
    func credentialImportCheck() {
        step { [self] done in
            guard let app = c.app else { return done() }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("AircCredentialCheck-\(UUID().uuidString)")
            let profileDir = root.appendingPathComponent("User Data/Profile 1")
            var arc: OpaquePointer?
            func cleanUp() {
                sqlite3_close(arc)
                try? fm.removeItem(at: root)
            }
            func copies() -> Int {
                ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("AircImport-") }.count
            }
            do {
                try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
                let key = try ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))
                func blob(_ d: Data) throws -> String { try Self.encryptedHex(d, key: key) }
                // Logins: two that come over, one never-save entry, one app login Chromium doesn't take, one v11 row.
                arc = try Self.sqlite(profileDir.appendingPathComponent("Login Data"), """
                    PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA locking_mode=EXCLUSIVE;
                    CREATE TABLE logins(origin_url TEXT, action_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);
                    INSERT INTO logins VALUES('https://one.example/','https://one.example/login','https://one.example/','synthetic-1',X'\(try blob(Data("pw-1".utf8)))',0);
                    INSERT INTO logins VALUES('https://two.example/','','https://two.example/','synthetic-2',X'\(try blob(Data("pw-2".utf8)))',0);
                    INSERT INTO logins VALUES('https://never.example/','','https://never.example/','',X'',1);
                    INSERT INTO logins VALUES('android://hash@com.example.app/','','android://hash@com.example.app/','synthetic-3',X'\(try blob(Data("pw-3".utf8)))',0);
                    INSERT INTO logins VALUES('https://v11.example/','','https://v11.example/','synthetic-4',X'7631310000000000000000000000000000000000',0);
                    """, keepOpen: true)
                // Cookies: two that come over, one partitioned (refused rather than flattened), one with a bad digest.
                let far = Int64((Date().timeIntervalSince1970 + 11_644_473_600 + 86_400 * 30) * 1_000_000)
                func cookieBlob(_ host: String, _ value: String) throws -> String { try blob(ArcSafeStorage.digest(host) + Data(value.utf8)) }
                _ = try Self.sqlite(profileDir.appendingPathComponent("Cookies"), """
                    CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24');
                    CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT);
                    INSERT INTO cookies VALUES('.one.example','sid','/','',X'\(try cookieBlob(".one.example", "c-1"))',\(far),1,1,1,'');
                    INSERT INTO cookies VALUES('two.example','pref','/','',X'\(try cookieBlob("two.example", "c-2"))',\(far),1,0,1,'');
                    INSERT INTO cookies VALUES('three.example','part','/','',X'\(try cookieBlob("three.example", "c-3"))',\(far),1,0,-1,'https://top.example');
                    INSERT INTO cookies VALUES('four.example','bad','/','',X'\(try cookieBlob("other.example", "c-4"))',\(far),1,0,1,'');
                    """, keepOpen: false)
            } catch {
                check(false, "credentials: synthetic Arc folder (\(error))")
                cleanUp()
                return done()
            }
            let copiesBefore = copies()
            let profileID = c.store.defaultProfile.id
            let expectEngine = app.credentialSink.acceptsCredentials
            let started = CACurrentMediaTime()
            CredentialImport.run(arcDirectory: root, profiles: [("Profile 1", profileID)], sink: app.credentialSink,
                                 key: try? ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8)),
                                 progress: { _ in }) { [self] result in
                let ms = Int((CACurrentMediaTime() - started) * 1000)
                switch (expectEngine, result) {
                case (false, .failure(let e)):
                    check(e is CredentialImport.Unsupported && copies() == copiesBefore,
                          "credentials (no Chromium engine): nothing read — \(e.localizedDescription)")
                case (true, .success(let o)):
                    check(o.loginsImported == 2 && o.cookiesImported == 2 && o.skipped == 3 && o.failed == 2
                          && o.failedProfiles.isEmpty && !o.isFailure,
                          "credentials: Arc running, into the engine in \(ms) ms — \(o.summary) (expected 2 and 2 imported, 3 skipped, 2 failed)")
                    check(copies() == copiesBefore, "credentials: the private copies are deleted")
                    // Engine pass 8: a result for every row, with its site, its username and why.
                    let got = Set(o.rows.map { "\($0.kind.rawValue) \($0.site) \($0.username) \($0.status.rawValue)" })
                    let expected: Set<String> = [
                        "login one.example synthetic-1 imported", "login two.example synthetic-2 imported",
                        "login never.example  skipped", "login com.example.app synthetic-3 skipped", "login v11.example synthetic-4 failed",
                        "cookies one.example  imported", "cookies two.example  imported", "cookies three.example  skipped",
                        "cookies four.example  failed",
                    ]
                    let reasons = o.rows.allSatisfy { $0.status == .imported ? $0.reason.isEmpty : !$0.reason.isEmpty }
                    check(got == expected && reasons && o.count(.imported) == 4 && o.count(.skipped) == 3 && o.count(.failed) == 2,
                          "credentials: per-row results (\(o.rows.count) rows, every skip and failure with a reason \(reasons))"
                          + (got == expected ? "" : "; missing \(expected.subtracting(got).sorted()), extra \(got.subtracting(expected).sorted())"))
                    note("credentials: reasons: " + o.rows.filter { !$0.reason.isEmpty }.map { "\($0.site): \($0.reason)" }.joined(separator: " · "))
                    // Again: the logins are already there and say so; nothing is duplicated.
                    CredentialImport.run(arcDirectory: root, profiles: [("Profile 1", profileID)], sink: app.credentialSink,
                                         key: try? ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8)),
                                         progress: { _ in }) { [self] again in
                        if case .success(let o2) = again {
                            let dupes = o2.rows.filter { $0.kind == .login && $0.status == .skipped && $0.reason == "Already saved in this profile" }
                            check(o2.loginsImported == 0 && dupes.count == 2,
                                  "credentials: importing again: the 2 logins are \"Already saved in this profile\" (\(o2.summary))")
                        } else {
                            check(false, "credentials: importing again")
                        }
                        // Settings → Import shows the rows (the last import's).
                        app.showSettings(page: .importing)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                            if let w = app.settingsWindow?.window, let v = w.contentView {
                                v.layoutSubtreeIfNeeded()
                                if let img = render(v), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                                   let png = rep.representation(using: .png, properties: [:]) {
                                    try? png.write(to: dir.appendingPathComponent("settings-import-results.png"))
                                    note("wrote settings-import-results.png")
                                }
                                w.orderOut(nil)
                            }
                            cleanUp()
                            done()
                        }
                    }
                    return
                case (_, .success(let o)):
                    check(false, "credentials: read on an engine that can't take them — \(o.summary)")
                case (_, .failure(let e)):
                    check(false, "credentials: \(e.localizedDescription)")
                }
                cleanUp()
                done()
            }
        }
    }

    private static func encryptedHex(_ plain: Data, key: Data) throws -> String {
        try ArcSafeStorage.encryptForTests(plain, key: key).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a database and runs `sql`. With `keepOpen`, the connection stays open (holding its lock) for the caller.
    private static func sqlite(_ url: URL, _ sql: String, keepOpen: Bool) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw NSError(domain: "CredentialCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }
}
#endif
