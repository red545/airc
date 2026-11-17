// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
import XCTest
import CArcCrypto
import AircKit
@testable import AircImport

/// C08b: Chromium-family search engines (`Web Data` keywords + `Preferences`), on synthetic profiles only: made-up
/// engines on example domains, the picker's engines by their public addresses. Never a real browser's files.
final class SearchEngineTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    var profile: URL { root.appendingPathComponent("Profile") }
    var temp: URL { root.appendingPathComponent("tmp") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("airc-engines-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Chromium 156's `keywords` table (components/search_engines/keyword_table.cc).
    static let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        CREATE TABLE keywords (id INTEGER PRIMARY KEY, short_name VARCHAR NOT NULL, keyword VARCHAR NOT NULL,
          favicon_url VARCHAR NOT NULL, url VARCHAR NOT NULL, safe_for_autoreplace INTEGER, originating_url VARCHAR,
          date_created INTEGER DEFAULT 0, usage_count INTEGER DEFAULT 0, input_encodings VARCHAR, suggest_url VARCHAR,
          prepopulate_id INTEGER DEFAULT 0, created_by_policy INTEGER DEFAULT 0, last_modified INTEGER DEFAULT 0,
          sync_guid VARCHAR, alternate_urls VARCHAR, image_url VARCHAR, search_url_post_params VARCHAR,
          suggest_url_post_params VARCHAR, image_url_post_params VARCHAR, new_tab_url VARCHAR, last_visited INTEGER DEFAULT 0,
          created_from_play_api INTEGER DEFAULT 0, is_active INTEGER DEFAULT 0, starter_pack_id INTEGER DEFAULT 0,
          enforced_by_policy INTEGER DEFAULT 0, featured_by_policy INTEGER DEFAULT 0, url_hash BLOB);
        """

    struct K {
        var id: Int, name: String, keyword: String, url: String
        var safe = 0, prepopulate = 0, guid: String? = nil, active = 1, starter = 0, policy = 0, suggest = ""
    }

    static func insert(_ k: K) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return """
            INSERT INTO keywords(id, short_name, keyword, favicon_url, url, safe_for_autoreplace, prepopulate_id, sync_guid,
              is_active, starter_pack_id, created_by_policy, suggest_url)
            VALUES(\(k.id), \(q(k.name)), \(q(k.keyword)), '', \(q(k.url)), \(k.safe), \(k.prepopulate), \(q(k.guid ?? "guid-\(k.id)")),
              \(k.active), \(k.starter), \(k.policy), \(q(k.suggest)));
            """
    }

    /// Prepopulated engines, the starter pack, an engine Chromium added by itself, one the user switched off, one from
    /// policy, and the user's own shortcuts.
    static let standard: [K] = [
        K(id: 1, name: "Google", keyword: "google.com", url: "{google:baseURL}search?q={searchTerms}&{google:RLZ}ie={inputEncoding}", safe: 1, prepopulate: 1),
        K(id: 2, name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q={searchTerms}", safe: 1, prepopulate: 92),
        K(id: 3, name: "Bing", keyword: "bing.com", url: "https://www.bing.com/search?q={searchTerms}", safe: 1, prepopulate: 3),
        K(id: 4, name: "Bookmarks", keyword: "@bookmarks", url: "chrome://bookmarks/?q={searchTerms}", safe: 1, starter: 1),
        K(id: 5, name: "Auto Site", keyword: "auto.example.com", url: "https://auto.example.com/find?q={searchTerms}", safe: 1, active: 0),
        K(id: 6, name: "Switched Off", keyword: "off", url: "https://off.example.com/?q={searchTerms}", active: 2),
        K(id: 7, name: "Policy Engine", keyword: "corp", url: "https://corp.example.com/?q={searchTerms}", policy: 1),
        K(id: 8, name: "Video Sample", keyword: "vs", url: "https://video.example.com/results?search_query={searchTerms}"),
        K(id: 9, name: "Wiki Sample", keyword: "ws", url: "https://wiki.example.org/w/index.php?search={searchTerms}&ie={inputEncoding}"),
        // Chromium added it, then the user activated it: Arc's settings listed it with the active shortcuts.
        K(id: 10, name: "Activated Site", keyword: "act", url: "https://act.example.net/s/{searchTerms}", safe: 1, active: 1),
    ]

    func webData(_ rows: [K], meta: [String: String] = [:], locked: Bool = false) throws -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(profile.appendingPathComponent("Web Data").path, &db), SQLITE_OK)
        let sql = Self.schema + rows.map(Self.insert).joined()
            + meta.map { "INSERT INTO meta VALUES('\($0.key)', '\($0.value)');" }.joined()
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        if locked {
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)
            return db
        }
        sqlite3_close(db)
        return nil
    }

    func preferences(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: profile.appendingPathComponent("Preferences"))
    }

    func read() throws -> ImportedSearchEngines? { try ChromiumSearchEngines.read(profile: profile, tempRoot: temp) }

    // MARK: Defaults

    func testKnownDefaultByPrepopulateID() throws {
        try webData(Self.standard)
        try preferences(["default_search_provider": ["guid": "guid-2"]])
        let e = try XCTUnwrap(try read())
        XCTAssertEqual(e.defaultEngine?.known, "duckDuckGo")
        XCTAssertEqual(e.defaultEngine?.template, "", "a picker engine uses Airc's own address")
        XCTAssertEqual(e.custom.map(\.keyword), ["vs", "ws", "act"], "only the user's own shortcuts")
        XCTAssertEqual(e.rejected, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [], "the private copy is deleted")
    }

    func testGoogleDefaultWithChromiumPlaceholders() throws {
        try webData(Self.standard)
        try preferences(["default_search_provider": ["guid": "guid-1"]])
        XCTAssertEqual(try read()?.defaultEngine?.known, "google")
    }

    func testKnownDefaultByHostWithoutKnownID() throws {
        // Brave numbers its prepopulated engines its own way; the address still says which engine it is.
        try webData([K(id: 1, name: "Brave", keyword: ":br", url: "https://search.brave.com/search?q={searchTerms}", safe: 1, prepopulate: 550, guid: "b")])
        try preferences(["default_search_provider": ["guid": "b"]])
        XCTAssertEqual(try read()?.defaultEngine?.known, "brave")
    }

    func testCustomDefault() throws {
        try webData(Self.standard)
        try preferences(["default_search_provider": ["guid": "guid-9"]])
        let e = try XCTUnwrap(try read())
        XCTAssertNil(e.defaultEngine?.known)
        XCTAssertEqual(e.defaultEngine?.name, "Wiki Sample")
        XCTAssertEqual(e.defaultEngine?.keyword, "ws")
        XCTAssertEqual(e.defaultEngine?.template, "https://wiki.example.org/w/index.php?search=%s&ie=UTF-8")
        XCTAssertEqual(e.custom.map(\.keyword), ["vs", "act"], "the default isn't listed twice")
    }

    // MARK: Suggestion endpoints (cbfixes)

    func testSuggestURLsComeAlong() throws {
        try webData([
            K(id: 1, name: "Sample Search", keyword: "ss", url: "https://search.example.com/find?q={searchTerms}", guid: "d",
              suggest: "https://suggest.example.com/complete?q={searchTerms}&ie={inputEncoding}"),
            K(id: 2, name: "Video Sample", keyword: "vs", url: "https://video.example.com/results?search_query={searchTerms}",
              suggest: "https://video.example.com/sugg/{searchTerms}"),
            K(id: 3, name: "No Suggest", keyword: "ns", url: "https://none.example.com/?q={searchTerms}"),
            // Not kept: in the clear, a script, the query in the host, a placeholder Airc can't fill.
            K(id: 4, name: "Plain", keyword: "pl", url: "https://plain.example.com/?q={searchTerms}", suggest: "http://plain.example.com/s?q={searchTerms}"),
            K(id: 5, name: "Script", keyword: "sc", url: "https://script.example.com/?q={searchTerms}", suggest: "javascript:alert('{searchTerms}')"),
            K(id: 6, name: "Host", keyword: "ho", url: "https://host.example.com/?q={searchTerms}", suggest: "https://{searchTerms}.example.com/"),
            K(id: 7, name: "Other", keyword: "ot", url: "https://other.example.com/?q={searchTerms}", suggest: "https://other.example.com/s?q={searchTerms}&c={google:clientName}"),
            // A picker engine's own copy isn't used: Airc asks DuckDuckGo at its own address.
            K(id: 8, name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q={searchTerms}", safe: 1, prepopulate: 92,
              suggest: "https://duckduckgo.com/ac/?q={searchTerms}&type=list"),
        ])
        try preferences(["default_search_provider": ["guid": "d"]])
        let e = try XCTUnwrap(try read())
        XCTAssertEqual(e.defaultEngine?.suggest, "https://suggest.example.com/complete?q=%s&ie=UTF-8")
        let byKey = Dictionary(uniqueKeysWithValues: e.custom.map { ($0.keyword, $0.suggest) })
        XCTAssertEqual(byKey["vs"], .some("https://video.example.com/sugg/%s"))
        for k in ["ns", "pl", "sc", "ho", "ot"] { XCTAssertEqual(byKey[k], .some(nil), k) }
        XCTAssertNil(byKey["duckduckgo.com"], "a prepopulated engine that isn't the default stays out")
    }

    func testPickerDefaultHasNoSuggestEndpoint() throws {
        try webData([K(id: 1, name: "DuckDuckGo", keyword: "duckduckgo.com", url: "https://duckduckgo.com/?q={searchTerms}", safe: 1,
                       prepopulate: 92, guid: "d", suggest: "https://duckduckgo.com/ac/?q={searchTerms}&type=list")])
        try preferences(["default_search_provider": ["guid": "d"]])
        let e = try XCTUnwrap(try read())
        XCTAssertEqual(e.defaultEngine?.known, "duckDuckGo")
        XCTAssertNil(e.defaultEngine?.suggest)
    }

    func testSavedDefaultDataCarriesSuggestURL() throws {
        try preferences(["default_search_provider_data": ["template_url_data": [
            "short_name": "Gone Sample", "keyword": "gone", "url": "https://gone.example.com/search?q={searchTerms}",
            // Chromium's DefaultSearchManager::kSuggestionsURL.
            "suggestions_url": "https://gone.example.com/ac?q={searchTerms}",
            "prepopulate_id": 0, "synced_guid": "not-in-table"]]])
        XCTAssertEqual(try read()?.defaultEngine?.suggest, "https://gone.example.com/ac?q=%s")
    }

    func testDefaultFromSavedDataWhenRowIsGone() throws {
        try webData(Self.standard)
        try preferences(["default_search_provider_data": ["template_url_data": [
            "short_name": "Gone Sample", "keyword": "gone", "url": "https://gone.example.com/search?q={searchTerms}",
            "prepopulate_id": 0, "synced_guid": "not-in-table"]]])
        let e = try XCTUnwrap(try read())
        XCTAssertEqual(e.defaultEngine?.template, "https://gone.example.com/search?q=%s")
        XCTAssertEqual(e.defaultEngine?.keyword, "gone")
    }

    func testDefaultFromMetaInOldProfiles() throws {
        try webData(Self.standard, meta: ["Default Search Provider ID": "3"])
        XCTAssertEqual(try read()?.defaultEngine?.known, "bing")
    }

    func testNoChoiceLeavesDefaultUnset() throws {
        try webData(Self.standard)
        let e = try XCTUnwrap(try read())
        XCTAssertNil(e.defaultEngine, "Chromium's region default isn't a choice the user made")
        XCTAssertEqual(e.custom.count, 3)
    }

    func testPolicyDefaultIsNotImported() throws {
        try webData(Self.standard)
        try preferences(["default_search_provider": ["guid": "guid-7"]])
        XCTAssertNil(try read()?.defaultEngine)
    }

    // MARK: Safety

    func testInvalidTemplatesRejected() throws {
        let bad = [
            "javascript:alert(document.cookie)//{searchTerms}", "http://plain.example.com/?q={searchTerms}",
            "https://nowords.example.com/search", "data:text/html,{searchTerms}", "https://{searchTerms}.example.com/",
            "https://odd.example.com/?q={searchTerms}&x={google:unknownThing}", "file:///etc/{searchTerms}",
            "https://user@login.example.com/?q={searchTerms}", "https://sp ace.example.com/?q={searchTerms}",
            "https://pct.example.com/?q=%s&r={searchTerms}", "https:///?q={searchTerms}",
        ]
        try webData(bad.enumerated().map { K(id: $0.offset + 1, name: "Bad \($0.offset)", keyword: "b\($0.offset)", url: $0.element) }
                    + [K(id: 99, name: "Good", keyword: "good", url: "HTTPS://good.example.com/?q={searchTerms}")])
        try preferences(["default_search_provider": ["guid": "guid-1"]])
        let e = try XCTUnwrap(try read())
        XCTAssertNil(e.defaultEngine, "a javascript: default is never kept")
        XCTAssertEqual(e.custom.map(\.template), ["https://good.example.com/?q=%s"])
        XCTAssertEqual(e.rejected, bad.count)
        for t in bad { XCTAssertNil(ChromiumSearchEngines.template(t), t) }
    }

    func testDuplicateKeywordsKeepTheFirst() throws {
        try webData([K(id: 1, name: "One", keyword: "dup", url: "https://one.example.com/?q={searchTerms}"),
                     K(id: 2, name: "Two", keyword: "DUP", url: "https://two.example.com/?q={searchTerms}")])
        XCTAssertEqual(try read()?.custom.map(\.name), ["One"])
    }

    // MARK: Files

    func testMissingFiles() throws {
        XCTAssertNil(try read(), "no Web Data and no Preferences: nothing to bring")
        try preferences(["default_search_provider_data": ["template_url_data": [
            "short_name": "DuckDuckGo", "keyword": "duckduckgo.com", "url": "https://duckduckgo.com/?q={searchTerms}", "prepopulate_id": 92]]])
        XCTAssertEqual(try read()?.defaultEngine?.known, "duckDuckGo", "Preferences alone still says the default")
    }

    func testDamagedWebDataThrows() throws {
        try Data("not a database".utf8).write(to: profile.appendingPathComponent("Web Data"))
        XCTAssertThrowsError(try read())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    func testLockedWebDataIsReadFromACopy() throws {
        let db = try webData(Self.standard, locked: true)
        defer { sqlite3_close(db) }
        try preferences(["default_search_provider": ["guid": "guid-8"]])
        var reader: OpaquePointer?
        sqlite3_open_v2(profile.appendingPathComponent("Web Data").path, &reader, SQLITE_OPEN_READONLY, nil)
        XCTAssertEqual(sqlite3_exec(reader, "SELECT count(*) FROM keywords", nil, nil, nil), SQLITE_BUSY, "a direct reader is locked out")
        sqlite3_close(reader)
        let e = try XCTUnwrap(try read())
        XCTAssertEqual(e.defaultEngine?.keyword, "vs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.path), [])
    }

    /// Every engine the importer can name is one Airc's picker has.
    func testKnownEnginesAreAircEngines() {
        for raw in Set(ChromiumSearchEngines.prepopulated.values).union(ChromiumSearchEngines.pages.map(\.engine)) {
            XCTAssertNotNil(SearchEngine(rawValue: raw), raw)
        }
    }

    // MARK: Through the importers

    func testArcPlanCarriesEachProfilesEngines() async throws {
        let arc = root.appendingPathComponent("Arc")
        try FileManager.default.createDirectory(at: arc.appendingPathComponent("User Data"), withIntermediateDirectories: true)
        let fixture = Bundle.module.url(forResource: "StorableSidebar.sample", withExtension: "json", subdirectory: "Fixtures")!
        try FileManager.default.copyItem(at: fixture, to: arc.appendingPathComponent("StorableSidebar.json"))
        try webData(Self.standard)
        try preferences(["default_search_provider": ["guid": "guid-9"]])
        try FileManager.default.moveItem(at: profile, to: arc.appendingPathComponent("User Data/Default"))
        let plan = try await ArcImporter.plan(at: arc, tempRoot: temp)
        let e = try XCTUnwrap(plan.searchEngines?["default"])
        XCTAssertEqual(e.defaultEngine?.keyword, "ws")
        let mapped = plan.mappedSearchEngines(profileIDs: ["arc-profile:Default": "airc-1"])
        XCTAssertEqual(mapped.keys.sorted(), ["airc-1"])
        XCTAssertFalse(plan.warnings.contains { $0.code == .unreadableSearchEngines || $0.code == .unsafeSearchEngine })
    }

    func testChromeReadCarriesEngines() async throws {
        let support = root.appendingPathComponent("Library/Application Support")
        let chrome = support.appendingPathComponent("Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": ["Default": ["name": "Person 1"]]]])
            .write(to: chrome.appendingPathComponent("Local State"))
        try webData(Self.standard + [K(id: 50, name: "Unsafe", keyword: "js", url: "javascript:void({searchTerms})")])
        try preferences(["default_search_provider": ["guid": "guid-2"]])
        try JSONSerialization.data(withJSONObject: ["roots": ["bookmark_bar": ["type": "folder", "children": []]]])
            .write(to: profile.appendingPathComponent("Bookmarks"))
        try FileManager.default.moveItem(at: profile, to: chrome.appendingPathComponent("Default"))
        let install = try XCTUnwrap(BrowserImporter.detect(home: root).first)
        let r = try await BrowserImporter.read(install, tempRoot: temp)
        let e = try XCTUnwrap(r.searchEngines["chrome-profile:Default"])
        XCTAssertEqual(e.defaultEngine?.known, "duckDuckGo")
        XCTAssertEqual(e.custom.count, 3)
        XCTAssertEqual(r.profiles.first?.searchEngines, 4)
        XCTAssertEqual(r.plan.warnings.filter { $0.code == .unsafeSearchEngine }.count, 1)
        let words = r.plan.warnings.map(\.message).joined(separator: " ")
        XCTAssertFalse(words.contains("example") || words.contains("javascript:void"), "warnings carry no address")
    }
}
