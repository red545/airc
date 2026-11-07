// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import Foundation
import SQLite3

/// Synthetic other browsers for automated runs (`--script import-browsers`, the marketing shots): a home folder with a
/// Chrome-layout user-data folder (Local State, Bookmarks JSON, History databases), a Brave profile whose bookmarks
/// are damaged, a Firefox profile (profiles.ini, places.sqlite), a Safari bookmarks export and password CSV files. Only
/// example.com-style names and addresses, and made-up passwords. Never anyone's data.
enum BrowserFixtures {
    struct Written {
        var root: URL
        /// The home folder to detect browsers in (`BrowserImportLocator.testHome`).
        var home: URL
        var bookmarksFile: URL
        var passwordsFile: URL
        var notPasswordsFile: URL
        /// Keeps Chrome's Default History open under SQLite's exclusive lock, as a running Chrome does. Close it with
        /// `release()`.
        var held: OpaquePointer?

        func release() { sqlite3_close(held) }
    }

    /// What the fixture holds, for the checks.
    enum Expect {
        static let chromeBookmarks = (default: 18, work: 8)
        static let chromeFolders = (default: 5, work: 1)
        static let chromeHistory = (default: 240, work: 60)
        static let firefox = (bookmarks: 9, folders: 3, history: 50)
        static let braveHistory = 30
        static let safariFile = (bookmarks: 10, folders: 3)
        /// The CSV: 4 logins, the same site and username again, one without a password, one app login.
        static let passwords = (logins: 4, duplicates: 1, incomplete: 1, notWebsite: 1)
    }

    /// `publicSites`: the marketing shots' variant, whose Chrome bookmarks are well-known public sites (so the preview has
    /// their icons) and whose Brave profile is intact. Still nobody's data.
    static func write(to root: URL, holdHistory: Bool = true, publicSites: Bool = false) throws -> Written {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support")
        func file(_ path: String, _ text: String) throws {
            let url = support.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func json(_ path: String, _ object: Any) throws {
            try file(path, String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
        }
        func node(_ name: String, _ url: String? = nil, _ guid: String, _ children: [Any] = []) -> [String: Any] {
            url.map { ["type": "url", "name": name, "url": $0, "guid": guid, "id": guid] }
                ?? ["type": "folder", "name": name, "guid": guid, "id": guid, "children": children]
        }
        func roots(bar: [Any], other: [Any] = [], synced: [Any] = []) -> [String: Any] {
            ["version": 1, "checksum": "0", "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar", "children": bar],
                "other": ["type": "folder", "name": "Other bookmarks", "children": other],
                "synced": ["type": "folder", "name": "Mobile bookmarks", "children": synced],
            ]]
        }
        let now = Date()
        func chromeTime(_ secondsAgo: Double) -> Int64 { Int64((now.timeIntervalSince1970 - secondsAgo + 11_644_473_600) * 1_000_000) }
        let history = "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);"
        func historyRows(_ count: Int, host: String, offset: Int = 0) -> String {
            let rows = (0..<count).map { i -> String in
                "(\(offset + i + 1),'https://\(host)/page/\(i)','\(host.capitalized) page \(i)',\(1 + i % 9),\(i % 4 == 0 ? 1 : 0),\(chromeTime(Double(i) * 1800)),0)"
            }
            return "INSERT INTO urls VALUES " + rows.joined(separator: ",") + ";"
        }

        // Chrome: two profiles (one with Chrome's default name), and a third listed without a folder.
        try json("Google/Chrome/Local State", ["profile": [
            "profiles_order": ["Default", "Profile 1", "Profile 2"],
            "info_cache": [
                "Default": ["name": "Person 1", "is_using_default_name": true, "profile_highlight_color": -11_097_651],
                "Profile 1": ["name": "Work", "is_using_default_name": false, "default_avatar_fill_color": -2_354_116],
                "Profile 2": ["name": "Gone", "is_using_default_name": false],
            ],
        ]])
        let pages = ["Example", "Docs", "Mail", "Calendar", "Notes", "Photos"]
        let sites = [("GitHub", "https://github.com/"), ("Wikipedia", "https://en.wikipedia.org/"), ("Figma", "https://www.figma.com/"),
                     ("Notion", "https://www.notion.so/"), ("The Verge", "https://www.theverge.com/"), ("Apple", "https://www.apple.com/")]
        let bar = publicSites ? sites : pages.map { ($0, "https://\($0.lowercased()).example.com/") }
        try json("Google/Chrome/Default/Bookmarks", roots(bar: bar.enumerated().map { node($1.0, $1.1, "c-bar-\($0)") } + [
            node("Reading", nil, "c-reading", publicSites
                ? [("Lisbon – Wikipedia", "https://en.wikipedia.org/wiki/Lisbon"), ("Kyoto – Wikivoyage", "https://en.wikivoyage.org/wiki/Kyoto"),
                   ("Bauhaus – Wikipedia", "https://en.wikipedia.org/wiki/Bauhaus")].enumerated().map { node($1.0, $1.1, "c-read-\($0)") }
                : (0..<3).map { node("Article \($0 + 1)", "https://read.example.org/\($0 + 1)", "c-read-\($0)") }),
            node("Projects", nil, "c-projects", [
                node("Archive", nil, "c-archive", (0..<2).map { node("Old project \($0 + 1)", "https://archive.example.net/\($0 + 1)", "c-arch-\($0)") }),
                node("Roadmap", "https://plan.example.com/roadmap", "c-roadmap"),
            ]),
        ] + (publicSites ? [] : [node("Bookmarklet", "javascript:void(0)", "c-js")]), other: (0..<4).map { node("Saved \($0 + 1)", "https://saved.example.com/\($0 + 1)", "c-other-\($0)") },
           synced: (0..<2).map { node("Phone \($0 + 1)", "https://m.example.com/\($0 + 1)", "c-mobile-\($0)") }))
        try json("Google/Chrome/Profile 1/Bookmarks", roots(bar: (0..<5).map { node("Tool \($0 + 1)", "https://tools.example.com/\($0 + 1)", "w-bar-\($0)") } + [
            node("Team", nil, "w-team", (0..<3).map { node("Team page \($0 + 1)", "https://team.example.org/\($0 + 1)", "w-team-\($0)") }),
        ]))
        _ = try sqlite(support.appendingPathComponent("Google/Chrome/Profile 1/History"), history + historyRows(60, host: "work.example.com"))
        let held = try sqlite(support.appendingPathComponent("Google/Chrome/Default/History"),
                              (holdHistory ? "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA locking_mode=EXCLUSIVE;" : "") + history
                              + historyRows(240, host: "example.com")
                              + "INSERT INTO urls VALUES(900,'https://hidden.example.com/','Hidden',3,0,\(chromeTime(1)),1);"
                              + "INSERT INTO urls VALUES(901,'chrome://settings/','Settings',3,0,\(chromeTime(1)),0);",
                              keepOpen: holdHistory)

        // Brave: damaged bookmarks, good history.
        if publicSites {
            try json("BraveSoftware/Brave-Browser/Default/Bookmarks", roots(bar: [node("Search", "https://search.brave.com/", "b-1")]))
        } else {
            try file("BraveSoftware/Brave-Browser/Default/Bookmarks", "{ \"roots\": [ this isn't JSON")
        }
        _ = try sqlite(support.appendingPathComponent("BraveSoftware/Brave-Browser/Default/History"), history + historyRows(30, host: "brave.example.net"))

        // Firefox: one profile.
        try file("Firefox/profiles.ini", "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/fx01.default-release\nDefault=1\n\n[General]\nVersion=2\n")
        let firefoxNow = Int64(now.timeIntervalSince1970 * 1_000_000)
        var places = """
            CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, typed INTEGER, last_visit_date INTEGER);
            CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
            INSERT INTO moz_bookmarks VALUES(1,2,NULL,0,0,'','root________');
            INSERT INTO moz_bookmarks VALUES(2,2,NULL,1,0,'menu','menu________');
            INSERT INTO moz_bookmarks VALUES(3,2,NULL,1,1,'toolbar','toolbar_____');
            INSERT INTO moz_bookmarks VALUES(4,2,NULL,1,2,'tags','tags________');
            INSERT INTO moz_bookmarks VALUES(5,2,NULL,1,3,'unfiled','unfiled_____');
            INSERT INTO moz_bookmarks VALUES(6,2,NULL,1,4,'mobile','mobile______');
            INSERT INTO moz_bookmarks VALUES(20,2,NULL,3,4,'Recipes','fx-recipes01');

            """
        let marks: [(parent: Int, title: String, url: String)] = [
            (3, "Fox start", "https://start.example.org/"), (3, "Fox news", "https://news.example.org/"), (3, "Fox maps", "https://maps.example.org/"),
            (3, "Fox wiki", "https://wiki.example.org/"), (20, "Soup", "https://cook.example.com/soup"), (20, "Bread", "https://cook.example.com/bread"),
            (2, "Menu one", "https://menu.example.net/1"), (2, "Menu two", "https://menu.example.net/2"), (5, "Unfiled", "https://unfiled.example.net/"),
        ]
        for (i, m) in marks.enumerated() {
            places += "INSERT INTO moz_places VALUES(\(100 + i),'\(m.url)','\(m.title)',0,0,0,NULL);"
            places += "INSERT INTO moz_bookmarks VALUES(\(30 + i),1,\(100 + i),\(m.parent),\(i),'\(m.title)','fx-mark-\(String(format: "%03d", i))');"
        }
        for i in 0..<50 {
            places += "INSERT INTO moz_places VALUES(\(500 + i),'https://fox.example.org/visit/\(i)','Fox page \(i)',\(1 + i % 5),0,\(i % 3 == 0 ? 1 : 0),\(firefoxNow - Int64(i) * 60_000_000));"
        }
        _ = try sqlite(support.appendingPathComponent("Firefox/Profiles/fx01.default-release/places.sqlite"), places)

        // Safari's File → Export → Bookmarks…
        let bookmarksFile = root.appendingPathComponent("Safari Bookmarks.html")
        try Data("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            \t<HTML>
            \t<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            \t<Title>Bookmarks</Title>
            \t<H1>Bookmarks</H1>
            \t<DT><H3 FOLDED>Favorites</H3>
            \t<DL><p>
            \t\t<DT><A HREF="https://apple.example.com/">Apple-ish</A>
            \t\t<DT><A HREF="https://maps.example.com/">Maps</A>
            \t\t<DT><A HREF="https://music.example.com/">Music</A>
            \t\t<DT><A HREF="https://weather.example.com/">Weather</A>
            \t\t<DT><A HREF="https://shop.example.com/?a=1&amp;b=2">Shop &amp; more</A>
            \t\t<DT><H3 FOLDED>News</H3>
            \t\t<DL><p>
            \t\t\t<DT><A HREF="https://news.example.com/world">World</A>
            \t\t\t<DT><A HREF="https://news.example.com/science">Science</A>
            \t\t</DL><p>
            \t</DL><p>
            \t<DT><H3 FOLDED>Bookmarks Menu</H3>
            \t<DL><p>
            \t\t<DT><A HREF="https://menu.example.org/">Menu link</A>
            \t</DL><p>
            \t<DT><H3 id="com.apple.ReadingList">Reading List</H3>
            \t<DL><p>
            \t\t<DT><A HREF="https://read.example.net/1">Long read</A>
            \t\t<DT><A HREF="https://read.example.net/2">Another read</A>
            \t</DL><p>
            </HTML>
            """.utf8).write(to: bookmarksFile)

        // Chrome's Export passwords, made up.
        let passwordsFile = root.appendingPathComponent("Chrome Passwords.csv")
        try Data(passwordsCSV.utf8).write(to: passwordsFile)
        let notPasswordsFile = root.appendingPathComponent("Not Passwords.csv")
        try Data("name,url,username\nExample,https://example.com/,alex\n".utf8).write(to: notPasswordsFile)
        return Written(root: root, home: home, bookmarksFile: bookmarksFile, passwordsFile: passwordsFile, notPasswordsFile: notPasswordsFile,
                       held: held)
    }

    static let passwordsCSV = #"""
        name,url,username,password,note
        one.example,https://one.example/login,synthetic-1,made-up-1,
        two.example,https://two.example/,synthetic-2,"made, up ""2""",
        three.example,https://three.example/,synthetic-3,"made
        up 3",
        four.example,https://four.example:8443/signin,synthetic-4,made-up-4,
        one.example,https://one.example/login,synthetic-1,made-up-again,
        five.example,https://five.example/,synthetic-5,,
        app,android://hash@app.example/,synthetic-6,made-up-6,

        """#

    /// Creates a database and runs `sql`; with `keepOpen` its connection (and locks) stay with the caller.
    static func sqlite(_ url: URL, _ sql: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw NSError(domain: "BrowserFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }
}
#endif
