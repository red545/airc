// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import XCTest
import CArcCrypto
@testable import AircImport

/// Other browsers (bookmarks, history, password CSV files), on synthetic data only: a fake home folder with a
/// Chrome-layout user-data folder, a Firefox profile, bookmarks HTML exports and password CSV files with example.com
/// entries. Never the real home folder or any real browser's files.
final class BrowserTests: XCTestCase, @unchecked Sendable {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("airc-browsers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    var support: URL { home.appendingPathComponent("Library/Application Support") }

    func write(_ text: String, _ path: String) throws {
        let url = support.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func json(_ object: Any, _ path: String) throws {
        try write(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), path)
    }

    /// A database at `path`; with `keepOpen`, its connection stays open (and its locks held) until the caller closes it.
    @discardableResult
    func sqlite(_ path: String, _ sql: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        let url = support.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(rc, SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }

    static func chromeTime(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 + 11_644_473_600) * 1_000_000) }

    func node(_ name: String, url: String? = nil, guid: String, children: [Any]? = nil) -> [String: Any] {
        var n: [String: Any] = ["name": name, "guid": guid, "id": guid]
        if let url { n["type"] = "url"; n["url"] = url } else { n["type"] = "folder"; n["children"] = children ?? [] }
        return n
    }

    func chromeBookmarks(bar: [Any], other: [Any] = [], synced: [Any] = []) -> [String: Any] {
        ["version": 1, "checksum": "0", "roots": [
            "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": bar],
            "other": ["type": "folder", "name": "Other bookmarks", "children": other],
            "synced": ["type": "folder", "name": "Mobile bookmarks", "children": synced],
        ]]
    }

    static let historySchema = "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);"

    // MARK: Detection

    func testDetectsChromiumProfilesFromLocalState() throws {
        try json(["profile": [
            "profiles_order": ["Profile 2", "Default"],
            "info_cache": [
                "Default": ["name": "Person 1", "is_using_default_name": true, "profile_highlight_color": -11_097_651],
                "Profile 2": ["name": "Work", "is_using_default_name": false, "default_avatar_fill_color": -2_354_116],
                "Profile 3": ["name": "Gone"],
                "Guest Profile": ["name": "Guest"],
                "../escape": ["name": "Escape"],
            ],
        ]], "Google/Chrome/Local State")
        try json(chromeBookmarks(bar: []), "Google/Chrome/Default/Bookmarks")
        try sqlite("Google/Chrome/Profile 2/History", Self.historySchema)
        try sqlite("Google/Chrome/Guest Profile/History", Self.historySchema)
        // A folder without a profile list, and Opera's one profile in its data folder.
        try json(chromeBookmarks(bar: []), "BraveSoftware/Brave-Browser/Default/Bookmarks")
        try json(chromeBookmarks(bar: []), "com.operasoftware.Opera/Bookmarks")
        // Folders without bookmarks or history don't count.
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Microsoft Edge/Default"), withIntermediateDirectories: true)

        let found = BrowserImporter.detect(home: home)
        XCTAssertEqual(found.map(\.id), ["chrome", "brave", "opera"])
        let chrome = found[0]
        XCTAssertEqual(chrome.profiles.map(\.id), ["Profile 2", "Default"], "Chrome's own order")
        XCTAssertEqual(chrome.profiles.map(\.name), ["Work", "Chrome"], "a default name gives way to the browser's")
        XCTAssertEqual(chrome.profiles.map(\.hasDefaultName), [false, true])
        XCTAssertEqual(chrome.profiles.map(\.color), ["#dc143c", "#56a9cd"])
        XCTAssertEqual(chrome.profiles.map(\.isDefault), [false, true])
        XCTAssertEqual(found[1].profiles.map(\.id), ["Default"])
        XCTAssertEqual(found[2].profiles.map(\.id), [""])
        XCTAssertEqual(found[2].profiles.first?.folder.standardizedFileURL, support.appendingPathComponent("com.operasoftware.Opera").standardizedFileURL)
    }

    func testDetectsFirefoxProfilesFromProfilesIni() throws {
        try write("""
            [Install4F96D1932A9F858E]
            Default=Profiles/def456.default-release
            Locked=1

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/abc123.default

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/def456.default-release

            [Profile2]
            Name=Escape
            IsRelative=1
            Path=../../outside

            [Profile3]
            Name=Absolute
            IsRelative=0
            Path=/tmp/somewhere

            [Profile4]
            Name=Work
            IsRelative=1
            Path=Profiles/ghi789.work
            """, "Firefox/profiles.ini")
        for p in ["abc123.default", "def456.default-release", "ghi789.work"] {
            try sqlite("Firefox/Profiles/\(p)/places.sqlite", "CREATE TABLE t(x)")
        }
        try write("[Profile0]\nName=Default (release)\nIsRelative=1\nPath=Profiles/z.Default (release)\n", "zen/profiles.ini")
        try sqlite("zen/Profiles/z.Default (release)/places.sqlite", "CREATE TABLE t(x)")
        let found = BrowserImporter.detect(home: home)
        XCTAssertEqual(found.map(\.id), ["firefox", "zen"])
        XCTAssertEqual(found[0].profiles.map(\.id), ["Profiles/def456.default-release", "Profiles/abc123.default", "Profiles/ghi789.work"],
                       "the default first; paths outside the folder never")
        XCTAssertEqual(found[0].profiles.map(\.name), ["Firefox", "Firefox", "Work"])
        XCTAssertEqual(found[0].profiles.map(\.isDefault), [true, false, false])
        XCTAssertEqual(found[1].profiles.map(\.name), ["Default (release)"])
        XCTAssertTrue(BrowserImporter.isDefaultName("Person 3") && BrowserImporter.isDefaultName("Profile 12")
                      && BrowserImporter.isDefaultName("default-release") && !BrowserImporter.isDefaultName("Personal"))
    }

    func testNothingFoundInAnEmptyHome() {
        XCTAssertTrue(BrowserImporter.detect(home: home).isEmpty)
    }

    // MARK: Chromium: bookmarks and history

    func chromeFixture() throws -> BrowserInstall {
        try json(["profile": ["info_cache": ["Default": ["name": "Person 1", "is_using_default_name": true]]]], "Google/Chrome/Local State")
        try json(chromeBookmarks(bar: [
            node("Example", url: "https://example.com/", guid: "g-1"),
            node("Docs", guid: "g-2", children: [
                node("Guide & tips", url: "https://docs.example.com/guide", guid: "g-3"),
                node("Deep", guid: "g-4", children: [node("", url: "https://example.org/deep", guid: "g-5")]),
            ]),
            node("Bookmarklet", url: "javascript:alert(1)", guid: "g-6"),
            node("No address", url: "", guid: "g-7"),
        ], other: [
            node("Other one", url: "https://example.net/1", guid: "g-8"),
            node("Other two", url: "https://example.net/2", guid: "g-9"),
        ], synced: [node("Phone", url: "https://m.example.com/", guid: "g-10")]), "Google/Chrome/Default/Bookmarks")
        let now = Date()
        try sqlite("Google/Chrome/Default/History", Self.historySchema + """
            INSERT INTO urls VALUES(1,'https://example.com/','Example',12,3,\(Self.chromeTime(now.addingTimeInterval(-60))),0);
            INSERT INTO urls VALUES(2,'https://docs.example.com/guide','Guide',2,0,\(Self.chromeTime(now.addingTimeInterval(-3600))),0);
            INSERT INTO urls VALUES(3,'https://hidden.example.com/','Hidden',1,0,\(Self.chromeTime(now)),1);
            INSERT INTO urls VALUES(4,'chrome://settings/','Settings',5,0,\(Self.chromeTime(now)),0);
            INSERT INTO urls VALUES(5,'http://old.example.org/','Old',1,0,\(Self.chromeTime(now.addingTimeInterval(-86_400 * 30))),0);
            """)
        return try XCTUnwrap(BrowserImporter.detect(home: home).first)
    }

    func testChromiumBookmarksBecomeOneSpaceWithStableIDs() async throws {
        let chrome = try chromeFixture()
        let r = try await BrowserImporter.read(chrome)
        XCTAssertEqual(r.plan.profiles.map(\.id), ["chrome-profile:Default"])
        XCTAssertEqual(r.plan.profiles.map(\.name), ["Chrome"])
        XCTAssertEqual(r.plan.spaces.count, 1)
        let s = r.plan.spaces[0]
        XCTAssertEqual(s.id, "chrome-space:Default")
        XCTAssertEqual(s.name, "Chrome")
        XCTAssertEqual(s.profileID, "chrome-profile:Default")
        XCTAssertTrue(r.plan.favorites.isEmpty, "Favorites stay empty")
        XCTAssertTrue(s.today.isEmpty)
        // The bar's tabs and folders, then "Other bookmarks" and "Mobile bookmarks" as one pinned folder each.
        func shape(_ items: [ImportedItem]) -> [String] {
            items.map {
                switch $0 {
                case .tab(let t): t.title ?? t.url
                case .folder(let f): "[\(f.title): \(shape(f.children).joined(separator: ", "))]"
                case .split: "split"
                }
            }
        }
        XCTAssertEqual(shape(s.pinned), ["Example", "[Docs: Guide & tips, [Deep: https://example.org/deep]]",
                                         "[Other bookmarks: Other one, Other two]", "[Mobile bookmarks: Phone]"])
        XCTAssertEqual(s.pinned.first?.tabs.first?.id, "chrome-item:Default/g-1")
        guard case .folder(let other) = s.pinned[2] else { return XCTFail("no Other bookmarks folder") }
        XCTAssertEqual(other.id, "chrome-item:Default/root:other")
        XCTAssertEqual(r.profiles.first?.bookmarks, 6)
        XCTAssertEqual(r.profiles.first?.folders, 4)
        XCTAssertEqual(Set(r.plan.warnings.map(\.code)), [.bookmarklet, .invalidTab])
        // History: newest first; hidden pages and non-web addresses left out; Chromium's 1601-based times.
        let h = try XCTUnwrap(r.history["chrome-profile:Default"])
        XCTAssertEqual(h.map(\.url), ["https://example.com/", "https://docs.example.com/guide", "http://old.example.org/"])
        XCTAssertEqual(h.first?.visitCount, 12)
        XCTAssertEqual(h.first?.typedCount, 3)
        XCTAssertEqual(h.first!.lastVisit.timeIntervalSinceNow, -60, accuracy: 2)
        XCTAssertEqual(r.historyEntries, 3)
        // Reading again gives the same IDs (re-import merges in place).
        let again = try await BrowserImporter.read(chrome)
        XCTAssertEqual(again.plan, r.plan)
        // Without history, nothing of it is read.
        let noHistory = try await BrowserImporter.read(chrome, includeHistory: false)
        XCTAssertEqual(noHistory.history["chrome-profile:Default"], [])
        // Warnings never carry a title or an address.
        let words = r.plan.warnings.map(\.message).joined(separator: " ")
        XCTAssertFalse(words.contains("example") || words.contains("Bookmarklet") || words.contains("alert"))
    }

    /// The browser running: History held under SQLite's exclusive lock with uncheckpointed WAL pages.
    func testLockedHistoryIsReadFromACopy() async throws {
        let chrome = try chromeFixture()
        let path = "Google/Chrome/Default/History"
        try FileManager.default.removeItem(at: support.appendingPathComponent(path))
        let held = try sqlite(path, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA locking_mode=EXCLUSIVE;" + Self.historySchema
                              + "INSERT INTO urls VALUES(1,'https://locked.example.com/','Locked',1,0,\(Self.chromeTime(Date())),0);", keepOpen: true)
        defer { sqlite3_close(held) }
        var reader: OpaquePointer?
        sqlite3_open_v2(support.appendingPathComponent(path).path, &reader, SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(sqlite3_exec(reader, "SELECT count(*) FROM urls", nil, nil, nil), SQLITE_BUSY, "a direct reader is locked out")
        sqlite3_close(reader)
        let temp = home.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let r = try await BrowserImporter.read(chrome, tempRoot: temp)
        XCTAssertEqual(r.history["chrome-profile:Default"]?.map(\.url), ["https://locked.example.com/"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [], "the private copy is deleted")
    }

    func testMalformedFilesBringWhatCanBeRead() async throws {
        let chrome = try chromeFixture()
        try write("{ this is not json", "Google/Chrome/Default/Bookmarks")
        var r = try await BrowserImporter.read(chrome)
        XCTAssertEqual(r.profiles.first?.unreadable, ["bookmarks"])
        XCTAssertEqual(r.historyEntries, 3, "history still comes over")
        XCTAssertTrue(r.plan.warnings.contains { $0.code == .unreadableBookmarks })
        XCTAssertEqual(r.plan.spaces.first?.pinned, [], "the profile still gets its Space")

        try json(["roots": "nope"], "Google/Chrome/Default/Bookmarks")
        r = try await BrowserImporter.read(chrome)
        XCTAssertEqual(r.profiles.first?.unreadable, ["bookmarks"])

        try json(chromeBookmarks(bar: [node("Example", url: "https://example.com/", guid: "g-1")]), "Google/Chrome/Default/Bookmarks")
        try write("SQLite format 3\0 but not really a database at all", "Google/Chrome/Default/History")
        r = try await BrowserImporter.read(chrome)
        XCTAssertEqual(r.profiles.first?.unreadable, ["history"])
        XCTAssertEqual(r.bookmarks, 1, "bookmarks still come over")
        XCTAssertTrue(r.plan.warnings.contains { $0.code == .unreadableHistory })

        // A History without the urls table.
        try FileManager.default.removeItem(at: support.appendingPathComponent("Google/Chrome/Default/History"))
        try sqlite("Google/Chrome/Default/History", "CREATE TABLE other(x)")
        r = try await BrowserImporter.read(chrome)
        XCTAssertEqual(r.profiles.first?.unreadable, ["history"])
    }

    func testHugeFilesAreCapped() async throws {
        _ = try chromeFixture()
        let many = (0..<12_000).map { node("Page \($0)", url: "https://example.com/\($0)", guid: "big-\($0)") }
        var deep: [String: Any] = node("Leaf", url: "https://example.com/leaf", guid: "leaf")
        for i in 0..<70 { deep = node("Level \(i)", guid: "level-\(i)", children: [deep]) }
        try json(chromeBookmarks(bar: [deep], other: many), "Google/Chrome/Default/Bookmarks")
        let rows = (0..<50_000).map { "(\($0 + 1),'https://example.com/p/\($0)','Page \($0)',1,0,\(13_300_000_000_000_000 + Int64($0)),0)" }
        try FileManager.default.removeItem(at: support.appendingPathComponent("Google/Chrome/Default/History"))
        try sqlite("Google/Chrome/Default/History", Self.historySchema + "BEGIN;" + stride(from: 0, to: rows.count, by: 500).map {
            "INSERT INTO urls VALUES " + rows[$0..<min($0 + 500, rows.count)].joined(separator: ",") + ";"
        }.joined() + "COMMIT;")
        let chrome = try XCTUnwrap(BrowserImporter.detect(home: home).first)
        let started = Date()
        let r = try await BrowserImporter.read(chrome)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertEqual(r.bookmarks, BrowserImporter.maxBookmarks)
        XCTAssertTrue(r.plan.warnings.contains { $0.code == .tooManyBookmarks })
        XCTAssertEqual(r.plan.warnings.filter { $0.code == .tooManyBookmarks }.count, 1, "said once")
        XCTAssertTrue(r.plan.warnings.contains { $0.code == .depthLimit })
        XCTAssertEqual(r.historyEntries, BrowserImporter.defaultHistoryLimit)
        XCTAssertEqual(r.history["chrome-profile:Default"]?.first?.url, "https://example.com/p/49999", "the newest first")
        // Files past the size limit aren't read.
        XCTAssertThrowsError(try BrowserImporter.readLimited(support.appendingPathComponent("Google/Chrome/Default/Bookmarks"), limit: 100)) {
            XCTAssertEqual($0 as? ImportError, .fileTooLarge)
        }
    }

    func testProfilesAreChosenAndNamedApart() async throws {
        try json(["profile": ["info_cache": [
            "Default": ["name": "Person 1", "is_using_default_name": true],
            "Profile 1": ["name": "Person 2", "is_using_default_name": true],
            "Profile 2": ["name": "Work", "is_using_default_name": false],
        ]]], "Google/Chrome/Local State")
        for p in ["Default", "Profile 1", "Profile 2"] {
            try json(chromeBookmarks(bar: [node("Same", url: "https://example.com/", guid: "shared-guid")]), "Google/Chrome/\(p)/Bookmarks")
        }
        let chrome = try XCTUnwrap(BrowserImporter.detect(home: home).first)
        let all = try await BrowserImporter.read(chrome)
        XCTAssertEqual(all.plan.spaces.map(\.name), ["Chrome", "Chrome 2", "Work"])
        // Two profiles synced to one account share bookmark GUIDs; their items don't.
        let ids = all.plan.spaces.flatMap { $0.pinned.flatMap(\.tabs).map(\.id) }
        XCTAssertEqual(Set(ids).count, 3)
        let some = try await BrowserImporter.read(chrome, profiles: ["Profile 2"])
        XCTAssertEqual(some.plan.spaces.map(\.id), ["chrome-space:Profile 2"])
    }

    // MARK: Firefox

    func firefoxFixture(lock: Bool = false) throws -> (BrowserInstall, OpaquePointer?) {
        try write("[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/x.default-release\nDefault=1\n", "Firefox/profiles.ini")
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let db = try sqlite("Firefox/Profiles/x.default-release/places.sqlite", (lock ? "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA locking_mode=EXCLUSIVE;" : "") + """
            CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, typed INTEGER, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
            INSERT INTO moz_places VALUES(1,'https://example.com/','Example',4,0,1,\(now - 1_000_000));
            INSERT INTO moz_places VALUES(2,'https://example.org/menu','Menu page',0,0,0,NULL);
            INSERT INTO moz_places VALUES(3,'place:sort=8&maxResults=10','Most Visited',0,1,0,NULL);
            INSERT INTO moz_places VALUES(4,'https://example.net/other','Other',2,0,0,\(now - 60_000_000));
            INSERT INTO moz_places VALUES(5,'https://hidden.example.com/','Hidden',3,1,0,\(now));
            INSERT INTO moz_places VALUES(6,'https://example.com/tagged','Tagged',0,0,0,NULL);
            INSERT INTO moz_bookmarks VALUES(1,2,NULL,0,0,'','root________');
            INSERT INTO moz_bookmarks VALUES(2,2,NULL,1,0,'menu','menu________');
            INSERT INTO moz_bookmarks VALUES(3,2,NULL,1,1,'toolbar','toolbar_____');
            INSERT INTO moz_bookmarks VALUES(4,2,NULL,1,2,'tags','tags________');
            INSERT INTO moz_bookmarks VALUES(5,2,NULL,1,3,'unfiled','unfiled_____');
            INSERT INTO moz_bookmarks VALUES(6,2,NULL,1,4,'mobile','mobile______');
            INSERT INTO moz_bookmarks VALUES(10,1,1,3,0,'Example','ff-example01');
            INSERT INTO moz_bookmarks VALUES(11,3,NULL,3,1,NULL,'ff-separator');
            INSERT INTO moz_bookmarks VALUES(12,2,NULL,3,2,'Reading','ff-folder001');
            INSERT INTO moz_bookmarks VALUES(13,1,4,12,0,'Other page','ff-other0001');
            INSERT INTO moz_bookmarks VALUES(14,1,3,3,3,'Most Visited','ff-smart0001');
            INSERT INTO moz_bookmarks VALUES(15,1,2,2,0,'Menu page','ff-menu00001');
            INSERT INTO moz_bookmarks VALUES(16,1,4,5,0,'Unfiled','ff-unfiled01');
            INSERT INTO moz_bookmarks VALUES(17,2,NULL,4,0,'a-tag','ff-tag000001');
            INSERT INTO moz_bookmarks VALUES(18,1,6,17,0,NULL,'ff-tagged001');
            """, keepOpen: lock)
        return (try XCTUnwrap(BrowserImporter.detect(home: home).first), db)
    }

    func testFirefoxBookmarksAndHistoryWhileFirefoxRuns() async throws {
        let (firefox, held) = try firefoxFixture(lock: true)
        defer { sqlite3_close(held) }
        let r = try await BrowserImporter.read(firefox)
        let s = try XCTUnwrap(r.plan.spaces.first)
        XCTAssertEqual(s.name, "Firefox")
        XCTAssertEqual(s.id, "firefox-space:Profiles/x.default-release")
        func shape(_ items: [ImportedItem]) -> [String] {
            items.map {
                switch $0 {
                case .tab(let t): t.title ?? t.url
                case .folder(let f): "[\(f.title): \(shape(f.children).joined(separator: ", "))]"
                case .split: "split"
                }
            }
        }
        // The toolbar's bookmarks and folders, then the menu, Other Bookmarks; no separators, smart folders or tags.
        XCTAssertEqual(shape(s.pinned), ["Example", "[Reading: Other page]", "[Bookmarks Menu: Menu page]", "[Other Bookmarks: Unfiled]"])
        XCTAssertEqual(s.pinned.first?.tabs.first?.id, "firefox-item:Profiles/x.default-release/ff-example01")
        XCTAssertTrue(r.plan.warnings.contains { $0.code == .smartBookmark })
        XCTAssertEqual(r.history.values.first?.map(\.url), ["https://example.com/", "https://example.net/other"])
        XCTAssertEqual(r.history.values.first?.first?.typedCount, 1)
        XCTAssertEqual(r.profiles.first?.bookmarks, 4)
        XCTAssertEqual(r.profiles.first?.folders, 3)
    }

    func testFirefoxDatabaseThatIsntOne() async throws {
        let (firefox, _) = try firefoxFixture()
        try write("garbage", "Firefox/Profiles/x.default-release/places.sqlite")
        let r = try await BrowserImporter.read(firefox)
        XCTAssertEqual(r.profiles.first?.unreadable, ["bookmarks", "history"])
        XCTAssertEqual(r.plan.spaces.count, 1)
    }

    // MARK: Bookmarks HTML files

    static let safariExport = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        \t<HTML>
        \t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        \t<Title>Bookmarks</Title>
        \t<H1>Bookmarks</H1>
        \t<DT><H3 FOLDED>Favorites</H3>
        \t<DL><p>
        \t\t<DT><A HREF="https://example.com/">Example</A>
        \t\t<DT><H3 FOLDED>News</H3>
        \t\t<DL><p>
        \t\t\t<DT><A HREF="https://news.example.org/?a=1&amp;b=2">News &amp; more &#8212; today</A>
        \t\t</DL><p>
        \t</DL><p>
        \t<DT><H3 FOLDED>Bookmarks Menu</H3>
        \t<DL><p>
        \t</DL><p>
        \t<DT><H3 FOLDED>Trips</H3>
        \t<DL><p>
        \t\t<DT><A HREF="https://travel.example.net/">Travel</A>
        \t\t<DT><A HREF="https://travel.example.net/">Travel</A>
        \t</DL><p>
        \t<DT><H3 id="com.apple.ReadingList">Reading List</H3>
        \t<DL><p>
        \t\t<DT><A HREF="https://read.example.com/article">An article</A>
        \t</DL><p>
        </HTML>
        """

    func file(_ text: String, _ name: String = "bookmarks.html") throws -> URL {
        let url = home.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func shape(_ items: [ImportedItem]) -> [String] {
        items.map {
            switch $0 {
            case .tab(let t): t.title ?? t.url
            case .folder(let f): "[\(f.title): \(shape(f.children).joined(separator: ", "))]"
            case .split: "split"
            }
        }
    }

    func testSafariBookmarksFile() async throws {
        let r = try await BrowserImporter.readBookmarksFile(file(Self.safariExport))
        XCTAssertEqual(r.kind, .safari)
        XCTAssertTrue(r.fromFile)
        let s = try XCTUnwrap(r.plan.spaces.first)
        XCTAssertEqual(s.name, "Safari")
        XCTAssertEqual(s.id, "safari-file-space:file")
        // Favorites (Safari's bar) become the pinned tabs; empty folders stay; the same bookmark twice stays twice.
        XCTAssertEqual(shape(s.pinned), ["Example", "[News: News & more — today]", "[Bookmarks Menu: ]", "[Trips: Travel, Travel]",
                                         "[Reading List: An article]"])
        XCTAssertEqual(s.pinned[1].tabs.first?.url, "https://news.example.org/?a=1&b=2")
        let ids = s.pinned.flatMap(\.tabs).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every entry its own ID")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("safari-file-item:file/") })
        guard case .folder(let reading) = s.pinned[4] else { return XCTFail() }
        XCTAssertEqual(reading.id, "safari-file-item:file/com.apple.ReadingList")
        // The same export again: the same IDs.
        let again = try await BrowserImporter.readBookmarksFile(file(Self.safariExport, "again.html"))
        XCTAssertEqual(again.plan, r.plan)
    }

    func testChromeAndFirefoxBookmarksFiles() async throws {
        let icon = "data:image/png;base64," + String(repeating: "iVBORw0KGgo", count: 200_000)
        let chrome = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <!-- This is an automatically generated file.
                 It will be read and overwritten.
                 DO NOT EDIT! -->
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000001" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/" ADD_DATE="1700000000" ICON="\(icon)">Example "quoted" &lt;b&gt;</A>
                    <DT><A HREF="javascript:void(0)">Bookmarklet</A>
                </DL><p>
                <DT><A HREF="https://example.org/loose" ADD_DATE="1700000000">Loose one</A>
            </DL><p>
            """
        let started = Date()
        let c = try await BrowserImporter.readBookmarksFile(file(chrome))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "megabytes of inline icons stay fast")
        XCTAssertNil(c.kind, "Chromium browsers all write the same file")
        XCTAssertEqual(c.plan.spaces.first?.name, "Bookmarks")
        XCTAssertEqual(shape(c.plan.spaces.first!.pinned), ["Example \"quoted\" <b>", "[Other bookmarks: Loose one]"])
        XCTAssertTrue(c.plan.warnings.contains { $0.code == .bookmarklet })
        // A hint names the Space (the user picked the file for Safari).
        let hinted = try await BrowserImporter.readBookmarksFile(file(chrome), kind: .safari)
        XCTAssertEqual(hinted.plan.spaces.first?.name, "Safari")

        let firefox = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
            <title>Bookmarks</title>
            <h1>Bookmarks Menu</h1>
            <dl><p>
                <dt><a href="https://example.com/menu" add_date="1">Menu item</a>
                <dt><h3 add_date="1" personal_toolbar_folder="true">Bookmarks Toolbar</h3>
                <dl><p>
                    <dt><a href="https://example.com/bar">Bar item</a>
                </dl><p>
                <dt><h3 add_date="1" unfiled_bookmarks_folder="true">Other Bookmarks</h3>
                <dl><p>
                    <dt><a href="https://example.com/other">Other item</a>
                </dl><p>
            </dl>
            """
        let f = try await BrowserImporter.readBookmarksFile(file(firefox))
        XCTAssertEqual(f.kind, .firefox)
        XCTAssertEqual(shape(f.plan.spaces.first!.pinned), ["Bar item", "[Bookmarks Menu: Menu item]", "[Other Bookmarks: Other item]"])
    }

    func testBookmarksFilesThatArent() async throws {
        do {
            _ = try await BrowserImporter.readBookmarksFile(file("name,url\nExample,https://example.com/\n", "not.html"))
            XCTFail("a CSV isn't a bookmarks file")
        } catch { XCTAssertEqual(error as? ImportError, .invalidBookmarks) }
        do {
            _ = try await BrowserImporter.readBookmarksFile(file("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n</DL>", "empty.html"))
            XCTFail("an empty file has nothing to import")
        } catch { XCTAssertEqual(error as? ImportError, .invalidBookmarks) }
        // Unbalanced and deeply nested lists don't crash or loop.
        let deep = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL>" + String(repeating: "<DT><H3>F</H3><DL>", count: 200)
            + "<DT><A HREF=\"https://example.com/\">Deep</A>" + "</DL></DL></DL></DL>"
        let r = try await BrowserImporter.readBookmarksFile(file(deep, "deep.html"))
        XCTAssertEqual(r.bookmarks, 1)
        XCTAssertTrue(r.plan.warnings.isEmpty || r.plan.warnings.allSatisfy { $0.code == .depthLimit })
    }

    // MARK: Password CSV files

    func csv(_ text: String) throws -> PasswordFile { try PasswordCSV.parse(Data(text.utf8)) }

    func testChromePasswordsCSV() throws {
        let p = try csv("""
            name,url,username,password,note\r
            example.com,https://example.com/login?next=%2F#top,alex@example.com,"pa,ss""word",\r
            accounts.example.org,https://accounts.example.org/,alex,"multi
            line",a note\r
            example.com,https://example.com/login,alex@example.com,another,\r
            app,android://hash@app.example/,alex,secret,\r
            empty,https://empty.example.com/,alex,,\r
            port,https://example.net:443/,,pw,\r
            port,http://example.net:8080/a,bob,pw,\r
            \r

            """)
        XCTAssertEqual(p.format, .chrome)
        XCTAssertEqual(p.rows, 7)
        XCTAssertEqual(p.logins.count, 4)
        XCTAssertEqual(p.duplicates, 1, "the same site and username twice")
        XCTAssertEqual(p.notWebsite, 1)
        XCTAssertEqual(p.incomplete, 1)
        XCTAssertEqual(p.logins[0].origin, "https://example.com/login")
        XCTAssertEqual(p.logins[0].signonRealm, "https://example.com/")
        XCTAssertEqual(p.logins[0].username, "alex@example.com")
        XCTAssertEqual(p.logins[0].password, "pa,ss\"word")
        XCTAssertEqual(p.logins[1].password, "multi\nline")
        XCTAssertEqual(p.logins[2].signonRealm, "https://example.net/", "the default port isn't part of the realm")
        XCTAssertEqual(p.logins[2].username, "")
        XCTAssertEqual(p.logins[3].signonRealm, "http://example.net:8080/")
    }

    func testFirefoxAndSafariPasswordsCSV() throws {
        let firefox = try csv("""
            "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
            "https://example.com","alex","ff-pass",,"https://example.com","{0001}","1700000000000","1700000000000","1700000000000"
            "chrome://FirefoxAccounts","alex@example.com","{""kind"":""token""}","Firefox Accounts credentials",,"{0002}","1","1","1"
            "https://basic.example.org","admin","basic-pass","Admin area",,"{0003}","1","1","1"
            """)
        XCTAssertEqual(firefox.format, .firefox)
        XCTAssertEqual(firefox.logins.map(\.signonRealm), ["https://example.com/", "https://basic.example.org/"])
        XCTAssertEqual(firefox.logins.first?.actionURL, "https://example.com/")
        XCTAssertEqual(firefox.notWebsite, 1, "Firefox's own account entry isn't a website login")

        let safari = try csv("\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\nExample,https://example.com/,alex,safari-pass,,\nBare,example.org,sam,pw2,,otpauth://totp/x\n")
        XCTAssertEqual(safari.format, .safari)
        XCTAssertEqual(safari.logins.map(\.origin), ["https://example.com/", "https://example.org/"])
        XCTAssertEqual(safari.logins.map(\.username), ["alex", "sam"])
    }

    func testPasswordFilesThatArent() throws {
        XCTAssertThrowsError(try csv("")) { XCTAssertEqual($0 as? ImportError, .invalidPasswordFile) }
        XCTAssertThrowsError(try csv("name,url,username\nx,https://example.com/,alex\n")) { XCTAssertEqual($0 as? ImportError, .invalidPasswordFile) }
        XCTAssertThrowsError(try PasswordCSV.parse(Data([0x75, 0x72, 0x6C, 0x2C, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6F, 0x72, 0x64, 0x0A, 0xFF, 0xFE]))) {
            XCTAssertEqual($0 as? ImportError, .invalidPasswordFile, "not UTF-8")
        }
        // Short rows are counted, never guessed at; an unclosed quote takes the rest of the file as one field.
        let p = try csv("url,username,password\nhttps://example.com/\nhttps://example.org/,a,\"open\n")
        XCTAssertEqual(p.unreadable, 1)
        XCTAssertEqual(p.logins.map(\.password), ["open\n"])
    }

    func testHugePasswordFile() throws {
        var text = "name,url,username,password\n"
        for i in 0..<30_000 { text += "site\(i),https://site\(i).example.com/,user\(i),pw\(i)\n" }
        let started = Date()
        let p = try csv(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(p.logins.count, 30_000)
        XCTAssertEqual(p.duplicates, 0)
    }
}
