// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script splitparity` (both engines; on Chromium under the dialog test gate, `--airc-test=modalDialogs`): Split View
/// against Arc, on loopback pages in a Space of its own.
///   - a Today tab dragged onto a pinned split's row (real drags through the sidebar's own drag loop): the right half
///     makes it the last pane, the left half the first, up to Arc's four; a full split takes no fifth;
///   - the same on a Favorite split's tile;
///   - a Favorite split's custom icon (Change Icon…): the tile is whole with the emoji and a split mark; Remove Icon
///     brings the panes' favicons back;
///   - Arc's ⌃⇧[ / ⌃⇧] go round the panes (wrapping); "Cannot Add New Pane" on a full split;
///   - a pane's handle: a click opens Arc's Split View Controls (Move Left/Right, Add Left/Right Split, Arrange, Separate
///     Tab from Split, Close Split View Pane), and Move Right moves it; the Command Bar's Add Left / Right / Top /
///     Bottom Split (two along a split's axis) and Add Left Split's pane going before the anchor;
///   - ⌥-click on a Today tab opens it in a split with the page on screen; on the tab on screen, a copy of it;
///   - Chromium: deleting a pinned split whose two panes have unsaved changes asks "Leave site?" for each in turn; Stay
///     keeps the whole split (the first pane loads again); Leave on the other deletes it. Archive from a multi-selection
///     asks the same way.
///   - a pane's Copy Link (a Today split's and a pinned split's) copies its link without trackers, with Arc's toast;
///     Reset All Panes takes every pane back, asking first for a pane with unsaved input (Chromium: "Reset all
///     panes?", Reset Others keeps the draft; then "Leave site?" for it alone, and the engine doesn't ask again).
/// Posted drags, clicks and keys wait for the owner to be away (`whenOwnerAway`); otherwise those checks are FAIL-ENV
/// with the evidence. Writes splitparity-pinned-4.png, splitparity-favorite-4.png, splitparity-favorite-icon.png.
extension SnapshotRunner {
    func splitParityScenario() {
        var server: LocalPageServer?
        var base = ""
        var sid = ""
        step { [self] done in
            var pages: [String: String] = [:]
            let colors = ["#E8664D", "#3E9B6E", "#8A63D2", "#D9A21B", "#3B7BE0", "#D9455F", "#2F8F83", "#E07A3B", "#7A5AE0"]
            for (k, c) in colors.enumerated() { pages["/p\(k + 1)"] = parityPage("Page \(k + 1)", c) }
            let leave = "<input id=f style='margin:40px;font-size:20px'><script>onbeforeunload=function(e){e.preventDefault();e.returnValue=''}</script>"
            pages["/leave-a"] = parityPage("Draft A", "#D9455F", leave)
            pages["/leave-b"] = parityPage("Draft B", "#3B7BE0", leave)
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "splitparity: a loopback page server") }
                done()
            }
        }
        run { [self] in
            let home = c.currentSpaceID
            guard let s = try? c.store.createSpace(name: "Split parity", profileID: c.store.profile(ofSpace: home).id, after: home) else {
                return check(false, "splitparity: a Space for the checks")
            }
            sid = s.id
            c.switchToSpace(sid, animated: false)
        }
        parityPinnedDrop(base: { base }, space: { sid })
        parityFavoriteDrop(base: { base }, space: { sid })
        parityKeysAndControls(base: { base }, space: { sid })
        parityOptionClick(base: { base }, space: { sid })
        parityLeaveSite(base: { base }, space: { sid })
        parityPaneLinksAndReset(base: { base }, space: { sid })
        run { server?.stop() }
    }

    /// A page with its own favicon (a coloured rounded square, inline).
    private func parityPage(_ title: String, _ ink: String, _ extra: String = "") -> String {
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32' viewBox='0 0 32 32'><rect width='32' height='32' rx='8' fill='\(ink)'/>"
            + "<circle cx='16' cy='16' r='7' fill='white' fill-opacity='0.92'/></svg>"
        return "<head><title>\(title)</title><link rel='icon' href='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'></head>"
            + "<body style='margin:0;background:#f6f3ee;font:20px -apple-system'><h1 style='margin:40px;color:\(ink)'>\(title)</h1>\(extra)</body>"
    }

    // MARK: Real input only while the owner is away

    /// Posted clicks, drags and keys (to our own window, never HID) only while the owner is away from the Mac: no
    /// hardware input for `idleNeeded` seconds, our window on the active Space and not covered, the screen unlocked.
    /// Waits up to `wait` seconds for that (less once a wait has run out this run). `then(nil)` when it holds, else the
    /// evidence for a FAIL-ENV.
    func whenOwnerAway(idleNeeded: Double = 120, wait: Double = 10, _ then: @escaping (String?) -> Void) {
        let deadline = Date().addingTimeInterval(Self.ownerAwayMissed ? 2 : wait)
        func evidence() -> String? {
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            let w = c.window
            var why: [String] = []
            if Self.screenLocked { why.append("the screen is locked") }
            if !w.isOnActiveSpace { why.append("our window (pid \(getpid())) isn't on the active Space") }
            if !w.occlusionState.contains(.visible) { why.append("our window (pid \(getpid())) is covered") }
            if idle < idleNeeded { why.append("the owner used the Mac \(Int(idle)) s ago (needs \(Int(idleNeeded)) s)") }
            return why.isEmpty ? nil : why.joined(separator: ", ")
        }
        func poll() {
            let e = evidence()
            if e == nil { return then(nil) }
            if Date() > deadline { Self.ownerAwayMissed = true; return then(e) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: poll)
        }
        poll()
    }

    nonisolated(unsafe) private static var ownerAwayMissed = false

    /// A check that couldn't use real input, with the evidence; the publish gate doesn't count it.
    func failEnv(_ what: String, _ why: String) { note("FAIL-ENV " + what + " (\(why))") }

    // MARK: Helpers

    private func paritySplitRow(_ id: String, in p: SpacePageView) -> SplitRowView? {
        p.layoutSubtreeIfNeeded()
        return p.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.splitItem?.id == id }
    }

    private func parityTile(_ id: String, in p: SpacePageView) -> FavoriteTileView? {
        p.layoutSubtreeIfNeeded()
        return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == id }
    }

    private func panePaths(_ split: String) -> [String] {
        c.store.panes(ofSplitItem: split).map { $0.savedURL.flatMap { URL(string: $0)?.path } ?? "-" }
    }

    private func says(_ d: DropDestination?, _ split: String) -> String {
        switch d {
        case .split(_, let target, let leading)?: target == split ? (leading ? "first pane" : "last pane") : "another split"
        case .pinned?: "between pinned rows"
        case .favorites(_, let i)?: "Favorite \(i)"
        case .today?: "Today"
        case nil: "nothing"
        }
    }

    /// Two Today tabs as a split, then pinned (`favorite`: a Favorite). Returns the split's (now its item's) ID.
    private func paritySplitItem(_ urls: [String], in sid: String, favorite: Bool) -> String? {
        let tabs = urls.enumerated().compactMap { k, u in try? c.store.openTab(url: u, inSpace: sid, activate: false, title: "Page \(k)").id }
        guard tabs.count == urls.count, let x = try? c.store.createSplit(tabs, inSpace: sid, focused: tabs[0]) else { return nil }
        let to: DropDestination = favorite ? .favorites(profileID: c.store.profile(ofSpace: sid).id, index: 0)
                                           : .pinned(spaceID: sid, parentID: nil, index: 0)
        guard (try? c.store.move(.split(x.id), to: to)) != nil, c.store.item(x.id)?.kind == .split else { return nil }
        return x.id
    }

    /// Drags Today tab `tabID`'s row to the window point `end()` through the sidebar's drag loop, owner away. When real
    /// input can't be used (FAIL-ENV logged), the drop goes where the sidebar's own drop code says for that point
    /// (`dropDestination`, then `performDrop`, as the drag loop's release does), so the later checks still have their
    /// split. `then(ran)`: false only when the rows or the target weren't there.
    private func parityDrag(_ what: String, tabID: @escaping () -> String, to end: @escaping (SpacePageView) -> NSPoint?,
                            space: @escaping () -> String, then: @escaping (Bool) -> Void) {
        whenOwnerAway { why in
            guard let p = self.c.pageView(for: space()) else { self.check(false, what + ": the Space's sidebar"); return then(false) }
            p.layoutSubtreeIfNeeded()
            guard let row = p.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == tabID() }), let entry = row.entry,
                  let e = end(p) else {
                self.check(false, what + ": the Today row and the target are on screen"); return then(false)
            }
            if let why {
                self.failEnv(what + ": the real drag", why)
                let d = p.dropDestination(at: p.convert(e, from: nil), source: .tab(tabID()), entry: entry)
                p.hideDropIndicator()
                self.note(what + ": dropped where the sidebar's drop code says for that point (\(d.map { "\($0)" } ?? "nowhere"))")
                if let d { self.c.performDrop(.tab(tabID()), to: d) }
                return then(true)
            }
            self.drag(from: row.convert(NSPoint(x: 40, y: row.bounds.midY), to: nil), to: e) { then(true) }
        }
    }

    // MARK: Drops onto a pinned split's row

    private func parityPinnedDrop(base: @escaping () -> String, space: @escaping () -> String) {
        var split = ""
        var today: [String] = []
        run { [self] in
            let sid = space(), b = base()
            guard let s = paritySplitItem([b + "/p1", b + "/p2"], in: sid, favorite: false) else {
                return check(false, "pinned split drop: a pinned split of two pages")
            }
            split = s
            today = (3...5).compactMap { try? c.store.openTab(url: b + "/p\($0)", inSpace: sid, activate: false, title: "Page \($0)").id }
            c.reloadAll(animated: false)
            if let t = c.store.liveTab(forSplitItem: split) { c.show(t.id, focus: false) }
        }
        waitForPage()
        // Where a drop would land: the middle band's halves join, the row's edge goes between rows.
        run { [self] in
            guard let p = c.pageView(for: space()), let row = paritySplitRow(split, in: p), today.count == 3, let t = c.store.tab(today[0]) else {
                return check(false, "pinned split drop: the row and a Today tab are shown")
            }
            func at(_ fx: CGFloat, _ fy: CGFloat = 0.5) -> DropDestination? {
                let w = row.convert(NSPoint(x: row.bounds.width * fx, y: row.bounds.height * fy), to: nil)
                return p.dropDestination(at: p.convert(w, from: nil), source: .tab(t.id), entry: .today(t))
            }
            let right = at(0.8), left = at(0.2), edge = at(0.5, 0.05)
            p.hideDropIndicator()
            let joins: (DropDestination?, Bool) -> Bool = { d, l in if case .split(_, let x, let lead)? = d { return x == split && lead == l }; return false }
            check(joins(right, false) && joins(left, true) && !joins(edge, false) && !joins(edge, true),
                  "pinned split drop: the row's middle takes a tab (left half first, right half last), its edge doesn't "
                  + "(right \(says(right, split)), left \(says(left, split)), edge \(says(edge, split)))")
        }
        // Right half: the last pane; left half: the first.
        for (k, leading) in [(0, false), (1, true)] {
            step { [self] done in
                let before = panePaths(split)
                parityDrag("pinned split drop \(k + 1)", tabID: { today[k] }, to: { p in
                    self.paritySplitRow(split, in: p).map { r in r.convert(NSPoint(x: leading ? 26 : r.bounds.maxX - 26, y: r.bounds.midY), to: nil) }
                }, space: space) { ran in
                    guard ran else { return done() }
                    self.waitUntil({ self.c.store.panes(ofSplitItem: split).count == before.count + 1 }, timeout: 3) {
                        let want = leading ? ["/p\(k + 3)"] + before : before + ["/p\(k + 3)"]
                        let shown = self.c.store.tab(self.c.shownTabID)?.id == today[k] && self.c.shownSplitID == split
                        self.check(self.panePaths(split) == want && shown,
                                   "pinned split drop: a Today tab dragged onto the row's \(leading ? "left" : "right") half is its "
                                   + "\(leading ? "first" : "last") pane, the split shown with it focused (panes \(self.panePaths(split)), shown \(shown))")
                        done()
                    }
                }
            }
        }
        waitForPage()
        capture("splitparity-pinned-4")
        // Full (Arc's four): the row's middle takes no fifth.
        step { [self] done in
            guard c.store.panes(ofSplitItem: split).count == Split.maxPanes, today.count == 3 else {
                check(false, "pinned split drop: four panes before the fifth (\(panePaths(split)))"); return done()
            }
            if let p = c.pageView(for: space()), let row = paritySplitRow(split, in: p), let t = c.store.tab(today[2]) {
                let w = row.convert(NSPoint(x: row.bounds.width * 0.8, y: row.bounds.midY), to: nil)
                let d = p.dropDestination(at: p.convert(w, from: nil), source: .tab(t.id), entry: .today(t))
                p.hideDropIndicator()
                let joins: Bool = { if case .split? = d { return true }; return false }()
                check(!joins, "pinned split drop: a full split's row offers no fifth pane (\(says(d, split)))")
            }
            parityDrag("pinned split drop (full)", tabID: { today[2] }, to: { p in
                self.paritySplitRow(split, in: p).map { $0.convert(NSPoint(x: $0.bounds.maxX - 26, y: $0.bounds.midY), to: nil) }
            }, space: space) { ran in
                guard ran else { return done() }
                self.waitUntil({ false }, timeout: 0.6) {
                    let pane = self.c.store.splitItem(ofPane: self.c.store.tab(today[2])?.itemID)?.id == split
                    self.check(self.c.store.panes(ofSplitItem: split).count == Split.maxPanes && !pane,
                               "pinned split drop: dragged onto a full split, the fifth tab doesn't join (\(self.panePaths(split)))")
                    done()
                }
            }
        }
        run { [self] in
            // Clean up without questions (these pages have no unload handlers): the pages go, then the split.
            for t in c.store.paneTabs(ofSplitItem: split) { c.forgetPage(t.id, close: true) }
            try? c.store.deleteItem(split)
        }
    }

    // MARK: Drops onto a Favorite split's tile, its custom icon

    private func parityFavoriteDrop(base: @escaping () -> String, space: @escaping () -> String) {
        var split = ""
        var today: [String] = []
        run { [self] in
            let sid = space(), b = base()
            guard let s = paritySplitItem([b + "/p6", b + "/p7"], in: sid, favorite: true) else {
                return check(false, "favorite split drop: a Favorite split of two pages")
            }
            split = s
            today = (8...9).compactMap { try? c.store.openTab(url: b + "/p\($0)", inSpace: sid, activate: false, title: "Page \($0)").id }
            today += [(try? c.store.openTab(url: b + "/p1?fifth", inSpace: sid, activate: false, title: "Fifth"))?.id ?? ""]
            c.reloadAll(animated: false)
            if let t = c.store.liveTab(forSplitItem: split) { c.show(t.id, focus: false) }
        }
        waitForPage()
        for (k, leading) in [(0, false), (1, true)] {
            step { [self] done in
                let before = panePaths(split)
                parityDrag("favorite split drop \(k + 1)", tabID: { today[k] }, to: { p in
                    self.parityTile(split, in: p).map { t in t.convert(NSPoint(x: t.bounds.width * (leading ? 0.35 : 0.65), y: t.bounds.midY), to: nil) }
                }, space: space) { ran in
                    guard ran else { return done() }
                    self.waitUntil({ self.c.store.panes(ofSplitItem: split).count == before.count + 1 }, timeout: 3) {
                        let want = leading ? ["/p\(k + 8)"] + before : before + ["/p\(k + 8)"]
                        let shown = self.c.store.tab(self.c.shownTabID)?.id == today[k] && self.c.shownSplitID == split
                        self.check(self.panePaths(split) == want && shown,
                                   "favorite split drop: a Today tab dragged onto the tile's \(leading ? "left" : "right") half is its "
                                   + "\(leading ? "first" : "last") pane, the split shown with it focused (panes \(self.panePaths(split)), shown \(shown))")
                        done()
                    }
                }
            }
        }
        run { [self] in
            let tile = c.pageView(for: space()).flatMap { parityTile(split, in: $0) }
            let parts = MainActor.assumeIsolated { tile?.splitFace?.partFrames.count }
            check(parts == 4, "favorite split drop: the tile is cut into four parts (\(parts ?? 0))")
        }
        waitForPage()
        capture("splitparity-favorite-4")
        step { [self] done in
            parityDrag("favorite split drop (full)", tabID: { today[2] }, to: { p in
                self.parityTile(split, in: p).map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
            }, space: space) { ran in
                guard ran else { return done() }
                self.waitUntil({ false }, timeout: 0.6) {
                    let pane = self.c.store.splitItem(ofPane: self.c.store.tab(today[2])?.itemID)?.id == split
                    self.check(self.c.store.panes(ofSplitItem: split).count == Split.maxPanes && !pane,
                               "favorite split drop: dragged onto a full split's tile, a fifth tab doesn't join (\(self.panePaths(split)))")
                    done()
                }
            }
        }
        // Arc: "Favorited Split Views can have custom icons".
        run { [self] in
            guard let item = c.store.item(split) else { return check(false, "favorite split icon: the split") }
            let titles = c.itemSplitMenu(item, pane: nil).items.map(\.title)
            check(titles.contains("Change Icon…") && !titles.contains("Remove Icon"), "favorite split icon: its menu has Change Icon…")
            // What the emoji picker's pick does.
            try? c.store.setItemIcon(split, to: "🧪")
        }
        wait(0.3)
        run { [self] in
            let tile = c.pageView(for: space()).flatMap { parityTile(split, in: $0) }
            let (icon, parts) = MainActor.assumeIsolated { (tile?.splitFace?.customIcon, tile?.splitFace?.partFrames.count ?? 0) }
            check(icon == "🧪" && parts == 1, "favorite split icon: the tile shows the icon, whole (\(icon ?? "none"), \(parts) part)")
        }
        capture("splitparity-favorite-icon")
        run { [self] in
            guard let item = c.store.item(split) else { return }
            let m = c.itemSplitMenu(item, pane: nil)
            guard let i = m.items.firstIndex(where: { $0.title == "Remove Icon" }) else { return check(false, "favorite split icon: Remove Icon in its menu") }
            m.performActionForItem(at: i)
        }
        wait(0.3)
        run { [self] in
            let tile = c.pageView(for: space()).flatMap { parityTile(split, in: $0) }
            let (icon, parts) = MainActor.assumeIsolated { (tile?.splitFace?.customIcon, tile?.splitFace?.partFrames.count ?? 0) }
            check(icon == nil && parts == 4 && c.store.item(split)?.icon == nil,
                  "favorite split icon: Remove Icon brings the panes' favicons back (\(parts) parts)")
            // The full split's drag pressed (so showed) the fifth tab: the split of four comes back for the key checks.
            if let t = c.store.liveTab(forSplitItem: split) { c.show(t.id, focus: false) }
        }
        waitForPage()
    }

    // MARK: Keys, the pane's controls, the Command Bar's entries

    private func parityKeysAndControls(base: @escaping () -> String, space: @escaping () -> String) {
        var x: Split?
        run { [self] in
            x = c.store.split(c.shownSplitID)
            guard let x, x.tabIDs.count == 4 else { return check(false, "split keys: a split of four on screen (\(c.store.split(c.shownSplitID)?.tabIDs.count ?? 0))") }
            c.focusPane(number: 1)
            // Arc's toast when a split is full.
            c.newSplitView()
            check(c.toast.shownText == WindowController.splitFullMessage && c.pendingSplit == nil,
                  "split keys: ⌃⇧+ on a full split says “\(c.toast.shownText ?? "nothing")”")
        }
        func paneKey(_ label: String, _ chars: String, _ code: UInt16, id: String) {
            step { [self] done in
                whenOwnerAway { why in
                    if let why {
                        self.failEnv("split keys: the posted \(label)", why)
                        CommandMenus.all.first { $0.id == id }?.run(self.c)
                        return done()
                    }
                    self.postKey(chars, keyCode: code, modifiers: [.control, .shift])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
                }
            }
        }
        paneKey("⌃⇧[", "{", 33, id: "tabs.previousPane")
        run { [self] in
            check(x != nil && c.shownTabID == x?.tabIDs.last, "split keys: ⌃⇧[ on the first pane goes round to the last (Arc, wrapping)")
        }
        paneKey("⌃⇧]", "}", 30, id: "tabs.nextPane")
        run { [self] in check(x != nil && c.shownTabID == x?.tabIDs.first, "split keys: ⌃⇧] on the last goes round to the first") }
        // The pane's handle: a click opens Arc's Split View Controls.
        step { [self] done in
            guard let x, let first = x.tabIDs.first, let pane = c.splitContainer.pane(for: first) else {
                check(false, "split controls: the first pane's handle"); return done()
            }
            let titles = c.paneMenu(first).items.filter { !$0.isSeparatorItem }.map(\.title)
            // P06c adds Expand Current Split (SplitExtras.swift) while the split is on screen.
            check(titles == ["Move Left", "Move Right", "Add Left Split", "Add Right Split", "Arrange Top to Bottom", "Make Panes the Same Size",
                             "Expand Current Split", "Separate Tab from Split", "Close Split View Pane"]
                  && c.paneMenu(first).item(withTitle: "Move Left")?.isEnabled == false && c.paneMenu(first).item(withTitle: "Add Left Split")?.isEnabled == false,
                  "split controls: Arc's menu for the first pane (\(titles)); Move Left and Add (full) greyed")
            SplitContainerView.paneMenuShown = nil
            whenOwnerAway { why in
                if let why {
                    self.failEnv("split controls: a real click on the handle", why)
                    self.c.showPaneMenu(first)
                    return done()
                }
                pane.handle.setShown(true)
                let r = pane.handle.grabRect
                self.click(at: pane.handle.convert(NSPoint(x: r.midX, y: r.midY), to: nil), in: self.c.window) { done() }
            }
        }
        run { [self] in
            check(SplitContainerView.paneMenuShown == x?.tabIDs.first, "split controls: a click on a pane's handle opens its controls")
            guard let x, let first = x.tabIDs.first else { return }
            let m = c.paneMenu(first)
            if let i = m.items.firstIndex(where: { $0.title == "Move Right" }) { m.performActionForItem(at: i) }
        }
        wait(0.4)
        run { [self] in
            guard let x else { return }
            let now = c.store.split(x.id)?.tabIDs ?? []
            check(now.count == 4 && now[1] == x.tabIDs[0] && now[0] == x.tabIDs[1], "split controls: Move Right moves the pane one place right")
        }
        // The Command Bar: Arc's Add … Split entries; in a full split none.
        run { [self] in
            let titles = c.splitCommandActions().map(\.title)
            check(!titles.contains { $0.hasPrefix("Add ") } && titles.contains("Separate Tab from Split") && titles.contains("Close Split View Pane"),
                  "split command bar: in a full split no Add entries, Separate Tab from Split and Close Split View Pane (\(titles))")
        }
        // A page alone: all four; Add Left Split puts the picked page before it.
        var alone = "", picked = ""
        run { [self] in
            guard let t = try? c.store.openTab(url: base() + "/p2?alone", inSpace: space(), title: "Alone") else { return }
            alone = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        waitForPage()
        run { [self] in
            let titles = c.splitCommandActions().map(\.title)
            check(titles == ["Add Left Split", "Add Right Split", "Add Top Split", "Add Bottom Split"],
                  "split command bar: a page alone offers Arc's four (\(titles))")
            c.splitCommandActions().first { $0.title == "Add Left Split" }?.run()
            let p = c.pendingSplit
            check(p?.anchor == alone && p?.leading == true && p?.axis == .horizontal && c.commandBar != nil,
                  "split command bar: Add Left Split opens the Command Bar for a pane left of the page")
            guard let url = URL(string: base() + "/p3?picked") else { return }
            _ = c.performSplitPick(.open(url), typed: false)
            c.closeCommandBar()
            picked = c.store.split(containing: alone)?.tabIDs.first ?? ""
        }
        wait(0.4)
        run { [self] in
            let x = c.store.split(containing: alone)
            check(x?.tabIDs.count == 2 && x?.tabIDs.last == alone && c.store.tab(picked)?.url.hasSuffix("?picked") == true && x?.axis == .horizontal,
                  "split command bar: the picked page is the left pane (\(x?.tabIDs.map { $0 == alone ? "page" : "picked" } ?? []))")
            let titles = c.splitCommandActions().map(\.title)
            check(titles.prefix(2) == ["Add Left Split", "Add Right Split"] && !titles.contains("Add Top Split"),
                  "split command bar: in a side-by-side split only Add Left / Right Split (\(titles))")
        }
    }

    // MARK: ⌥-click

    private func parityOptionClick(base: @escaping () -> String, space: @escaping () -> String) {
        var shown = "", other = ""
        run { [self] in
            let b = base(), sid = space()
            guard let s = try? c.store.openTab(url: b + "/p4?opt", inSpace: sid, title: "Shown"),
                  let o = try? c.store.openTab(url: b + "/p5?opt", inSpace: sid, activate: false, title: "Other") else {
                return check(false, "⌥-click: two Today tabs")
            }
            shown = s.id
            other = o.id
            c.reloadAll(animated: false)
            c.show(shown, focus: false)
        }
        waitForPage()
        func optionClick(_ what: String, _ tabID: @escaping () -> String) {
            step { [self] done in
                whenOwnerAway { why in
                    guard let p = self.c.pageView(for: space()) else { return done() }
                    p.layoutSubtreeIfNeeded()
                    guard let row = p.list.subviews.compactMap({ $0 as? TabRowView }).first(where: { $0.tabID == tabID() }), let entry = row.entry else {
                        self.check(false, what + ": the row"); return done()
                    }
                    if let why {
                        self.failEnv(what + ": the real ⌥-click", why)
                        self.c.optionClickSplit(entry)
                        return done()
                    }
                    let w = self.c.window
                    let at = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
                    func mouse(_ t: NSEvent.EventType) -> NSEvent? {
                        NSEvent.mouseEvent(with: t, location: at, modifierFlags: .option, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
                    }
                    let up = Timer(timeInterval: 0.08, repeats: false) { _ in if let e = mouse(.leftMouseUp) { NSApp.postEvent(e, atStart: false) } }
                    RunLoop.main.add(up, forMode: .common)
                    if let e = mouse(.leftMouseDown) { w.sendEvent(e) }   // returns after the release
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        // The tab on screen, alone: a copy of it beside it (Arc). (A split's tabs are one row, so this comes first.)
        optionClick("⌥-click on the tab on screen") { shown }
        run { [self] in
            let x = c.store.split(containing: shown)
            let copy = x?.tabIDs.last.flatMap { c.store.tab($0) }
            check(x?.tabIDs.count == 2 && x?.tabIDs.first == shown && copy?.id != shown && copy?.url == c.store.tab(shown)?.url
                  && c.shownTabID == copy?.id,
                  "⌥-click: on the tab on screen, a copy of it opens beside it in a split, focused (\(x?.tabIDs.count ?? 0) panes)")
        }
        optionClick("⌥-click") { other }
        run { [self] in
            let x = c.store.split(containing: shown)
            check(x?.tabIDs.count == 3 && x?.tabIDs.last == other && c.shownTabID == other && c.shownSplitID == x?.id,
                  "⌥-click: another Today tab joins the split on screen, after the focused pane, focused (\(x?.tabIDs.count ?? 0) panes)")
        }
    }

    // MARK: "Leave site?" for every pane on delete and archive

    private func parityLeaveSite(base: @escaping () -> String, space: @escaping () -> String) {
        var split = ""
        var tabs: [String] = []
        func makeSplit() {
            run { [self] in
                let b = base(), sid = space()
                guard let s = paritySplitItem([b + "/leave-a", b + "/leave-b"], in: sid, favorite: false) else {
                    return check(false, "leave site (delete): a pinned split of two drafts")
                }
                split = s
                c.reloadAll(animated: false)
                if let t = c.store.liveTab(forSplitItem: split) { c.show(t.id, focus: false) }
                tabs = c.store.paneTabs(ofSplitItem: split).map(\.id)
            }
            waitForPage()
            wait(0.8)
        }
        makeSplit()
        #if canImport(AircCore)
        if let engine = app?.engine as? ChromiumEngine {
            func page(_ k: Int) -> EngineTab? { tabs.count > k ? c.engineTab(for: tabs[k]) : nil }
            func dialogs() -> Int {
                (page(0) ?? page(1)).flatMap { (engine.modalDialogState(for: $0)["dialogs"] as? [Any])?.count } ?? 0
            }
            func asking(_ k: Int) -> Bool {
                dialogs() == 1 && tabs.count > k && c.paneCloseQueue?.current == tabs[k] && page(k).map { !$0.isClosed } ?? false
            }
            func state() -> String {
                "dialogs \(dialogs()), waiting on \(c.paneCloseQueue?.current.map { $0 == tabs.first ? "the first" : $0 == tabs.last ? "the second" : $0 } ?? "none"), "
                + "pages \(page(0) == nil ? "-" : "first") \(page(1) == nil ? "-" : "second"), split \(c.store.item(split) == nil ? "gone" : "kept")"
            }
            func leave(_ k: Int) -> Bool {
                guard let p = page(k) ?? page(1 - k), let core = Mirror(reflecting: p).children.first(where: { $0.label == "core" })?.value as? AircTab else { return false }
                return core.respondToModalDialog(forTesting: true)
            }
            var gate = false
            func dirty() {
                step { [self] done in
                    gate = page(0).map { engine.modalDialogState(for: $0)["registeredHost"] != nil } ?? false
                    guard gate else { skip("leave site (delete): the dialog test gate is off (--airc-test=modalDialogs)"); return done() }
                    // Chromium asks only pages the person used: a DevTools user gesture on each pane, and typed input.
                    var left = 2
                    for k in 0..<2 {
                        guard let p = page(k) else { left -= 1; continue }
                        engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('f').value='draft';navigator.userActivation.isActive",
                                                                         "userGesture": true, "returnByValue": true], in: p) { _, _ in
                            left -= 1
                            if left == 0 { done() }
                        }
                    }
                    if left == 0 { done() }
                }
            }
            dirty()
            // Delete (the row's menu): the first asks; Leave; the second asks; Stay keeps the whole split.
            step { [self] done in
                guard gate else { return done() }
                c.deleteItemSplit(split)
                waitUntil({ asking(0) }, timeout: 5) {
                    self.check(asking(0) && page(1).map { !$0.isClosed } ?? false && self.c.store.item(split) != nil,
                               "leave site (delete): deleting a pinned split asks its first pane with unsaved changes first (\(state()))")
                    let accepted = leave(0)
                    self.waitUntil({ asking(1) && page(0) == nil }, timeout: 5) {
                        self.check(accepted && asking(1) && self.c.store.item(split) != nil,
                                   "leave site (delete): after Leave on the first pane, the second asks too, the split still there (\(state()))")
                        done()
                    }
                }
            }
            step { [self] done in
                guard gate, let p = page(1) else { return done() }
                let cancelled = engine.cancelModalDialog(in: p)
                waitUntil({ self.c.paneCloseQueue == nil && page(0) != nil }, timeout: 4) {
                    self.check(cancelled && self.c.store.item(split) != nil && self.c.store.panes(ofSplitItem: split).count == 2
                               && page(0) != nil && page(1).map { !$0.isClosed } ?? false && self.c.shownSplitID == split,
                               "leave site (delete): Stay on the second pane keeps the whole split, shown, the first loaded again (\(state()))")
                    done()
                }
            }
            step { [self] done in
                guard gate else { return done() }
                c.deleteItemSplit(split)
                waitUntil({ asking(1) }, timeout: 5) {
                    let asked = asking(1), accepted = leave(1)
                    self.waitUntil({ self.c.store.item(split) == nil }, timeout: 5) {
                        self.check(asked && accepted && self.c.store.item(split) == nil && tabs.allSatisfy { self.c.engineTab(for: $0) == nil },
                                   "leave site (delete): deleting again asks only the pane still dirty; Leave deletes the split (\(state()))")
                        done()
                    }
                }
            }
            // Archive from a multi-selection (Delete on the selected rows): asked the same way; Stay keeps it whole.
            makeSplit()
            dirty()
            step { [self] done in
                guard gate else { return done() }
                c.archiveSelected([split], spaceID: space())
                waitUntil({ asking(0) }, timeout: 5) {
                    let first = asking(0), accepted = leave(0)
                    self.waitUntil({ asking(1) }, timeout: 5) {
                        guard let p = page(1) else { self.check(false, "leave site (archive): the second pane asks (\(state()))"); return done() }
                        let cancelled = engine.cancelModalDialog(in: p)
                        self.waitUntil({ self.c.paneCloseQueue == nil && page(0) != nil }, timeout: 4) {
                            self.check(first && accepted && cancelled && self.c.store.item(split) != nil && self.c.store.panes(ofSplitItem: split).count == 2,
                                       "leave site (archive): archiving the selected split asks each dirty pane in turn; Stay keeps it whole (\(state()))")
                            done()
                        }
                    }
                }
            }
            // Clean up without questions: the drafts drop their unload handler (a page still asking would hold the
            // app's quit), then the pages go, then the split.
            step { [self] done in
                let pages = c.store.paneTabs(ofSplitItem: split).compactMap { c.engineTab(for: $0.id) }
                var left = pages.count, finished = false
                let finish = {
                    guard !finished else { return }
                    finished = true
                    for t in self.c.store.paneTabs(ofSplitItem: split) { self.c.forgetPage(t.id, close: true) }
                    try? self.c.store.deleteItem(split)
                    done()
                }
                for p in pages {
                    p.evaluate("window.onbeforeunload = null; true") { _ in
                        left -= 1
                        if left == 0 { finish() }
                    }
                }
                if pages.isEmpty { finish() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
            }
            return
        }
        #endif
        // WebKit pages never ask before closing: Delete closes every pane and deletes the split.
        step { [self] done in
            c.deleteItemSplit(split)
            waitUntil({ self.c.store.item(split) == nil }, timeout: 3) {
                self.check(self.c.store.item(split) == nil && tabs.allSatisfy { self.c.engineTab(for: $0) == nil },
                           "leave site (delete): deleting a pinned split closes every pane and deletes it (WebKit never asks)")
                self.skip("leave site (delete): \"Leave site?\" for every pane is a Chromium check")
                done()
            }
        }
    }

    // MARK: A pane's Copy Link, Reset All Panes

    private func parityPaneLinksAndReset(base: @escaping () -> String, space: @escaping () -> String) {
        // Copy Link from a Today split's pane and a pinned split's pane, on a pasteboard of the run's own.
        run { [self] in
            let b = base(), sid = space()
            let board = NSPasteboard(name: .init("org.airc.splitparity.\(UUID().uuidString)"))
            let saved = WindowController.linkPasteboard
            WindowController.linkPasteboard = board
            defer { WindowController.linkPasteboard = saved; board.releaseGlobally() }
            func copied(_ m: NSMenu) -> String? {
                board.clearContents()
                guard let i = m.items.firstIndex(where: { $0.title == "Copy Link" }) else { return nil }
                m.performActionForItem(at: i)
                return board.string(forType: .string)
            }
            let clean = LinkCopyPolicy.toast(count: 1, removedTrackers: true, single: "Copied Link")
            let ids = ["/p3?utm_source=newsletter&id=7", "/p4"].compactMap { try? c.store.openTab(url: b + $0, inSpace: sid, activate: false, title: "Page").id }
            if ids.count == 2, let x = try? c.store.createSplit(ids, inSpace: sid, focused: ids[0]) {
                let got = copied(c.menu(for: .split(x, ids.compactMap { c.store.tab($0) }), pane: ids[0]))
                check(got == b + "/p3?id=7" && c.toast.shownText == clean,
                      "pane links: a Today split's pane Copy Link copies its link without trackers (\(got ?? "nothing"), \"\(c.toast.shownText ?? "no toast")\")")
            } else {
                check(false, "pane links: a Today split of two tabs")
            }
            if let s = paritySplitItem([b + "/p5?utm_campaign=launch&id=8", b + "/p6"], in: sid, favorite: false), let item = c.store.item(s),
               let pane = c.store.paneTabs(ofSplitItem: s).first?.id {
                let got = copied(c.itemSplitMenu(item, pane: pane))
                check(got == b + "/p5?id=8" && c.toast.shownText == clean,
                      "pane links: a pinned split's pane Copy Link copies its link without trackers (\(got ?? "nothing"), \"\(c.toast.shownText ?? "no toast")\")")
            } else {
                check(false, "pane links: a pinned split of two tabs")
            }
        }
        // Reset All Panes: a pinned split whose two panes went away from their saved pages. Under Chromium's dialog
        // gate they go to the drafts (one gets unsaved input); otherwise to plain pages with nothing to ask about (a
        // draft's unconditional beforeunload handler can count as asking on WebKit: sp-webkit-8 stopped on that question).
        var split = ""
        var tabs: [String] = []
        var drafts = false
        /// A reset question still up (a check that went wrong) is cancelled, so the run can always quit.
        func dismissSheet(_ when: String) {
            guard let sheet = c.window.attachedSheet else { return }
            note("reset panes: \(when), a question was still up (\(WindowController.lastResetAlert?.messageText ?? "?")): cancelled")
            c.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        func page(_ k: Int) -> EngineTab? { tabs.count > k ? c.engineTab(for: tabs[k]) : nil }
        func resetAll() -> Bool {
            guard let item = c.store.item(split) else { return false }
            let m = c.itemSplitMenu(item, pane: nil)
            guard let i = m.items.firstIndex(where: { $0.title == "Reset All Panes" }) else { return false }
            m.performActionForItem(at: i)
            return true
        }
        run { [self] in
            guard let s = paritySplitItem([base() + "/p7", base() + "/p8"], in: space(), favorite: false) else {
                return check(false, "reset panes: a pinned split of two pages")
            }
            split = s
            c.reloadAll(animated: false)
            if let t = c.store.liveTab(forSplitItem: split) { c.show(t.id, focus: false) }
            tabs = c.store.paneTabs(ofSplitItem: split).map(\.id)
        }
        waitForPage()
        step { [self] done in
            #if canImport(AircCore)
            if let engine = app?.engine as? ChromiumEngine, let p = page(0) { drafts = engine.modalDialogState(for: p)["registeredHost"] != nil }
            #endif
            let want = drafts ? ["Draft A", "Draft B"] : ["Page 1", "Page 2"]
            let paths: [String] = drafts ? ["/leave-a", "/leave-b"] : ["/p1", "/p2"]
            for (k, path) in paths.enumerated() {
                if let p = page(k), let u = URL(string: base() + path) { c.engineWindow.load(u, in: p) }
            }
            waitUntil({ tabs.count == 2 && page(0)?.title == want[0] && page(1)?.title == want[1]
                        && tabs.allSatisfy { self.c.store.isDrifted($0) } }, timeout: 8) { done() }
        }
        #if canImport(AircCore)
        if let engine = app?.engine as? ChromiumEngine {
            func dialogs() -> Int {
                [page(0), page(1)].compactMap { $0.flatMap { (engine.modalDialogState(for: $0)["dialogs"] as? [Any])?.count } }.reduce(0, +)
            }
            // The first draft has unsaved input (a DevTools user gesture: Chromium asks only pages the person used).
            step { [self] done in
                guard drafts, let p = page(0) else { skip("reset panes: the questions need the dialog test gate (--airc-test=modalDialogs)"); return done() }
                engine.devToolsCall("Runtime.evaluate", params: ["expression": "document.getElementById('f').value='draft';true",
                                                                 "userGesture": true, "returnByValue": true], in: p) { _, _ in done() }
            }
            step { [self] done in
                guard drafts else { return done() }
                WindowController.lastResetAlert = nil
                let fired = resetAll()
                waitUntil({ WindowController.lastResetAlert != nil && self.c.window.attachedSheet != nil }, timeout: 3) {
                    let a = WindowController.lastResetAlert
                    self.check(fired && a?.messageText == "Reset all panes?" && a?.buttons.map(\.title) == ["Reset All", "Cancel", "Reset Others"]
                               && page(0)?.title == "Draft A" && page(1)?.title == "Draft B",
                               "reset panes: Reset All Panes asks first, once, when a pane has unsaved input (\(a?.messageText ?? "no question") \(a?.informativeText ?? ""))")
                    a?.buttons.last?.performClick(nil)   // Reset Others
                    self.waitUntil({ page(1)?.title == "Page 8" }, timeout: 6) {
                        guard let p = page(0) else { self.check(false, "reset panes: the draft pane is still there"); return done() }
                        p.evaluate("document.getElementById('f').value") { v in
                            self.check(page(1)?.title == "Page 8" && !self.c.store.isDrifted(tabs[1]) && page(0)?.title == "Draft A"
                                       && (v as? String) == "draft" && self.c.store.isDrifted(tabs[0]) && dialogs() == 0,
                                       "reset panes: Reset Others takes the other pane back and keeps the draft with its input (\(page(0)?.title ?? "-"), \(page(1)?.title ?? "-"))")
                            done()
                        }
                    }
                }
            }
            step { [self] done in
                guard drafts else { return done() }
                WindowController.lastResetAlert = nil
                let fired = resetAll()
                waitUntil({ WindowController.lastResetAlert != nil }, timeout: 3) {
                    let a = WindowController.lastResetAlert
                    let asked = a?.messageText == "Leave site?" && a?.buttons.map(\.title) == ["Leave", "Cancel"]
                    a?.buttons.first?.performClick(nil)   // Leave
                    self.waitUntil({ page(0)?.title == "Page 7" }, timeout: 6) {
                        self.check(fired && asked && page(0)?.title == "Page 7" && !self.c.store.isDrifted(tabs[0]) && dialogs() == 0,
                                   "reset panes: with only the draft away it asks \"Leave site?\"; Leave takes it back and the engine doesn't ask again (dialogs \(dialogs()))")
                        done()
                    }
                }
            }
        }
        #endif
        // WebKit (and Chromium without the gate): nothing unsaved to ask about, so every pane goes back at once.
        step { [self] done in
            dismissSheet("before the plain reset")
            guard tabs.contains(where: { self.c.store.isDrifted($0) }) else { return done() }
            let fired = resetAll()
            waitUntil({ page(0)?.title == "Page 7" && page(1)?.title == "Page 8" }, timeout: 6) {
                self.check(fired && tabs.allSatisfy { !self.c.store.isDrifted($0) } && self.c.window.attachedSheet == nil,
                           "reset panes: Reset All Panes takes every pane back to its saved page without asking (\(page(0)?.title ?? "-"), \(page(1)?.title ?? "-"))")
                dismissSheet("after the plain reset")
                done()
            }
        }
        // Clean up without questions: the drafts' unload handler goes, then the pages, then the split.
        step { [self] done in
            dismissSheet("at the clean-up")
            let pages = [page(0), page(1)].compactMap { $0 }
            var left = pages.count, finished = false
            let finish = {
                guard !finished else { return }
                finished = true
                for t in tabs { self.c.forgetPage(t, close: true) }
                try? self.c.store.deleteItem(split)
                done()
            }
            for p in pages { p.evaluate("window.onbeforeunload = null; true") { _ in left -= 1; if left == 0 { finish() } } }
            if pages.isEmpty { finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
        }
    }
}
#endif
