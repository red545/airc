// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircImport
import AircKit
import AppKit

/// `--script import-browsers` (in scripts/build-app.sh's suite, on both engines): importing from other browsers (IM-4)
/// on synthetic browsers only (BrowserFixtures: a Chrome-layout folder with two profiles and its History held locked, a
/// Brave profile with damaged bookmarks, a Firefox profile, a Safari export, password CSV files). Never the owner's
/// browsers: `BrowserImportLocator.testHome` points detection at the fixture, and automated runs see nothing else.
///
///   - Airc menu → Import from Another Browser… opens the import step: Arc first, then Chrome, Brave, Firefox, Safari
///     and Passwords; everything fits above the buttons;
///   - Chrome: its profiles by name with their colours, "2 profiles · 26 bookmarks · 6 folders · 300 history entries"
///     read while its History is locked; Import: a Space and a profile per Chrome profile, the bookmarks bar as pinned
///     tabs and folders, Other and Mobile bookmarks one folder each, no Favorites, the history in ⌘T's store;
///   - the logins step offers a passwords CSV file: on Chromium 4 imported · 1 duplicate skipped (and the rest named),
///     Move to Trash deletes the file, the same file again is all duplicates, a file that isn't one says so; on WebKit
///     nothing is read;
///   - importing Chrome again duplicates nothing (Spaces, items, profiles, history counts);
///   - Firefox, Brave (its bookmarks unreadable, its history still in) and Safari's file, the file twice;
///   - Settings → Import → Passwords opens the Passwords source, and Arc turning up later doesn't take it over.
extension SnapshotRunner {
    func importBrowsersScenario() {
        let label = "import-browsers"
        typealias Expect = BrowserFixtures.Expect
        var fixture: BrowserFixtures.Written?
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AircImportBrowsersCheck-\(UUID().uuidString)")
        var baseProfiles = 0
        run { [self] in
            do {
                fixture = try BrowserFixtures.write(to: root)
                BrowserImportLocator.testHome = fixture?.home
            } catch {
                check(false, "\(label): synthetic browsers written (\(error))")
            }
            baseProfiles = c.store.state.profiles.count
        }

        // MARK: The picker

        run { [self] in
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Import from Another Browser…" }
            check(item != nil && NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.title == "Import from Arc…" } == false,
                  "\(label): the Airc menu has Import from Another Browser… (and no Import from Arc…)")
            if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
        }
        waitForSources(label)
        run { [self] in
            guard let o = app?.onboarding else { return check(false, "\(label): Import from Another Browser… opens the import step") }
            let m = o.model
            check(o.model.step == .arc && m.sources.map(\.anchor) == ["arc", "chrome", "brave", "firefox", "file", "passwords"] && m.source == .arc,
                  "\(label): the import step lists Arc first, then every browser found (\(m.sources.map(\.anchor).joined(separator: ", ")))")
            check(m.sources.allSatisfy { TestAnchors.frames["onboarding.source.\($0.anchor)"] != nil }, "\(label): every source has its pill")
            fits(label, "Arc")
        }
        shoot("ib-1-sources")

        // MARK: Chrome

        select(.browser("chrome"))
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.browserReads["chrome"] else { return check(false, "\(label): Chrome read") }
            check(r.profiles.map(\.profileID) == ["Default", "Profile 1"] && r.profiles.map(\.name) == ["Chrome", "Work"],
                  "\(label): Chrome's profiles by name, a default name as Chrome's (\(r.profiles.map(\.name).joined(separator: ", ")))")
            check(r.profiles.map { $0.color ?? "-" } == ["#56a9cd", "#dc143c"], "\(label): each profile with its avatar colour")
            let line = BrowserSourceDetail.countsLine(r, chosen: m.chosenSpaces, history: m.includeHistory)
            check(line == "26 bookmarks · 6 folders · 300 history entries" && r.profiles.map(\.bookmarks) == [18, 8],
                  "\(label): the counts are specific, read while Chrome holds its History locked (\(line))")
            check(m.previewSpaces.map(\.name) == ["Chrome", "Work"] && m.counts.spaces == 2 && m.counts.favorites == 0,
                  "\(label): the preview shows a Space per profile, no Favorites")
            check(TestAnchors.frames["onboarding.browser.profile.Default"] != nil && TestAnchors.frames["onboarding.browser.history"] != nil,
                  "\(label): every profile and the history have their rows")
            fits(label, "Chrome")
        }
        shoot("ib-2-chrome")
        var before = StoreCounts()
        run { [self] in
            before = StoreCounts(c.store)
            app?.onboarding?.model.onImportEverything?()
        }
        waitForAccounts()
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.result else { return check(false, "\(label): Chrome imported") }
            let store = c.store
            let chrome = store.space(sourceID: "chrome-space:Default"), work = store.space(sourceID: "chrome-space:Profile 1")
            check(m.step == .accounts && r.spacesCreated == 2 && chrome?.name == "Chrome" && work?.name == "Work",
                  "\(label): Import makes a Space per Chrome profile, named after it (\(store.orderedSpaces.map(\.name).joined(separator: ", ")))")
            let pChrome = chrome.map { store.profile(ofSpace: $0.id) }, pWork = work.map { store.profile(ofSpace: $0.id) }
            check(pChrome?.sourceID == "chrome-profile:Default" && pWork?.sourceID == "chrome-profile:Profile 1" && pChrome?.id != pWork?.id
                  && store.state.profiles.count == baseProfiles + 1,
                  "\(label): each Chrome profile is an Airc profile (Chrome's default one takes over Airc's untouched default)")
            if let chrome {
                let roots = store.pinnedRoots(ofSpace: chrome.id)
                let pinned = ItemContainer.pinned(spaceID: chrome.id)
                let tabs = store.state.items.values.filter { $0.container == pinned && $0.kind == .tab }.count
                let folders = store.state.items.values.filter { $0.container == pinned && $0.kind == .folder }.map { $0.title ?? "" }
                check(roots.count == 10 && tabs == Expect.chromeBookmarks.default && folders.count == Expect.chromeFolders.default
                      && folders.contains("Other bookmarks") && folders.contains("Mobile bookmarks"),
                      "\(label): the bar's tabs and folders, then Other and Mobile bookmarks as one folder each (\(roots.count) rows, \(tabs) tabs, \(folders.count) folders)")
                check(store.favorites(ofProfile: store.profile(ofSpace: chrome.id).id).isEmpty && store.todayTabs(ofSpace: chrome.id).isEmpty,
                      "\(label): Favorites and Today stay empty")
            }
            if let app, let pc = pChrome, let pw = pWork {
                let h = app.history!
                check(h.entries(ofProfile: pc.id).count == Expect.chromeHistory.default && h.entries(ofProfile: pw.id).count == Expect.chromeHistory.work,
                      "\(label): each profile's history went into its own Airc profile (\(h.entries(ofProfile: pc.id).count), \(h.entries(ofProfile: pw.id).count))")
                let hit = h.search("Example.Com", profileID: pc.id).first?.entry.url
                let elsewhere = h.search("Example.Com", profileID: pw.id).contains { $0.entry.url.hasPrefix("https://example.com/") }
                check(hit?.hasPrefix("https://example.com/page/") == true && !elsewhere,
                      "\(label): ⌘T finds an imported page in its profile only (\(hit.map { URL(string: $0)?.host ?? "-" } ?? "nothing"))")
            }
            check(m.profileRows.count == 2, "\(label): Spaces and accounts lists the 2 profiles")
            m.onNext?()
        }
        wait(0.6)

        // MARK: Passwords from a CSV file

        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            check(m.step == .logins && !m.importedFromArc && TestAnchors.frames["onboarding.passwords.profile"] != nil,
                  "\(label): after Chrome, the logins step offers a passwords file (\(m.step))")
        }
        shoot("ib-3-passwords")
        let chromium = app?.credentialSink.acceptsCredentials == true
        passwords(label, file: { fixture?.passwordsFile }) { [self] state in
            if chromium {
                guard case .done(let o) = state else { return check(false, "\(label): the passwords file came in (\(state))") }
                check(o.imported == Expect.passwords.logins && o.duplicates == Expect.passwords.duplicates && o.incomplete == Expect.passwords.incomplete
                      && o.notWebsite == Expect.passwords.notWebsite && o.failed == 0 && o.format == .chrome,
                      "\(label): \(o.summary) (\(o.details ?? "")) into \(app?.onboarding?.model.passwordsProfile == c.store.defaultProfile.id ? "the first imported profile" : "another profile")")
                check(o.summary == "4 passwords imported · 1 duplicate skipped", "\(label): the count and duplicates are said plainly (\(o.summary))")
            } else {
                guard case .failed(let why) = state else { return check(false, "\(label): WebKit doesn't read a passwords file (\(state))") }
                check(why.contains("Chromium engine") && FileManager.default.fileExists(atPath: fixture?.passwordsFile.path ?? ""),
                      "\(label): on WebKit, nothing is read — \(why)")
            }
        }
        if chromium {
            shoot("ib-4-passwords-done")
            run { [self] in app?.onboarding?.model.onDiscardPasswordsFile?() }
            wait(0.4)
            run { [self] in
                check(app?.onboarding?.model.passwordsFileDiscarded == true && !FileManager.default.fileExists(atPath: fixture?.passwordsFile.path ?? "x"),
                      "\(label): Move to Trash gets rid of the plain-text file (a test deletes its synthetic one)")
                if let f = fixture { try? Data(BrowserFixtures.passwordsCSV.utf8).write(to: f.passwordsFile) }
                app?.onboarding?.model.passwords = .idle
            }
            passwords(label, file: { fixture?.passwordsFile }) { [self] state in
                guard case .done(let o) = state else { return check(false, "\(label): the same file again (\(state))") }
                check(o.imported == 0 && o.duplicates == Expect.passwords.logins + Expect.passwords.duplicates,
                      "\(label): the same file again: nothing twice (\(o.summary))")
            }
            run { [self] in app?.onboarding?.model.passwords = .idle }
            passwords(label, file: { fixture?.notPasswordsFile }) { [self] state in
                guard case .failed(let why) = state else { return check(false, "\(label): a CSV without passwords (\(state))") }
                check(why.contains("url and a password column"), "\(label): a file that isn't a passwords file says so — \(why)")
            }
        }
        run { [self] in app?.onboarding?.requestClose() }
        wait(0.6)

        // MARK: Chrome again: nothing twice

        var afterFirst = StoreCounts()
        var historyCounts: [Int] = []
        run { [self] in
            afterFirst = StoreCounts(c.store)
            let h = app!.history!
            historyCounts = c.store.orderedProfiles.map { h.entries(ofProfile: $0.id).count }
            check(afterFirst.items == before.items + Expect.chromeBookmarks.default + Expect.chromeBookmarks.work + Expect.chromeFolders.default
                  + Expect.chromeFolders.work, "\(label): the first import added exactly the bookmarks and folders (\(before.items) → \(afterFirst.items))")
        }
        reopen(label)
        select(.browser("chrome"))
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            check(m.reimport?.line == "2 already in Airc", "\(label): Chrome again: the step says both Spaces are already here (\(m.reimport?.line ?? "-"))")
            m.onImportEverything?()
        }
        waitForAccounts()
        run { [self] in
            guard let r = app?.onboarding?.model.result else { return check(false, "\(label): Chrome again imported") }
            let after = StoreCounts(c.store)
            let h = app!.history!
            let counts = c.store.orderedProfiles.map { h.entries(ofProfile: $0.id).count }
            check(r.spacesUpdated == 2 && r.spacesCreated == 0 && r.profilesCreated.isEmpty && after.items == afterFirst.items
                  && after.duplicateSourceIDs == 0 && counts == historyCounts,
                  "\(label): Chrome again: 2 Spaces updated in place, nothing added (items \(afterFirst.items) → \(after.items), history \(historyCounts) → \(counts))")
            let visits = c.store.space(sourceID: "chrome-space:Default").flatMap { h.entry(profileID: c.store.profile(ofSpace: $0.id).id, url: "https://example.com/page/1") }
            check(visits?.visitCount == 2, "\(label): Chrome again: visit counts aren't added up (\(visits?.visitCount ?? -1))")
            app?.onboarding?.requestClose()
        }
        wait(0.6)

        // MARK: Firefox, Brave, Safari's file

        reopen(label)
        select(.browser("firefox"))
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.browserReads["firefox"] else { return check(false, "\(label): Firefox read") }
            check(r.bookmarks == Expect.firefox.bookmarks && r.folders == Expect.firefox.folders && r.historyEntries == Expect.firefox.history
                  && r.profiles.map(\.name) == ["Firefox"],
                  "\(label): Firefox: \(BrowserImportAdapter.counts(bookmarks: r.bookmarks, folders: r.folders, history: r.historyEntries))")
            m.onImportEverything?()
        }
        waitForAccounts()
        run { [self] in
            let store = c.store
            guard let s = store.space(sourceID: "firefox-space:Profiles/fx01.default-release") else { return check(false, "\(label): Firefox's Space") }
            let folders = store.pinnedRoots(ofSpace: s.id).filter { $0.kind == .folder }.map { $0.title ?? "" }
            check(s.name == "Firefox" && folders == ["Recipes", "Bookmarks Menu", "Other Bookmarks"]
                  && app!.history!.entries(ofProfile: store.profile(ofSpace: s.id).id).count == Expect.firefox.history,
                  "\(label): Firefox: the toolbar as pinned tabs and folders, the menu and Other Bookmarks as folders, its history (\(folders.joined(separator: ", ")))")
            app?.onboarding?.requestClose()
        }
        wait(0.6)
        reopen(label)
        select(.browser("brave"))
        run { [self] in
            guard let m = app?.onboarding?.model, let r = m.browserReads["brave"] else { return check(false, "\(label): Brave read") }
            check(r.profiles.first?.unreadable == ["bookmarks"] && r.historyEntries == Expect.braveHistory
                  && m.importChanges.contains { $0.summary == "1 profile's bookmarks couldn't be read" },
                  "\(label): Brave: damaged bookmarks are said, its history still comes (\(m.importChanges.map(\.summary).joined(separator: "; ")))")
            m.onImportEverything?()
        }
        waitForAccounts()
        run { [self] in
            let s = c.store.space(sourceID: "brave-space:Default")
            check(s != nil && c.store.pinnedRoots(ofSpace: s!.id).isEmpty
                  && app!.history!.entries(ofProfile: c.store.profile(ofSpace: s!.id).id).count == Expect.braveHistory,
                  "\(label): Brave: its Space and profile, with its history")
            app?.onboarding?.requestClose()
        }
        wait(0.6)
        for pass in 1...2 {
            reopen(label)
            select(.bookmarksFile)
            run { [self] in
                guard let o = app?.onboarding else { return }
                o.testFiles["bookmarks"] = fixture?.bookmarksFile
                o.model.onChooseBookmarksFile?()
            }
            step { [self] done in waitUntil({ self.app?.onboarding?.model.browserReads["file"] != nil }, timeout: 5) { done() } }
            if pass == 1 { shoot("ib-5-safari-file") }
            var itemsBefore = 0
            run { [self] in
                guard let m = app?.onboarding?.model, let r = m.browserReads["file"] else { return check(false, "\(label): Safari's file read") }
                if pass == 1 {
                    check(r.bookmarks == Expect.safariFile.bookmarks && r.folders == Expect.safariFile.folders && m.previewSpaces.first?.name == "Safari",
                          "\(label): Safari's export: \(BrowserImportAdapter.counts(bookmarks: r.bookmarks, folders: r.folders, history: nil)), as the Space Safari")
                    fits(label, "Safari's file")
                }
                itemsBefore = c.store.state.items.count
                m.onImportEverything?()
            }
            waitForAccounts()
            run { [self] in
                let s = c.store.space(sourceID: "safari-file-space:file")
                let rows = s.map { c.store.pinnedRoots(ofSpace: $0.id).count } ?? 0
                if pass == 1 {
                    check(s?.name == "Safari" && rows == 8 && c.store.state.items.count == itemsBefore + Expect.safariFile.bookmarks + Expect.safariFile.folders,
                          "\(label): Safari's file: Favorites as pinned tabs, then its folders (\(rows) rows)")
                } else {
                    check(c.store.state.items.count == itemsBefore && StoreCounts(c.store).duplicateSourceIDs == 0,
                          "\(label): the same Safari file again: nothing twice (\(itemsBefore) → \(c.store.state.items.count) items)")
                }
                app?.onboarding?.requestClose()
            }
            wait(0.6)
        }

        // MARK: Settings → Import → Passwords from a CSV file

        run { [self] in
            app?.startOnboarding(mode: .rerun, atImport: true)
            app?.onboarding?.select(.passwords, picked: true)
        }
        wait(1.2)
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "\(label): the Passwords source opens") }
            check(m.source == .passwords && m.hasArc && TestAnchors.frames["onboarding.passwords.profile"] != nil,
                  "\(label): Settings' Passwords opens the Passwords source, and Arc turning up doesn't take it over")
            fits(label, "Passwords")
        }
        shoot("ib-6-passwords-source")
        run { [self] in
            app?.onboarding?.requestClose()
            fixture?.release()
            try? FileManager.default.removeItem(at: root)
            BrowserImportLocator.testHome = nil
            check(!FileManager.default.fileExists(atPath: root.path), "\(label): the synthetic browsers are deleted")
        }
        wait(0.6)
    }

    /// The onboarding window at 2× on a sample desktop (the runner's own capture only knows the first-run window).
    private func shoot(_ name: String) {
        step { [self] done in
            guard let w = app?.onboarding?.window else { note("\(name): no onboarding window"); return done() }
            captureWindow(w, name: name, rounded: AircMetrics.Onboarding.windowRadius, done)
        }
    }

    /// Opens the re-run on the import step and waits for its sources.
    private func reopen(_ label: String) {
        run { [self] in
            forgetStepRows()
            app?.startOnboarding(mode: .rerun, atImport: true)
        }
        waitForSources(label)
    }

    private func waitForSources(_ label: String) {
        step { [self] done in
            waitUntil({ (self.app?.onboarding?.model.sources.count ?? 0) >= 6 && self.app?.onboarding?.model.hasArc == true }, timeout: 8) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done)
            }
        }
    }

    /// Picks a source on the import step (its pill's intent) and waits until it's read and its preview has played.
    private func select(_ source: OnboardingModel.ImportSource) {
        run { [self] in
            forgetStepRows()
            app?.onboarding?.model.onSelectSource?(source)
        }
        step { [self] done in
            waitUntil({
                guard let m = self.app?.onboarding?.model, m.source == source, !m.readingSource else { return false }
                if case .browser(let id) = source, m.browserReads[id] == nil { return false }
                return m.blueprint == nil || m.revealedSpaces >= m.previewSpaces.count
            }, timeout: 10) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done) }
        }
    }

    /// A passwords file through the pane's own intent (the check's file instead of an open panel), then `then` with
    /// the outcome.
    private func passwords(_ label: String, file: @escaping () -> URL?, then: @escaping (OnboardingModel.PasswordsState) -> Void) {
        run { [self] in
            guard let o = app?.onboarding else { return }
            o.testFiles["passwords"] = file()
            if o.model.loginsAvailable { o.model.onChoosePasswordsFile?() } else if let url = file() { o.importPasswords(from: url) }
        }
        step { [self] done in
            waitUntil({ self.app?.onboarding.map { $0.model.passwords != .reading && $0.model.passwords != .idle } ?? true }, timeout: 20) {
                then(self.app?.onboarding?.model.passwords ?? .idle)
                done()
            }
        }
    }

    /// The anchors of the import step's own rows (its picker excluded: it sits on top).
    static let stepRowPrefixes = ["onboarding.source.header", "onboarding.import.", "onboarding.browser.", "onboarding.passwords."]

    /// Frames of rows no longer on screen stay recorded: forget them before the step changes.
    private func forgetStepRows() {
        for key in TestAnchors.frames.keys where Self.stepRowPrefixes.contains(where: key.hasPrefix) { TestAnchors.frames[key] = nil }
    }

    /// Everything on the import step fits above its buttons: no row clipped by the fixed card (IM-4's picker on top).
    private func fits(_ label: String, _ what: String) {
        let content = TestAnchors.frames["onboarding.content"] ?? .null
        let primary = TestAnchors.frames["onboarding.primary"] ?? .null
        let rows = TestAnchors.frames.filter { key, _ in Self.stepRowPrefixes.contains(where: key.hasPrefix) }
        let bottom = rows.values.map(\.maxY).max() ?? content.minY
        // Top-left origin, y growing downwards; the buttons sit 20 pt under the content.
        check(!content.isNull && !primary.isNull && !rows.isEmpty && bottom <= primary.minY - 20 + 0.5,
              "\(label): \(what): the import step's \(rows.count) rows end above its buttons (rows to \(Int(bottom)), buttons at \(Int(primary.minY)))")
    }
}
#endif
