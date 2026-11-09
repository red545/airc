// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircImport
import AircKit
import AppKit
import SQLite3
import SwiftUI

/// `--script arcaccept` (P22, E11): Arc import acceptance on synthetic Arc folders only. Never the owner's Arc profile,
/// never the Keychain (its answers are simulated through the real lookup's handling), never the real Web Store.
///   - Source permutations: the sidebar alone, a damaged profile list, a profile folder linking outside Arc's folder.
///   - Onboarding's Import from Arc on a two-profile Arc whose Work history is only in SQLite's log (Arc open): the
///     WAL warning, profile mapping (Default takes over Airc's default profile, Profile 1 becomes "Synthetic Work"),
///     history per profile, the extension checklist's pending / installed / opened / not-in-the-Web-Store states.
///     Then Arc quits and the import runs again: the warning is gone, Work's visits come over once, nothing doubles.
///   - Logins: the Keychain declining, locked, without Arc's item; a wrong key; a partial result (a database macOS won't
///     let Airc read, a store that didn't keep some rows) and Try Again clicked in the results, which redoes only those
///     parts; precise reasons for what Airc can't import. On Chromium the engine's own store gives the same words.
extension SnapshotRunner {
    func importAcceptanceScenario() {
        let root = dir.appendingPathComponent("arcaccept")
        let arc = root.appendingPathComponent("Arc")
        var writer: OpaquePointer?
        var homeID = "", workID = ""
        let fm = FileManager.default
        func copies() -> Int {
            ((try? fm.contentsOfDirectory(atPath: fm.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("AircImport-") }.count
        }

        // MARK: Source permutations (the plan alone)

        step { [self] done in
            Task { @MainActor in
                do {
                    let alone = root.appendingPathComponent("sidebar-only")
                    try ImportAcceptanceFixture.sidebar(alone)
                    let a = try await ArcImporter.plan(at: alone)
                    let changes = ImportAdapter.changes(for: a.warnings)
                    check(a.spaces.count == 2 && a.profiles.allSatisfy { !$0.isAvailable }
                          && changes.contains { $0.summary == "2 Arc profile folders are missing" && $0.detail.contains("history, extensions, logins and cookies") },
                          "arcaccept: the sidebar alone imports its Spaces and says what its missing profile folders can't bring (\(changes.map(\.summary)))")

                    let damaged = root.appendingPathComponent("damaged-list")
                    try ImportAcceptanceFixture.sidebar(damaged)
                    try ImportAcceptanceFixture.folders(damaged, ["Default", "Profile 1"])
                    try Data("{\"profile\": {".utf8).write(to: damaged.appendingPathComponent("User Data/Local State"))
                    let d = try await ArcImporter.plan(at: damaged)
                    let dc = ImportAdapter.changes(for: d.warnings)
                    check(d.spaces.count == 2 && d.profiles.map(\.name) == ["Default", "Profile 1"] && d.profiles.allSatisfy(\.isAvailable)
                          && dc.contains { $0.summary == "Arc's profile list is damaged" },
                          "arcaccept: a damaged profile list no longer stops the import; profiles are named after their folders (\(dc.map(\.summary)))")

                    let linked = root.appendingPathComponent("linked")
                    try ImportAcceptanceFixture.sidebar(linked)
                    try ImportAcceptanceFixture.folders(linked, ["Default"])
                    let outside = root.appendingPathComponent("outside/Profile 1")
                    _ = try ImportAcceptanceFixture.sqlite(outside.appendingPathComponent("History"), ImportAcceptanceFixture.history("outside"))
                    try fm.createSymbolicLink(at: linked.appendingPathComponent("User Data/Profile 1"), withDestinationURL: outside)
                    let l = try await ArcImporter.plan(at: linked)
                    check(l.history?["Profile 1"] == nil && ImportAdapter.changes(for: l.warnings).contains { $0.summary == "1 profile folder links outside Arc's folder" },
                          "arcaccept: a profile folder linking outside Arc's folder isn't followed, and the import says so")
                } catch {
                    check(false, "arcaccept: permutation fixtures (\(error))")
                }
                done()
            }
        }

        // MARK: Onboarding import with Arc open (WAL-only history)

        run { [self] in
            do {
                writer = try ImportAcceptanceFixture.write(arc)
                ArcExtensionChecklist.testStoreBase = URL(string: "http://127.0.0.1:9")
            } catch { check(false, "arcaccept: synthetic Arc written (\(error))") }
            OnboardingController.testArcDirectory = arc
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30, then: done) }
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "arcaccept: onboarding found the synthetic Arc") }
            check(m.importChanges.contains { $0.summary == "1 profile may have newer history in Arc" && $0.detail.contains("Quit Arc and import again") },
                  "arcaccept: Arc open: the import says one profile's newest history waits for Arc to quit (\(m.importChanges.map(\.summary)))")
            m.includeLogins = false
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.result != nil }, timeout: 30, then: done) }
        step { [self] done in
            guard let app, let r = app.onboarding?.model.result else { check(false, "arcaccept: imported"); return done() }
            let store: SpacesStore = app.store
            homeID = r.profileIDs["arc-profile:Default"] ?? ""
            workID = r.profileIDs["arc-profile:Profile 1"] ?? ""
            check(homeID == store.defaultProfile.id && store.state.profiles[workID]?.name == "Synthetic Work" && r.profilesCreated == [workID],
                  "arcaccept: profile mapping: Arc's Default takes over Airc's default profile, Profile 1 becomes “Synthetic Work”")
            check(store.space(sourceID: "arc-space:s-home")?.profileID == homeID && store.space(sourceID: "arc-space:s-work")?.profileID == workID,
                  "arcaccept: each Space is in its own Arc profile's Airc profile")
            check(app.history.entries(ofProfile: homeID).map(\.url) == ["https://home.example/visited"] && app.history.entries(ofProfile: workID).isEmpty,
                  "arcaccept: history per profile; Work's, still only in Arc's log, isn't read")
            // The profile is usable: its engine profile loads.
            app.profiles.whenLoaded(workID, { _ in
                self.check(true, "arcaccept: the new Work profile's engine profile loads")
                done()
            }, failed: {
                self.check(false, "arcaccept: the new Work profile's engine profile loads")
                done()
            })
        }

        // MARK: Extension checklist states

        run { [self] in
            guard let app else { return }
            let rows = ArcExtensionChecklist.shared.rows
            func row(_ name: String) -> ArcExtensionRow? { rows.first { $0.extensionInfo.name == name } }
            check(rows.count == 4 && row("Synthetic Reader")?.profileID == homeID && row("Synthetic Notes")?.profileID == workID,
                  "arcaccept: the checklist keeps each extension with its own profile (\(rows.map(\.extensionInfo.name)))")
            check(ArcExtensionChecklist.counts(rows, app: app) == .init(installed: 0, opened: 0, pending: 2, unavailable: 2),
                  "arcaccept: before reinstalling: 2 pending, 2 not in the Web Store (\(ArcExtensionChecklist.counts(rows, app: app).summary))")
            if case .unavailable(let why)? = row("Synthetic Dev Tool").map({ ArcExtensionChecklist.state($0, app: app) }) {
                check(why.contains("Loaded unpacked"), "arcaccept: an unpacked extension says how to load it again (\(why))")
            } else { check(false, "arcaccept: an unpacked extension is not in the Web Store") }
            if case .unavailable(let why)? = row("Synthetic Vendor Tool").map({ ArcExtensionChecklist.state($0, app: app) }) {
                check(why.contains("Not from the Chrome Web Store"), "arcaccept: an extension from elsewhere says so (\(why))")
            } else { check(false, "arcaccept: an extension from elsewhere is not in the Web Store") }
            ArcExtensionChecklist.testInstalled[homeID] = [ImportAcceptanceFixture.readerID]
            if let notes = row("Synthetic Notes") { ArcExtensionChecklist.open(notes, app: app) }
        }
        wait(2.3)
        run { [self] in
            guard let app else { return }
            let rows = ArcExtensionChecklist.shared.rows
            let counts = ArcExtensionChecklist.counts(rows, app: app)
            check(counts == .init(installed: 1, opened: 1, pending: 0, unavailable: 2),
                  "arcaccept: after reinstalling one and opening another's page: \(counts.summary)")
            check(counts.summary == "1 of 4 reinstalled · 1 opened in the Web Store · 2 not in the Web Store", "arcaccept: the checklist's summary line")
            check(ArcExtensionChecklist().rows.first { $0.extensionInfo.id == ImportAcceptanceFixture.notesID }?.openedAt != nil,
                  "arcaccept: the opened mark is saved")
            check(TestAnchors.frames["arcimport2.summary"] != nil && TestAnchors.frames.keys.contains { $0.hasPrefix("arcimport2.unavailable.") },
                  "arcaccept: the checklist shows its summary and the not-in-the-Web-Store rows")
        }
        step { [self] done in
            guard let w = app?.onboarding?.window else { return done() }
            captureWindow(w, name: "arcaccept-checklist", rounded: 24, done)
        }

        // MARK: Arc quits; import again

        run { [self] in
            sqlite3_close(writer)   // the last connection checkpoints the log into the main file and removes it
            writer = nil
            let wal = (try? arc.appendingPathComponent("User Data/Profile 1/History-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            check(wal <= 32, "arcaccept: Arc quit: its log is checkpointed (\(wal) bytes left; macOS's SQLite may keep an empty one)")
            app?.onboarding?.requestClose()
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.hasArc == true }, timeout: 30, then: done) }
        var before: (profiles: Int, spaces: Int, items: Int) = (0, 0, 0)
        run { [self] in
            guard let app, let m = app.onboarding?.model else { return check(false, "arcaccept: reimport found Arc") }
            check(!m.importChanges.contains { $0.summary.contains("newer history") }, "arcaccept: with Arc quit, the WAL warning is gone")
            before = (app.store.state.profiles.count, app.store.state.spaces.count, app.store.state.items.count)
            m.includeLogins = false
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.result?.spacesUpdated == 2 }, timeout: 30, then: done) }
        run { [self] in
            guard let app, let r = app.onboarding?.model.result else { return check(false, "arcaccept: reimported") }
            let store: SpacesStore = app.store
            check(r.profilesCreated.isEmpty && r.spacesCreated == 0 && r.profileIDs["arc-profile:Profile 1"] == workID
                  && (store.state.profiles.count, store.state.spaces.count, store.state.items.count) == before,
                  "arcaccept: importing again maps to the same profiles and doubles nothing (profiles, Spaces, items \(before))")
            let work = app.history.entries(ofProfile: workID).filter { $0.url.hasSuffix(".example/visited") }
            let home = app.history.entries(ofProfile: homeID).filter { $0.url.hasSuffix(".example/visited") }
            check(work.map(\.url) == ["https://work.example/visited"] && work.first?.visitCount == 4
                  && home.map(\.url) == ["https://home.example/visited"] && home.first?.visitCount == 4,
                  "arcaccept: Work's visits come over once Arc quit, once; Home's aren't doubled")
            check(ArcExtensionChecklist.shared.rows.count == 4
                  && ArcExtensionChecklist.shared.rows.first { $0.extensionInfo.id == ImportAcceptanceFixture.notesID }?.openedAt != nil,
                  "arcaccept: the checklist keeps its rows and the opened mark")
            app.onboarding?.requestClose()
            if let work = store.space(sourceID: "arc-space:s-work") { c.switchToSpace(work.id, animated: false) }
            c.openCommandBar(mode: .newTab)
            c.commandBar?.type("synthetic work")
        }
        wait(0.8)
        run { [self] in
            check(c.commandBar?.resultTitles.contains { $0.hasPrefix("Synthetic work") } == true,
                  "arcaccept: ⌘T in the Work Space suggests Work's imported page (\(c.commandBar?.resultTitles ?? []))")
            c.closeCommandBar()
        }

        // MARK: Logins: the Keychain's answers, a wrong key

        let sink = AcceptanceSink()
        let lookups = LookupCount()
        let password = Data("synthetic-only".utf8)
        for (status, want, label) in [(errSecUserCanceled, ImportError.keychainDeclined, "declined"),
                                      (errSecInteractionNotAllowed, .keychainLocked, "locked"),
                                      (errSecItemNotFound, .keychainNotFound, "without Arc's item")] {
            step { [self] done in
                let before = copies()
                CredentialImport.run(arcDirectory: arc, profiles: [("Default", homeID)], sink: sink, keychainStatus: { status }, password: password,
                                     progress: { _ in }) { [self] result in
                    if case .failure(let e) = result, (e as? ImportError) == want {
                        check(sink.received.isEmpty && copies() == before,
                              "arcaccept: the Keychain \(label): nothing is read, and it says so: \(e.localizedDescription)")
                    } else {
                        check(false, "arcaccept: the Keychain \(label) (\(result))")
                    }
                    done()
                }
            }
        }
        step { [self] done in
            let wrong = (try? ArcSafeStorage.deriveKey(password: Data("another-mac".utf8))) ?? Data(count: 16)
            CredentialImport.run(arcDirectory: arc, profiles: [("Default", homeID)], sink: sink, key: wrong, progress: { _ in }) { [self] result in
                if case .success(let o) = result {
                    check(o.keyMismatchProfiles == [homeID] && o.loginsImported + o.cookiesImported == 0 && sink.received.isEmpty
                          && o.summary.contains("“Arc Safe Storage”"),
                          "arcaccept: a wrong key: nothing decrypts, and it says it's the key — \(o.summary)")
                } else { check(false, "arcaccept: a wrong key (\(result))") }
                done()
            }
        }

        // MARK: Logins: a partial result, and Try Again

        var results: NSWindow?
        let loginData = arc.appendingPathComponent("User Data/Profile 1/Login Data")
        step { [self] done in
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: loginData.path)
            sink.failCookiesOnce = [homeID]
            sink.failLoginOnce[homeID] = 1
            CredentialImport.run(arcDirectory: arc, profiles: [("Default", homeID), ("Profile 1", workID)], sink: sink,
                                 keychainStatus: { lookups.add(); return errSecSuccess }, password: password, progress: { _ in }) { [self] result in
                guard case .success(let o) = result else { check(false, "arcaccept: partial import (\(result))"); return done() }
                // Try Again calls this completion again with the merged outcome (as onboarding's Logins step wants).
                guard o.attempt == 1 else { return }
                let parts = Set(o.retryable.map { "\($0.directory) \($0.kind.rawValue)" })
                check(parts == ["Default login", "Default cookies", "Profile 1 login"] && o.failedProfiles.isEmpty,
                      "arcaccept: a partial result: what failed and may pass is kept for Try Again (\(parts.sorted()))")
                check(o.rows.contains { $0.whole && $0.profileID == workID && $0.reason.contains("macOS didn't let Airc read it") }
                      && o.summary.contains("One profile's saved passwords couldn't be read."),
                      "arcaccept: the unreadable database is one row and one sentence — \(o.summary)")
                check(o.loginsImported == 1 && o.cookiesImported == 1, "arcaccept: what could come over did (\(o.loginsImported) logins, \(o.cookiesImported) cookies)")
                note("arcaccept: first attempt: " + o.summary)
                // The real view, in a window of its own, with Try Again.
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.title = "Login import results"
                let names = Dictionary(uniqueKeysWithValues: (self.app?.store.orderedProfiles ?? []).map { ($0.id, $0.name) })
                w.appearance = NSAppearance(named: .aqua)
                w.contentView = NSHostingView(rootView: ImportResultsView(outcome: o, profileNames: names, maxHeight: 300)
                    .padding(20).frame(width: 620, height: 470, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor)).testAnchorRoot())
                w.setFrameOrigin(NSPoint(x: 140, y: 140))
                // Key (the app stays in the background): a posted first click on a SwiftUI button needs it.
                w.makeKeyAndOrderFront(nil)
                results = w
                done()
            }
        }
        wait(0.8)
        step { [self] done in
            guard let w = results else { return done() }
            check(TestAnchors.frames["results.retry"] != nil && TestAnchors.frames["results.reasons"] != nil,
                  "arcaccept: the results show Try Again and what didn't come over, by reason")
            captureWindow(w, name: "arcaccept-results-partial", rounded: 18, done)
        }
        run { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loginData.path) }
        clickIn({ results?.contentView }, "results.retry")
        step { [self] done in
            let session = CredentialImport.Session.shared
            waitUntil({ session.outcome?.attempt == 2 && !session.retrying }, timeout: 10) {
                if session.outcome?.attempt != 2 {
                    self.note("arcaccept: Try Again missed (\(TestAnchors.lastHit["results.retry"] ?? "-")), clicking again")
                    guard let v = results?.contentView else { return done() }
                    return self.clickAnchor("results.retry", in: v) {
                        self.waitUntil({ session.outcome?.attempt == 2 && !session.retrying }, timeout: 10, then: done)
                    }
                }
                done()
            }
        }
        wait(0.5)
        step { [self] done in
            guard let o = CredentialImport.Session.shared.outcome, o.attempt == 2 else {
                check(false, "arcaccept: Try Again ran"); return done()
            }
            let retried = sink.received.suffix(2).map { "\($0.profile == homeID ? "Default" : "Profile 1") \($0.logins)/\($0.cookies)" }
            check(retried == ["Default 2/3", "Profile 1 1/0"] && lookups.value == 2,
                  "arcaccept: Try Again (a real click) read and sent only the failed parts: \(retried); macOS was asked again (\(lookups.value) lookups)")
            check(o.retryable.isEmpty && o.loginsImported == 3 && o.cookiesImported == 2 && o.failed == 0 && o.failedProfiles.isEmpty,
                  "arcaccept: after Try Again everything that can come over did, nothing failed — \(o.summary)")
            let saved = o.rows.filter { $0.kind == .login && $0.status == .imported }.map(\.site).sorted()
            check(saved == ["mail.example", "shop.example", "work.example"] && !o.rows.contains { $0.reason == "Already saved in this profile" },
                  "arcaccept: the login saved the first time stays imported, not “Already saved” (\(saved))")
            let why = Dictionary(o.rows.filter { $0.status == .skipped }.map { ($0.site, $0.reason) }, uniquingKeysWith: { a, _ in a })
            check(why["com.example.app"] == "An Android app's login: Airc takes website logins only"
                  && why["fed.example"]?.hasPrefix("Signs in through another account") == true
                  && why["intranet.example"]?.contains("HTTP authentication") == true
                  && why["news.example"]?.hasPrefix("Partitioned") == true
                  && why["old.example"] == "Already expired in Arc",
                  "arcaccept: precise reasons for what can't be imported: " + why.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
            check(CredentialImport.lastOutcome == o, "arcaccept: Settings → Import shows the merged result")
            guard let w = results else { return done() }
            captureWindow(w, name: "arcaccept-results-retried", rounded: 18, done)
        }
        run { results?.orderOut(nil); results = nil }

        // MARK: Chromium: the engine's own reasons in the same words

        step { [self] done in
            guard let app, app.credentialSink.acceptsCredentials else {
                note("arcaccept: no Chromium engine: the engine's own store isn't part of this run")
                return done()
            }
            CredentialImport.run(arcDirectory: arc, profiles: [("Default", homeID)], sink: app.credentialSink,
                                 key: (try? ArcSafeStorage.deriveKey(password: password)) ?? Data(count: 16), progress: { _ in }) { [self] result in
                guard case .success(let o) = result else { check(false, "arcaccept: engine import (\(result))"); return done() }
                let why = Dictionary(o.rows.filter { $0.status == .skipped && $0.kind == .cookies }.map { ($0.site, $0.reason) }, uniquingKeysWith: { a, _ in a })
                check(o.loginsImported == 2 && o.cookiesImported == 1 && why["news.example"]?.hasPrefix("Partitioned") == true
                      && why["old.example"] == "Already expired in Arc",
                      "arcaccept: Chromium's store: 2 logins and 1 cookie in; its refusals in the same precise words (\(why))")
                done()
            }
        }
        run { [self] in
            ArcExtensionChecklist.testStoreBase = nil
            ArcExtensionChecklist.testInstalled = [:]
            OnboardingController.testArcDirectory = nil
            sqlite3_close(writer)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loginData.path)
            try? fm.removeItem(at: root)
        }
        // The engine contract's own check (`--script events`), on the outcome model P22 rebuilt.
        credentialImportCheck()
    }
}

extension SnapshotRunner {
    /// Marketing part `arcimport2` (P22): `arc-import-logins`, the login results after one import: what came over, what
    /// didn't and why (most common first), and Try Again for the one profile whose passwords couldn't be read.
    /// Synthetic Arc data and a stand-in store only.
    func arcImportLoginsShot() {
        let root = dir.appendingPathComponent("arc-import-logins")
        let arc = root.appendingPathComponent("Arc")
        let sink = AcceptanceSink()
        var window: NSWindow?
        step { [self] done in
            guard let store = app?.store else { return done() }
            do { sqlite3_close(try ImportAcceptanceFixture.write(arc)) } catch { note("arc-import-logins: fixture (\(error))"); return done() }
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: arc.appendingPathComponent("User Data/Profile 1/Login Data").path)
            let profiles = store.orderedProfiles
            let home = profiles.first?.id ?? store.defaultProfile.id, work = profiles.dropFirst().first?.id ?? home
            CredentialImport.run(arcDirectory: arc, profiles: [("Default", home), ("Profile 1", work)], sink: sink,
                                 key: (try? ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))) ?? Data(count: 16),
                                 progress: { _ in }) { [self] result in
                guard case .success(let o) = result else { note("arc-import-logins: \(result)"); return done() }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })
                w.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                    Text("Logins from Arc").aircFont(AircFont.title3)
                    Text(o.summary).aircFont(AircFont.callout).fixedSize(horizontal: false, vertical: true)
                    ImportResultsView(outcome: o, profileNames: names, maxHeight: 230)
                }.padding(22).frame(width: 600, height: 430, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)).testAnchorRoot())
                w.appearance = NSAppearance(named: .aqua)
                w.orderFront(nil)
                window = w
                done()
            }
        }
        wait(0.8)
        step { [self] done in
            guard let w = window else { return done() }
            captureWindow(w, name: "arc-import-logins", rounded: 24, done)
        }
        run {
            window?.orderOut(nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: arc.appendingPathComponent("User Data/Profile 1/Login Data").path)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// The synthetic Arc: two Spaces (Home in Default, Work in Profile 1), named profiles, history (Work's only in
/// SQLite's log while `write`'s connection stays open), four extensions and logins and cookies under a synthetic key.
enum ImportAcceptanceFixture {
    static let readerID = String(repeating: "a", count: 32)
    static let devID = String(repeating: "b", count: 32)
    static let notesID = String(repeating: "c", count: 32)
    static let vendorID = String(repeating: "d", count: 32)

    static func json(_ root: URL, _ path: String, _ value: Any) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    static func sidebar(_ root: URL) throws {
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
        try json(root, "StorableSidebar.json", ["version": 1, "sidebar": ["containers": [["global": [:]], ["spaces": spaces, "items": items]]]])
    }
    static func folders(_ root: URL, _ names: [String]) throws {
        for n in names { try FileManager.default.createDirectory(at: root.appendingPathComponent("User Data/" + n), withIntermediateDirectories: true) }
    }
    static func chromeTime(days: Double) -> Int64 { Int64((Date().timeIntervalSince1970 + 11_644_473_600 + days * 86400) * 1_000_000) }
    static func history(_ name: String) -> String {
        """
        CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls VALUES('https://\(name).example/visited','Synthetic \(name)',4,1,\(chromeTime(days: -1)),0);
        """
    }
    static func sqlite(_ url: URL, _ sql: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        try BrowserFixtures.sqlite(url, sql, keepOpen: keepOpen)
    }

    /// Writes the whole synthetic Arc and returns the open connection that keeps Work's history in its log ("Arc open").
    static func write(_ root: URL) throws -> OpaquePointer? {
        try sidebar(root)
        try json(root, "User Data/Local State", ["profile": ["info_cache": ["Default": ["name": "Synthetic Home"], "Profile 1": ["name": "Synthetic Work"]]]])
        _ = try sqlite(root.appendingPathComponent("User Data/Default/History"), history("home"))
        let open = try sqlite(root.appendingPathComponent("User Data/Profile 1/History"),
                              "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;" + history("work"), keepOpen: true)
        let store = "https://clients2.google.com/service/update2/crx"
        try json(root, "User Data/Default/Preferences", ["extensions": ["settings": [
            readerID: ["manifest": ["name": "Synthetic Reader", "update_url": store], "location": 1, "state": 1, "from_webstore": true],
            devID: ["manifest": ["name": "Synthetic Dev Tool"], "location": 4, "state": 1],
        ]]])
        try json(root, "User Data/Profile 1/Preferences", ["extensions": ["settings": [
            notesID: ["manifest": ["name": "Synthetic Notes", "update_url": store], "location": 1, "state": 0, "from_webstore": true],
            vendorID: ["manifest": ["name": "Synthetic Vendor Tool", "update_url": "https://updates.vendor.example/crx"], "location": 1, "state": 1],
        ]]])
        // Logins and cookies, encrypted the way Arc does with a synthetic key (never the Keychain's).
        let key = try ArcSafeStorage.deriveKey(password: Data("synthetic-only".utf8))
        func hex(_ d: Data) throws -> String { try ArcSafeStorage.encryptForTests(d, key: key).map { String(format: "%02x", $0) }.joined() }
        func login(_ origin: String, _ realm: String, _ user: String, _ pw: String, scheme: Int = 0, federation: String = "") throws -> String {
            let blob = try pw.isEmpty ? "" : hex(Data(pw.utf8))
            return "INSERT INTO logins VALUES('\(origin)','','\(realm)','\(user)',X'\(blob)',0,\(scheme),'\(federation)');"
        }
        func cookie(_ host: String, _ value: String, expires: Int64, partition: String = "") throws -> String {
            "INSERT INTO cookies VALUES('\(host)','c','/','',X'\(try hex(ArcSafeStorage.digest(host) + Data(value.utf8)))',\(expires),1,0,1,'\(partition)');"
        }
        let logins = "CREATE TABLE logins(origin_url TEXT, action_url TEXT, signon_realm TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER, scheme INTEGER, federation_url TEXT);"
        let cookies = """
            CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24');
            CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, top_frame_site_key TEXT);
            """
        let later = chromeTime(days: 30), earlier = chromeTime(days: -3)
        _ = try sqlite(root.appendingPathComponent("User Data/Default/Login Data"), logins
            + (try login("https://mail.example/", "https://mail.example/", "home-1", "pw-1"))
            + (try login("https://shop.example/", "https://shop.example/", "home-2", "pw-2"))
            + (try login("android://hash@com.example.app/", "android://hash@com.example.app/", "app-1", "pw-3"))
            + (try login("https://fed.example/", "federation://fed.example/accounts.example", "fed-1", "", federation: "https://accounts.example")))
        _ = try sqlite(root.appendingPathComponent("User Data/Default/Cookies"), cookies
            + (try cookie("mail.example", "c-1", expires: later))
            + (try cookie("news.example", "c-2", expires: later, partition: "https://portal.example"))
            + (try cookie("old.example", "c-3", expires: earlier)))
        _ = try sqlite(root.appendingPathComponent("User Data/Profile 1/Login Data"), logins
            + (try login("https://work.example/", "https://work.example/", "work-1", "pw-4"))
            + (try login("https://intranet.example/", "https://intranet.example/Staff", "intranet", "pw-5", scheme: 1)))
        _ = try sqlite(root.appendingPathComponent("User Data/Profile 1/Cookies"), cookies + (try cookie("work.example", "c-4", expires: later)))
        return open
    }
}

/// How often the simulated Keychain was asked (the key source runs off the main thread).
final class LookupCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A credential sink with the engine's rules (PROFILE-SERVICES.md), on both engines: it records what it was sent, keeps
/// logins by realm and username (a second one is "skipped-duplicate"), refuses partitioned and expired cookies with the
/// engine's words, and can fail a profile's cookies or one login once ("store unavailable", "did not persist").
final class AcceptanceSink: CredentialSink {
    var acceptsCredentials: Bool { true }
    private(set) var received: [(profile: String, logins: Int, cookies: Int)] = []
    private var stored: [String: Set<String>] = [:]
    var failCookiesOnce: Set<String> = []
    var failLoginOnce: [String: Int] = [:]

    func receive(_ c: ImportedCredentials, forProfile profileID: String, completion: @escaping (CredentialImport.EngineResult) -> Void) {
        received.append((profileID, c.logins.count, c.cookies.count))
        var r = CredentialImport.EngineResult()
        var logins: [[String: Any]] = []
        for (i, l) in c.logins.enumerated() {
            let key = l.signonRealm + "\u{1f}" + l.username
            if !l.origin.hasPrefix("http") {
                r.loginsRejected += 1
                logins.append(["index": i, "status": "rejected", "reason": "invalid HTTP(S) origin, realm or password"])
            } else if failLoginOnce[profileID] == i {
                failLoginOnce[profileID] = nil
                r.loginsRejected += 1
                logins.append(["index": i, "status": "rejected", "reason": "password store did not persist login"])
            } else if stored[profileID, default: []].contains(key) {
                r.loginsSkipped += 1
                logins.append(["index": i, "status": "skipped-duplicate", "reason": "existing login key preserved"])
            } else {
                stored[profileID, default: []].insert(key)
                r.loginsImported += 1
                logins.append(["index": i, "status": "saved", "reason": ""])
            }
        }
        let failCookies = failCookiesOnce.remove(profileID) != nil
        let now = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        var cookies: [[String: Any]] = []
        for (i, k) in c.cookies.enumerated() {
            let reason = failCookies ? "store unavailable"
                : !(k.metadata["top_frame_site_key"] ?? "").isEmpty ? "partitioned cookie unsupported"
                : (k.expiresUTC != 0 && k.expiresUTC < now) ? "expired cookie" : ""
            if reason.isEmpty { r.cookiesImported += 1 } else { r.cookiesRejected += 1 }
            cookies.append(["index": i, "status": reason.isEmpty ? "accepted" : "rejected", "reason": reason])
        }
        r.rows = CredentialImport.rows(logins: c.logins, loginResults: logins, cookies: c.cookies, cookieResults: cookies, profileID: profileID)
        DispatchQueue.main.async { completion(r) }
    }
}
#endif
