// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircImport
import AircKit
import AppKit
import SwiftUI

/// `--script importux`: Import from Arc on a real-size Arc (OnboardingFixture.bigPlan: 6 Spaces, 6 profiles, 175 pinned
/// tabs, all synthetic), as a re-run into an Airc that already has two of its Spaces and one of its own, the way the
/// owner opened it (Airc menu → Import from Arc…, 2026-11-06). Checks, each PASS or FAIL:
///   - the import step's counts, the re-import line (merge by Arc ID) and the named changes ("1 Easel was left out");
///   - showing every Space in the preview and hovering every profile row moves and resizes nothing: the window, the
///     page, the preview, the step's content, its primary button and every row keep their frames;
///   - every profile is listed, one 64 pt row each, also the Space whose profile isn't in Arc's list;
///   - a profile signed in to Google (a loopback mock of ListAccounts; never a real account) shows "Signed in", the
///     account and Switch…, not Sign in; a signed-out answer clears it; a new profile isn't asked;
///   - the preview's rows are the real sidebar's (41 pt pitch);
///   - re-importing duplicates nothing: Spaces, pinned tabs, Favorites and profiles each once, and a Today tab closed
///     since the first import doesn't come back;
///   - the re-run closes from every step with ⌘W, from its first step with Esc, and with its ✕; not while logins are
///     being written; ⌘W and ⌘T never reach the browser window behind it; the first run doesn't close;
///   - a ⌘Q tap shows "Hold ⌘Q to Quit" in the onboarding window.
/// Every step is shot at the window's size (2×, `ux-<light|dark>-<step>.png`) and on 1280 × 800 and 1512 × 982
/// screens (1×, `ux-<light|dark>-<step>-<screen>.jpg`).
extension SnapshotRunner {
    typealias Big = OnboardingFixture.Big

    func importUXScenario() {
        let mock = AccountMock(photo: dir.appendingPathComponent("ux-mock-account-photo.png"))
        var fake: FakeDefaultBrowser?
        startAccountMock(mock, "importux")
        var signedIn: URL? { mock.signedIn }
        var signedOut: URL? { mock.signedOut }
        var mixed: URL? { mock.mixed }

        // An Airc that already has two of the Arc's Spaces (an earlier import), a Space of its own named like one of
        // Arc's, and a Today tab of the earlier import closed since.
        var before = StoreCounts()
        var closedToday: String?
        run { [self] in
            guard let plan = OnboardingFixture.bigPlan() else { return check(false, "importux: the big fixture decodes") }
            let store = c.store
            let b = ImportAdapter.blueprint(from: plan)
            let r = try? store.applyImport(b, options: ImportOptions(spaces: [Big.spaces[0], Big.spaces[1]], includeToday: true, includeFavorites: true))
            _ = try? store.createSpace(name: "Family")
            if let sid = r?.spaceIDs[Big.spaces[0]], let t = store.todayTabs(ofSpace: sid).first {
                closedToday = t.sourceID
                _ = try? store.closeTab(t.id)
            }
            c.reloadAll(animated: false)
            before = StoreCounts(store)
            note("importux: before the re-run: \(store.orderedSpaces.count) Spaces, \(store.state.profiles.count) profiles, "
                 + "\(before.items) sidebar items, \(before.today) Today tabs")
            OnboardingFixture.useBigPlan = true
            GoogleAccountProbe.testURL = signedIn
            let f = FakeDefaultBrowser()
            fake = f
            DefaultBrowser.shared.system = f
        }

        // MARK: The import step (Airc menu → Import from Arc…)

        run { [self] in app?.startOnboarding(mode: .rerun, atImport: true) }
        waitForReveal()
        run { [self] in
            guard let o = app?.onboarding else { return check(false, "importux: Import from Arc… opens the onboarding window") }
            let m = o.model
            let c = m.counts
            check(m.step == .arc && c.spaces == 6 && c.profiles == 6 && c.tabs == 175,
                  "importux: the import step counts 6 Spaces · 6 profiles · 175 tabs (\(c.spaces) · \(c.profiles) · \(c.tabs))")
            check(m.reimport?.line == "2 already in Airc · 4 new, after yours · 1 named like one of yours",
                  "importux: the re-import says what happens to the Spaces already here (\(m.reimport?.line ?? "-"))")
            let summaries = m.importChanges.map(\.summary)
            let expected = ["1 Easel was left out", "2 Notes were left out", "1 live folder is now a plain folder",
                            "1 tab group became single tabs", "1 split view became separate tabs", "1 Arc profile folder is missing"]
            check(expected.allSatisfy(summaries.contains) && !summaries.contains { $0.contains("flattened") },
                  "importux: the import names what changes on the way (\(summaries.joined(separator: "; ")))")
            check(TestAnchors.frames["onboarding.import.details"] != nil, "importux: the changes line has a Details button")
            check(o.window.frame.size == AircMetrics.Onboarding.windowSize,
                  "importux: the window is 760 × 540 (\(NSStringFromSize(o.window.frame.size)))")
            let page = TestAnchors.frames["onboarding.page"] ?? .null
            check(page == CGRect(origin: .zero, size: AircMetrics.Onboarding.windowSize),
                  "importux: the page fills the window exactly, nothing pushed past its edges (\(NSStringFromRect(page)))")
            let preview = TestAnchors.frames["onboarding.preview"] ?? .null
            check(preview == CGRect(x: 0, y: 0, width: AircMetrics.Sidebar.defaultWidth, height: AircMetrics.Onboarding.windowSize.height),
                  "importux: the sidebar preview is 228 × 540 at the window's edge (\(NSStringFromRect(preview)))")
            let content = TestAnchors.frames["onboarding.content"] ?? .null
            check(content.minX == AircMetrics.Sidebar.defaultWidth + AircMetrics.Onboarding.cardPadding
                  && content.maxX == AircMetrics.Onboarding.windowSize.width - AircMetrics.Onboarding.cardPadding,
                  "importux: the card is flush with the window's right edge, no strip of theme (content \(NSStringFromRect(content)))")
        }
        // Every Space in the preview: nothing else moves.
        stableFrames("importux: import step, the preview on each Space", keys: Self.pageKeys) { m in
            (0..<m.previewSpaces.count).map { i -> () -> Void in { m.focusedSpace = i } }
        }
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            m.focusedSpace = 0
            m.onImportEverything?()
        }

        // MARK: Spaces and accounts

        step { [self] done in
            waitUntil({ self.app?.onboarding?.model.checkingAccounts.isEmpty == true && self.app?.onboarding?.model.isImporting == false }, timeout: 12) { done() }
        }
        wait(0.6)
        run { [self] in
            guard let o = app?.onboarding, let r = o.model.result else { return check(false, "importux: the import ran") }
            let m = o.model
            let rows = m.profileRows
            let heights = rows.map { TestAnchors.frames["onboarding.account.\($0.id)"]?.height ?? 0 }
            check(m.step == .accounts && rows.count == 6 && rows.count == m.counts.profiles,
                  "importux: Spaces and accounts lists every profile (\(rows.count) rows for \(m.counts.profiles) profiles: \(rows.map(\.profile.name).joined(separator: ", ")))")
            check(heights.allSatisfy { $0 == AccountsStep.rowHeight },
                  "importux: every profile row is \(Int(AccountsStep.rowHeight)) pt (\(heights.map { "\(Int($0))" }.joined(separator: ", ")))")
            check(rows.contains { $0.id == Big.missing && $0.profile.name == "Profile 7" } && r.profileIDs[Big.missing] != nil,
                  "importux: the Space whose profile is missing from Arc's list gets its own profile, not the default one")
            // Signed in (the profiles that were here before the import) and not (the ones it just made).
            let personal = m.accounts[Big.personal], work = m.accounts[Big.work]
            let store = self.c.store
            check(personal?.email == "alex@example.com" && personal?.name == "Alex Example" && work?.email == "alex@example.com"
                  && store.profile(r.profileIDs[Big.personal])?.googleAccount == "alex@example.com",
                  "importux: profiles signed in to Google show it, from their own cookies (mock ListAccounts)")
            check(TestAnchors.frames["onboarding.account.signedIn.\(Big.personal)"] != nil,
                  "importux: the signed-in row says Signed in, with the account and Switch…")
            check(m.accountPhotos[Big.personal] != nil, "importux: the signed-in row shows the account's picture")
            check([Big.side, Big.family, Big.studio, Big.missing].allSatisfy { m.accounts[$0] == nil },
                  "importux: profiles the import just made aren't asked and show Sign in")
            // Re-importing duplicates nothing.
            let after = StoreCounts(store)
            check(after.duplicateSourceIDs == 0, "importux: re-import: every Arc Space, item, tab and profile is in Airc once (\(after.duplicateSourceIDs) twice)")
            check(store.orderedSpaces.count == 7 && r.spacesUpdated == 2 && r.spacesCreated == 4,
                  "importux: re-import: 2 Spaces updated in place, 4 added after the user's 3 (\(store.orderedSpaces.count) Spaces, "
                  + "\(r.spacesUpdated) updated, \(r.spacesCreated) added)")
            let favs = store.favorites(ofProfile: store.defaultProfile.id).count
            check(favs == SpacesStore.maxFavorites, "importux: re-import: the Personal profile keeps 12 Favorites, not 24 (\(favs))")
            let personalSpace = r.spaceIDs[Big.spaces[0]].flatMap { store.space($0) }
            let back = personalSpace.map { s in store.todayTabs(ofSpace: s.id).contains { $0.sourceID == closedToday } } ?? true
            check(closedToday != nil && !back, "importux: re-import: a Today tab closed since the first import doesn't come back")
            note("importux: after the re-run: \(store.orderedSpaces.count) Spaces, \(store.state.profiles.count) profiles, "
                 + "\(after.items) sidebar items (\(before.items) before), \(after.today) Today tabs")
        }
        // Hovering every row: the preview switches profile and Space; nothing moves or resizes.
        stableFrames("importux: Spaces and accounts, hovering every profile row", keys: Self.pageKeys + Self.rowKeys) { m in
            m.profileRows.flatMap { row -> [() -> Void] in [{ m.hover(profile: row.id, inside: true) }, { m.hover(profile: row.id, inside: false) }] }
        }
        // A signed-out answer clears the account; signing in again brings it back.
        step { [self] done in
            guard let o = app?.onboarding, let pid = o.model.result?.profileIDs[Big.work] else { return done() }
            GoogleAccountProbe.testURL = signedOut
            o.checkAccount(source: Big.work, profileID: pid)
            waitUntil({ o.model.checkingAccounts.isEmpty }, timeout: 10) {
                self.check(o.model.accounts[Big.work] == nil && self.c.store.profile(pid)?.googleAccount == nil,
                           "importux: a signed-out answer shows Sign in again and clears the profile's account")
                GoogleAccountProbe.testURL = signedIn
                o.checkAccount(source: Big.work, profileID: pid)
                self.waitUntil({ o.model.checkingAccounts.isEmpty }, timeout: 10) { done() }
            }
        }
        previewMatchesSidebar()
        // Logins being written: the re-run can't be closed; once they're in, it can.
        run { [self] in
            guard let o = app?.onboarding else { return }
            o.model.logins = .reading(0.3)
            _ = Self.press(o.window, Self.key("w", 13, .command, o.window))
        }
        wait(0.5)
        run { [self] in
            guard let o = app?.onboarding else { return check(false, "importux: ⌘W while logins are written leaves the window open (it closed)") }
            check(o.window.isVisible && o.model.closeBlockedReason != nil,
                  "importux: while logins are being written, ⌘W does nothing and the ✕ is disabled (\(o.model.closeBlockedReason ?? "no reason"))")
            o.model.logins = .idle
        }
        // ⌘T and ⌘W never act on the browser window behind.
        var tabs = 0
        run { [self] in
            guard let o = app?.onboarding else { return }
            tabs = c.store.todayTabs(ofSpace: c.currentSpaceID).count + c.store.pinnedRows(ofSpace: c.currentSpaceID).count
            let swallowed = Self.press(o.window, Self.key("t", 17, .command, o.window))
            check(swallowed, "importux: ⌘T in the onboarding window is kept from the browser's menu")
            _ = Self.press(o.window, Self.key("w", 13, .command, o.window))
        }
        wait(0.6)
        run { [self] in
            check(app?.onboarding == nil, "importux: ⌘W closes the re-run (Spaces and accounts)")
            let now = c.store.todayTabs(ofSpace: c.currentSpaceID).count + c.store.pinnedRows(ofSpace: c.currentSpaceID).count
            check(now == tabs && c.commandBar == nil, "importux: ⌘W and ⌘T didn't touch the browser window (rows \(tabs) → \(now), command bar \(c.commandBar == nil ? "closed" : "open"))")
        }

        // MARK: Closing from every step

        closeChecks()

        // MARK: Every step, light and dark, at three sizes

        run { GoogleAccountProbe.testURL = mixed }
        shootEveryStep(dark: false)
        shootEveryStep(dark: true)
        run { [self] in
            NSApp.appearance = nil
            DefaultBrowser.shared.system = SystemDefaultBrowser()
            GoogleAccountProbe.testURL = nil
            mock.stop()
            _ = fake
            let s = StoreCounts(c.store)
            check(s.duplicateSourceIDs == 0, "importux: after three imports of the same Arc, still nothing twice (\(s.items) sidebar items)")
        }
    }

    // MARK: Closing

    func closeChecks(_ label: String = "importux") {
        // ⌘W from every step of a re-run (Settings → Run onboarding again).
        let steps: [OnboardingStep] = [.welcome, .arc, .accounts, .logins, .theme, .defaultBrowser, .done]
        for target in steps {
            openRerun(atImport: false)
            advance(to: target)
            run { [self] in
                guard let o = app?.onboarding else { return check(false, "\(label): re-run open at \(target)") }
                let close = TestAnchors.frames["onboarding.close"] ?? .null
                check(o.model.step == target && close.maxX == AircMetrics.Onboarding.windowSize.width - 22 && close.minY == 22,
                      "\(label): the re-run shows its ✕ at \(target) (\(o.model.step), \(NSStringFromRect(close)))")
                _ = Self.press(o.window, Self.key("w", 13, .command, o.window))
            }
            wait(0.5)
            run { [self] in check(app?.onboarding == nil, "\(label): ⌘W closes the re-run at \(target)") }
        }
        // Esc on the first step: Import from Arc… (the import step) and Run onboarding again (welcome).
        for atImport in [true, false] {
            openRerun(atImport: atImport)
            run { [self] in
                guard let o = app?.onboarding else { return }
                Self.deliver(o.window, Self.key("\u{1b}", 53, [], o.window))
            }
            wait(0.5)
            run { [self] in check(app?.onboarding == nil, "\(label): Esc on the first step closes the re-run (\(atImport ? "import step" : "welcome"))") }
        }
        // Esc on a later step goes back, it doesn't close.
        openRerun(atImport: true)
        advance(to: .accounts)
        run { [self] in
            guard let o = app?.onboarding else { return }
            Self.deliver(o.window, Self.key("\u{1b}", 53, [], o.window))
        }
        wait(0.5)
        run { [self] in
            check(app?.onboarding?.model.step == .arc, "\(label): Esc on a later step goes back a step (\(app?.onboarding.map { "\($0.model.step)" } ?? "closed"))")
            app?.onboarding?.requestClose()
        }
        wait(0.4)
        // The ✕: a real click when the run can post one, else its action.
        openRerun(atImport: true)
        step { [self] done in
            guard let o = app?.onboarding, let host = MainActor.assumeIsolated({ o.window.contentContainer.subviews.first }) else { return done() }
            clickAnchor("onboarding.close", in: host) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if self.app?.onboarding == nil {
                        self.check(true, "\(label): a click on the ✕ closes the re-run")
                    } else {
                        self.skip("\(label): a posted click on the ✕ didn't land (\(TestAnchors.lastHit["onboarding.close"] ?? "-")); using its action")
                        o.model.onClose?()
                        self.check(self.app?.onboarding == nil, "\(label): the ✕'s action closes the re-run")
                    }
                    done()
                }
            }
        }
        // ⌘Q: a tap shows the hint. Posted, the key-up reaches the app's event monitors with AppKit's application class;
        // Chromium's hands a ⌘ key-up to the key window instead (and this run's window is never key), so it's handed
        // to the window the way Chromium would.
        openRerun(atImport: true)
        run { [self] in
            guard let o = app?.onboarding else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] { NSApp.postEvent(Self.key("q", 12, .command, o.window, type: type), atStart: false) }
        }
        wait(0.3)
        var how = "posted"
        run { [self] in
            guard let o = app?.onboarding, !o.model.showsQuitHint else { return }
            how = "at the window, as Chromium delivers it"
            Self.deliver(o.window, Self.key("q", 12, .command, o.window, type: .keyUp))
        }
        wait(0.2)
        run { [self] in
            check(app?.onboarding?.model.showsQuitHint == true, "\(label): a ⌘Q tap shows Hold ⌘Q to Quit in the onboarding window (\(how))")
            app?.onboarding?.requestClose()
        }
        wait(0.4)
        // The first run: no ✕, ⌘W and Esc don't close it (ON-5).
        var first: OnboardingController?
        run { [self] in
            guard let app else { return }
            TestAnchors.frames["onboarding.close"] = nil
            let o = OnboardingController(app: app, mode: .firstRun, fixture: OnboardingFixture.bigPlan())
            first = o
            o.present(focus: false)
        }
        wait(0.6)
        run { [self] in
            guard let o = first else { return }
            _ = Self.press(o.window, Self.key("w", 13, .command, o.window))
            Self.deliver(o.window, Self.key("\u{1b}", 53, [], o.window))
        }
        wait(0.5)
        run { [self] in
            guard let o = first else { return }
            check(o.window.isVisible && !o.model.closable && TestAnchors.frames["onboarding.close"] == nil,
                  "\(label): the first run has no ✕, and ⌘W and Esc don't close it (ON-5)")
            o.window.orderOut(nil)
            first = nil
        }
    }

    func openRerun(atImport: Bool) {
        run { [self] in app?.startOnboarding(mode: .rerun, atImport: atImport) }
        if atImport { waitForReveal() } else { wait(0.6) }
    }

    /// Walks the open re-run forward to `target` through the steps' own intents.
    func advance(to target: OnboardingStep) {
        step { [self] done in
            guard let o = app?.onboarding else { return done() }
            let m = o.model
            func go() {
                guard m.step != target else { return done() }
                switch m.step {
                case .welcome: m.onNext?()
                case .arc:
                    guard m.hasArc else { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: go) }
                    m.onImportEverything?()
                case .accounts: m.onNext?()
                case .logins: m.onSkipLogins?()
                case .theme, .defaultBrowser: m.onNext?()
                case .done: return done()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: go)
            }
            go()
        }
    }

    func waitForReveal() {
        step { [self] done in
            waitUntil({
                guard let m = self.app?.onboarding?.model, m.hasArc else { return false }
                return m.revealedSpaces >= m.previewSpaces.count && m.revealedFavorites >= m.favorites(of: m.previewSpaces[0]).count
            }, timeout: 8) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done) }
        }
    }

    // MARK: Frames that must not move

    /// The preview's rows move inside it with the Favorites a profile has (as in the sidebar); its bounds, its footer
    /// edge and its row height don't.
    static let pageKeys = ["onboarding.page", "onboarding.preview", "preview rows bottom", "preview row height",
                                   "onboarding.content", "onboarding.primary"]
    /// Placeholder for "every account row" (filled from the model).
    static let rowKeys = ["rows"]

    /// Runs each change in turn and checks that the window and every frame in `keys` stay exactly where they were.
    func stableFrames(_ what: String, keys: [String], _ changes: @escaping (OnboardingModel) -> [() -> Void]) {
        var baseline: [String: CGRect] = [:]
        var moved: [String] = []
        var count = 0
        func frames() -> [String: CGRect] {
            guard let o = app?.onboarding else { return [:] }
            var f = ["window": o.window.frame]
            for k in keys {
                if k == "rows" {
                    for r in o.model.profileRows { f["row \(r.profile.name)"] = TestAnchors.frames["onboarding.account.\(r.id)"] ?? .null }
                } else if k == "preview rows bottom" {
                    f[k] = CGRect(x: 0, y: (TestAnchors.frames["onboarding.preview.rows"] ?? .null).maxY, width: 0, height: 0)
                } else if k == "preview row height" {
                    f[k] = CGRect(x: 0, y: 0, width: 0, height: (TestAnchors.frames["onboarding.preview.line0"] ?? .null).height)
                } else {
                    f[k] = TestAnchors.frames[k] ?? .null
                }
            }
            return f
        }
        run { baseline = frames() }
        step { [self] done in
            guard let m = app?.onboarding?.model else { return done() }
            let list = changes(m)
            count = list.count
            func apply(_ i: Int) {
                guard i < list.count else { return done() }
                list[i]()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let now = frames()
                    for (k, v) in baseline where now[k] != v {
                        moved.append("\(k) \(NSStringFromRect(v)) → \(NSStringFromRect(now[k] ?? .null)) (change \(i + 1))")
                    }
                    apply(i + 1)
                }
            }
            apply(0)
        }
        run { [self] in
            check(!baseline.isEmpty && moved.isEmpty,
                  "\(what): the window and \(baseline.count - 1) frames stay put through \(count) changes"
                  + (moved.isEmpty ? "" : "; moved: " + moved.prefix(4).joined(separator: "; ")))
        }
    }

    // MARK: The preview against the real sidebar

    /// The preview's rows are the browser sidebar's: same pitch, same row font and favicon (AircMetrics). Shoots both
    /// side by side on the same Space (`ux-preview-vs-sidebar.png`).
    func previewMatchesSidebar(_ label: String = "importux") {
        run { [self] in
            guard let o = app?.onboarding, let sid = o.model.result?.spaceIDs[Big.spaces[0]] else { return }
            o.model.hoveredProfile = nil
            o.model.focusedSpace = 0
            c.switchToSpace(sid, animated: false)
        }
        wait(0.9)
        run { [self] in
            guard let o = app?.onboarding else { return }
            let l0 = TestAnchors.frames["onboarding.preview.line0"] ?? .null, l1 = TestAnchors.frames["onboarding.preview.line1"] ?? .null
            let preview = l1.minY - l0.minY
            // The real rows: the visible Space page's tab rows, top first.
            let rows = Self.views(TabRowView.self, in: c.sidebar).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
                .map { $0.convert($0.bounds, to: nil) }
                .filter { $0.minX >= 0 && $0.maxX <= c.sidebar.convert(c.sidebar.bounds, to: nil).maxX }
                .sorted { $0.maxY > $1.maxY }
            let pitches = zip(rows, rows.dropFirst()).map { $0.minY - $1.minY }.filter { $0 > 0 && $0 < 60 }
            let real = pitches.sorted().first ?? 0
            check(preview == AircMetrics.Row.pitch && real == AircMetrics.Row.pitch && l0.height == AircMetrics.Row.pitch,
                  "\(label): the preview's rows are the real sidebar's: \(preview) pt pitch in the preview, \(real) pt in the sidebar (AircMetrics.Row.pitch \(AircMetrics.Row.pitch))")
            // Side by side, same scale: the preview (left) and the browser's sidebar on the same Space (right).
            guard let pv = o.window.contentView.flatMap({ render($0) }), let bv = c.window.contentView.flatMap({ render($0) }) else { return }
            let w = AircMetrics.Sidebar.defaultWidth, h = AircMetrics.Onboarding.windowSize.height
            let gap: CGFloat = 24
            let size = NSSize(width: 2 * w + gap, height: h)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            pv.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: NSRect(x: 0, y: pv.size.height - h, width: w, height: h), operation: .sourceOver, fraction: 1)
            bv.draw(in: NSRect(x: w + gap, y: 0, width: w, height: h), from: NSRect(x: 0, y: bv.size.height - h, width: w, height: h), operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("ux-preview-vs-sidebar.png"))
            note("wrote ux-preview-vs-sidebar.png")
        }
    }

    private static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { v -> [T] in ((v as? T).map { [$0] } ?? []) + views(type, in: v) }
    }

    // MARK: Shots

    private func shootEveryStep(dark: Bool) {
        let mode = dark ? "dark" : "light"
        run { [self] in
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            app?.startOnboarding(mode: .rerun)
        }
        wait(0.9)
        shoot("ux-\(mode)-1-welcome")
        run { [self] in app?.onboarding?.model.onNext?() }
        waitForReveal()
        shoot("ux-\(mode)-2-import")
        run { [self] in app?.onboarding?.model.choosing = true }
        wait(0.6)
        shoot("ux-\(mode)-2b-choose")
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            m.choosing = false
            m.onImportEverything?()
        }
        step { [self] done in waitUntil({ self.app?.onboarding?.model.checkingAccounts.isEmpty == true }, timeout: 10) { done() } }
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            m.hover(profile: Big.personal, inside: true)
        }
        wait(1.2)
        shoot("ux-\(mode)-3-accounts")
        run { [self] in
            guard let m = app?.onboarding?.model else { return }
            m.hover(profile: Big.personal, inside: false)
            m.onNext?()
        }
        wait(0.7)
        shoot("ux-\(mode)-3b-logins")
        run { [self] in app?.onboarding?.model.onSkipLogins?() }
        wait(0.7)
        shoot("ux-\(mode)-4-theme")
        run { [self] in app?.onboarding?.model.onNext?() }
        wait(0.7)
        shoot("ux-\(mode)-5-default-browser")
        run { [self] in app?.onboarding?.model.onDefaultNotNow?() }
        wait(0.8)
        shoot("ux-\(mode)-6-done")
        run { [self] in
            guard let o = app?.onboarding else { return }
            _ = Self.press(o.window, Self.key("w", 13, .command, o.window))
        }
        wait(0.5)
    }

    /// The window at 2× on a sample desktop, and on a 1280 × 800 and a 1512 × 982 screen where onboarding places it.
    private func shoot(_ name: String) {
        step { [self] done in
            guard let w = app?.onboarding?.window else { note("\(name): no onboarding window"); return done() }
            captureWindow(w, name: name, rounded: AircMetrics.Onboarding.windowRadius) {
                self.onScreens(w, name: name)
                done()
            }
        }
    }

    private func onScreens(_ w: NSWindow, name: String) {
        guard let view = w.contentView, let content = render(view) else { return }
        // Menu bars: 24 pt, and 37 pt on a notched 14" (1512 × 982).
        for (label, screen, menuBar) in [("1280x800", NSSize(width: 1280, height: 800), CGFloat(24)), ("1512x982", NSSize(width: 1512, height: 982), CGFloat(37))] {
            let visible = CGRect(x: 0, y: 0, width: screen.width, height: screen.height - menuBar)
            let f = MainActor.assumeIsolated { AircFloatingWindow.centeredFrame(size: w.frame.size, in: visible) }
            if name.hasSuffix("1-welcome") {
                check(visible.contains(f), "importux: the window fits a \(label) screen (\(NSStringFromRect(f)))")
            }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(screen.width), pixelsHigh: Int(screen.height), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = screen
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGradient(colors: [NSColor(red: 0.20, green: 0.17, blue: 0.40, alpha: 1), NSColor(red: 0.55, green: 0.32, blue: 0.55, alpha: 1),
                                NSColor(red: 0.90, green: 0.55, blue: 0.40, alpha: 1)])?.draw(in: NSRect(origin: .zero, size: screen), angle: -35)
            NSColor(white: 1, alpha: 0.55).setFill()
            NSRect(x: 0, y: screen.height - menuBar, width: screen.width, height: menuBar).fill()
            let r = AircMetrics.Onboarding.windowRadius
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: f, xRadius: r, yRadius: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSBezierPath(roundedRect: f, xRadius: r, yRadius: r).addClip()
            content.draw(in: f)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])?.write(to: dir.appendingPathComponent("\(name)-\(label).jpg"))
        }
        note("wrote \(name)-1280x800.jpg, \(name)-1512x982.jpg")
    }

    // MARK: Helpers

    func writeMockPhoto(to url: URL) {
        let size = 96
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(red: 0.36, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.62, green: 0.40, blue: 0.90, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -45)
        let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 52, weight: .semibold), .foregroundColor: NSColor.white])
        a.draw(at: NSPoint(x: (CGFloat(size) - a.size().width) / 2, y: (CGFloat(size) - a.size().height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// A key equivalent the way AppKit hands it to the key window first (the onboarding window is never key in a
    /// scripted run, so NSApp would give it to the menu instead).
    @discardableResult
    static func press(_ w: AircFloatingWindow, _ e: NSEvent) -> Bool {
        MainActor.assumeIsolated { w.performKeyEquivalent(with: e) }
    }

    /// An event straight to the window (Esc; a ⌘ key-up the way Chromium hands it to the key window).
    static func deliver(_ w: AircFloatingWindow, _ e: NSEvent) {
        MainActor.assumeIsolated { w.sendEvent(e) }
    }

    static func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags, _ w: NSWindow,
                            type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }
}

/// A loopback ListAccounts for the account checks, never a real Google account: one synthetic account (its picture a
/// scratch file), an empty list, and "mixed" (of each round of six profiles, asked one at a time in row order, the first
/// two are signed in).
final class AccountMock {
    let photo: URL
    private(set) var signedIn: URL?
    private(set) var signedOut: URL?
    private(set) var mixed: URL?
    private var servers: [LocalPageServer] = []

    init(photo: URL) { self.photo = photo }

    var account: String {
        #"["gaia.l.a.r",[["gaia.l.a",1,"Alex Example","alex@example.com","\#(photo.absoluteString)",1,1,0,null,1,"100000000000000000001",null,null,null,null,1]]]"#
    }

    func start(_ done: @escaping (Bool) -> Void) {
        let account = account, empty = #"["gaia.l.a.r",[]]"#
        guard let a = LocalPageServer(pages: ["/ListAccounts": account]), let b = LocalPageServer(pages: ["/ListAccounts": empty]),
              let x = LocalPageServer(pages: [:]) else { return done(false) }
        var asked = 0   // the server's queue only
        x.handler = { path in
            guard path == "/ListAccounts" else { return nil }
            asked += 1
            return LocalPageServer.Page(body: (asked - 1) % 6 < 2 ? account : empty)
        }
        servers = [a, b, x]
        func url(_ p: UInt16?) -> URL? { p.map { URL(string: "http://127.0.0.1:\($0)/ListAccounts")! } }
        a.start { p in
            self.signedIn = url(p)
            b.start { q in
                self.signedOut = url(q)
                x.start { r in
                    self.mixed = url(r)
                    done(self.signedIn != nil && self.signedOut != nil && self.mixed != nil)
                }
            }
        }
    }

    func stop() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: photo)
    }
}

extension SnapshotRunner {
    /// Starts `mock` (with its picture) as a step; logs whether it's up.
    func startAccountMock(_ mock: AccountMock, _ label: String) {
        step { [self] done in
            writeMockPhoto(to: mock.photo)
            mock.start { ok in
                self.check(ok, "\(label): the loopback ListAccounts mock starts")
                done()
            }
        }
    }
}

/// What the store holds, for the re-import checks.
struct StoreCounts {
    var items = 0
    var today = 0
    /// Arc IDs that appear more than once among Spaces, items, tabs and profiles.
    var duplicateSourceIDs = 0

    init() {}

    init(_ s: SpacesStore) {
        let st = s.state
        items = st.items.count
        today = st.tabs.count
        func dups(_ ids: [String]) -> Int { ids.count - Set(ids).count }
        duplicateSourceIDs = dups(st.spaces.values.compactMap(\.sourceID)) + dups(st.items.values.compactMap(\.sourceID))
            + dups(st.tabs.values.compactMap(\.sourceID)) + dups(st.profiles.values.compactMap(\.sourceID))
    }
}
#endif
