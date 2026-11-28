// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import SQLite3

/// `--script cmdtrust`: the Command Bar's site rows (cmdtrust, owner feedback 2026-11-10: "grey squares, more trust").
/// Synthetic history only: the Chrome Web Store, a store page, a lookalike host, the store over http, a news site whose
/// icon is only in a (synthetic) engine favicon database, and a loopback page opened once so its tab's icon is kept.
/// 1. Icons: no site row shows the blank placeholder; the loopback page's row shows the icon its tab had (Airc's store,
///    read back from disk), the news site's the engine database's; nothing reaches the network while typing.
/// 2. Trust: the mark and "Supported in Airc" on exactly the real store's https rows; never on the lookalike or http.
/// 3. Kinds: unselected site rows say "Website"; the selected row shows its action instead.
/// 4. A private window: letter tiles only (no store or database read), the same marks from the bundled list.
extension SnapshotRunner {
    func cmdTrustScenario() {
        let tag = app?.engine.name.hasPrefix("Chromium") == true ? "chromium" : "webkit"
        var pid = ""
        var server: LocalPageServer?
        var port: UInt16 = 0
        var fixtureTab: String?
        let dbDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmdtrust-\(UUID().uuidString)")
        let db = dbDir.appendingPathComponent("Favicons")
        let bar = { self.c.commandBar }
        let store = "https://chromewebstore.google.com/"
        let storePage = "https://chromewebstore.google.com/detail/1password-password-manager/aeblfdkhhhdcdjpifhhbdiojplfjncoa"
        let lookalike = "https://chromewebstore.google.com.evil.example/detail/free-vpn"
        let httpStore = "http://chromewebstore.google.com/category/extensions"
        let news = "https://www.derstandard.at/"
        func fixture() -> String { "http://127.0.0.1:\(port)/trust-fixture" }

        func say(_ ok: Bool, _ what: String) { check(ok, "cmdtrust (\(tag)): " + what) }
        func describe(_ b: CommandBarView?) -> String {
            guard let b else { return "no bar" }
            return zip(b.results, b.rowViewsForTesting).map { r, v in
                "\(r.title) [\(v.iconStateForTesting)\(v.sealShownForTesting ? " ✓" : "")] {\(v.subtitleForTesting)} <\(v.kindForTesting)>"
            }.joined(separator: " | ")
        }
        func row(_ b: CommandBarView?, page: String) -> (CommandResult, CommandRowView)? {
            guard let b else { return nil }
            return zip(b.results, b.rowViewsForTesting).first { $0.0.page == page }
        }
        func sitePage(_ r: CommandResult) -> Bool {
            switch r.icon {
            case .symbol, .emoji: return false
            default: return r.page.map { $0.hasPrefix("http") } ?? false
            }
        }
        func isRealStore(_ page: String) -> Bool {
            let u = URLComponents(string: page)
            return u?.scheme == "https" && u?.host == "chromewebstore.google.com"
        }
        /// Types `q` into the main window's bar (opening it fresh) and waits for history, icons and the database.
        func type(_ q: String, wait: Double = 1.2) {
            step { [self] done in
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
                bar()?.type(q)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { done() }
            }
        }

        // Setup: a loopback page with its own icon, the history, the synthetic engine database.
        step { [self] done in
            pid = c.store.profile(ofSpace: c.currentSpaceID).id
            let png = Self.cmdTrustPNG(NSColor(srgbRed: 0.85, green: 0.25, blue: 0.2, alpha: 1))
            server = LocalPageServer(responses: [
                "/trust-fixture": .init(body: "<!doctype html><html><head><title>Trust Fixture page</title>"
                                        + "<link rel=\"icon\" type=\"image/png\" href=\"/fixture-icon.png\"></head><body><h1>Fixture</h1></body></html>"),
                "/fixture-icon.png": .init(headers: ["Content-Type": "image/png"], body: "", data: png),
            ])
            server?.start { p in
                port = p ?? 0
                done()
            }
        }
        run { [self] in
            say(port != 0, "the loopback fixture server listens")
            guard let h = c.app?.history else { return say(false, "history store") }
            for (url, title) in [(store, "Chrome Web Store"),
                                 (storePage, "1Password – Password Manager – Chrome Web Store"),
                                 (lookalike, "Chrome Web Store – Free VPN extension"),
                                 (httpStore, "Chrome Web Store – Extensions (http)"),
                                 (news, "derStandard.at – Nachrichten in Echtzeit")] {
                for _ in 0..<3 { h.recordVisit(profileID: pid, url: url, title: title, typed: true) }
            }
            do {
                try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
                try Self.cmdTrustWriteFaviconDB(db, page: news, png: Self.cmdTrustPNG(NSColor(srgbRed: 0.2, green: 0.35, blue: 0.75, alpha: 1)))
                say(true, "a synthetic engine favicon database with derstandard.at's icon")
            } catch {
                say(false, "a synthetic engine favicon database (\(error))")
            }
            SiteIcons.databaseOverrideForTesting = db
            // The database reader on its own: the news site's icon, nothing for the store.
            let read = SiteIcons.readEngineIcons(["derstandard.at", "chromewebstore.google.com"], database: db)
            say(read["derstandard.at"] != nil && read["chromewebstore.google.com"] == nil,
                "the engine favicon database answers by site (\(read.keys.sorted()))")
            c.navigate(to: URL(string: fixture())!, newTab: true)
            fixtureTab = c.shownTabID
        }
        // The fixture page's tab shows its icon: Airc keeps it for the site.
        step { [self] done in
            waitUntil({ SiteIcons.shared.cached(page: fixture()) != nil }, timeout: 15) { done() }
        }
        run { [self] in
            say(SiteIcons.shared.cached(page: fixture()) != nil, "a page's icon in a normal window is kept for its site")
            if let id = fixtureTab { c.closeTab(id) }
            c.app?.history.recordVisit(profileID: pid, url: fixture(), title: "Trust Fixture page", typed: true)
            c.app?.history.prepareIndex(profileID: pid)
            // From disk from now on, as after a relaunch.
            SiteIcons.shared.forgetMemoryForTesting()
            FaviconCache.shared.forgetMemoryForTesting()
        }
        wait(1.0)

        // "chrome": the owner's screenshot.
        var requestsBefore = 0
        run { requestsBefore = FaviconCache.shared.networkRequests.count }
        type("chrome")
        run { [self] in
            let b = bar()
            let text = describe(b)
            note("cmdtrust (\(tag)): \"chrome\" rows: " + text)
            let views = b?.rowViewsForTesting ?? []
            let sites = zip(b?.results ?? [], views).filter { sitePage($0.0) }
            say(!sites.isEmpty && sites.allSatisfy { ["image", "tile"].contains($0.1.iconStateForTesting) },
                "no site row shows a blank square (\(text))")
            if case let (_, v)? = row(b, page: store) {
                say(v.sealShownForTesting && (v.subtitleForTesting == "chromewebstore.google.com · Supported in Airc"
                                              || v.subtitleForTesting == "Chrome Web Store · Supported in Airc"),
                    "the store's row has the mark and \"… · Supported in Airc\" ({\(v.subtitleForTesting)})")
            } else { say(false, "the store's row shows (\(text))") }
            if case let (_, v)? = row(b, page: storePage) {
                say(v.sealShownForTesting && v.subtitleForTesting.hasSuffix("Supported in Airc"), "a store page's row has the mark")
            } else { say(false, "the store page's row shows (\(text))") }
            if case let (_, v)? = row(b, page: lookalike) {
                say(!v.sealShownForTesting && v.subtitleForTesting.contains("chromewebstore.google.com.evil.example"),
                    "the lookalike has no mark and shows its whole host ({\(v.subtitleForTesting)})")
            } else { say(false, "the lookalike's row shows (\(text))") }
            if case let (_, v)? = row(b, page: httpStore) {
                say(!v.sealShownForTesting, "the store over http has no mark")
            }
            let marked = zip(b?.results ?? [], views).filter { $0.1.sealShownForTesting }.compactMap { $0.0.page }
            say(!marked.isEmpty && marked.allSatisfy { OfficialSites.match($0) != nil && isRealStore($0) },
                "the mark is on exactly the real store's rows (\(marked))")
            let unselectedSites = zip(b?.results ?? [], views).dropFirst().filter { $0.0.badge == "Open" && sitePage($0.0) }
            say(!unselectedSites.isEmpty && unselectedSites.allSatisfy { $0.1.kindForTesting == "Website" },
                "unselected site rows say \"Website\" (\(unselectedSites.map { $0.1.kindForTesting }))")
            say(views.first?.kindForTesting == "", "the selected row shows its action, not its kind")
            say(FaviconCache.shared.networkRequests.count == requestsBefore, "typing asked the network for no icon")
        }
        capture("cmdtrust-chrome")

        // The loopback page: the icon its tab had, read back from Airc's store on disk.
        type("Trust Fixture")
        run { [self] in
            let b = bar()
            if case let (_, v)? = row(b, page: fixture()) {
                say(v.iconStateForTesting == "image", "a page opened before shows its own icon from Airc's store (\(describe(b)))")
            } else { say(false, "the fixture's history row shows (\(describe(b)))") }
        }
        // The news site: only the engine's favicon database has its icon.
        type("derstandard")
        // The icon lands off the main thread; wait for it (up to 5 s more) instead of reading at a fixed 1.2 s, and say
        // how long it took (0.1.66 tail: WebKit read the tile at 1.2 s once in ~16 runs, at load ~12).
        let newsRow = { [self] () -> CommandRowView? in
            bar().flatMap { b in zip(b.results, b.rowViewsForTesting).first { $0.0.page?.contains("derstandard.at") == true }?.1 }
        }
        var iconWait = Date()
        run { iconWait = Date() }
        step { [self] done in waitUntil({ newsRow()?.iconStateForTesting == "image" }, timeout: 5) { done() } }
        run { [self] in
            let b = bar()
            let v = newsRow()
            note("cmdtrust (\(tag)): derstandard.at's icon state \(v?.iconStateForTesting ?? "no row") 1.2 s + \(String(format: "%.2f", Date().timeIntervalSince(iconWait))) s after typing")
            say(v?.iconStateForTesting == "image", "a site only the engine's database knows shows its icon (\(describe(b)))")
            say(SiteIcons.shared.databaseReads >= 1, "the database was read off the main thread (\(SiteIcons.shared.databaseReads) batch(es))")
        }
        capture("cmdtrust-derstandard")
        // A typed address that isn't in the history: "Open" with the site's name and label.
        type("github.com")
        run { [self] in
            let b = bar()
            let first = b?.rowViewsForTesting.first
            say(first?.sealShownForTesting == true && first?.subtitleForTesting == "GitHub · Official",
                "a typed official address is marked \"GitHub · Official\" ({\(first?.subtitleForTesting ?? "-")}; \(describe(b)))")
        }
        capture("cmdtrust-typed")
        // Typing the store's address: every row's mark is exactly what the list says of its address (history may
        // complete it to the lookalike or the http page, which stay unmarked).
        type("chromewebstore.google.com")
        run { [self] in
            let b = bar()
            let pairs = zip(b?.results ?? [], b?.rowViewsForTesting ?? [])
            let wrong = pairs.filter { r, v in v.sealShownForTesting != (r.trust != nil && r.page.map { OfficialSites.match($0) != nil } == true) }
            let realMarked = pairs.contains { r, v in r.page.map(isRealStore) == true && v.sealShownForTesting }
            say(wrong.isEmpty && realMarked, "typing the store's address marks only its real https rows (\(describe(b)))")
        }
        type("chromewebstore.google.com.evil.example")
        run { [self] in
            let b = bar()
            say(b?.rowViewsForTesting.contains { $0.sealShownForTesting } == false, "a typed lookalike is never marked (\(describe(b)))")
            c.closeCommandBar()
        }

        // A private window: tiles only, nothing read; the bundled list's marks still show.
        var priv: PrivateWindowController?
        var readsBefore = 0
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                priv = w
                done()
            }
        }
        step { [self] done in
            readsBefore = SiteIcons.shared.databaseReads
            guard let w = priv else { say(false, "a private window opens"); return done() }
            w.openCommandBar(mode: .newTab)
            w.commandBar?.type("chromewebstore.google.com")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { done() }
        }
        run { [self] in
            let b = priv?.commandBar
            let first = b?.rowViewsForTesting.first
            say(first?.iconStateForTesting == "tile", "a private window's site row shows a letter tile (\(describe(b)))")
            say(first?.sealShownForTesting == true, "a private window marks the store from the bundled list too")
            b?.type("chromewebstore.google.com.evil.example")
        }
        wait(0.6)
        run { [self] in
            let b = priv?.commandBar
            say(b?.rowViewsForTesting.contains { $0.sealShownForTesting } == false, "a private window never marks the lookalike")
            say(SiteIcons.shared.databaseReads == readsBefore, "a private window reads no icon store or database")
            priv?.closeWindow()
            SiteIcons.databaseOverrideForTesting = nil
            server?.stop()
            try? FileManager.default.removeItem(at: dbDir)
        }
        wait(0.5)
    }

    /// A 32 px square PNG in `color`.
    static func cmdTrustPNG(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 32, height: 32), xRadius: 7, yRadius: 7).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// A database with Chromium's favicon tables (the columns SiteIcons reads), one icon mapped to `page`.
    static func cmdTrustWriteFaviconDB(_ url: URL, page: String, png: Data) throws {
        struct Failure: Error { let message: String }
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw Failure(message: "open") }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE favicons(id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);
            CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0,
              image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0);
            CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
            CREATE INDEX icon_mapping_page_url_idx ON icon_mapping(page_url);
            INSERT INTO favicons(id, url) VALUES (1, 'https://www.derstandard.at/favicon.ico');
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw Failure(message: String(cString: sqlite3_errmsg(db))) }
        var stmt: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(db, "INSERT INTO favicon_bitmaps(icon_id, image_data, width, height) VALUES (1, ?1, 32, 32)", -1, &stmt, nil) == SQLITE_OK
        else { throw Failure(message: "prepare") }
        _ = png.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(png.count), transient) }
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        guard ok, sqlite3_exec(db, "INSERT INTO icon_mapping(page_url, icon_id) VALUES ('\(page)', 1)", nil, nil, nil) == SQLITE_OK
        else { throw Failure(message: "insert") }
    }
}
#endif
