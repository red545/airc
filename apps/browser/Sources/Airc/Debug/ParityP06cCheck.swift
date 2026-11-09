// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityp06c` (both engines): Split View's extras (Browser/SplitExtras.swift), on loopback pages in a Space
/// of its own.
///   - Arc's Separate Page from Split View and Expand Current Split are in the menu, off with no split on screen;
///   - two panes at 30/70: Expand (the menu item) fills the split's place with the focused pane, the other waits hidden
///     and live, no dividers or ring; the item and the Command Bar say Restore Current Split; ⌘[ is the page's Back;
///     Restore brings both back at 30/70, the same pane focused; neither is an undo step;
///   - four panes: another pane taking the keyboard (⌃⇧1–4) restores the split; closing a hidden pane keeps the
///     expansion and Restore shows the three left; closing the expanded pane brings the rest back;
///   - Arrange (the axis) and showing another tab end an expansion; back on the split, it isn't expanded;
///   - two windows: the split taken by a second window ends the first's expansion and isn't expanded there;
///   - Separate Page from Split View (the menu item) makes the focused pane a tab of its own, on screen; ⌘Z brings the
///     split back at its sizes;
///   - a pinned split expands and restores, and Separate Page makes the pane a pinned tab; ⌘Z undoes it;
///   - a real ⌥-click on a Today split's row and on a Favorite split's tile separates it into tabs; ⌘Z undoes each.
/// Posted clicks wait for the owner to be away (`whenOwnerAway`); otherwise they're FAIL-ENV with the evidence and
/// the same action runs without them.
extension SnapshotRunner {
    func parityP06cScenario() {
        var server: LocalPageServer?
        var base = ""
        var sid = ""
        var tabs: [String] = []
        var splitID = ""
        var before: [String: NSRect] = [:]
        var undoBefore: String?
        let v = { self.c.splitContainer }

        func page(_ k: Int) -> String { "\(base)/p\(k)" }
        func open(_ k: Int, _ tag: String) -> String {
            (try? c.store.openTab(url: page(k) + "?\(tag)", inSpace: sid, activate: false, title: "Pane \(k)"))?.id ?? ""
        }
        func rects() -> [String: NSRect] { Dictionary(uniqueKeysWithValues: v().panes.map { ($0.tabID, $0.frame) }) }
        func same(_ a: [String: NSRect], _ b: [String: NSRect]) -> Bool {
            Set(a.keys) == Set(b.keys) && a.allSatisfy { k, r in
                b[k].map { abs($0.minX - r.minX) <= 1 && abs($0.minY - r.minY) <= 1 && abs($0.width - r.width) <= 1 && abs($0.height - r.height) <= 1 } ?? false
            }
        }
        func widths() -> String { v().panes.map { "\(c.store.tab($0.tabID)?.title ?? "?") \(Int($0.frame.width))\($0.isHidden ? " hidden" : "")" }.joined(separator: " | ") }
        func name(_ id: String?) -> String { id.flatMap { c.store.tab($0)?.title } ?? "-" }
        /// The Today tabs that are rows of their own (not in a split).
        func todayTabs() -> Set<String> {
            Set(c.store.todayRows(ofSpace: sid).compactMap { if case .today(let t) = $0 { return t.id } else { return nil } })
        }
        /// The expanded pane over the split's whole place, the others hidden, no dividers and no ring.
        func expandedOK(_ id: String) -> Bool {
            let p = v().pane(for: id)
            return c.expandedPane == id && p.map { $0.frame == v().bounds && !$0.isHidden && !$0.focused } == true
                && v().panes.allSatisfy { $0.tabID == id || $0.isHidden } && v().dividers.allSatisfy(\.isHidden)
        }
        /// The split as its shares say, every pane and divider showing, `focused` with the ring.
        func restoredOK(_ focused: String) -> Bool {
            let r = v().frames(for: v().fractions)
            return c.expandedPane == nil && c.shownTabID == focused && zip(v().panes, r).allSatisfy { p, f in
                abs(p.frame.width - f.width) <= 1 && abs(p.frame.height - f.height) <= 1 && !p.isHidden
            } && v().dividers.allSatisfy { !$0.isHidden } && v().pane(for: focused)?.focused == true
        }
        func settled(_ done: @escaping () -> Void) {
            waitUntil({ !self.c.animator.isRunning("split") }, timeout: 3) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done) }
        }
        func settle() { step { done in settled(done) } }
        func menuItem(_ id: String) -> CommandMenuItem? { Self.p06cItems(NSApp.mainMenu).first { $0.command?.id == id } }
        /// Shows `ids` as a Today split at `fractions`, `focus` focused.
        func makeSplit(_ ids: @escaping () -> [String], fractions: [Double], focus: Int) {
            run { [self] in
                tabs = ids()
                guard tabs.count >= 2, !tabs.contains(""), let x = try? c.store.createSplit(tabs, inSpace: sid, focused: tabs[focus]) else {
                    return check(false, "P06c: a split of \(tabs.count) panes")
                }
                splitID = x.id
                c.store.setSplitFractions(x.id, fractions)
                c.reloadAll(animated: false)
                c.show(tabs[focus])
            }
            step { [self] done in
                waitUntil({ self.c.shownSplitID == splitID && tabs.allSatisfy { self.c.engineTab(for: $0)?.isLoading == false } }, timeout: 8) {
                    settled(done)
                }
            }
        }

        step { [self] done in
            var pages: [String: String] = [:]
            let colors = ["#E8664D", "#3E9B6E", "#8A63D2", "#D9A21B", "#3B7BE0", "#D9455F", "#2F8F83", "#E07A3B", "#7A5AE0"]
            for (k, color) in colors.enumerated() {
                pages["/p\(k + 1)"] = "<!doctype html><title>Pane \(k + 1)</title><body style='margin:0;background:\(color);font:28px -apple-system'>"
                    + "<p style='margin:40px;color:#fff'>Pane \(k + 1)</p>"
            }
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "P06c: a loopback page server") }
                done()
            }
        }
        run { [self] in
            let home = c.currentSpaceID
            guard let s = try? c.store.createSpace(name: "Split extras", profileID: c.store.profile(ofSpace: home).id, after: home) else {
                return check(false, "P06c: a Space for the checks")
            }
            sid = s.id
            c.switchToSpace(sid, animated: false)
            let t = open(1, "alone")
            c.reloadAll(animated: false)
            c.show(t)
        }
        waitForPage()

        // The menu items, off with no split.
        run { [self] in
            let sep = menuItem("tabs.separatePage"), exp = menuItem("tabs.expandSplit")
            let on = [sep, exp].map { i in i.map { $0.validateMenuItem($0) } ?? true }
            check(sep?.title == "Separate Page from Split View" && exp?.title == WindowController.expandSplitTitle && on == [false, false],
                  "P06c: Arc's Separate Page from Split View and Expand Current Split are in the \(exp?.menu?.title ?? "?") menu, off with no "
                  + "split on screen (\(sep?.title ?? "missing"), \(exp?.title ?? "missing"), enabled \(on))")
        }

        // Two panes at 30/70, the right one focused, with a page to go back to.
        makeSplit({ [open(2, "two"), open(3, "two")] }, fractions: [0.3, 0.7], focus: 1)
        run { [self] in c.engineTab(for: tabs[1])?.load(URL(string: page(4) + "?two-next")!) }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabs[1])?.url?.query == "two-next" && self.c.engineTab(for: tabs[1])?.isLoading == false }, timeout: 8) { done() }
        }
        settle()
        run { [self] in
            before = rects()
            undoBefore = c.store.undoLabel
            guard let exp = menuItem("tabs.expandSplit") else { return check(false, "P06c: the Expand Current Split item") }
            let enabled = exp.validateMenuItem(exp)
            check(enabled && exp.title == WindowController.expandSplitTitle && v().fractions.map { ($0 * 100).rounded() } == [30, 70],
                  "P06c: with a split on screen, Expand Current Split is on (\(enabled), “\(exp.title)”, shares \(v().fractions))")
            exp.fire()
        }
        settle()
        run { [self] in
            let exp = menuItem("tabs.expandSplit")
            _ = exp.map { $0.validateMenuItem($0) }
            let bar = c.splitCommandActions().map(\.title).filter { $0.hasSuffix("Current Split") }
            let other = c.engineTab(for: tabs[0])
            check(expandedOK(tabs[1]) && exp?.title == WindowController.restoreSplitTitle && bar == [WindowController.restoreSplitTitle]
                  && other != nil && other?.isClosed == false && c.shownTabID == tabs[1],
                  "P06c: Expand Current Split: the focused pane fills the split's place, the other waits hidden and live, no dividers or ring; "
                  + "the item and the Command Bar say Restore Current Split (\(widths()); item “\(exp?.title ?? "?")”, Command Bar \(bar))")
            check(c.store.split(splitID)?.fractions.map { ($0 * 100).rounded() } == [30, 70] && c.store.undoLabel == undoBefore,
                  "P06c: expanding leaves the split's sizes as they were and isn't an undo step (shares \(c.store.split(splitID)?.fractions ?? []), "
                  + "undo “\(c.store.undoLabel ?? "none")”)")
            // ⌘[ while expanded: the page's Back, not the other pane.
            menuItem("tabs.back")?.fire()
        }
        step { [self] done in
            waitUntil({ self.c.engineTab(for: tabs[1])?.url?.query == "two" }, timeout: 5) {
                self.check(self.c.engineTab(for: tabs[1])?.url?.query == "two" && self.c.shownTabID == tabs[1] && expandedOK(tabs[1]),
                           "P06c: while expanded, ⌘[ is the page's Back (\(self.c.engineTab(for: tabs[1])?.url?.query ?? "?"), focused \(name(self.c.shownTabID)), "
                           + "still expanded \(self.c.expandedPane == tabs[1]))")
                done()
            }
        }
        run { [self] in menuItem("tabs.expandSplit")?.fire() }
        settle()
        run { [self] in
            check(restoredOK(tabs[1]) && same(rects(), before) && c.store.undoLabel == undoBefore,
                  "P06c: Restore Current Split brings both panes back at 30/70 with the same pane focused, and isn't an undo step (\(widths()), "
                  + "focused \(name(c.shownTabID)))")
        }

        // Four panes: another pane taking the keyboard restores; closing panes while expanded.
        makeSplit({ [open(5, "four"), open(6, "four"), open(7, "four"), open(8, "four")] }, fractions: [0.1, 0.2, 0.3, 0.4], focus: 1)
        run { [self] in
            before = rects()
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            let ok = expandedOK(tabs[1])
            c.focusPane(number: 4)
            check(ok, "P06c: four panes: the second expands over the split (\(widths()))")
        }
        settle()
        run { [self] in
            check(restoredOK(tabs[3]) && same(rects(), before),
                  "P06c: another pane taking the keyboard (⌃⇧4) brings the split back as it was, that pane focused (\(widths()), focused \(name(c.shownTabID)))")
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            guard expandedOK(tabs[3]) else { return check(false, "P06c: the fourth pane expands (\(widths()))") }
            c.closeTab(tabs[0])
        }
        step { [self] done in
            waitUntil({ self.c.store.split(splitID)?.tabIDs.count == 3 }, timeout: 5) { settled(done) }
        }
        run { [self] in
            check(expandedOK(tabs[3]) && v().panes.count == 3,
                  "P06c: closing a hidden pane keeps the expanded one as it is (\(widths()))")
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            check(restoredOK(tabs[3]) && v().panes.count == 3,
                  "P06c: and Restore shows the three left at their sizes (\(widths()), shares \(v().fractions.map { ($0 * 100).rounded() }))")
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in c.closeFocusedPane() }
        step { [self] done in
            waitUntil({ self.c.store.split(splitID)?.tabIDs.count == 2 }, timeout: 5) { settled(done) }
        }
        run { [self] in
            let left = [tabs[1], tabs[2]]
            check(c.expandedPane == nil && v().tabIDs == left && v().panes.allSatisfy { !$0.isHidden && $0.frame.width > 100 }
                  && v().dividers.allSatisfy { !$0.isHidden },
                  "P06c: closing the expanded pane (⌃⇧−) brings the rest back (\(widths()))")
            tabs = left
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            let ok = c.expandedPane != nil
            try? c.store.setSplitAxis(splitID, .vertical)
            check(ok, "P06c: expanded again before Arrange (\(widths()))")
        }
        settle()
        run { [self] in
            check(c.expandedPane == nil && v().axis == .vertical && v().panes.allSatisfy { !$0.isHidden },
                  "P06c: Arrange Top to Bottom ends the expansion: both panes show, stacked (\(widths()))")
            c.toggleExpandedSplit()
        }
        settle()
        var lone = ""
        run { [self] in
            lone = open(9, "lone")
            c.reloadAll(animated: false)
            c.show(lone)
        }
        waitForPage()
        run { [self] in
            check(!c.showsSplit && v().expandedTabID == nil && c.shownTabID == lone,
                  "P06c: showing another tab ends the expansion (split shown \(c.showsSplit), expanded \(name(v().expandedTabID)))")
            c.show(tabs[0])
        }
        settle()
        run { [self] in
            check(c.showsSplit && c.expandedPane == nil && v().panes.allSatisfy { !$0.isHidden },
                  "P06c: back on the split, it isn't expanded (\(widths()))")
        }

        // Separate Page from Split View, and ⌘Z.
        makeSplit({ [open(2, "sep"), open(3, "sep")] }, fractions: [0.35, 0.65], focus: 0)
        run { [self] in
            undoBefore = c.store.undoLabel
            guard let sep = menuItem("tabs.separatePage"), sep.validateMenuItem(sep) else { return check(false, "P06c: Separate Page from Split View is on") }
            sep.fire()
        }
        settle()
        run { [self] in
            let rows = todayTabs()
            check(c.store.split(splitID) == nil && c.shownTabID == tabs[0] && !c.showsSplit && rows.isSuperset(of: tabs),
                  "P06c: Separate Page from Split View: the focused pane is a tab of its own, on screen (split gone \(c.store.split(splitID) == nil), "
                  + "shown \(name(c.shownTabID)))")
            c.undo()
        }
        settle()
        run { [self] in
            let x = c.store.split(containing: tabs[0])
            check(x?.tabIDs == tabs && x?.fractions.map { ($0 * 100).rounded() } == [35, 65],
                  "P06c: ⌘Z brings the split back at its sizes (\(x?.tabIDs.map(name) ?? []), shares \(x?.fractions ?? []))")
        }

        // A pinned split: Expand and Restore, Separate Page, ⌘Z.
        var pinned = ""
        run { [self] in
            let ids = [open(4, "pinned"), open(5, "pinned")]
            guard let x = try? c.store.createSplit(ids, inSpace: sid, focused: ids[0]),
                  (try? c.store.move(.split(x.id), to: .pinned(spaceID: sid, parentID: nil, index: 0))) != nil,
                  let item = c.store.item(x.id), item.kind == .split else { return check(false, "P06c: a pinned split") }
            pinned = item.id
            c.reloadAll(animated: false)
            // As a press on its row does: every pane opens, the first focused.
            guard let first = c.store.panes(ofSplitItem: item.id).first else { return check(false, "P06c: the pinned split's panes") }
            c.openPane(first.id)
        }
        step { [self] done in
            waitUntil({ self.c.shownSplitID == pinned && self.c.splitContainer.panes.count == 2 }, timeout: 8) { settled(done) }
        }
        run { [self] in
            before = rects()
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            let focused = c.shownTabID ?? ""
            let ok = expandedOK(focused)
            c.toggleExpandedSplit()
            check(ok, "P06c: a pinned split's pane expands too (\(widths()))")
        }
        settle()
        run { [self] in
            check(c.expandedPane == nil && same(rects(), before), "P06c: and restores as it was (\(widths()))")
            undoBefore = c.store.undoLabel
            menuItem("tabs.separatePage")?.fire()
        }
        settle()
        run { [self] in
            let pinnedTabs = c.store.pinnedRoots(ofSpace: sid).filter { $0.kind == .tab }.count
            check(c.store.item(pinned)?.kind != .split && pinnedTabs >= 2,
                  "P06c: Separate Page from Split View on a pinned split: its panes are pinned tabs (pinned tabs \(pinnedTabs))")
            c.undo()
        }
        settle()
        run { [self] in
            check(c.store.item(pinned)?.kind == .split && c.store.panes(ofSplitItem: pinned).count == 2,
                  "P06c: ⌘Z makes it a pinned split again (\(c.store.panes(ofSplitItem: pinned).count) panes)")
        }

        // A real ⌥-click on a Today split's row, then on a Favorite split's tile.
        makeSplit({ [open(6, "opt"), open(7, "opt")] }, fractions: [0.5, 0.5], focus: 0)
        func optionClick(_ what: String, at point: @escaping () -> NSPoint?, entry: @escaping () -> SidebarEntry?) {
            step { [self] done in
                whenOwnerAway { why in
                    guard let at = point(), let entry = entry() else { self.check(false, what + ": the row"); return done() }
                    if let why {
                        self.failEnv(what + ": the real ⌥-click", why)
                        self.c.optionClickSplit(entry)
                        return done()
                    }
                    let w = self.c.window
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
        func splitRow() -> SplitRowView? {
            guard let p = c.pageView(for: sid) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.split?.id == splitID }
        }
        run { [self] in undoBefore = c.store.undoLabel }
        optionClick("P06c: ⌥-click on a split's row", at: { [self] in
            guard let p = c.pageView(for: sid), let r = splitRow() else { return nil }
            p.list.scrollToVisible(r.frame.insetBy(dx: 0, dy: -16))
            p.layoutSubtreeIfNeeded()
            return r.convert(NSPoint(x: 60, y: r.bounds.midY), to: nil)
        }, entry: { splitRow()?.entry })
        settle()
        run { [self] in
            check(c.store.split(splitID) == nil && todayTabs().isSuperset(of: tabs),
                  "P06c: ⌥-click on a Today split's row separates it into tabs (Arc 1.17.2) (split gone \(c.store.split(splitID) == nil))")
            c.undo()
        }
        settle()
        run { [self] in
            check(c.store.split(containing: tabs[0])?.tabIDs == tabs, "P06c: ⌘Z makes them a split again")
        }
        var favorite = ""
        run { [self] in
            let ids = [open(8, "fav"), open(9, "fav")]
            guard let x = try? c.store.createSplit(ids, inSpace: sid, focused: ids[0]),
                  (try? c.store.move(.split(x.id), to: .favorites(profileID: c.store.profile(ofSpace: sid).id, index: 0))) != nil,
                  c.store.item(x.id)?.kind == .split else { return check(false, "P06c: a Favorite split") }
            favorite = x.id
            c.reloadAll(animated: false)
        }
        wait(0.4)
        func tile() -> FavoriteTileView? {
            guard let p = c.pageView(for: sid) else { return nil }
            p.layoutSubtreeIfNeeded()
            return p.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == favorite }
        }
        optionClick("P06c: ⌥-click on a Favorite split's tile", at: { tile().map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) } },
                    entry: { [self] in c.store.item(favorite).map { SidebarEntry.favorite($0, c.store.liveTab(forSplitItem: $0.id)) } })
        settle()
        run { [self] in
            check(c.store.item(favorite)?.kind != .split, "P06c: ⌥-click on a Favorite split's tile separates it into Favorites")
            c.undo()
        }
        settle()
        run { [self] in
            check(c.store.item(favorite)?.kind == .split && c.store.panes(ofSplitItem: favorite).count == 2,
                  "P06c: ⌘Z makes it a Favorite split again (\(c.store.panes(ofSplitItem: favorite).count) panes)")
        }
        // Two windows: the second takes the split; the first's expansion ends there, and it isn't expanded in the second.
        // (`c` is the window used last: the first window is kept here before the second opens.)
        var first: WindowController?
        var second: WindowController?
        makeSplit({ [open(2, "windows"), open(3, "windows")] }, fractions: [0.5, 0.5], focus: 0)
        run { [self] in
            c.toggleExpandedSplit()
        }
        settle()
        run { [self] in
            guard c.expandedPane == tabs[0] else { return check(false, "P06c: expanded before the second window (\(widths()))") }
            first = c
            second = app?.openNewWindow(from: c, spaceID: sid, commandBar: false)
            second?.show(tabs[1])
        }
        step { [self] done in
            waitUntil({ second?.shownSplitID == splitID }, timeout: 5) { settled(done) }
        }
        run { [self] in
            guard let first, let second, first !== second else { return check(false, "P06c: a second window") }
            check(second.shownSplitID == splitID && second.expandedPane == nil && !first.showsSplit && first.splitContainer.expandedTabID == nil,
                  "P06c: two windows: a second window that takes the split shows it as it is, and the first's expansion ends "
                  + "(second expanded \(name(second.expandedPane)), first shows it \(first.showsSplit))")
            second.toggleExpandedSplit()
            check(second.expandedPane == tabs[1] && first.expandedPane == nil && first.splitContainer.expandedTabID == nil,
                  "P06c: and an expansion is each window's own (second \(name(second.expandedPane)), first \(name(first.expandedPane)))")
        }
        settle()
        step { [self] done in
            second?.window.close()
            waitUntil({ self.app?.controllers.contains { $0 === second } != true }, timeout: 5) {
                second = nil
                first = nil
                done()
            }
        }

        run { server?.stop() }
    }

    /// Every command item in `menu`, depth first.
    static func p06cItems(_ menu: NSMenu?) -> [CommandMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { item -> [CommandMenuItem] in
            if let c = item as? CommandMenuItem { return [c] }
            return p06cItems(item.submenu)
        }
    }
}
#endif
