// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import AircKit
import AppKit

/// Synthetic Arc and Chrome profiles with search engines (C08b). Made-up sites under `.invalid` (RFC 6761: never
/// resolves), so nothing a check opens leaves the Mac; the picker engines go to the loopback stand-in.
enum ParityC08bFixture {
    static let videoTemplate = "https://video.c08b.invalid/results?q={searchTerms}"
    static let wikiTemplate = "https://wiki.c08b.invalid/w/index.php?search={searchTerms}"

    static let keywordsSchema = """
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

    /// (id, name, keyword, url, safe_for_autoreplace, prepopulate_id, is_active)
    typealias Row = (id: Int, name: String, keyword: String, url: String, safe: Int, prepopulate: Int, active: Int)

    static func insert(_ rows: [Row]) -> String {
        rows.map { r in
            "INSERT INTO keywords(id, short_name, keyword, favicon_url, url, safe_for_autoreplace, prepopulate_id, sync_guid, is_active) "
                + "VALUES(\(r.id), '\(r.name)', '\(r.keyword)', '', '\(r.url)', \(r.safe), \(r.prepopulate), 'guid-\(r.id)', \(r.active));"
        }.joined()
    }

    /// Prepopulated engines, one Chromium added by itself (inactive), one unsafe, and the user's shortcuts.
    static let common: [Row] = [
        (1, "Google", "google.com", "{google:baseURL}search?q={searchTerms}", 1, 1, 0),
        (2, "DuckDuckGo", "duckduckgo.com", "https://duckduckgo.com/?q={searchTerms}", 1, 92, 0),
        (3, "Bing", "bing.com", "https://www.bing.com/search?q={searchTerms}", 1, 3, 0),
        (4, "Auto Site", "auto.c08b.invalid", "https://auto.c08b.invalid/find?q={searchTerms}", 1, 0, 0),
        (5, "Unsafe Sample", "js", "javascript:void(0)//{searchTerms}", 0, 0, 1),
        (6, "Video Sample", "vs", videoTemplate, 0, 0, 1),
        (7, "Wiki Sample", "ws", wikiTemplate, 0, 0, 1),
    ]

    static func writeProfile(_ folder: URL, defaultGUID: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let webData = folder.appendingPathComponent("Web Data")
        try? FileManager.default.removeItem(at: webData)
        _ = try BrowserFixtures.sqlite(webData, keywordsSchema + insert(common))
        let prefsURL = folder.appendingPathComponent("Preferences")
        var prefs = (try? JSONSerialization.jsonObject(with: Data(contentsOf: prefsURL)) as? [String: Any]) ?? [:]
        prefs["default_search_provider"] = ["guid": defaultGUID]
        try JSONSerialization.data(withJSONObject: prefs).write(to: prefsURL)
    }

    /// An Arc folder: Personal (Default) searches DuckDuckGo, Work (Profile 1) a custom engine; no tabs, so switching
    /// Spaces loads nothing.
    static func writeArc(_ root: URL) throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("User Data"), withIntermediateDirectories: true)
        let spaces: [[String: Any]] = [
            ["id": "c08b-personal", "title": "Personal", "profile": ["default": [:]], "containerIDs": []],
            ["id": "c08b-work", "title": "Work", "profile": ["custom": ["_0": ["directoryBasename": "Profile 1"]]], "containerIDs": []],
        ]
        try JSONSerialization.data(withJSONObject: ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": []]]]])
            .write(to: root.appendingPathComponent("StorableSidebar.json"))
        try writeProfile(root.appendingPathComponent("User Data/Default"), defaultGUID: "guid-2")
        try writeProfile(root.appendingPathComponent("User Data/Profile 1"), defaultGUID: "guid-7")
    }
}

/// `--script parityc08b` (C08b; docs/user/search-engine.md), both engines:
///   A. Onboarding's Arc import (Settings → Import runs the same step) brings each profile's default and shortcuts:
///      Personal searches DuckDuckGo, Work its custom engine as a site search made the default; the user's shortcuts
///      become site searches; Chromium's inactive auto-added site and a javascript: engine don't come over (the
///      import's Details say one was left out).
///   B. Settings → Profiles shows each imported default (drawn to parityc08b-profiles(-chromium).png).
///   C. The Command Bar searches with it: ⌘T, “wool”, Return in Personal asks DuckDuckGo (the loopback stand-in); in
///      Work the search row and Return open the custom engine; “vs” + Tab scopes to the imported shortcut. With
///      AIRC_REAL_KEYS=1 the keys are real presses from the UI driver to this app's PID; without, the bar's own typing
///      path (labelled).
///   D. A Chrome import (same code, Chrome's profile folders) sets Bing from Chrome's prepopulated engine.
extension SnapshotRunner {
    func parityC08bScenario() {
        let engineName = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "parityc08b (\(engineName))"
        let root = dir.appendingPathComponent("synthetic-c08b")
        let arc = root.appendingPathComponent("arc")
        var browsers: BrowserFixtures.Written?
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var requests: [String] = []
        var personal = "", work = "", personalSpace = "", workSpace = ""
        func asked(_ prefix: String) -> Bool { lock.withLock { requests.contains { $0.hasPrefix(prefix) } } }
        func openURL(_ r: CommandResult?) -> String? {
            if case .open(let u)? = r?.action { return u.absoluteString }
            return nil
        }

        step { [self] done in
            do {
                try ParityC08bFixture.writeArc(arc)
                browsers = try BrowserFixtures.write(to: root.appendingPathComponent("browsers"), holdHistory: false)
                if let home = browsers?.home {
                    try ParityC08bFixture.writeProfile(home.appendingPathComponent("Library/Application Support/Google/Chrome/Default"), defaultGUID: "guid-3")
                }
            } catch { check(false, "\(tag): synthetic Arc and Chrome folders written (\(error))") }
            OnboardingController.testArcDirectory = arc
            BrowserImportLocator.testHome = browsers?.home
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                lock.withLock { requests.append(req.target) }
                return .init(body: "<!doctype html><title>C08b results</title><p>results</p>")
            }
            server?.start { p in
                port = p ?? 0
                SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
                done()
            }
        }

        // A. The Arc import.
        run { [self] in
            check(port != 0, "\(tag): the loopback stand-in engine listens")
            app?.settings.values.suggestionsEnabled = false   // only the searches themselves reach the stand-in
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30, then: done) }
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "\(tag) A: the import step") }
            check(m.hasArc, "\(tag) A: onboarding reads the synthetic Arc folder")
            let details = m.importChanges.map(\.summary)
            check(details.contains("2 search engines were left out"), "\(tag) A: the Details say the unsafe engine of each profile was left out (\(details))")
            m.includeLogins = false
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done) }
        run { [self] in
            guard let app, let m = app.onboarding?.model, let r = m.result,
                  let p = r.profileIDs["arc-profile:Default"], let w = r.profileIDs["arc-profile:Profile 1"],
                  let ps = r.spaceIDs["arc-space:c08b-personal"], let ws = r.spaceIDs["arc-space:c08b-work"] else {
                return check(false, "\(tag) A: Arc imported with both profiles and Spaces")
            }
            personal = p; work = w; personalSpace = ps; workSpace = ws
            let search = app.settings.values.siteSearch
            check(c.store.profile(p)?.searchEngine == .duckDuckGo && search.defaultSite(for: p) == nil,
                  "\(tag) A: Personal's default is DuckDuckGo, from Arc's prepopulated engine")
            let site = search.defaultSite(for: w)
            check(site?.name == "Wiki Sample" && site?.keyword == "ws" && site?.template == "https://wiki.c08b.invalid/w/index.php?search=%s",
                  "\(tag) A: Work's custom default is its default site search (\(site?.name ?? "none"))")
            let mine = search.searches(for: p).map(\.keyword)
            check(mine.contains("vs") && mine.contains("ws") && !mine.contains("js") && !mine.contains("auto.c08b.invalid"),
                  "\(tag) A: the user's shortcuts come over; Chromium's inactive auto-added site and the javascript: one don't")
            check(mine.count == SiteSearchSettings.defaults.count + 2, "\(tag) A: Airc's seeded sites stay (\(mine.count) site searches)")
            check(m.searchEnginesImported == "2 default search engines · 3 search shortcuts",
                  "\(tag) A: the summary says what came over (\(m.searchEnginesImported ?? "nothing"))")
            check(TestAnchors.frames["onboarding.importedCounts"] != nil, "\(tag) A: the summary line is on screen")
        }
        wait(1.5)   // the accounts step's crossfade
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: app?.engine is WebKitEngine ? "parityc08b-import" : "parityc08b-import-chromium", rounded: 24, done)
        }
        run { [self] in app?.onboarding?.requestClose() }
        wait(0.6)

        // B. Settings → Profiles.
        run { [self] in app?.showSettings(page: .profiles) }
        wait(0.8)
        run { [self] in
            guard let app else { return }
            check(TestAnchors.frames["profile.searchEngine." + personal] != nil && TestAnchors.frames["profile.searchEngine." + work] != nil,
                  "\(tag) B: Settings › Profiles has a search row for each imported profile")
            let subtitle = ProfileSearchRow.subtitle(app.settings.values.siteSearch, profileID: work)
            check(subtitle == "Searching with Wiki Sample, from Site Search.", "\(tag) B: Work's row says \(subtitle ?? "nothing")")
            check(ProfileSearchRow.subtitle(app.settings.values.siteSearch, profileID: personal) == nil && c.store.profile(personal)?.searchEngine == .duckDuckGo,
                  "\(tag) B: Personal's row picks DuckDuckGo")
            if let v = app.settingsWindow?.window.contentView, let img = render(v), let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let name = app.engine is WebKitEngine ? "parityc08b-profiles.png" : "parityc08b-profiles-chromium.png"
                try? png.write(to: dir.appendingPathComponent(name))
                note("wrote \(name)")
            }
            app.settingsWindow?.window.close()
        }

        // C. The Command Bar.
        var realInput = false
        step { [self] done in
            guard UIDriverClient.available else { return done() }
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                realInput = NSApp.isActive && self.c.window.isKeyWindow && self.c.window.isOnActiveSpace
                if !realInput {
                    self.note("FAIL-ENV \(tag): real input needs the window key (active \(NSApp.isActive), key \(self.c.window.isKeyWindow), "
                              + "on active Space \(self.c.window.isOnActiveSpace), front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")); in-app input instead")
                }
                done()
            }
        }
        /// ⌘T and `text` (then `extra` keys, e.g. Tab), real or in-app; calls back with how.
        func typeInNewTabBar(_ text: String, then extra: [String] = [], _ done: @escaping (String) -> Void) {
            let pid = ProcessInfo.processInfo.processIdentifier
            if realInput, let typing = UIDriverClient.keys(typing: text) {
                UIDriverClient.press(["cmd+t"], pid: pid) { _, _ in
                    self.waitUntil({ self.c.commandBar?.mode == .newTab }, timeout: 2) {
                        UIDriverClient.press(typing + extra, pid: pid) { ok, out in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.note("\(tag) C: typed “\(text)” \(extra) (layout \(UIDriverClient.layoutName)): field “\(self.c.commandBar?.fieldText ?? "-")”, driver \(ok) \(out.prefix(60))")
                                done("real keys from the UI driver")
                            }
                        }
                    }
                }
            } else {
                c.openCommandBar(mode: .newTab)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.c.commandBar?.type(text)
                    // Tab as a key reaches the bar: the bar's own field editor (not the window's shared one, which
                    // the bar doesn't use, so nothing was sent: suitereds) runs insertTab: through its delegate chain.
                    if !extra.isEmpty, let b = self.c.commandBar {
                        let ed = (b.window?.firstResponder as? NSTextView) ?? b.fieldEditor
                        ed.doCommand(by: #selector(NSResponder.insertTab(_:)))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done("the bar's typing path, no UI driver") }
                }
            }
        }
        func pressReturn(_ how: String, _ done: @escaping () -> Void) {
            if how.hasPrefix("real") {
                UIDriverClient.press(["return"], pid: ProcessInfo.processInfo.processIdentifier) { _, _ in done() }
            } else {
                if let r = c.commandBar?.results.first(where: { $0.badge == "Search" }) { c.performCommand(r.action, newTab: true, typed: true) }
                done()
            }
        }
        // Personal: DuckDuckGo.
        run { [self] in
            c.closeCommandBar()
            c.switchToSpace(personalSpace, animated: false)
            lock.withLock { requests.removeAll() }
        }
        wait(0.3)
        step { [self] done in
            typeInNewTabBar("wool") { how in
                let row = self.c.commandBar?.results.first { $0.badge == "Search" }
                self.check(openURL(row)?.hasPrefix("http://127.0.0.1:\(port)/duckduckgo.com/?q=wool") == true,
                           "\(tag) C: Personal's search row is DuckDuckGo (\(openURL(row) ?? "-"); \(how))")
                pressReturn(how) {
                    self.waitUntil({ asked("/duckduckgo.com/?q=wool") }, timeout: 10) {
                        self.check(asked("/duckduckgo.com/?q=wool"), "\(tag) C: ⌘T, “wool”, Return in Personal searches DuckDuckGo (\(how))")
                        self.c.closeCommandBar()
                        done()
                    }
                }
            }
        }
        // Personal: the imported shortcut "vs".
        step { [self] done in
            typeInNewTabBar("vs", then: ["tab"]) { how in
                var scoped: String?
                if case .site(let s)? = self.c.commandBar?.scope { scoped = s.keyword }
                self.check(scoped == "vs", "\(tag) C: “vs” + Tab scopes the Command Bar to the imported shortcut (\(scoped ?? "no scope"); \(how))")
                if scoped != "vs", let b = self.c.commandBar {
                    #if AIRC_TESTING
                    let keys = b.keyLog.suffix(6).joined(separator: ",")
                    #else
                    let keys = "-"
                    #endif
                    let vs = self.c.commandBarSiteSearches?.index.searches.filter { $0.keyword == "vs" }.map(\.name) ?? []
                    self.note("\(tag) C: after “vs” + Tab: field “\(b.fieldText)”, typed “\(b.typed)”, candidate \(b.siteCandidate?.keyword ?? "none"), "
                              + "inline \(b.inline.map { "\($0.url)" } ?? "none"), keys [\(keys)], first responder "
                              + "\(b.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-"), vs sites \(vs)")
                }
                self.c.commandBar?.type("wool")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let urls = self.c.commandBar?.results.compactMap { openURL($0) } ?? []
                    self.check(urls.contains("https://video.c08b.invalid/results?q=wool"),
                               "\(tag) C: the scoped search goes to the imported site (\(urls.prefix(3)))")
                    self.c.closeCommandBar()
                    done()
                }
            }
        }
        // Work: the custom default.
        run { [self] in c.switchToSpace(workSpace, animated: false) }
        wait(0.3)
        step { [self] done in
            let before = Set(c.store.state.tabs.keys)
            typeInNewTabBar("wool") { how in
                let row = self.c.commandBar?.results.first { $0.badge == "Search" }
                let want = "https://wiki.c08b.invalid/w/index.php?search=wool"
                self.check(openURL(row) == want, "\(tag) C: Work's search row is its imported engine (“\(row?.title ?? "-")” → \(openURL(row) ?? "-"); \(how))")
                pressReturn(how) {
                    func opened() -> Bool { self.c.store.state.tabs.values.contains { !before.contains($0.id) && $0.url == want } }
                    self.waitUntil(opened, timeout: 5) {
                        self.check(opened() && self.c.store.profile(ofSpace: workSpace).id == work,
                                   "\(tag) C: ⌘T, “wool”, Return in Work opens its imported engine (\(how))")
                        self.c.closeCommandBar()
                        done()
                    }
                }
            }
        }

        // D. Chrome, through the same import.
        run { [self] in app?.startOnboarding(mode: .rerun, atImport: true) }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.installs["chrome"] != nil }, timeout: 30, then: done) }
        run { [self] in app?.onboarding?.model.onSelectSource?(.browser("chrome")) }
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.browserReads["chrome"] != nil && self.app?.onboarding?.model.blueprint != nil }, timeout: 20, then: done)
        }
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.browserReads["chrome"] else { return check(false, "\(tag) D: Chrome read") }
            check(r.searchEngines["chrome-profile:Default"]?.defaultEngine?.known == "bing" && r.profiles.first?.searchEngines == 3,
                  "\(tag) D: Chrome's Default profile brings Bing and its 2 shortcuts (3 engines: \(r.profiles.first?.searchEngines ?? 0))")
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done) }
        run { [self] in
            guard let app, let m = app.onboarding?.model, let r = m.result, let p = r.profileIDs["chrome-profile:Default"] else {
                return check(false, "\(tag) D: Chrome imported")
            }
            check(c.store.profile(p)?.searchEngine == .bing && app.settings.values.siteSearch.searches(for: p).contains { $0.keyword == "vs" },
                  "\(tag) D: the Chrome profile searches Bing and has the “vs” shortcut")
            check(c.store.profile(personal)?.searchEngine == .duckDuckGo, "\(tag) D: Arc's Personal profile keeps DuckDuckGo")
            app.onboarding?.requestClose()
            OnboardingController.testArcDirectory = nil
            BrowserImportLocator.testHome = nil
            SearchEngineStandIn.origin = nil
            server?.stop()
            browsers?.release()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
