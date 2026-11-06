// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// Part of `--script split-write` and `--script split-read` (both engines), in a Space of its own so the Today split
/// those runs keep is untouched: SV-2 pinned and Favorite splits and SB-15 Favorites unloading, through real input.
///   - a Today split's row dragged above the divider is one pinned row; the split stays on screen, same pages;
///   - a pane that wandered off shows " /"; a click on its favicon resets that pane only;
///   - ⌘W closes the pinned split (its pages go, the row stays, unloaded); a click on a segment opens both panes again,
///     that one focused;
///   - the row dragged above the Space name is one Favorite tile cut by a 2 pt gap; a click on it shows the split;
///     tiles reorder by drag; the tile dragged below the divider is a Today split again;
///   - pinned rows reorder by drag, and a split dropped onto a folder goes into it;
///   - Separate All Tabs in Pinned and Favorites puts the panes where the split was;
///   - SB-15 with a 1 s unload override: hidden Favorites (a tab and a split's panes) are freed and drawn at half
///     strength; one with typed input stays; a click loads the freed one again;
///   - relaunch: a pinned split (stacked, 40 / 60) and a Favorite split come back and open as they were.
extension SnapshotRunner {
    private static var favSplitSpaceName: String { "Split pins" }

    /// A page with its own favicon (a coloured rounded square, inline), so rows and tiles show real icons.
    private func favSplitPage(_ title: String, _ color: String, _ extra: String = "") -> String {
        let ink = ["Docs": "#E8664D", "Notes": "#3E9B6E", "Away": "#8A63D2", "Other": "#D9A21B", "Inbox": "#3B7BE0",
                   "Form": "#D9455F", "Alpha": "#2F8F83", "Beta": "#E07A3B", "Gamma": "#7A5AE0", "Delta": "#C9A227"][title] ?? "#888888"
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'><rect width='32' height='32' rx='8' fill='\(ink)'/>"
            + "<circle cx='16' cy='16' r='7' fill='white' fill-opacity='0.92'/></svg>"
        let icon = "<link rel='icon' href='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>"
        return "<head><title>\(title)</title>\(icon)</head><body style='margin:0;background:\(color);font:20px -apple-system'>"
            + "<h1 style='margin:40px'>\(title)</h1>\(extra)</body>"
    }

    private func pinnedSplitRow(_ id: String, in p: SpacePageView) -> SplitRowView? {
        p.layoutSubtreeIfNeeded()
        return p.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.splitItem?.id == id }
    }

    private func todaySplitRow(_ id: String, in p: SpacePageView) -> SplitRowView? {
        p.layoutSubtreeIfNeeded()
        return p.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.split?.id == id }
    }

    private func favoriteTile(_ id: String, in p: SpacePageView) -> FavoriteTileView? {
        p.layoutSubtreeIfNeeded()
        return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == id }
    }

    /// A window point in a Space page's list (list coordinates are flipped, from the top of the pinned section).
    private func listPoint(_ p: SpacePageView, x: CGFloat = 70, y: CGFloat) -> NSPoint { p.list.convert(NSPoint(x: x, y: y), to: nil) }

    private func centre(_ v: NSView, dx: CGFloat = 0) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX + dx, y: v.bounds.midY), to: nil) }

    /// `beforeUnloading` queues more steps between the SV-2 checks and the SB-15 ones (the split relaunch write): once
    /// pages have been freed, nothing after these checks opens a new page (see the report's engine ask).
    func favSplitChecks(beforeUnloading middle: () -> Void = {}) {
        var server: LocalPageServer?
        var base = ""
        var sid = "", home = "", split = "", other = "", mail = "", form = "", folder = "", pin = ""
        var pagesBefore: [ObjectIdentifier] = []
        func url(_ path: String) -> String { base + path }
        func paneTabs() -> [String] { c.store.paneTabs(ofSplitItem: split).map(\.id) }

        step { [self] done in
            let pages = ["/docs": favSplitPage("Docs", "#f4ece2"), "/notes": favSplitPage("Notes", "#e3f0ea"),
                         "/away": favSplitPage("Away", "#efe7f6"), "/other": favSplitPage("Other", "#f7f2df"),
                         "/mail": favSplitPage("Inbox", "#e6eef8"),
                         "/form": favSplitPage("Form", "#fbe9e7", "<input id=f style='margin:40px;font-size:20px'>")]
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "pinned split: a loopback page server") }
                done()
            }
        }
        run { [self] in
            home = c.currentSpaceID
            guard let s = try? c.store.createSpace(name: Self.favSplitSpaceName, profileID: c.store.profile(ofSpace: home).id, after: home) else {
                return check(false, "pinned split: a Space for the checks")
            }
            sid = s.id
            c.switchToSpace(sid, animated: false)
            let notes = (try? c.store.openTab(url: url("/notes"), inSpace: sid, activate: false, title: "Notes"))?.id ?? ""
            let docs = (try? c.store.openTab(url: url("/docs"), inSpace: sid, activate: false, title: "Docs"))?.id ?? ""
            other = (try? c.store.openTab(url: url("/other"), inSpace: sid, activate: false, title: "Other"))?.id ?? ""
            split = (try? c.store.createSplit([docs, notes], inSpace: sid, focused: notes))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(notes, focus: false)
        }
        waitForPage()

        // 1. The Today split's row dragged above the divider: pinned, one row, still on screen with the same pages.
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = todaySplitRow(split, in: p), let divider = p.rows["divider"] else {
                check(false, "pinned split (drag into Pinned): the split's row and the divider are shown"); return done()
            }
            pagesBefore = c.store.split(split)?.tabIDs.compactMap { c.engineTab(for: $0).map { ObjectIdentifier($0) } } ?? []
            let start = row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil)
            let end = listPoint(p, y: max(1, divider.frame.minY + 2))
            drag(from: start, to: end) {
                self.waitUntil({ self.c.store.item(split)?.kind == .split }, timeout: 3) {
                    let pinned = self.c.store.pinnedRows(ofSpace: sid).map(\.id) == [split]
                    let today = self.c.store.todayRows(ofSpace: sid).contains { $0.id == split }
                    let now = self.c.store.split(split)?.tabIDs.compactMap { self.c.engineTab(for: $0).map { ObjectIdentifier($0) } } ?? []
                    self.check(pinned && !today && self.c.shownSplitID == split && now == pagesBefore && now.count == 2,
                               "pinned split (drag into Pinned): dropped above the divider it's one pinned row (pinned \(pinned), in Today \(today)), "
                               + "still on screen (\(self.c.shownSplitID == split)) with the same two pages (\(now == pagesBefore))")
                    done()
                }
            }
        }
        wait(0.4)
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = pinnedSplitRow(split, in: p) else {
                check(false, "pinned split: its row in Pinned"); return done()
            }
            let tabs = paneTabs()
            let urls = c.store.panes(ofSplitItem: split).map(\.savedURL)
            check(row.segmentTitles.count == 2 && row.isSelected && urls == [url("/docs"), url("/notes")] && tabs.count == 2,
                  "pinned split: the row shows \(row.segmentTitles) (selected \(row.isSelected)); each pane keeps its saved URL (\(urls.compactMap { $0.map { URL(string: $0)?.path ?? $0 } }))")
            captureNow("pinned-split") { done() }
        }

        // 2. A pane that wanders off shows " /"; a click on its favicon resets that pane alone.
        var notesURL = ""
        step { [self] done in
            let tabs = paneTabs()
            guard tabs.count == 2, let docsPage = c.engineTab(for: tabs[0]), let away = URL(string: url("/away")) else {
                check(false, "pinned split (drift): two loaded panes"); return done()
            }
            notesURL = c.engineTab(for: tabs[1])?.url?.absoluteString ?? ""
            docsPage.load(away)
            waitUntil({ self.c.store.isDrifted(tabs[0]) && docsPage.isLoading == false }, timeout: 6) {
                self.c.reloadAll(animated: false)
                let row = self.c.pageView(for: sid).flatMap { self.pinnedSplitRow(split, in: $0) }
                let titles = row?.segmentTitles ?? []
                self.check(self.c.store.isDrifted(tabs[0]) && !self.c.store.isDrifted(tabs[1]) && titles.first?.hasSuffix(" /") == true
                           && titles.last?.hasSuffix(" /") == false,
                           "pinned split (drift): the pane that went elsewhere shows \" /\" (\(titles)), the other doesn't")
                done()
            }
        }
        step { [self] done in
            let tabs = paneTabs()
            guard tabs.count == 2, let p = c.pageView(for: sid), let row = pinnedSplitRow(split, in: p), let icon = row.faviconCentre(0) else {
                check(false, "pinned split (reset): the drifted pane's favicon"); return done()
            }
            click(at: icon, in: c.window) {
                self.waitUntil({ !self.c.store.isDrifted(tabs[0]) && self.c.engineTab(for: tabs[0])?.url?.path == "/docs" }, timeout: 5) {
                    let otherSame = self.c.engineTab(for: tabs[1])?.url?.absoluteString == notesURL
                    self.check(!self.c.store.isDrifted(tabs[0]) && self.c.engineTab(for: tabs[0])?.url?.path == "/docs" && otherSame,
                               "pinned split (reset): a click on the drifted pane's favicon takes that pane back to its saved URL "
                               + "(\(self.c.engineTab(for: tabs[0])?.url?.path ?? "-")); the other pane is untouched (\(otherSame))")
                    done()
                }
            }
        }

        // 3. ⌘W closes the pinned split: its pages go, its row stays (unloaded).
        step { [self] done in
            c.show(paneTabs().last ?? "", focus: false)
            let before = paneTabs()
            postKey("w", keyCode: 13, modifiers: .command)
            waitUntil({ paneTabs().isEmpty }, timeout: 4) {
                let p = self.c.pageView(for: sid)
                p?.reload(animated: false)
                let row = p.flatMap { self.pinnedSplitRow(split, in: $0) }
                let pagesGone = before.allSatisfy { self.c.engineTab(for: $0) == nil }
                let dim = row?.segmentAlphas.allSatisfy { $0 < 0.6 } ?? false
                self.check(paneTabs().isEmpty && self.c.store.item(split) != nil && row != nil && pagesGone && dim && self.c.shownSplitID != split,
                           "pinned split (⌘W): its pages close (\(pagesGone)), the row stays (\(row != nil)) with both favicons at half strength "
                           + "(\(row?.segmentAlphas.map { String(format: "%.1f", $0) } ?? []))")
                done()
            }
        }
        // …and a click on a segment opens both panes again, that one focused.
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = pinnedSplitRow(split, in: p), let seg = row.segmentCentre(1) else {
                check(false, "pinned split (reopen): the row"); return done()
            }
            click(at: seg, in: c.window) {
                self.waitUntil({ self.c.shownSplitID == split && paneTabs().allSatisfy { self.c.engineTab(for: $0)?.isLoading == false } }, timeout: 6) {
                    let tabs = paneTabs()
                    let paths = tabs.compactMap { self.c.engineTab(for: $0)?.url?.path }
                    self.check(self.c.shownSplitID == split && paths == ["/docs", "/notes"] && self.c.shownTabID == tabs.last,
                               "pinned split (reopen): a click on its second segment opens both panes at their saved URLs \(paths), that pane focused")
                    done()
                }
            }
        }

        // 4. Into Favorites: dragged above the Space name, one tile cut along the split.
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = pinnedSplitRow(split, in: p) else {
                check(false, "favorite split (drag into Favorites): the row"); return done()
            }
            let start = row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil)
            let end = p.convert(NSPoint(x: p.bounds.midX, y: p.header.frame.minY + 3), to: nil)
            drag(from: start, to: end) {
                self.waitUntil({ self.c.store.item(split)?.isFavorite == true }, timeout: 3) {
                    let pid = self.c.store.profile(ofSpace: sid).id
                    self.c.reloadAll(animated: false)
                    let tile = self.favoriteTile(split, in: p)
                    let parts = MainActor.assumeIsolated { tile?.splitFace?.partFrames } ?? []
                    let gap = parts.count == 2 ? parts[1].minX - parts[0].maxX : -1
                    self.check(self.c.store.favorites(ofProfile: pid).map(\.id) == [split] && tile != nil && parts.count == 2
                               && abs(gap - FavoriteSplitFace.gap) < 0.01 && self.c.store.pinnedRows(ofSpace: sid).isEmpty,
                               String(format: "favorite split (drag into Favorites): one tile cut in %d parts by a %.1f pt gap; no pinned row left", parts.count, gap))
                    self.captureNow("favorite-split-tile") { done() }
                }
            }
        }
        // A click on the tile shows the split (another tab in front first).
        step { [self] done in
            c.show(other, focus: false)
            guard let p = c.pageView(for: sid), let tile = favoriteTile(split, in: p) else { check(false, "favorite split (click): the tile"); return done() }
            click(at: centre(tile), in: c.window) {
                self.waitUntil({ self.c.shownSplitID == split }, timeout: 4) {
                    let selected = self.favoriteTile(split, in: p)?.isSelected == true
                    self.check(self.c.shownSplitID == split && self.c.store.split(split)?.tabIDs.count == 2 && selected,
                               "favorite split (click): a click on the tile shows the split (shown \(self.c.shownSplitID == split), tile selected \(selected))")
                    done()
                }
            }
        }
        // Tiles reorder by drag.
        step { [self] done in
            let pid = c.store.profile(ofSpace: sid).id
            if let t = try? c.store.openTab(url: url("/mail"), inSpace: sid, activate: false, title: "Inbox") {
                try? c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 1))
                mail = c.store.tab(t.id)?.itemID ?? ""
            }
            c.reloadAll(animated: false)
            guard let p = c.pageView(for: sid), let tile = favoriteTile(split, in: p), let mailTile = favoriteTile(mail, in: p) else {
                check(false, "favorite split (reorder): two tiles"); return done()
            }
            drag(from: centre(tile), to: mailTile.convert(NSPoint(x: mailTile.bounds.maxX - 3, y: mailTile.bounds.midY), to: nil)) {
                self.waitUntil({ self.c.store.favorites(ofProfile: pid).map(\.id) == [mail, split] }, timeout: 3) {
                    self.check(self.c.store.favorites(ofProfile: pid).map(\.id) == [mail, split],
                               "favorite split (reorder): the split's tile dragged past the next tile goes after it")
                    done()
                }
            }
        }
        // Below the divider: a Today split again (same ID).
        step { [self] done in
            guard let p = c.pageView(for: sid), let tile = favoriteTile(split, in: p), let last = p.rows["newtab"] ?? p.rows["divider"] else {
                check(false, "favorite split (drag into Today): the tile"); return done()
            }
            drag(from: centre(tile), to: listPoint(p, y: last.frame.maxY + 30)) {
                self.waitUntil({ self.c.store.state.splits[split] != nil }, timeout: 3) {
                    let rows = self.c.store.todayRows(ofSpace: sid).map(\.id)
                    let pid = self.c.store.profile(ofSpace: sid).id
                    self.check(self.c.store.state.splits[split]?.tabIDs.count == 2 && rows.contains(split)
                               && !self.c.store.favorites(ofProfile: pid).contains { $0.id == split },
                               "favorite split (drag into Today): dropped below the divider it's a Today split again, one row")
                    done()
                }
            }
        }

        // 5. Pinned rows reorder by drag; a split dropped onto a folder goes into it.
        step { [self] done in
            // Pin the split with ⌘D, then a pinned tab above it and a folder below.
            c.show(paneTabs().first ?? c.store.state.splits[split]?.tabIDs.first ?? "", focus: false)
            postKey("d", keyCode: 2, modifiers: .command)
            waitUntil({ self.c.store.item(split)?.kind == .split && self.c.store.item(split)?.isFavorite == false }, timeout: 3) {
                let pinnedByKey = self.c.store.item(split)?.spaceID == sid
                self.check(pinnedByKey, "pinned split (⌘D): ⌘D on a pane pins the whole split")
                if let t = try? self.c.store.openTab(url: url("/other"), inSpace: sid, activate: false, title: "Pinned") {
                    try? self.c.store.move(.tab(t.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))
                    pin = self.c.store.tab(t.id)?.itemID ?? ""
                }
                folder = (try? self.c.store.createFolder(named: "Work", inSpace: sid))?.id ?? ""
                self.c.reloadAll(animated: false)
                guard let p = self.c.pageView(for: sid), let row = self.pinnedSplitRow(split, in: p),
                      let pinRow = p.rows[pin] else { self.check(false, "pinned split (reorder): rows"); return done() }
                self.drag(from: row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil),
                          to: pinRow.convert(NSPoint(x: 70, y: pinRow.bounds.minY + 4), to: nil)) {
                    self.waitUntil({ self.c.store.pinnedRoots(ofSpace: sid).first?.id == split }, timeout: 3) {
                        let order = self.c.store.pinnedRoots(ofSpace: sid).map(\.id)
                        self.check(order == [split, pin, folder], "pinned split (reorder): dragged above the pinned tab it's first (\(order.count) roots in order \(order == [split, pin, folder]))")
                        done()
                    }
                }
            }
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = pinnedSplitRow(split, in: p), let f = p.rows[folder] else {
                check(false, "pinned split (into a folder): rows"); return done()
            }
            drag(from: row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil), to: centre(f)) {
                self.waitUntil({ self.c.store.item(split)?.parentID == folder }, timeout: 3) {
                    self.c.reloadAll(animated: false)
                    let depth = self.c.pageView(for: sid).flatMap { self.pinnedSplitRow(split, in: $0) }?.depth
                    self.check(self.c.store.item(split)?.parentID == folder && depth == 1,
                               "pinned split (into a folder): dropped onto the folder it's inside it, one level in (depth \(depth.map(String.init) ?? "-"))")
                    done()
                }
            }
        }

        // 6. Separate All Tabs in Pinned and in Favorites: the panes where the split was.
        step { [self] done in
            let panes = c.store.panes(ofSplitItem: split).map(\.id)
            c.separateItemSplit(split)
            let inFolder = c.store.children(of: .pinned(spaceID: sid), parent: folder).map(\.id)
            check(c.store.item(split) == nil && inFolder == panes,
                  "pinned split (Separate All Tabs): its panes are pinned tabs where it was, in the folder, in order (\(inFolder == panes))")
            // Make a Favorite split and separate it too.
            let pid = c.store.profile(ofSpace: sid).id
            let a = try? c.store.openTab(url: url("/docs"), inSpace: sid, activate: false, title: "Docs")
            let b = try? c.store.openTab(url: url("/notes"), inSpace: sid, activate: false, title: "Notes")
            if let a, let b, let x = try? c.store.createSplit([a.id, b.id], inSpace: sid) {
                _ = try? c.store.move(.split(x.id), to: .favorites(profileID: pid, index: 0))
                c.separateItemSplit(x.id)
                let favs = c.store.favorites(ofProfile: pid).compactMap { c.store.liveTab(forItem: $0.id)?.id }
                check(c.store.item(x.id) == nil && Array(favs.prefix(2)) == [a.id, b.id],
                      "favorite split (Separate All Tabs): its panes are Favorites of their own where it was (\(Array(favs.prefix(2)) == [a.id, b.id]))")
                for t in [a.id, b.id] { if let i = c.store.tab(t)?.itemID { c.forgetPage(t, close: true); try? c.store.deleteItem(i) } }
            } else {
                check(false, "favorite split (Separate All Tabs): a split to separate")
            }
            c.reloadAll(animated: false)
            done()
        }

        run { [self] in c.switchToSpace(home, animated: false) }
        middle()
        run { [self] in c.switchToSpace(sid, animated: false) }

        // 7. SB-15: Favorites unload when unused (1 s override), keep their tile, and load again on a click.
        var fav: (docs: String, notes: String) = ("", "")
        step { [self] done in
            let pid = c.store.profile(ofSpace: sid).id
            if let t = try? c.store.openTab(url: url("/form"), inSpace: sid, activate: false, title: "Form") {
                try? c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 1))
                form = c.store.tab(t.id)?.itemID ?? ""
            }
            let a = try? c.store.openTab(url: url("/docs"), inSpace: sid, activate: false, title: "Docs")
            let b = try? c.store.openTab(url: url("/notes"), inSpace: sid, activate: false, title: "Notes")
            if let a, let b, let x = try? c.store.createSplit([a.id, b.id], inSpace: sid) {
                _ = try? c.store.move(.split(x.id), to: .favorites(profileID: pid, index: 2))
                split = x.id
                fav = (a.id, b.id)
            }
            c.reloadAll(animated: false)
            // Each Favorite shown once, so it has a page; the form gets typed input. Then the 1 s timeout starts.
            guard let m = try? c.store.openItem(mail, inSpace: sid) else { check(false, "favorites unload: the Favorites"); return done() }
            c.show(m.id, focus: false)
            waitUntil({ self.c.engineTab(for: m.id)?.isLoading == false }, timeout: 5) { done() }
        }
        step { [self] done in
            guard let f = try? c.store.openItem(form, inSpace: sid) else { return done() }
            c.show(f.id, focus: false)
            waitUntil({ self.c.engineTab(for: f.id)?.isLoading == false }, timeout: 5) {
                self.c.engineTab(for: f.id)?.evaluate("document.getElementById('f').value = 'typed by hand'; true", completion: nil)
                done()
            }
        }
        step { [self] done in
            c.show(fav.notes, focus: false)
            waitUntil({ self.c.shownSplitID == split && [fav.docs, fav.notes].allSatisfy { self.c.engineTab(for: $0)?.isLoading == false } }, timeout: 6) {
                self.c.show(other, focus: false)
                WindowController.unloadOverride = 1
                self.c.applyUnloadSetting()
                done()
            }
        }
        // The engine (Chromium) or the app (WebKit) frees them about a second later; allow 8 s.
        step { [self] done in
            let mailTab = c.store.liveTab(forItem: mail)?.id
            waitUntil({ [mailTab, fav.docs, fav.notes].allSatisfy { self.c.isPageUnloaded($0) } }, timeout: 8) { done() }
        }
        step { [self] done in
            c.reloadAll(animated: false)
            guard let p = c.pageView(for: sid), let mailTile = favoriteTile(mail, in: p), let splitTile = favoriteTile(split, in: p),
                  let formTile = favoriteTile(form, in: p) else { check(false, "favorites unload: the tiles"); return done() }
            let mailTab = c.store.liveTab(forItem: mail)?.id, formTab = c.store.liveTab(forItem: form)?.id
            let freed = c.isPageUnloaded(mailTab) && c.isPageUnloaded(fav.docs) && c.isPageUnloaded(fav.notes)
            let kept = !c.isPageUnloaded(formTab)
            let what = "favorites unload (SB-15): hidden Favorites freed (a tab \(c.isPageUnloaded(mailTab)), a split's panes "
                + "\(c.isPageUnloaded(fav.docs) && c.isPageUnloaded(fav.notes))), one with typed input kept \(kept)"
            if c.appUnloads { check(freed && kept, what) } else { note((freed && kept ? "ENGINE-PASS " : "ENGINE-FAIL ") + what) }
            // The app's part on both engines: a freed Favorite keeps its tile, drawn at half strength.
            let dims = [mailTile.iconAlpha] + (MainActor.assumeIsolated { splitTile.splitFace?.iconAlphas } ?? [])
            let drawnAsFreed = zip([c.isPageUnloaded(mailTab), c.isPageUnloaded(fav.docs), c.isPageUnloaded(fav.notes)], dims)
                .allSatisfy { unloaded, a in unloaded ? a < 0.6 : a > 0.9 }
            check(drawnAsFreed && formTile.iconAlpha > 0.9 && c.store.favorites(ofProfile: c.store.profile(ofSpace: sid).id).count == 3,
                  "favorites unload (SB-15): the tiles stay; freed ones draw at half strength (\(dims.map { String(format: "%.1f", $0) })), the kept one in full")
            captureNow("favorite-unloaded") { done() }
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let mailTile = favoriteTile(mail, in: p) else { return done() }
            let tab = c.store.liveTab(forItem: mail)?.id
            guard c.isPageUnloaded(tab) else {
                // Chromium frees it itself: when the engine didn't, there's nothing to load again (an engine result).
                note("ENGINE-FAIL favorites unload (SB-15): the Favorite wasn't freed (page URL \(c.engineTab(for: tab ?? "")?.url?.path ?? "none")), so its reload on a click can't be checked")
                WindowController.unloadOverride = nil
                c.applyUnloadSetting()
                return done()
            }
            click(at: centre(mailTile), in: c.window) {
                self.waitUntil({ self.c.shownTabID == tab && !self.c.isPageUnloaded(tab) && self.c.engineTab(for: tab ?? "")?.isLoading == false }, timeout: 6) {
                    self.c.reloadAll(animated: false)
                    let path = self.c.engineTab(for: tab ?? "")?.url?.path
                    let full = self.favoriteTile(mail, in: p).map { $0.iconAlpha > 0.9 } ?? false
                    self.check(self.c.shownTabID == tab && !self.c.isPageUnloaded(tab) && path == "/mail" && full,
                               "favorites unload (SB-15): a click on the freed Favorite loads its page again (\(path ?? "-"), shown \(self.c.shownTabID == tab)), its tile in full")
                    WindowController.unloadOverride = nil
                    self.c.applyUnloadSetting()
                    done()
                }
            }
        }

        // 8. For the relaunch: a stacked pinned split (Alpha 40 % over Beta, Beta focused) and a Favorite split, on
        // pages that load without the server.
        run { [self] in
            func data(_ title: String, _ color: String) -> String {
                "data:text/html," + (self.favSplitPage(title, color).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
            }
            let pid = c.store.profile(ofSpace: sid).id
            for id in c.store.favorites(ofProfile: pid).map(\.id) {
                for t in c.store.paneTabs(ofSplitItem: id) + [c.store.liveTab(forItem: id)].compactMap({ $0 }) { c.forgetPage(t.id, close: true) }
                try? c.store.deleteItem(id)
            }
            guard let a = try? c.store.openTab(url: data("Alpha", "#e3f0ea"), inSpace: sid, activate: false, title: "Alpha"),
                  let b = try? c.store.openTab(url: data("Beta", "#f4ece2"), inSpace: sid, activate: false, title: "Beta"),
                  let x = try? c.store.createSplit([a.id, b.id], inSpace: sid, axis: .vertical, focused: b.id),
                  let g = try? c.store.openTab(url: data("Gamma", "#efe7f6"), inSpace: sid, activate: false, title: "Gamma"),
                  let d = try? c.store.openTab(url: data("Delta", "#f7f2df"), inSpace: sid, activate: false, title: "Delta"),
                  let y = try? c.store.createSplit([g.id, d.id], inSpace: sid) else { return check(false, "split relaunch (pinned): splits to keep") }
            c.store.setSplitFractions(x.id, [0.4, 0.6])
            _ = try? c.store.move(.split(x.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))
            _ = try? c.store.move(.split(y.id), to: .favorites(profileID: pid, index: 0))
            note("split relaunch (pinned): before quitting, a pinned split \(c.store.panes(ofSplitItem: x.id).count) panes "
                 + "\(c.store.item(x.id)?.splitLayout?.axis.rawValue ?? "-"), a Favorite split \(c.store.panes(ofSplitItem: y.id).count) panes")
            server?.stop()
            c.switchToSpace(home, animated: false)
            try? c.store.flush()
        }
    }

    /// After the relaunch: the pinned split and the Favorite split are there, and the pinned one opens as it was.
    func favSplitPersistRead() {
        var sid = "", pinned = "", favorite = ""
        run { [self] in
            sid = c.store.orderedSpaces.first { $0.name == Self.favSplitSpaceName }?.id ?? ""
            pinned = c.store.pinnedRoots(ofSpace: sid).first { $0.kind == .split }?.id ?? ""
            favorite = c.store.favorites(ofProfile: c.store.profile(ofSpace: sid).id).first { $0.kind == .split }?.id ?? ""
            let titles = c.store.panes(ofSplitItem: pinned).map(\.displayTitle)
            let layout = c.store.item(pinned)?.splitLayout
            let panes = c.store.panes(ofSplitItem: pinned).map(\.id)
            check(!sid.isEmpty && titles == ["Alpha", "Beta"] && layout?.axis == .vertical
                  && abs((layout?.fractions(panes).first ?? 0) - 0.4) < 0.001 && layout?.focusedItemID == panes.last
                  && c.store.panes(ofSplitItem: favorite).map(\.displayTitle) == ["Gamma", "Delta"],
                  "split relaunch (pinned): the pinned split (\(titles.joined(separator: " / ")), \(layout?.axis.rawValue ?? "-")) and the Favorite split come back")
            c.switchToSpace(sid, animated: false)
            c.reloadAll(animated: false)
        }
        wait(0.4)
        step { [self] done in
            guard let p = c.pageView(for: sid), let row = pinnedSplitRow(pinned, in: p), let tile = favoriteTile(favorite, in: p),
                  let seg = row.segmentCentre(1) else { check(false, "split relaunch (pinned): its row and tile are drawn"); return done() }
            check(MainActor.assumeIsolated { tile.splitFace?.partFrames.count } == 2, "split relaunch (pinned): the Favorite split's tile is cut in two")
            click(at: seg, in: c.window) {
                // Pages loaded, and the panes' opening spring done (it runs while the display is on).
                self.waitUntil({ self.c.shownSplitID == pinned && !self.c.animator.isRunning("split")
                    && self.c.splitContainer.panes.allSatisfy { self.c.engineTab(for: $0.tabID)?.isLoading == false } }, timeout: 8) {
                    let v = self.c.splitContainer
                    let heights = v.panes.map(\.frame.height)
                    let share = heights.count == 2 ? heights[0] / max(1, heights[0] + heights[1]) : 0
                    let attached = v.panes.allSatisfy { p in self.c.engineTab(for: p.tabID).map { $0.view.isDescendant(of: p.host) } ?? false }
                    self.check(self.c.shownSplitID == pinned && v.axis == .vertical && abs(share - 0.4) < 0.02 && attached,
                               String(format: "split relaunch (pinned): a click opens it as it was: stacked, top pane %.0f %%, pages attached %@",
                                      share * 100, attached ? "yes" : "no"))
                    self.captureNow("pinned-split-after-relaunch") { done() }
                }
            }
        }
    }
}
#endif
