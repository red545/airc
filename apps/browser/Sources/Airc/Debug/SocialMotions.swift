// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit

/// The social studio's motions, one per feature (`--script social`, AIRC_SOCIAL_MOTION; SocialFrames.swift has the reel
/// and the frame helpers). Each sets the app's own state a frame at a time, as a person's input leaves it, and draws the
/// window offscreen. Demo data only:
///   - multiselect: three Today tabs ⌘-clicked one by one in Personal, their menu (drawn from the app's own
///     `selectionMenu`, as MultiSelectShots.swift draws it: a system menu can't be captured), then New Folder with 3 Tabs;
///   - boosts: Wikipedia's Typography article in Personal, the Boost editor's tint going up on Colors, Charter on Font,
///     then a zap;
///   - commandbar: ⌘T in Travel and "lisbon" typed a letter at a time;
///   - intro: one take for the intro video, on the swipe's pages (SocialFrames.swift): Personal, a swipe to Travel, ⌘T
///     and "lisbon", then swipes to Studio and to Work (its own profile), each beat labelled for its caption;
///   - import: onboarding's move from Arc, on the marketing shots' fixtures (OnboardingFixture's Arc, BrowserFixtures'
///     other browsers; automated runs never read the Mac's own): welcome, Arc's Spaces in the preview one by one,
///     Chrome's profiles, Import Everything, the profiles, a colour for a Space, done;
///   - sidebarright: Travel on Lisbon, the sidebar moved to the right, then a swipe to Studio on that side;
///   - private: a new private window, two articles opened in it, then ⌘F and "cookie" typed a letter at a time;
///   - split: Travel on Lisbon, the map added beside it, then the trams on the other side, then the divider between the
///     map and the city dragged (the panes reflow at each tick).
/// These are features of a release (0.1.2), so they build from its own source too; newer ones are in SocialNext.swift.
extension SnapshotRunner {
    func socialSpace(_ name: String) -> String? { c.store.orderedSpaces.first { $0.name == name }?.id }

    func socialTab(_ space: String, _ url: String) -> String? {
        socialSpace(space).flatMap { s in c.store.todayTabs(ofSpace: s).first { $0.url.contains(url) }?.id }
    }

    /// `space` on its Today tab whose address contains `url`, loaded and settled.
    func socialShow(_ space: String, _ url: String) {
        run { [self] in
            guard let s = socialSpace(space) else { return note("social: MISSING Space \(space)") }
            if c.currentSpaceID != s { c.switchToSpace(s, animated: false) }
            if let t = socialTab(space, url) { c.show(t, focus: false) } else { note("social: MISSING \(space) tab on \(url)") }
        }
        mkSettleShown(timeout: 20, extra: 1.5)
    }

    // MARK: Select several tabs

    func socialMultiSelect() {
        let reel = SocialReel("multiselect")
        socialShow("Personal", "wikipedia.org/wiki/Typography")
        var ids: [String] = []
        run { [self] in
            ids = ["wikivoyage.org/wiki/Kyoto", "www.swift.org", "nytimes.com/section/travel"].compactMap { socialTab("Personal", $0) }
            if ids.count < 3 { note("social: MISSING multiselect: \(ids.count) of 3 tabs") }
        }
        socialFrame(reel, hold: 0.9, label: "select")
        for n in 1...3 {
            run { [self] in
                c.pageView(for: c.currentSpaceID)?.setSelection(Array(ids.prefix(n)))
                c.root.layoutSubtreeIfNeeded()
            }
            wait(0.3)
            socialFrame(reel, hold: n == 3 ? 0.7 : 0.45, label: "select")
        }
        // The menu a right-click on the middle row opens there: as it opens, then with New Folder under the pointer.
        for lit in [nil, "New Folder with 3 Tabs"] as [String?] {
            socialOverlayFrame(reel, hold: lit == nil ? 0.5 : 0.8, label: "menu") { [self] in
                guard let page = c.pageView(for: c.currentSpaceID), ids.count > 1, let row = page.rows[ids[1]] else { return [] }
                let menu = c.selectionMenu(ids: page.selection, spaceID: page.spaceID)
                guard let image = Self.mkMenuImage(menu, highlighted: lit, dark: mkIsDark()) else { return [] }
                let r = row.convert(row.bounds, to: nil)
                let at = NSPoint(x: r.minX + 150, y: r.midY + 6)
                return [(image, NSRect(x: at.x, y: at.y - image.size.height, width: image.size.width, height: image.size.height))]
            }
        }
        run { [self] in c.newFolderWithSelected(ids, spaceID: c.currentSpaceID) }
        wait(0.9)
        socialFrame(reel, hold: 2.2, label: "folder")
        socialWrite(reel)
    }

    // MARK: Boosts

    func socialBoosts() {
        let reel = SocialReel("boosts")
        socialShow("Personal", "wikipedia.org/wiki/Typography")
        socialFrame(reel, hold: 0.9, label: "page")
        run { [self] in
            BoostCenter.shared?.update(domain: "wikipedia.org") {
                $0.colors = BoostColors(hue: 0.09, tint: 0, brightness: 1, contrast: 1.04, invert: false)
            }
            c.showBoostEditor(section: .colors)
        }
        wait(1.2)
        socialFrame(reel, hold: 0.6, label: "colors")
        // The tint slider dragged up over 1.2 s (ease in and out), the page warming with it.
        let steps = 36
        for k in 1...steps {
            run { [self] in
                let p = Double(k) / Double(steps)
                let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                c.boostEditor?.model.color(\.tint).wrappedValue = 0.38 * e
            }
            wait(0.12)   // the page's new style paints before its snapshot
            socialFrame(reel, hold: k == steps ? 0.8 : 1.0 / 30, label: "colors")
        }
        run { [self] in c.boostEditor?.model.section = .font }
        wait(0.6)
        socialFrame(reel, hold: 0.5, label: "font")
        run { [self] in c.boostEditor?.model.setFamily(.charter) }
        wait(0.9)
        socialFrame(reel, hold: 1.1, label: "font")
        run { [self] in
            c.boostEditor?.model.section = .zap
            BoostCenter.shared?.update(domain: "wikipedia.org") { $0.zaps = [BoostZap(selector: ".vector-column-end", label: "Appearance")] }
            c.boostEditor?.model.reload()
        }
        wait(0.9)
        socialFrame(reel, hold: 1.8, label: "zap")
        socialWrite(reel)
        run { [self] in
            c.closeBoostEditor(animated: false)
            BoostCenter.shared?.remove(domain: "wikipedia.org", page: nil)
        }
    }

    // MARK: Command Bar

    func socialCommandBar() {
        let reel = SocialReel("commandbar")
        socialShow("Travel", "wikipedia.org/wiki/Lisbon")
        socialFrame(reel, hold: 0.8, label: "page")
        run { [self] in c.openCommandBar(mode: .newTab) }
        wait(0.8)
        socialFrame(reel, hold: 0.5, label: "open")
        let word = "lisbon"
        for n in 1...word.count {
            run { [self] in c.commandBar?.type(String(word.prefix(n))) }
            wait(0.5)   // its results for these letters arrive
            socialFrame(reel, hold: n == word.count ? 2.2 : 0.14, label: "typed")
        }
        socialWrite(reel)
        run { [self] in c.closeCommandBar() }
    }

    // MARK: The intro's take

    func socialIntro() {
        let reel = SocialReel("intro")
        // Every Space's page loaded and settled, the last first, so the take starts in Personal (SocialFrames.swift).
        let server = socialSpacesReady()
        socialFrame(reel, hold: 1.8, label: "sidebar")
        socialSwipeStep(reel, from: 0, label: "spaces")
        socialFrame(reel, hold: 0.9, label: "spaces")
        run { [self] in c.openCommandBar(mode: .newTab) }
        wait(0.8)
        socialFrame(reel, hold: 0.4, label: "commandbar")
        let word = "lisbon"
        for n in 1...word.count {
            run { [self] in c.commandBar?.type(String(word.prefix(n))) }
            wait(0.5)
            socialFrame(reel, hold: n == word.count ? 1.6 : 0.13, label: "commandbar")
        }
        run { [self] in c.closeCommandBar() }
        wait(0.4)
        socialFrame(reel, hold: 0.5, label: "commandbar")
        socialSwipeStep(reel, from: 1, label: "spaces")
        socialFrame(reel, hold: 0.6, label: "spaces")
        socialSwipeStep(reel, from: 2, label: "profiles")
        socialFrame(reel, hold: 2.0, label: "profiles")
        socialWrite(reel)
        run { server.value?.stop() }
    }

    // MARK: Moving from Arc

    func socialImport() {
        let reel = SocialReel("import")
        let fake = FakeDefaultBrowser()
        var o: OnboardingController?
        // Other browsers are synthetic (BrowserFixtures), never the Mac's own; Arc is OnboardingFixture's plan.
        let browsers = FileManager.default.temporaryDirectory.appendingPathComponent("AircSocialBrowsers-\(UUID().uuidString)")
        step { [self] done in
            guard let app else { return done() }
            let fixture = try? BrowserFixtures.write(to: browsers, holdHistory: false, publicSites: true)
            BrowserImportLocator.testHome = fixture?.home
            DefaultBrowser.shared.system = fake
            app.settings.values.defaultBrowser = DefaultBrowserState()
            let ob = OnboardingController(app: app, mode: .rerun, fixture: OnboardingFixture.plan())
            o = ob
            onboarding = ob
            ob.present(focus: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                ob.window.setFrameOrigin(NSPoint(x: -6000, y: 300))
                done()
            }
        }
        wait(1.0)
        let frame = { [self] (hold: Double, label: String) in
            socialWindowFrame(reel, { o?.window }, hold: hold, label: label, lights: false,
                              radius: AircMetrics.Onboarding.windowRadius) { [self] w, give in
                give(mkContentImage(w), w.contentView?.bounds.size ?? .zero)
            }
        }
        frame(1.5, "welcome")
        run { o?.model.onNext?() }
        wait(3.4)
        frame(1.3, "arc")
        // The preview on the left: each of Arc's Spaces in turn, as it will come over.
        for k in 1...3 {
            run {
                guard let m = o?.model, m.previewSpaces.count > k else { return }
                m.focusedSpace = k
            }
            wait(0.6)
            frame(0.8, "arc")
        }
        run { o?.model.onSelectSource?(.browser("chrome")) }
        wait(2.6)
        frame(1.5, "browsers")
        run { o?.model.onSelectSource?(.arc) }
        wait(2.4)
        run { o?.model.onImportEverything?() }
        wait(1.6)
        frame(1.9, "profiles")
        // On to the colours (no logins: that step would ask macOS for the Keychain).
        run { o?.model.onNext?() }
        wait(0.7)
        run { o?.model.onSkipLogins?() }
        wait(0.9)
        frame(0.9, "colours")
        for preset in ["sky", "lilac", "ember"] {
            run {
                guard let m = o?.model, m.previewSpaces.count > 2, let theme = DesignTheme.preset(preset) else { return }
                m.focusedSpace = 2
                m.themes[m.previewSpaces[2].sourceID] = theme.model
                m.onThemeChange?()
            }
            wait(0.8)
            frame(preset == "ember" ? 1.4 : 0.6, "colours")
        }
        run { o?.model.onNext?() }
        wait(0.8)
        run { o?.model.onDefaultNotNow?() }
        wait(0.9)
        frame(2.2, "done")
        socialWrite(reel)
        run { [self] in
            o?.window.orderOut(nil)
            onboarding = nil
            DefaultBrowser.shared.system = SystemDefaultBrowser()
            BrowserImportLocator.testHome = nil
            try? FileManager.default.removeItem(at: browsers)
        }
    }

    // MARK: The sidebar on the right

    func socialSidebarRight() {
        let reel = SocialReel("sidebarright")
        socialShow("Studio", "wikipedia.org/wiki/Color_theory")
        socialShow("Travel", "wikipedia.org/wiki/Lisbon")
        socialFrame(reel, hold: 1.6, label: "left")
        run { [self] in app?.setSidebarOnRight(true) }
        wait(0.8)   // the side's cross-fade
        socialFrame(reel, hold: 1.6, label: "right")
        socialSwipeStep(reel, from: 1, label: "swipe")
        socialFrame(reel, hold: 1.8, label: "swipe")
        socialWrite(reel)
        run { [self] in app?.setSidebarOnRight(false) }
        wait(0.6)
    }

    // MARK: Private windows

    func socialPrivate() {
        let reel = SocialReel("private")
        var w: PrivateWindowController?
        let size = NSSize(width: 1440, height: 900)
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { p in
                w = p
                if let p {
                    p.window.setFrame(NSRect(origin: NSPoint(x: self.c.window.frame.minX + 40, y: self.c.window.frame.minY - 40), size: size),
                                      display: true)
                }
                done()
            }
        }
        wait(0.6)
        let frame = { [self] (hold: Double, label: String) in
            socialWindowFrame(reel, { w?.window }, hold: hold, label: label, dark: true) { [self] _, give in
                guard let p = w else { return give(nil, .zero) }
                privateWindowImage(p) { give($0, p.root.bounds.size) }
            }
        }
        frame(1.4, "start")
        run {
            guard let p = w else { return }
            for url in ["https://en.wikipedia.org/wiki/HTTP_cookie", "https://en.wikipedia.org/wiki/Private_browsing"] {
                _ = p.openPage(URL(string: url))
            }
        }
        mkSettle({ w?.pages.map(\.tab) ?? [] }, timeout: 20, extra: 1.5)
        frame(1.6, "page")
        run { w?.showFind() }
        wait(0.5)
        let word = "cookie"
        for n in 1...word.count {
            run {
                guard let p = w else { return }
                p.findBar?.field.stringValue = String(word.prefix(n))
                p.findBar?.find(forward: true)
                p.window.makeFirstResponder(nil)
            }
            wait(0.4)   // the matches light up
            frame(n == word.count ? 2.0 : 0.14, "find")
        }
        socialWrite(reel)
        run { w?.closeFind(refocusPage: false) }
        run { w?.closeWindow() }
        wait(0.6)
    }

    // MARK: Split View

    func socialSplit() {
        let reel = SocialReel("split")
        socialShow("Travel", "wikipedia.org/wiki/Lisbon")
        var lisbon = "", map = "", trams = ""
        run { [self] in
            lisbon = socialTab("Travel", "wikipedia.org/wiki/Lisbon") ?? ""
            map = socialTab("Travel", "openstreetmap.org") ?? ""
            trams = socialTab("Travel", "wikipedia.org/wiki/Trams_in_Lisbon") ?? ""
            if lisbon.isEmpty || map.isEmpty || trams.isEmpty { note("social: MISSING split: Travel's Lisbon, map or trams tab") }
        }
        socialFrame(reel, hold: 1.3, label: "page")
        run { [self] in if !map.isEmpty { c.addPane(map, nextTo: lisbon, axis: .horizontal, leading: true) } }
        mkSettleShown()
        wait(0.8)
        socialFrame(reel, hold: 1.4, label: "two")
        run { [self] in if !trams.isEmpty { c.addPane(trams, nextTo: lisbon, axis: .horizontal) } }
        mkSettleShown()
        wait(0.8)
        socialFrame(reel, hold: 1.2, label: "three")
        // The divider between the map and the city dragged 140 pt to the right over 0.6 s, easing out as a hand slows.
        run { [self] in c.splitContainer.beginDividerDrag(0, at: .zero) }
        let ticks = 24
        for k in 1...ticks {
            run { [self] in
                let p = Double(k) / Double(ticks)
                c.splitContainer.dragDivider(0, to: NSPoint(x: 140 * (1 - pow(1 - p, 3)), y: 0))
            }
            wait(0.15)   // each page reflows at its new width before its snapshot
            socialFrame(reel, hold: k == ticks ? 0.3 : 1.0 / 40, label: "resize")
        }
        run { [self] in c.splitContainer.endDividerDrag(0) }
        wait(0.6)
        socialFrame(reel, hold: 2.0, label: "resize")
        socialWrite(reel)
        run { [self] in if let x = c.store.split(containing: lisbon) { c.separateSplit(x.id) } }
        wait(0.4)
    }
}
#endif
