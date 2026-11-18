// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircImport
import AircKit
import AppKit
import Security

/// diaimport: importing from Dia through onboarding, end to end, on a synthetic Dia only: a fake home folder
/// (`BrowserImportLocator.testHome`) with Dia's layout (`Library/Application Support/Dia/User Data`), Chromium's own
/// schemas for Login Data, Cookies (one partitioned) and Local Storage (arcimport3's fixture), bookmarks locked in
/// `EncryptedBookmarks2` (Dia 1.54+) and a Web Store extension, all encrypted with the secret of the runner's scratch
/// keychain item ("Airc Test Dia Safe Storage", never Dia's own item, never the login keychain). Real driver clicks pick
/// Dia, start the import, press Import logins (or Import bookmarks on WebKit) and Try Again.
///   - The source list offers Dia; its import brings history, the extension checklist and Spaces, and says its
///     bookmarks wait for Dia's key.
///   - macOS denying the key (simulated, as the prompt's Deny answers): logins and cookies are skipped rows saying why,
///     in Dia's words; sites' storage still comes over; no bookmarks yet.
///   - Try Again reads the scratch item through the real Keychain API: logins, cookies and sites' storage imported, and
///     the locked bookmarks join Dia's Spaces. On Chromium the site then gets its cookies and its localStorage.
///   - WebKit: the step offers only Dia's bookmarks; Deny, then Try Again brings them; no login is read.
extension SnapshotRunner {
    func diaImportScenario() {
        let root = dir.appendingPathComponent("diaimport")
        let home = root.appendingPathComponent("home")
        let dia = home.appendingPathComponent("Library/Application Support/Dia")
        let fm = FileManager.default
        let seen = SeenRequests()
        var page = "", alt = "", homeID = ""
        var server: LocalPageServer?
        let keychain = TestArcKeychain.current
        let chromium = app?.credentialSink.acceptsCredentials == true
        let onboardingWindow: () -> NSWindow? = { self.app?.onboarding?.window }

        step { [self] done in
            server = LocalPageServer(responses: [:])
            server?.requestHandler = { r in
                seen.add(r)
                switch r.path {
                case "/storage": return .init(body: "<title>storage</title><script>document.title='ls:'+localStorage.getItem('token')</script>")
                case "/cookies": return .init(body: "<title>cookies</title><p>\(r.headers["cookie"] ?? "")</p>")
                default: return .init(body: "<title>dia</title>")
                }
            }
            guard let server else { check(false, "diaimport: the loopback page server starts"); return done() }
            server.start { port in
                page = "http://127.0.0.1:\(port ?? 0)"
                alt = "http://localhost:\(port ?? 0)"
                done()
            }
        }
        run { [self] in
            guard let keychain else {
                return skip("diaimport: no scratch keychain (AIRC_TEST_ARC_KEYCHAIN, AIRC_TEST_ARC_SAFE_STORAGE): the real Keychain path isn't part of this run")
            }
            do { try DiaImportFixture.write(dia, page: page, alt: alt, secret: keychain.secret) }
            catch { check(false, "diaimport: synthetic Dia written (\(error))") }
            BrowserImportLocator.testHome = home
            ArcExtensionChecklist.testStoreBase = URL(string: "http://127.0.0.1:9")
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({ self.app?.onboarding?.model.sources.contains { $0.source == .browser("dia") } == true }, timeout: 30, then: done)
        }
        wait(0.8)

        func activate(_ window: @escaping () -> NSWindow?) {
            step { done in
                NSApp.activate(ignoringOtherApps: true)
                window()?.makeKeyAndOrderFront(nil)
                self.waitUntil({ NSApp.isActive && window()?.isKeyWindow == true }, timeout: 3, then: done)
            }
        }
        /// A real click (the UI driver) on an anchor of `window`; FAIL-ENV when the driver refuses, then a posted press
        /// so the rest of the check still runs (labelled).
        func realClick(_ anchor: String, _ what: String, fallback: @escaping () -> Void) {
            step { [self] done in
                guard keychain != nil else { return done() }
                guard let w = onboardingWindow(), let host = w.contentView, let v = TestAnchors.view(anchor, in: host), let primary = NSScreen.screens.first else {
                    check(false, "diaimport [real click] \(what): on screen (\(anchor))"); return done()
                }
                let r = w.convertToScreen(v.convert(v.bounds, to: nil))
                UIDriverClient.run(["--click", String(Double(r.midX.rounded())), String(Double((primary.frame.maxY - r.midY).rounded()))]) { ok, out in
                    if ok { self.note("diaimport [real click] \(what)") } else {
                        self.note("FAIL-ENV diaimport [real click] \(what): \(out); pressing it in-app [posted]")
                        fallback()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
                }
            }
        }
        func capture(_ name: String) {
            step { [self] done in
                guard keychain != nil, let w = onboardingWindow() else { return done() }
                captureWindow(w, name: name, rounded: 24, done)
            }
        }

        // MARK: The source: Dia, found, read

        activate(onboardingWindow)
        realClick("onboarding.source.dia", "Dia in the source list") { self.app?.onboarding?.model.onSelectSource?(.browser("dia")) }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({ self.app?.onboarding?.model.browserReads["dia"] != nil && self.app?.onboarding?.model.blueprint != nil }, timeout: 30, then: done)
        }
        wait(0.8)
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            let item = m.sources.first { $0.source == .browser("dia") }
            let read = m.browserReads["dia"]
            check(m.source == .browser("dia") && item?.kind == .dia && item?.bundleIDs == ["company.thebrowser.dia"],
                  "diaimport: onboarding's import step offers Dia and shows it (\(String(describing: m.source)))")
            check(read?.lockedProfiles == ["dia-profile:Default"] && read?.profiles.first { $0.profileID == "Default" }?.history == 1
                  && read?.plan.extensions?["dia-profile:Default"]?.map(\.id) == [DiaImportFixture.readerID],
                  "diaimport: Dia's read: Home's bookmarks locked, its history and its Web Store extension (\(read?.lockedProfiles ?? []))")
            check(m.importChanges.contains { $0.summary.contains("locked with Dia's key") },
                  "diaimport: the import step says Dia's bookmarks come over with its key (\(m.importChanges.map(\.summary)))")
        }
        capture("diaimport-source")
        realClick("onboarding.primary", "Import") { self.app?.onboarding?.model.onImportEverything?() }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done)
        }
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model, let result = m.result else { return }
            homeID = result.profileIDs["dia-profile:Default"] ?? ""
            let rows = ArcExtensionChecklist.shared.rows.filter { $0.profileID == homeID }
            check(!homeID.isEmpty && rows.map(\.extensionInfo.id) == [DiaImportFixture.readerID],
                  "diaimport: Dia's Home profile came over with its extension in the reinstall checklist (\(rows.map(\.extensionInfo.name)))")
            check(m.credentialSource == .dia && m.lockedBookmarkProfiles == 1, "diaimport: the Logins step is Dia's, with one profile's bookmarks to unlock")
        }
        for _ in 0..<3 {
            run { [self] in
                guard let o = app?.onboarding, o.model.result != nil, o.model.step < .logins else { return }
                o.next()
            }
            wait(0.6)
        }
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            check(m.step == .logins, "diaimport: onboarding reaches the Logins step after the import (\(m.step))")
            check(TestAnchors.frames["onboarding.logins.import"] != nil, "diaimport: the step offers \(chromium ? "Import logins" : "Import bookmarks")")
        }
        capture("diaimport-logins-step")

        func pinnedURLs() -> [String] {
            guard let s = c.store.space(sourceID: BrowserImport.Keys.space("dia", "Default")) else { return [] }
            return c.store.pinnedRows(ofSpace: s.id).compactMap { $0.item?.savedURL }
        }

        // MARK: macOS denies Dia's key

        run { TestArcKeychain.state.simulate(errSecAuthFailed) }
        activate(onboardingWindow)
        realClick("onboarding.logins.import", chromium ? "Import logins" : "Import bookmarks") { self.app?.onboarding?.model.onImportLogins?() }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({
                switch self.app?.onboarding?.model.logins { case .done?, .failed?: true; default: false }
            }, timeout: 30, then: done)
        }
        wait(0.6)
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            if chromium {
                guard case .done(let o) = m.logins else { return check(false, "diaimport: denied: the import finished (\(m.logins))") }
                let whole = o.rows.filter { $0.whole && $0.profileID == homeID }
                check(o.keychainProblem?.hasPrefix("Keychain access to “Dia Safe Storage” was denied, so Dia's") == true
                      && whole.map(\.status) == [.skipped, .skipped] && o.siteDataImported == 1 && o.loginsImported + o.cookiesImported == 0
                      && Set(o.retryable.map(\.kind)) == [.login, .cookies] && TestArcKeychain.state.reads == 0,
                      "diaimport: Deny: logins and cookies are skipped rows saying why, sites' storage came over — \(o.summary)")
                check(!o.rows.contains { $0.reason.range(of: #"\bArc\b"#, options: .regularExpression) != nil },
                      "diaimport: Dia's results never say Arc (\(o.rows.map(\.reason).filter { $0.contains("Arc") }))")
            } else {
                check(m.logins == .failed("Keychain access to “Dia Safe Storage” was denied, so Dia's saved passwords and cookies stayed locked. Try Again and choose Allow."),
                      "diaimport: WebKit: Deny says why and offers Try Again (\(m.logins))")
            }
            check(m.unlockedBookmarks == nil && !pinnedURLs().contains("https://docs.example/"),
                  "diaimport: Deny: Dia's locked bookmarks didn't come over (\(pinnedURLs().count) pinned)")
        }
        capture("diaimport-denied")

        // MARK: Try Again, allowed: the scratch item through the real Keychain API

        run { TestArcKeychain.state.simulate(nil) }
        activate(onboardingWindow)
        realClick(chromium ? "results.retry" : "onboarding.logins.retry", "Try Again") {
            if chromium { _ = CredentialImport.retry() } else { self.app?.onboarding?.model.onImportLogins?() }
        }
        step { [self] done in
            guard keychain != nil else { return done() }
            waitUntil({
                chromium ? (CredentialImport.Session.shared.outcome?.attempt == 2 && !CredentialImport.Session.shared.retrying)
                    : self.app?.onboarding?.model.unlockedBookmarks != nil
            }, timeout: 30, then: done)
        }
        wait(0.8)
        run { [self] in
            guard keychain != nil, let m = app?.onboarding?.model else { return }
            check(TestArcKeychain.state.reads == 1, "diaimport: Try Again read the scratch keychain's item once (\(TestArcKeychain.state.reads))")
            let urls = pinnedURLs()
            check(m.unlockedBookmarks == 2 && m.bookmarksNote == nil && urls.contains("https://docs.example/") && urls.contains("https://tools.example/")
                  && urls.filter { $0 == "https://docs.example/" }.count == 1,
                  "diaimport: Dia's locked bookmarks joined its Home Space, once (\(m.unlockedBookmarks ?? -1) unlocked, \(urls.count) pinned)")
            check(TestAnchors.frames["onboarding.logins.bookmarks"] != nil, "diaimport: the step says the bookmarks were added")
            if chromium {
                guard let o = CredentialImport.Session.shared.outcome, o.attempt == 2 else { return check(false, "diaimport: Try Again ran") }
                note("diaimport: rows: " + o.rows.filter { !$0.whole }.map { "\($0.kind.rawValue) \($0.site) \($0.username) \($0.status.rawValue)" + ($0.reason.isEmpty ? "" : " · \($0.reason)") }.joined(separator: " | "))
                check(o.keychainProblem == nil && o.loginsImported == 3 && o.cookiesImported == 3 && o.siteDataImported == 1 && o.source == .dia,
                      "diaimport: Try Again imported Dia's logins, cookies (one partitioned) and sites' storage — \(o.summary)")
                check(o.rows.contains { $0.kind == .cookies && $0.site == "old.example" && $0.reason == "Already expired in Dia" }
                      && o.rows.contains { $0.kind == .login && $0.site == "never.example" && $0.reason == "Dia was set to never save passwords here" },
                      "diaimport: skipped rows say why in Dia's words")
            } else {
                check(CredentialImport.Session.shared.outcome?.source != .dia, "diaimport: WebKit: no login or cookie was read")
            }
        }
        capture("diaimport-results")
        run { [self] in app?.onboarding?.requestClose() }
        wait(0.8)

        // MARK: Chromium: the site uses what came over

        #if canImport(AircCore)
        var tabID = ""
        let tab = { self.c.engineTab(for: tabID) }
        func open(_ url: @escaping () -> String, title: String) {
            run { [self] in
                guard chromium, keychain != nil, let s = c.store.space(sourceID: BrowserImport.Keys.space("dia", "Default")),
                      let t = try? c.store.openTab(url: url(), inSpace: s.id, title: title) else { return }
                tabID = t.id
                c.switchToSpace(s.id, animated: false)
                c.reloadAll(animated: false)
                c.show(t.id, focus: false)
            }
            step { [self] done in
                guard chromium, keychain != nil else { return done() }
                waitUntil({ tab()?.isLoading == false && !(tab()?.title ?? "").isEmpty }, timeout: 10, then: done)
            }
            wait(0.4)
        }
        open({ page + "/storage" }, title: "storage")
        run { [self] in
            guard chromium, keychain != nil else { return }
            check(tab()?.title == "ls:arc-local-value", "diaimport: Chromium: the site reads its imported localStorage (\(tab()?.title ?? "-"))")
        }
        open({ page + "/cookies" }, title: "cookies")
        run { [self] in
            guard chromium, keychain != nil else { return }
            let sent = seen.last("/cookies")?.headers["cookie"] ?? ""
            check(sent.contains("a3sid=arc-cookie") && sent.contains("a3session=arc-session"),
                  "diaimport: Chromium: Dia's imported cookies are sent to 127.0.0.1 (Cookie: \(Self.names(sent)))")
        }
        run { [self] in if !tabID.isEmpty { c.closeTab(tabID) } }
        #endif

        run { [self] in
            server?.stop()
            BrowserImportLocator.testHome = nil
            ArcExtensionChecklist.testStoreBase = nil
            TestArcKeychain.state.simulate(nil)
            try? fm.removeItem(at: root)
        }
    }
}

/// The synthetic Dia: arcimport3's profiles (Home = Default, Work = Profile 1) with its logins, cookies and storage,
/// in Dia's folder; Home's bookmarks only in `EncryptedBookmarks2` (with a stale plain `Bookmarks`), a Web Store
/// extension in its Preferences, and Work with a plain `Bookmarks`. Encrypted with `secret`.
enum DiaImportFixture {
    static let readerID = String(repeating: "d", count: 32)

    static func write(_ dia: URL, page: String, alt: String, secret: String) throws {
        try Arcimport3Fixture.write(dia, page: page, alt: alt, secret: secret)
        // Dia has no Arc sidebar.
        try? FileManager.default.removeItem(at: dia.appendingPathComponent("StorableSidebar.json"))
        let key = try ArcSafeStorage.deriveKey(password: Data(secret.utf8))
        func bookmarks(_ bar: [(String, String, String)]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "checksum": "0", "roots": [
                "bookmark_bar": ["type": "folder", "name": "Bookmarks bar",
                                 "children": bar.map { ["type": "url", "name": $0.0, "url": $0.1, "guid": $0.2, "id": $0.2] }],
                "other": ["type": "folder", "name": "Other bookmarks", "children": []],
                "synced": ["type": "folder", "name": "Mobile bookmarks", "children": []],
            ]])
        }
        let d = dia.appendingPathComponent("User Data/Default"), w = dia.appendingPathComponent("User Data/Profile 1")
        try bookmarks([("Stale", "https://stale.example/", "g-stale")]).write(to: d.appendingPathComponent("Bookmarks"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 60)],
                                              ofItemAtPath: d.appendingPathComponent("Bookmarks").path)
        try ArcSafeStorage.encryptForTests(try bookmarks([("Docs", "https://docs.example/", "g-docs"), ("Tools", "https://tools.example/", "g-tools")]), key: key)
            .write(to: d.appendingPathComponent(DiaBookmarks.fileName))
        try ImportAcceptanceFixture.json(dia, "User Data/Default/Preferences", ["extensions": ["settings": [
            readerID: ["location": 1, "state": 1, "from_webstore": true,
                       "manifest": ["name": "Synthetic Dia Reader", "update_url": "https://clients2.google.com/service/update2/crx"]],
        ]]])
        try bookmarks([("Work", "https://work.example/", "g-work")]).write(to: w.appendingPathComponent("Bookmarks"))
    }
}
#endif
