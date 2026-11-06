// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircImport
import AircKit
import AppKit

/// `--script onboarding-e2e` (in scripts/build-app.sh's suite, on both engines): the whole onboarding end to end, on a
/// real-size synthetic Arc (OnboardingFixture.bigPlan: 6 Spaces, 6 profiles, 175 pinned tabs), scratch data only, so
/// it never regresses silently (owner, 2026-11-06).
///
/// First run (ON-1…5), through the steps' own intents:
///   - Welcome: no ✕, and ⌘W and Esc don't close it;
///   - the import step: 6 Spaces · 6 profiles · 175 tabs, Favorites and logins ticked, the changes named and never
///     "flattened"; showing each Space in the preview moves nothing;
///   - Import everything → Spaces and accounts: every profile listed in a 64 pt row; the profile signed in to the
///     loopback ListAccounts mock (never a real Google account) shows Signed in; the ones the import made show Sign
///     in; hovering every row moves nothing;
///   - logins: refused in an automated run (no Keychain), then skipped;
///   - colours: one Space recoloured;
///   - default browser: a stand-in for Launch Services, so no system dialog; Make Default goes on to the card;
///   - Open Airc: the browser window has the 6 Spaces in order, their 175 pinned tabs, 7 folders, Today tabs,
///     Favorites per profile, 6 profiles (the Space whose profile isn't in Arc's list in its own), the new colour.
/// Re-run (ON-3), Import from Arc… on top of that:
///   - re-importing duplicates nothing: same Spaces, items, Today tabs and profiles; a Today tab closed since stays
///     closed; the user's own Space stays; the step says "6 already in Airc";
///   - every profile from before shows Signed in, from its own cookies; hovering every row moves nothing;
///   - ⌘W and ⌘T never reach the browser window behind; it closes from every step (⌘W), from its first step (Esc),
///     with its ✕, never while logins are being written (`closeChecks`, ImportUXCheck.swift).
extension SnapshotRunner {
    func onboardingE2EScenario() {
        let label = "onboarding-e2e"
        let mock = AccountMock(photo: dir.appendingPathComponent("e2e-mock-account-photo.png"))
        let fake = FakeDefaultBrowser()
        let window = AircMetrics.Onboarding.windowSize
        var recoloured: (source: String, theme: SpaceTheme)?
        startAccountMock(mock, label)
        run { [self] in
            guard let o = onboarding else { return check(false, "\(label): the first run opens onboarding") }
            GoogleAccountProbe.testURL = mock.signedIn
            DefaultBrowser.shared.system = fake
            // Onboarding decided whether to offer the step when it opened; with the stand-in, Airc isn't the default.
            o.model.offersDefaultBrowser = fake.canAsk && !fake.isDefault
        }
        wait(0.6)

        // MARK: Welcome

        run { [self] in
            guard let o = onboarding else { return }
            check(o.mode == .firstRun && o.model.step == .welcome && !o.model.closable && TestAnchors.frames["onboarding.close"] == nil,
                  "\(label): the first run opens on Welcome, with no ✕ (ON-5)")
            check(o.window.frame.size == window && TestAnchors.frames["onboarding.page"] == CGRect(origin: .zero, size: window),
                  "\(label): the window and its page are 760 × 540 (\(NSStringFromSize(o.window.frame.size)))")
            Self.press(o.window, Self.key("w", 13, .command, o.window))
            Self.deliver(o.window, Self.key("\u{1b}", 53, [], o.window))
        }
        wait(0.5)
        run { [self] in
            guard let o = onboarding else { return }
            check(app?.onboarding === o && o.window.isVisible && o.model.step == .welcome, "\(label): ⌘W and Esc don't close the first run")
        }
        shootE2E("e2e-1-welcome")

        // MARK: The import step

        run { [self] in onboarding?.model.onNext?() }
        waitForReveal()
        run { [self] in
            guard let m = onboarding?.model else { return }
            let c = m.counts
            check(m.step == .arc && m.hasArc && c.spaces == 6 && c.profiles == 6 && c.tabs == 175 && c.favorites == 23,
                  "\(label): the import step counts 6 Spaces · 6 profiles · 175 tabs · 23 Favorites (\(c.spaces) · \(c.profiles) · \(c.tabs) · \(c.favorites))")
            check(m.includeFavorites && m.includeLogins, "\(label): Favorites and logins are ticked by default")
            check(m.reimport == nil, "\(label): a first import into an empty Airc says nothing about Spaces already here")
            let summaries = m.importChanges.map(\.summary)
            let expected = ["1 Easel was left out", "2 Notes were left out", "1 live folder is now a plain folder",
                            "1 tab group became single tabs", "1 split view became separate tabs", "1 Arc profile folder is missing"]
            check(summaries == expected, "\(label): the import names what changes on the way (\(summaries.joined(separator: "; ")))")
            let words = (m.importChanges.flatMap { [$0.summary, $0.detail] } + [m.importNote ?? ""]).joined(separator: " ").lowercased()
            check(!words.contains("flatten"), "\(label): no \"flattened\" anywhere in the import's copy")
        }
        stableFrames("\(label): import step, the preview on each Space", keys: Self.pageKeys) { m in
            (0..<m.previewSpaces.count).map { i -> () -> Void in { m.focusedSpace = i } }
        }
        run { [self] in onboarding?.model.focusedSpace = 0 }
        wait(0.4)
        shootE2E("e2e-2-import")

        // MARK: Spaces and accounts

        run { [self] in onboarding?.model.onImportEverything?() }
        waitForAccounts()
        run { [self] in
            guard let m = onboarding?.model, let r = m.result else { return check(false, "\(label): Import everything ran") }
            let rows = m.profileRows
            let heights = rows.map { TestAnchors.frames["onboarding.account.\($0.id)"]?.height ?? 0 }
            check(m.step == .accounts && rows.count == 6 && rows.count == m.counts.profiles && Set(rows.map(\.id)).count == 6,
                  "\(label): Spaces and accounts lists every profile (\(rows.map(\.profile.name).joined(separator: ", ")))")
            check(heights.allSatisfy { $0 == AccountsStep.rowHeight }, "\(label): every profile row is 64 pt (\(heights.map { "\(Int($0))" }.joined(separator: ", ")))")
            check(m.accounts[Big.personal]?.email == "alex@example.com" && TestAnchors.frames["onboarding.account.signedIn.\(Big.personal)"] != nil,
                  "\(label): the profile signed in to Google (mock ListAccounts, from its own cookies) shows Signed in")
            let created = rows.filter { r.profilesCreated.contains(r.profileIDs[$0.id] ?? "") }
            check(created.count == 5 && created.allSatisfy { m.accounts[$0.id] == nil },
                  "\(label): the 5 profiles the import made show Sign in (\(created.count) made)")
        }
        stableFrames("\(label): Spaces and accounts, hovering every profile row", keys: Self.pageKeys + Self.rowKeys) { m in
            m.profileRows.flatMap { row -> [() -> Void] in [{ m.hover(profile: row.id, inside: true) }, { m.hover(profile: row.id, inside: false) }] }
        }
        shootE2E("e2e-3-accounts")

        // MARK: Logins, colours, default browser, done

        run { [self] in onboarding?.model.onNext?() }
        wait(0.6)
        run { [self] in
            guard let m = onboarding?.model else { return }
            check(m.step == .logins, "\(label): logins come after the accounts (\(m.step))")
            m.onImportLogins?()
            if case .failed = m.logins { check(true, "\(label): an automated run never reads Arc's logins or the Keychain") }
            else { check(false, "\(label): an automated run never reads Arc's logins or the Keychain (\(m.logins))") }
            m.onSkipLogins?()
        }
        wait(0.6)
        run { [self] in
            guard let m = onboarding?.model, m.previewSpaces.count > 2 else { return }
            check(m.step == .theme, "\(label): Skip goes on to the colours (\(m.step))")
            let theme = DesignTheme.preset("ember")!.model
            m.focusedSpace = 2
            m.themes[m.previewSpaces[2].sourceID] = theme
            m.onThemeChange?()
            recoloured = (m.previewSpaces[2].sourceID, theme)
        }
        wait(0.6)
        shootE2E("e2e-4-colours")
        run { [self] in onboarding?.model.onNext?() }
        wait(0.6)
        run { [self] in
            guard let m = onboarding?.model else { return }
            check(m.step == .defaultBrowser && m.dots == 6, "\(label): the default-browser step follows while Airc isn't the default (\(m.step))")
        }
        shootE2E("e2e-5-default-browser")
        run { [self] in onboarding?.model.onMakeDefault?() }
        step { [self] done in waitUntil({ self.onboarding?.model.step == .done }, timeout: 3) { done() } }
        run { [self] in
            check(onboarding?.model.step == .done && fake.asked == 1 && app?.settings.values.defaultBrowser.answer == .madeDefault,
                  "\(label): Make Default asks once (the stand-in, no system dialog) and goes on to the card")
        }
        wait(0.6)
        shootE2E("e2e-6-done")
        step { [self] done in
            guard let o = onboarding else { return done() }
            var finished = false
            o.onFinished = { _ in
                guard !finished else { return }
                finished = true
                done()
            }
            o.model.onOpen?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard !finished else { return }
                finished = true
                self.check(false, "\(label): Open Airc grows into the browser window (no window after 5 s)")
                done()
            }
        }
        wait(0.8)

        // MARK: The browser window

        run { [self] in
            guard let c = app?.controller else { return check(false, "\(label): the browser window opens") }
            let store = c.store, st = store.state
            let spaces = store.orderedSpaces
            check(app?.onboarding == nil && c.window.isVisible && spaces.compactMap(\.sourceID) == Big.spaces && c.currentSpaceID == spaces.first?.id,
                  "\(label): the browser window has the 6 imported Spaces in Arc's order, on the first (\(spaces.map(\.name).joined(separator: ", ")))")
            let pinned = Set(spaces.map { ItemContainer.pinned(spaceID: $0.id) })
            let tabs = st.items.values.filter { pinned.contains($0.container) && $0.kind == .tab }.count
            let folders = st.items.values.filter { pinned.contains($0.container) && $0.kind == .folder }.count
            let today = st.tabs.values.filter { $0.sourceID != nil && $0.isToday }.count
            check(tabs == 175 && folders == 7 && today == 10,
                  "\(label): 175 pinned tabs, 7 folders and 10 Today tabs came over, the Today tabs still there with the browser open (\(tabs), \(folders), \(today))")
            let fav = { (key: String) in store.profile(sourceID: key).map { store.favorites(ofProfile: $0.id).count } ?? -1 }
            check(fav(Big.personal) == 12 && fav(Big.work) == 8 && fav(Big.side) == 3,
                  "\(label): Favorites per profile: 12, 8, 3 (\(fav(Big.personal)), \(fav(Big.work)), \(fav(Big.side)))")
            let reading = store.space(sourceID: Big.spaces[5]).map { store.profile(ofSpace: $0.id) }
            check(st.profiles.values.compactMap(\.sourceID).count == 6 && reading?.sourceID == Big.missing && reading?.isDefault == false,
                  "\(label): 6 profiles; the Space whose profile isn't in Arc's list has its own (\(reading?.name ?? "-"))")
            check(recoloured.flatMap { store.space(sourceID: $0.source)?.theme } == recoloured?.theme, "\(label): the colour picked in onboarding is the Space's")
            check(store.defaultProfile.googleAccount == "alex@example.com", "\(label): the signed-in account is kept with its profile (on this Mac)")
            check(app?.settings.values.onboardingCompletedAt != nil, "\(label): finishing records that onboarding ran")
        }
        capture("e2e-7-browser")

        // MARK: Re-run: Import from Arc… on top

        // Airc is the stand-in's default now; the re-runs below go through the default-browser step again.
        run { fake.isDefault = false }

        var before = StoreCounts()
        var counts = (spaces: 0, profiles: 0)
        var closedToday: String?
        var mine: String?
        run { [self] in
            guard let c = app?.controller else { return }
            let store = c.store
            // Since the first run: a Today tab closed (into the archive), and a Space of the user's own.
            if let sid = store.space(sourceID: Big.spaces[0])?.id, let t = store.todayTabs(ofSpace: sid).first {
                closedToday = t.sourceID
                _ = try? store.closeTab(t.id)
            }
            mine = (try? store.createSpace(name: "Reading"))?.id
            c.reloadAll(animated: false)
            before = StoreCounts(store)
            counts = (store.orderedSpaces.count, store.state.profiles.count)
        }
        openRerun(atImport: true)
        run { [self] in
            guard let m = app?.onboarding?.model else { return check(false, "\(label): Import from Arc… opens") }
            check(m.reimport?.line == "6 already in Airc" && m.counts.spaces == 6 && m.counts.tabs == 175,
                  "\(label): re-run: the import step says the 6 Spaces are already here (\(m.reimport?.line ?? "-"))")
            m.onImportEverything?()
        }
        waitForAccounts()
        run { [self] in
            guard let c = app?.controller, let m = app?.onboarding?.model, let r = m.result else { return check(false, "\(label): re-run: the import ran") }
            let store = c.store, after = StoreCounts(store)
            check(r.spacesUpdated == 6 && r.spacesCreated == 0 && r.profilesCreated.isEmpty,
                  "\(label): re-run: 6 Spaces updated in place, none added, no profile made (\(r.spacesUpdated), \(r.spacesCreated), \(r.profilesCreated.count))")
            check(after.items == before.items && after.today == before.today && after.duplicateSourceIDs == 0
                  && store.orderedSpaces.count == counts.spaces && store.state.profiles.count == counts.profiles,
                  "\(label): re-run: nothing duplicated (items \(before.items) → \(after.items), Today \(before.today) → \(after.today), "
                  + "Spaces \(counts.spaces) → \(store.orderedSpaces.count), profiles \(counts.profiles) → \(store.state.profiles.count))")
            let back = store.orderedSpaces.contains { s in store.todayTabs(ofSpace: s.id).contains { $0.sourceID == closedToday } }
            check(closedToday != nil && !back, "\(label): re-run: a Today tab closed since the first run stays closed")
            check(mine.flatMap { store.space($0)?.name } == "Reading", "\(label): re-run: the user's own Space stays, even with an Arc Space's name")
            check(m.profileRows.count == 6 && m.profileRows.allSatisfy { m.accounts[$0.id] != nil },
                  "\(label): re-run: every profile from before shows Signed in, from its own cookies")
        }
        stableFrames("\(label): re-run, hovering every profile row", keys: Self.pageKeys + Self.rowKeys) { m in
            m.profileRows.flatMap { row -> [() -> Void] in [{ m.hover(profile: row.id, inside: true) }, { m.hover(profile: row.id, inside: false) }] }
        }
        var rows = 0
        run { [self] in
            guard let c = app?.controller, let o = app?.onboarding else { return }
            rows = c.store.todayTabs(ofSpace: c.currentSpaceID).count + c.store.pinnedRows(ofSpace: c.currentSpaceID).count
            check(Self.press(o.window, Self.key("t", 17, .command, o.window)), "\(label): ⌘T in the onboarding window is kept from the browser's menu")
            Self.press(o.window, Self.key("w", 13, .command, o.window))
        }
        wait(0.6)
        run { [self] in
            guard let c = app?.controller else { return }
            let now = c.store.todayTabs(ofSpace: c.currentSpaceID).count + c.store.pinnedRows(ofSpace: c.currentSpaceID).count
            check(app?.onboarding == nil && now == rows && c.commandBar == nil,
                  "\(label): ⌘W closes the re-run and neither it nor ⌘T touched the browser window (rows \(rows) → \(now))")
        }
        closeChecks(label)
        run { [self] in
            guard let store = app?.controller?.store else { return }
            let s = StoreCounts(store)
            check(s.duplicateSourceIDs == 0 && s.items == before.items, "\(label): after every re-run, still nothing twice (\(s.items) sidebar items)")
            GoogleAccountProbe.testURL = nil
            DefaultBrowser.shared.system = SystemDefaultBrowser()
            mock.stop()
        }
    }

    /// Waits until the import's tail (profiles, icons) and the account checks are done.
    func waitForAccounts() {
        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.checkingAccounts.isEmpty == true && self.app?.onboarding?.model.isImporting == false },
                      timeout: 12) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done) }
        }
    }

    /// The onboarding window at 2× on a sample desktop.
    private func shootE2E(_ name: String) {
        step { [self] done in
            guard let w = app?.onboarding?.window else { note("\(name): no onboarding window"); return done() }
            captureWindow(w, name: name, rounded: AircMetrics.Onboarding.windowRadius, done)
        }
    }
}
#endif
