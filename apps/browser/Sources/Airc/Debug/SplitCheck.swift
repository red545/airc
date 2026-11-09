// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit
import QuartzCore
#if canImport(AircCore)
import AircCore
#endif

/// Part of `--script events` (both engines): SV-1 Split View through real input, on synthetic pages.
///   - a Today tab dragged onto the right half of another makes a split of the two, shown, in one sidebar row;
///   - the divider follows a 120 Hz drag (each tick's main-thread cost is measured), a release near the middle settles
///     there on a spring, and the sizes are saved;
///   - a click in a pane, ⌘[ / ⌘] and ⌃⇧2 move the keyboard; find and zoom act on the focused pane only;
///   - ⌃⇧+ and a pick in the Command Bar add a pane; ⌘W closes the focused pane and ⌘Z brings it back; a tab dragged
///     onto the page joins on the side it's dropped; Separate All Tabs puts the panes back as rows;
///   - panes in two profiles (a cross-Space split) show side by side, each in its own profile;
///   - Chromium: DevTools open for the focused pane; Peek's Split button splits the same page (no reload).
extension SnapshotRunner {
    func splitChecks() {
        var sid = "", left = "", right = "", third = ""
        func page(_ title: String, _ text: String, color: String) -> String {
            let html = "<title>\(title)</title><body style='margin:0;background:\(color);font:20px -apple-system'>"
                + "<h1 style='margin:40px'>\(title)</h1><p style='margin:40px'>\(text)</p></body>"
            return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        let container = { self.c.splitContainer }
        func panesShown(_ ids: [String]) -> (ok: Bool, text: String) {
            var ok = !container().isHidden && c.card.isHidden && container().tabIDs == ids
            var parts: [String] = []
            for id in ids {
                guard let p = c.engineTab(for: id), let pane = container().pane(for: id) else { ok = false; parts.append("no pane"); continue }
                let attached = p.view.isDescendant(of: pane.host) && !p.view.isHiddenOrHasHiddenAncestor
                let f = pane.frame
                ok = ok && attached && f.width > 150 && f.height > 150
                parts.append(String(format: "%@ %.0f×%.0f%@", c.store.tab(id)?.title ?? "?", f.width, f.height, attached ? "" : " (page not attached)"))
            }
            return (ok, parts.joined(separator: " | "))
        }
        func splitRow(_ splitID: String?) -> SplitRowView? {
            guard let page = c.pageView(for: sid) else { return nil }
            page.layoutSubtreeIfNeeded()
            return page.list.subviews.compactMap { $0 as? SplitRowView }.first { $0.split?.id == splitID }
        }
        func settled(_ done: @escaping () -> Void) {
            waitUntil({ !self.c.animator.isRunning("split") }, timeout: 3) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: done) }
        }
        /// A window point just inside the bottom of `row`, after scrolling the sidebar's list so the row shows, as a person
        /// would before dropping there: the end of Today is often below the list's visible part (the scenario's earlier
        /// checks leave rows, and how many depends on the run). Nil when the point still isn't the list on screen (off the
        /// window, or under the footer), with what it hits instead.
        func dropPoint(below row: NSView, in p: SpacePageView) -> (point: NSPoint?, hit: String) {
            p.list.scrollToVisible(row.frame.insetBy(dx: 0, dy: -16))
            p.layoutSubtreeIfNeeded()
            let end = row.convert(NSPoint(x: 60, y: row.bounds.maxY - 3), to: nil)
            let frameView = c.window.contentView?.superview
            let hit = frameView?.hitTest(frameView!.convert(end, from: nil))
            let onList = hit.map { $0 === p.list || $0.isDescendant(of: p.list) } ?? false
            return (onList ? end : nil, "\(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing") at \(end)")
        }

        run { [self] in
            sid = c.currentSpaceID
            func open(_ t: String, _ text: String, _ color: String) -> String {
                (try? c.store.openTab(url: page(t, text, color: color), inSpace: sid, activate: false, title: t))?.id ?? ""
            }
            third = open("Third", "A page for the third pane", "#efe7f6")
            right = open("Right", "One apple here", "#e3f0ea")
            left = open("Left", "apple, apple and apple", "#f4ece2")
            c.reloadAll(animated: false)
            c.show(right, focus: false)
        }
        waitForPage()

        // 1. Drag Left's row onto the right half of Right's row, once the sidebar has settled: Right shown with its page
        // loaded, no sidebar or split animation running, and both rows still for 0.15 s. A miss says what the press hit,
        // whether the drag started (the row lifts), what the sidebar would drop on at the release, and which window was
        // on top at the press and the release. Another app's window, or another window of ours that isn't part of this
        // one (a check's panel), over the rows is FAIL-ENV (ship run 2026-11-08 07:52: another agent's call panels
        // floated over the window); either way the split is then made directly, so the cases after it still run.
        // AIRC_SPLIT_MISS=1 (by hand): the release aims at the page instead, to see a miss reported.
        step { [self] done in
            var last: [NSRect] = [], still = 0
            waitUntil({
                guard let p = self.c.pageView(for: sid), let a = self.todayRow(left, in: p), let b = self.todayRow(right, in: p) else { return false }
                let now = [a.convert(a.bounds, to: nil), b.convert(b.bounds, to: nil)]
                still = now == last ? still + 1 : 0
                last = now
                return still >= 3 && self.c.shownTabID == right && self.c.engineTab(for: right)?.isLoading == false
                    && !self.c.animator.isRunning("sidebar") && !self.c.animator.isRunning("split")
            }, timeout: 4) { done() }
        }
        step { [self] done in
            guard let p = c.pageView(for: sid), let from = todayRow(left, in: p), let onto = todayRow(right, in: p) else {
                check(false, "split (drag onto a tab): both rows are shown"); return done()
            }
            let w: NSWindow = c.window
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            var end = onto.convert(NSPoint(x: onto.bounds.width - 40, y: onto.bounds.midY), to: nil)
            if ProcessInfo.processInfo.environment["AIRC_SPLIT_MISS"] == "1" { end = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil) }
            let frame = w.contentView!.superview!
            let pressHit = frame.hitTest(frame.convert(start, from: nil))
            let pressOnRow = pressHit.map { $0 === from || $0.isDescendant(of: from) } ?? false
            let releaseHit = frame.hitTest(frame.convert(end, from: nil))
            let entry = from.entry
            // Through the drag: the lifted row (the drag started), and any window over ours at the press or the release.
            var lifted = false
            var interference: String?
            let sampler = Timer(timeInterval: 0.02, repeats: true) { _ in
                if from.alphaValue < 0.9 { lifted = true }
                for q in [start, end] where interference == nil { interference = Self.windowOverOurs(at: q, in: w) }
            }
            RunLoop.main.add(sampler, forMode: .common)
            drag(from: start, to: end) {
                sampler.invalidate()
                self.waitUntil({ self.c.shownSplitID != nil }, timeout: 3) {
                    let x = self.c.store.split(containing: left)
                    let ok = x?.tabIDs == [right, left] && self.c.shownSplitID == x?.id && self.c.shownTabID == left
                    let what = "split (drag onto a tab): Left on Right's right half makes Right | Left, shown with Left focused "
                        + "(panes \(x?.tabIDs.map { self.c.store.tab($0)?.title ?? "?" } ?? []), focused \(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))"
                    guard !ok else {
                        self.check(true, what)
                        return done()
                    }
                    let target = entry.flatMap { p.dropDestination(at: p.convert(end, from: nil), source: .tab(left), entry: $0) }
                    let why = "the press hit \(Self.describe(pressHit)) (Left's row \(pressOnRow)); the drag \(lifted ? "started (the row lifted)" : "never started"); "
                        + "the release is over \(Self.describe(releaseHit)), where the sidebar would drop \(self.splitDropName(target)); "
                        + "on top at the press: \(Self.windowOwner(at: w.convertPoint(toScreen: start))), "
                        + "at the release: \(Self.windowOwner(at: w.convertPoint(toScreen: end)))"
                    if let interference { self.failEnv(what, interference + "; " + why) } else { self.check(false, what + "; " + why) }
                    // The rest of the cases run on the split the drop should have made.
                    if let x { try? self.c.store.separateSplit(x.id) }
                    if (try? self.c.store.createSplit([right, left], inSpace: sid, focused: left)) != nil { self.c.show(left, focus: false) }
                    done()
                }
            }
        }
        wait(0.6)
        step { [self] done in
            let x = c.store.split(containing: left)
            let row = splitRow(x?.id)
            let p = c.pageView(for: sid)
            let alone = p.map { todayRow(left, in: $0) == nil && todayRow(right, in: $0) == nil } ?? false
            check(row != nil && alone && c.store.todayRows(ofSpace: sid).filter { $0.split != nil }.count == 1,
                  "split: one row in the sidebar (\(row.map { "\($0.tabs.count) segments, selected \($0.isSelected)" } ?? "none")), no rows of its own for its tabs")
            let shown = panesShown([right, left])
            check(shown.ok, "split: both pages live side by side in their own cards: " + shown.text)
            captureNow("split-2-panes") { done() }
        }

        // 2. The divider: a 120 Hz drag, 120 pt to the right.
        step { [self] done in
            let v = container()
            guard v.panes.count == 2 else { check(false, "split (resize): two panes"); return done() }
            let before = v.panes[0].frame.width
            let gapMid = v.panes[0].frame.maxX + SplitContainerView.gap / 2
            let start = v.convert(NSPoint(x: gapMid, y: v.bounds.midY), to: nil)
            // Baseline: a commit carrying one hidden 1×1 layer's move, in the same window and session.
            let probe = CALayer()
            probe.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            probe.isHidden = true
            c.root.layer?.addSublayer(probe)
            var base: [Double] = []
            for k in 0..<30 {
                let b0 = CACurrentMediaTime()
                probe.position = CGPoint(x: k % 2, y: 0)
                CATransaction.flush()
                base.append((CACurrentMediaTime() - b0) * 1000)
            }
            probe.removeFromSuperlayer()
            base.sort()
            note(String(format: "split (resize) timing: a commit with nothing but a 1×1 layer move costs median %.3f ms here (baseline)", base[base.count / 2]))
            SplitContainerView.dividerTickMs = []
            SplitContainerView.measureCommit = true
            let clock = FrameClock()
            clock.start(on: c.root)
            let t0 = CACurrentMediaTime()
            dividerDrag(from: start, by: 120, ticks: 60) {
                let t1 = CACurrentMediaTime()
                SplitContainerView.measureCommit = false
                settled {
                    let after = v.panes[0].frame.width
                    let saved = self.c.store.split(v.splitID)?.fractions ?? []
                    let savedMatches = zip(saved, v.fractions).allSatisfy { abs($0 - $1) < 0.002 }
                    self.check(abs(after - before - 120) <= 2 && savedMatches,
                               String(format: "split (resize): a real divider drag widens the left pane %.0f → %.0f pt (+120 asked); sizes saved %@",
                                      before, after, savedMatches ? "yes" : "no \(saved)"))
                    let ms = SplitContainerView.dividerTickMs.sorted()
                    func q(_ f: Double) -> Double { ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * f))] }
                    let frames = clock.deltas(from: t0, to: t1)
                    let interval = clock.refreshHz.map { 1000 / $0 } ?? 8.33
                    let missed = frames.filter { $0 > interval * 1.5 }.count
                    clock.stop()
                    self.note(String(format: "split (resize) timing: %d ticks, main-thread per tick (layout + autoresize + CA commit) median %.3f ms, p95 %.3f ms, max %.3f ms; "
                                     + "display link %d frames at %.0f Hz, %d longer than 1.5 frames", ms.count, q(0.5), q(0.95), ms.last ?? 0,
                                     frames.count, clock.refreshHz ?? 0, missed))
                    SplitTimings.record(engine: self.app?.engine.name ?? "?", ticks: ms, frames: frames, refreshHz: clock.refreshHz, dir: self.dir)
                    self.check(!ms.isEmpty && q(0.95) < 8.3,
                               String(format: "split (resize): each divider tick fits a 120 Hz frame (p95 %.3f ms of 8.3)", q(0.95)))
                    if frames.count < 10 {
                        self.skip("split (resize): presented frames during the drag: the window isn't drawn (screen locked \(Self.screenLocked))")
                    } else {
                        self.check(missed <= 2, String(format: "split (resize): the drag kept the display's pace: %d of %d frames longer than 1.5 intervals at %.0f Hz",
                                                        missed, frames.count, clock.refreshHz ?? 0))
                    }
                    done()
                }
            }
        }
        // …and a release near the middle settles on an even split.
        step { [self] done in
            let v = container()
            guard v.panes.count == 2 else { return done() }
            let gapMid = v.panes[0].frame.maxX + SplitContainerView.gap / 2
            let start = v.convert(NSPoint(x: gapMid, y: v.bounds.midY), to: nil)
            let middle = v.bounds.width / 2
            dividerDrag(from: start, by: middle - gapMid + 9, ticks: 30) {
                settled {
                    let f = v.fractions
                    self.check(f.count == 2 && abs(f[0] - 0.5) < 0.001 && abs((self.c.store.split(v.splitID)?.fractions.first ?? 0) - 0.5) < 0.001,
                               String(format: "split (resize): let go 9 pt from the middle, the panes spring to an even split (%.3f / %.3f)",
                                      f.first ?? 0, f.last ?? 0))
                    done()
                }
            }
        }

        // 3. Focus: a click in a pane, ⌘[ / ⌘], the sidebar segment.
        step { [self] done in
            guard let pane = container().pane(for: right) else { return done() }
            let p = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            click(at: p, in: c.window) {
                self.waitUntil({ self.c.shownTabID == right }, timeout: 2) {
                    let field = self.c.pageView(for: sid)?.urlField
                    self.check(self.c.shownTabID == right && self.c.shownSplitID != nil && container().pane(for: right)?.focused == true,
                               "split (focus): a click in the left pane gives it the keyboard; the split stays (focused \(self.c.store.tab(self.c.shownTabID)?.title ?? "-"), URL field \(field != nil))")
                    done()
                }
            }
        }
        key("]", 30, .command)
        step { [self] done in
            waitUntil({ self.c.shownTabID == left }, timeout: 2) {
                self.check(self.c.shownTabID == left && self.c.store.split(self.c.shownSplitID)?.focusedTabID == left,
                           "split (focus): ⌘] moves to the next pane (\(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))")
                done()
            }
        }
        key("[", 33, .command)
        step { [self] done in
            waitUntil({ self.c.shownTabID == right }, timeout: 2) {
                self.check(self.c.shownTabID == right, "split (focus): ⌘[ moves back (\(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))")
                done()
            }
        }
        key("@", 19, [.control, .shift])
        step { [self] done in
            waitUntil({ self.c.shownTabID == left }, timeout: 2) {
                self.check(self.c.shownTabID == left, "split (focus): ⌃⇧2 focuses the second pane (\(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))")
                done()
            }
        }
        step { [self] done in
            guard let row = splitRow(c.shownSplitID), let p = row.segmentCentre(0) else { check(false, "split (focus): the row's first segment"); return done() }
            click(at: p, in: c.window) {
                self.waitUntil({ self.c.shownTabID == right }, timeout: 2) {
                    self.check(self.c.shownTabID == right && self.c.shownSplitID != nil,
                               "split (focus): a click on the row's first segment focuses its pane (\(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))")
                    done()
                }
            }
        }

        // 4. Find and zoom act on the focused pane only.
        key("@", 19, [.control, .shift])
        step { [self] done in waitUntil({ self.c.shownTabID == left }, timeout: 2) { done() } }
        key("f", 3, .command)
        step { [self] done in
            guard let bar = c.findBar else { check(false, "split (find): ⌘F opens the find bar"); return done() }
            let pane = container().pane(for: left).map { container().convert($0.frame, to: c.root) } ?? .zero
            check(pane.contains(bar.frame), "split (find): the find bar sits over the focused pane")
            let p = bar.field.convert(NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY), to: nil)
            click(at: p, in: c.window, done)
        }
        step { [self] done in
            typeText("apple")
            waitUntil({ self.c.findBar?.statusText.contains("3") == true }, timeout: 3) {
                self.check(self.c.findBar?.statusText.contains("3") == true,
                           "split (find): \"apple\" finds Left's 3 matches (\(self.c.findBar?.statusText ?? "no bar"))")
                done()
            }
        }
        key("\u{1b}", 53)
        key("[", 33, .command)
        key("f", 3, .command)
        step { [self] done in
            guard let bar = c.findBar else { check(false, "split (find): ⌘F in the other pane"); return done() }
            let p = bar.field.convert(NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY), to: nil)
            click(at: p, in: c.window, done)
        }
        step { [self] done in
            typeText("apple")
            waitUntil({ self.c.findBar?.statusText.hasPrefix("1") == true || self.c.findBar?.statusText.contains("1 of 1") == true }, timeout: 3) {
                self.check(self.c.shownTabID == right && self.c.findBar?.statusText.contains("1") == true && self.c.findBar?.statusText.contains("3") != true,
                           "split (find): in Right's pane it finds Right's 1 match (\(self.c.findBar?.statusText ?? "no bar"))")
                done()
            }
        }
        key("\u{1b}", 53)
        key("=", 24, .command)
        step { [self] done in
            waitUntil({ (self.c.engineTab(for: right)?.zoomFactor ?? 1) > 1.01 }, timeout: 2) {
                let zr = self.c.engineTab(for: right)?.zoomFactor ?? 0, zl = self.c.engineTab(for: left)?.zoomFactor ?? 0
                self.check(zr > 1.01 && abs(zl - 1) < 0.01,
                           String(format: "split (zoom): ⌘+ zooms the focused pane only (Right %.0f %%, Left %.0f %%)", zr * 100, zl * 100))
                done()
            }
        }
        key("0", 29, .command)
        #if canImport(AircCore)
        // DevTools for the focused pane (Chromium).
        step { [self] done in
            guard let engine = app?.engine as? ChromiumEngine, let r = c.engineTab(for: right), let l = c.engineTab(for: left) else { return done() }
            postKey("i", keyCode: 34, modifiers: [.command, .option])
            waitUntil({ engine.devToolsOpen(for: r) }, timeout: 4) {
                self.check(engine.devToolsOpen(for: r) && !engine.devToolsOpen(for: l),
                           "split (DevTools): ⌥⌘I opens DevTools for the focused pane only (Right \(engine.devToolsOpen(for: r)), Left \(engine.devToolsOpen(for: l)))")
                engine.closeDevTools(for: r)
                done()
            }
        }
        wait(0.4)
        #endif

        // 5. ⌃⇧+ and a pick: a third pane. ⌘W closes the focused pane; ⌘Z brings it back.
        key("+", 24, [.control, .shift])
        step { [self] done in
            waitUntil({ self.c.commandBar != nil && self.c.pendingSplit != nil }, timeout: 2) {
                self.check(self.c.commandBar != nil && self.c.pendingSplit != nil, "split (⌃⇧+): the Command Bar opens for a new pane")
                done()
            }
        }
        // The pick: "Third" typed, its Switch to Tab row chosen with ↓ and ↩.
        // postKey queues events: the unfiltered list already contains Third, so await the text too.
        run { [self] in typeText("Third") }
        step { [self] done in
            func index() -> Int? {
                c.commandBar?.results.firstIndex { r in if case .tab(let id) = r.action { return id == third }; return false }
            }
            waitUntil({ self.c.commandBar?.typed == "Third" && index() != nil }, timeout: 3) {
                guard let bar = self.c.commandBar, bar.typed == "Third", let i = index() else {
                    self.check(false, "split (⌃⇧+): the Command Bar lists Third's tab"); return done()
                }
                self.note("split pick: query \(bar.typed), target \(i), selected \(bar.selected), rows \(bar.resultTitles)")
                // A pointer hover can already have selected a row below the desired one.
                let delta = i - bar.selected
                for _ in 0..<abs(delta) {
                    self.postKey(delta < 0 ? "\u{F700}" : "\u{F701}", keyCode: delta < 0 ? 126 : 125)
                }
                self.waitUntil({
                    guard bar.results.indices.contains(bar.selected), case .tab(let id) = bar.results[bar.selected].action else { return false }
                    return id == third
                }, timeout: 3) {
                    self.note("split pick before Return: selected \(bar.selected), rows \(bar.resultTitles)")
                    self.check(bar.results.indices.contains(bar.selected) && {
                        if case .tab(let id) = bar.results[bar.selected].action { return id == third }
                        return false
                    }(), "split (⌃⇧+): keyboard selection reaches Third before Return")
                    self.postKey("\r", keyCode: 36)
                    done()
                }
            }
        }
        step { [self] done in
            waitUntil({ self.c.store.split(self.c.shownSplitID)?.tabIDs.count == 3 }, timeout: 3) {
                settled {
                    let ids = self.c.store.split(self.c.shownSplitID)?.tabIDs ?? []
                    let shown = panesShown(ids)
                    self.check(ids == [right, third, left] && self.c.shownTabID == third && shown.ok,
                               "split (⌃⇧+): the pick opens as a pane next to the focused one, focused: " + shown.text)
                    self.captureNow("split-3-panes") { done() }
                }
            }
        }
        key("w", 13, .command)
        step { [self] done in
            waitUntil({ self.c.store.split(self.c.shownSplitID)?.tabIDs.count == 2 }, timeout: 3) {
                settled {
                    let ids = self.c.store.split(self.c.shownSplitID)?.tabIDs ?? []
                    self.check(ids == [right, left] && self.c.store.tab(third) == nil && self.c.shownTabID == left && panesShown(ids).ok,
                               "split (close): ⌘W closes the focused pane; its neighbour takes the keyboard (focused \(self.c.store.tab(self.c.shownTabID)?.title ?? "-"))")
                    done()
                }
            }
        }
        key("z", 6, .command)
        step { [self] done in
            waitUntil({ self.c.store.split(self.c.shownSplitID)?.tabIDs.count == 3 }, timeout: 3) {
                settled {
                    let ids = self.c.store.split(self.c.shownSplitID)?.tabIDs ?? []
                    self.check(ids == [right, third, left] && panesShown(ids).ok,
                               "split (close): ⌘Z brings the pane back in its place (\(ids.count) panes)")
                    done()
                }
            }
        }

        // 6. Separate All Tabs: the panes are rows again, in pane order, where the split was.
        step { [self] done in
            guard let x = c.store.split(c.shownSplitID), let row = splitRow(x.id), let menu = c.menu(for: row.entry!, pane: nil) as NSMenu?,
                  let item = menu.items.first(where: { $0.title == "Separate All Tabs" }) as? ClosureMenuItem else {
                check(false, "split (separate): the row's menu has Separate All Tabs"); return done()
            }
            let focused = c.shownTabID
            item.fire()
            waitUntil({ self.c.shownSplitID == nil }, timeout: 2) {
                let rows = self.c.store.todayRows(ofSpace: sid).map(\.id)
                let order = rows.filter { [right, third, left].contains($0) }
                self.check(self.c.store.split(x.id) == nil && order == [right, third, left] && self.c.shownTabID == focused
                           && !self.c.card.isHidden && container().isHidden,
                           "split (separate): Separate All Tabs puts back \(order.count) rows in pane order; the focused tab stays shown alone")
                done()
            }
        }

        // 7. A tab dragged onto the page joins the page on screen, on the side it's dropped (Arc 101).
        step { [self] done in
            c.show(right, focus: false)
            guard let p = c.pageView(for: sid), let from = todayRow(third, in: p) else { check(false, "split (drag onto the page): Third's row"); return done() }
            let start = from.convert(NSPoint(x: 90, y: from.bounds.midY), to: nil)
            let card = c.card.frame
            let end = c.root.convert(NSPoint(x: card.minX + 60, y: card.midY), to: nil)
            drag(from: start, to: end) {
                self.waitUntil({ self.c.shownSplitID != nil }, timeout: 3) {
                    settled {
                        let x = self.c.store.split(self.c.shownSplitID)
                        self.check(x?.tabIDs == [third, right] && x?.axis == .horizontal && self.c.shownTabID == third && self.c.splitDropPreview.isHidden,
                                   "split (drag onto the page): Third dropped on the page's left edge opens left of Right "
                                   + "(\(x?.tabIDs.map { self.c.store.tab($0)?.title ?? "?" } ?? []))")
                        done()
                    }
                }
            }
        }
        run { [self] in if let id = c.shownSplitID { c.separateSplit(id) } }
        wait(0.3)

        // 8. Two profiles side by side (a cross-Space split): each pane keeps its own.
        var otherTab = ""
        step { [self] done in
            let mine = c.store.profile(ofSpace: sid).id
            let other = c.store.orderedProfiles.first { $0.id != mine } ?? (try? c.profiles.createProfile(name: "Split Test", emoji: "", color: nil))
            guard let other, let space = c.store.spaces(usingProfile: other.id).first
                    ?? (try? c.store.createSpace(name: "Split Other", profileID: other.id)),
                  let t = try? c.store.openTab(url: page("Elsewhere", "Another profile's page", color: "#e4ebf5"), inSpace: space.id, activate: false, title: "Elsewhere") else {
                check(false, "split (profiles): a page in another profile"); return done()
            }
            otherTab = t.id
            c.reloadAll(animated: false)
            waitUntil({ self.c.profiles.engineProfile(for: other.id) != nil }, timeout: 8) { [self] in
            do {
                _ = try c.store.move(.tab(t.id), to: .split(spaceID: sid, target: left, leading: false))
                c.show(left, focus: false)
            } catch { check(false, "split (profiles): \(error)") }
            waitUntil({ self.c.shownSplitID != nil && self.c.engineTab(for: otherTab)?.isLoading == false }, timeout: 6) {
                let ids = self.c.store.split(self.c.shownSplitID)?.tabIDs ?? []
                let profiles = ids.compactMap { self.c.engineTab(for: $0)?.profile }.map { ObjectIdentifier($0) }
                let tab = self.c.store.tab(otherTab)
                self.check(ids == [left, otherTab] && Set(profiles).count == 2 && tab?.profileID == other.id && tab?.spaceID == space.id
                           && panesShown(ids).ok,
                           "split (profiles): a tab of \(other.name) shows beside one of \(self.c.store.profile(mine)?.name ?? "?"), each in its own profile, in this Space's row")
                self.captureNow("split-two-profiles") { done() }
            }
            }
        }
        run { [self] in if let id = c.shownSplitID { c.separateSplit(id) } }
        wait(0.3)

        // 9. A split's row moves in Today like a tab's.
        step { [self] done in
            guard let x = try? c.store.createSplit([right, third], inSpace: sid) else { check(false, "split (row drag): a split"); return done() }
            c.reloadAll(animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let p = self.c.pageView(for: sid), let row = splitRow(x.id), let last = p.list.subviews.compactMap({ $0 as? SidebarRowView })
                        .filter({ ($0 as? TabRowView)?.entry?.liveTab?.isToday == true || $0 is SplitRowView }).max(by: { $0.frame.maxY < $1.frame.maxY }),
                      last !== row else { self.check(false, "split (row drag): its row and one below it"); return done() }
                let before = self.c.store.todayRows(ofSpace: sid).map(\.id)
                let (drop, dropHit) = dropPoint(below: last, in: p)
                guard let end = drop else {
                    self.check(false, "split (row drag): the last Today row shows in the sidebar (\(dropHit))"); return done()
                }
                let start = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
                self.drag(from: start, to: end) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let after = self.c.store.todayRows(ofSpace: sid).map(\.id)
                        self.check(after.last == x.id && before.last != x.id && self.c.store.split(x.id)?.tabIDs == [right, third],
                                   "split (row drag): dragging the split's row below the last Today row moves it there, whole (\(before.firstIndex(of: x.id) ?? -1) → \(after.firstIndex(of: x.id) ?? -1) of \(after.count))")
                        self.c.separateSplit(x.id)
                        done()
                    }
                }
            }
        }
        wait(0.3)

        // 10. A pane dragged out by its handle, onto Today below the last row: a tab of its own there, the rest of the
        // split still on screen. Real press, drags and release through the window.
        var paneSplit = ""
        step { [self] done in
            guard let x = try? c.store.createSplit([left, right, third], inSpace: sid) else { check(false, "split (pane out): a split"); return done() }
            paneSplit = x.id
            c.reloadAll(animated: false)
            c.show(left, focus: false)
            settled(done)
        }
        step { [self] done in
            guard let pane = container().pane(for: right), let p = c.pageView(for: sid),
                  let last = p.list.subviews.compactMap({ $0 as? SidebarRowView })
                    .filter({ ($0 as? TabRowView)?.entry?.liveTab?.isToday == true || $0 is SplitRowView }).max(by: { $0.frame.maxY < $1.frame.maxY }) else {
                check(false, "split (pane out): the middle pane and a Today row"); return done()
            }
            // What the pointer near the pane's top does (a posted move doesn't drive tracking areas).
            pane.handle.setShown(true)
            let h = pane.handle
            let start = h.convert(NSPoint(x: h.grabRect.midX, y: h.grabRect.midY), to: nil)
            let (drop, dropHit) = dropPoint(below: last, in: p)
            guard let end = drop else {
                check(false, "split (pane out): the last Today row shows in the sidebar (\(dropHit))"); return done()
            }
            let frameView = c.window.contentView?.superview
            let hit = frameView?.hitTest(frameView!.convert(start, from: nil))
            note("split (pane out): press on \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing") at \(start), drop on \(dropHit)")
            drag(from: start, to: end) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let x = self.c.store.split(paneSplit)
                    let rows = self.c.store.todayRows(ofSpace: sid).map(\.id)
                    let shown = panesShown([left, third])
                    self.check(x?.tabIDs == [left, third] && self.c.store.split(containing: right) == nil && rows.last == right
                               && self.c.store.tab(right)?.isToday == true && self.c.shownSplitID == paneSplit && shown.ok,
                               "split (pane out): dragging the middle pane's handle to the end of Today makes it a tab of its own there "
                               + "(split now \(x?.tabIDs.compactMap { self.c.store.tab($0)?.title } ?? []), last row \(self.c.store.tab(rows.last ?? "")?.title ?? "?"), "
                               + "on screen \(shown.text))")
                    self.captureNow("split-pane-dragged-out") { done() }
                }
            }
        }
        run { [self] in if c.store.split(paneSplit) != nil { c.separateSplit(paneSplit) } }
        wait(0.3)

        #if canImport(AircCore)
        peekSplitCheck(on: { left })
        #endif
        lateCommandSelectionCheck()
    }

    /// A 120 Hz drag on a divider: press at `start`, `ticks` drag events one display frame apart, `by` points along the
    /// split's axis, release. Through the app's event queue, as a trackpad drag arrives.
    func dividerDrag(from start: NSPoint, by distance: CGFloat, ticks: Int, _ done: @escaping () -> Void) {
        let w = c.window
        let vertical = c.splitContainer.axis == .vertical
        func post(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        post(.leftMouseDown, start)
        var n = 0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { t in
            n += 1
            let d = distance * CGFloat(n) / CGFloat(ticks)
            // Window coordinates have y up.
            let p = vertical ? NSPoint(x: start.x, y: start.y - d) : NSPoint(x: start.x + d, y: start.y)
            post(.leftMouseDragged, p)
            if n >= ticks {
                t.invalidate()
                post(.leftMouseUp, p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    #if canImport(AircCore)
    /// PK-1 → SV-1: Peek's Split button splits the same page (no reload) with the page under the card.
    private func peekSplitCheck(on anchor: @escaping () -> String) {
        var peeked: EngineTab?
        step { [self] done in
            let id = anchor()
            c.show(id, focus: false)
            guard let opener = c.engineTab(for: id) else { check(false, "peek → split: the opener"); return done() }
            let html = "<title>Peeked</title><p>Peeked page</p>"
            guard let url = URL(string: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")) else { return done() }
            c.openPeek(url, from: opener)
            waitUntil({ self.c.peek?.page.isLoading == false && self.c.peek?.page.title == "Peeked" }, timeout: 5) {
                peeked = self.c.peek?.page
                peeked?.evaluate("window.__aircToken = 42", completion: { _ in done() })
                if peeked == nil { done() }
            }
        }
        step { [self] done in
            guard let v = c.peek?.view else { check(false, "peek → split: Peek opened"); return done() }
            let b = v.splitButton
            click(at: b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil), in: c.window) {
                self.waitUntil({ self.c.peek == nil && self.c.shownSplitID != nil }, timeout: 3) {
                    let x = self.c.store.split(self.c.shownSplitID)
                    let pane = x?.tabIDs.last.flatMap { self.c.engineTab(for: $0) }
                    let same = pane != nil && pane === peeked
                    pane?.evaluate("window.__aircToken") { token in
                        self.check(x?.tabIDs.first == anchor() && same && (token as? Int) == 42 && self.c.shownTabID == x?.tabIDs.last,
                                   "peek → split: the Split button puts the same page (token \(token.map { "\($0)" } ?? "-"), same page \(same)) "
                                   + "beside the page under the card, focused")
                        self.captureNow("split-from-peek") { done() }
                    }
                }
            }
        }
        run { [self] in if let id = c.shownSplitID { c.separateSplit(id) } }
        wait(0.3)
    }
    #endif
}

/// The divider timings, as JSON next to the log (`split-timings.json`).
enum SplitTimings {
    static func record(engine: String, ticks: [Double], frames: [Double], refreshHz: Double?, dir: URL) {
        let s = ticks.sorted()
        func q(_ f: Double) -> Double { s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * f))] }
        let interval = refreshHz.map { 1000 / $0 } ?? 8.33
        let json: [String: Any] = [
            "engine": engine, "ticks": s.count, "tick_ms_median": q(0.5), "tick_ms_p95": q(0.95), "tick_ms_max": s.last ?? 0,
            "budget_ms": 8.33, "display_frames": frames.count, "refresh_hz": refreshHz ?? NSNull(),
            "frames_over_1_5_intervals": frames.filter { $0 > interval * 1.5 }.count,
            "frame_ms_max": frames.max() ?? NSNull(), "screen_locked": SnapshotRunner.screenLocked,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("split-timings.json"))
        }
    }
}

// MARK: - Relaunch (`--script split-write`, then `--script split-read` on the same data)

extension SnapshotRunner {
    private static func splitPage(_ title: String, _ color: String) -> String {
        let html = "<title>\(title)</title><body style='margin:0;background:\(color);font:20px -apple-system'><h1 style='margin:40px'>\(title)</h1></body>"
        return "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    /// SV-2 and SB-15 in a Space of their own (FavSplitCheck.swift), with the split below written in between.
    func splitPersistWrite() { favSplitChecks(beforeUnloading: writeTodaySplit) }

    /// A stacked split (Top 35 %, Bottom 65 %, Bottom focused) on screen when the app quits.
    private func writeTodaySplit() {
        run { [self] in
            let sid = c.currentSpaceID
            guard let top = try? c.store.openTab(url: Self.splitPage("Top", "#e3f0ea"), inSpace: sid, activate: false, title: "Top"),
                  let bottom = try? c.store.openTab(url: Self.splitPage("Bottom", "#f4ece2"), inSpace: sid, activate: false, title: "Bottom"),
                  let x = try? c.store.createSplit([top.id, bottom.id], inSpace: sid, axis: .vertical, focused: bottom.id) else {
                return check(false, "split relaunch: a split to keep")
            }
            c.store.setSplitFractions(x.id, [0.35, 0.65])
            c.reloadAll(animated: false)
            c.show(bottom.id, focus: false)
        }
        waitForPage()
        run { [self] in
            let x = c.store.split(c.shownSplitID)
            note("split relaunch: before quitting, split \(x?.tabIDs.count ?? 0) panes, axis \(x?.axis.rawValue ?? "-"), "
                 + "fractions \(x?.fractions.map { String(format: "%.2f", $0) } ?? []), focused \(c.store.tab(c.shownTabID)?.title ?? "-")")
            try? c.store.flush()
        }
    }

    /// The relaunch shows the same split: its panes, order, axis, sizes and focused pane, both pages live.
    func splitPersistRead() {
        waitForPage()
        step { [self] done in
            waitUntil({ self.c.shownSplitID != nil && self.c.splitContainer.panes.allSatisfy { self.c.engineTab(for: $0.tabID)?.isLoading == false } }, timeout: 8) {
                let x = self.c.store.split(self.c.shownSplitID)
                let titles = x?.tabIDs.map { self.c.store.tab($0)?.title ?? "?" } ?? []
                let v = self.c.splitContainer
                let heights = v.panes.map(\.frame.height)
                let share = heights.count == 2 ? heights[0] / max(1, heights[0] + heights[1]) : 0
                let attached = v.panes.allSatisfy { p in self.c.engineTab(for: p.tabID).map { $0.view.isDescendant(of: p.host) } ?? false }
                self.check(titles == ["Top", "Bottom"] && x?.axis == .vertical && abs((x?.fractions.first ?? 0) - 0.35) < 0.001
                           && self.c.store.tab(self.c.shownTabID)?.title == "Bottom" && abs(share - 0.35) < 0.02 && attached && !v.isHidden,
                           String(format: "split relaunch: the split comes back as it was: %@, %@, top pane %.0f %%, focused %@, pages attached %@",
                                  titles.joined(separator: " / "), x?.axis.rawValue ?? "-", share * 100,
                                  self.c.store.tab(self.c.shownTabID)?.title ?? "-", attached ? "yes" : "no"))
                let row = self.c.pageView(for: self.c.currentSpaceID)?.list.subviews.compactMap { $0 as? SplitRowView }.first
                self.check(row?.split?.id == x?.id && row?.isSelected == true, "split relaunch: its sidebar row is there, selected")
                self.captureNow("split-after-relaunch") { done() }
            }
        }
        favSplitPersistRead()
    }
}

extension SnapshotRunner {
    /// Another app's window, or another window of ours that isn't `w` or one of its own (a check's panel), on top at
    /// window point `p` of `w`: what it is (another app by its name only), else nil.
    static func windowOverOurs(at p: NSPoint, in w: NSWindow) -> String? {
        let n = NSWindow.windowNumber(at: w.convertPoint(toScreen: p), belowWindowWithWindowNumber: 0)
        guard n > 0, n != w.windowNumber else { return nil }
        if let ours = NSApp.windows.first(where: { $0.windowNumber == n }) {
            var parent = ours.parent
            while let up = parent, up !== w { parent = up.parent }
            if parent === w { return nil }
        }
        return "a window over ours at the rows: " + windowOwner(at: w.convertPoint(toScreen: p))
    }

    /// What the sidebar would do with the drop, in words.
    func splitDropName(_ d: DropDestination?) -> String {
        switch d {
        case .split(_, let target, let leading)?: "a split with \(c.store.tab(target)?.title ?? "?") (\(leading ? "first" : "last") pane)"
        case .today(_, let i)?: "into Today at \(i) (a move, no split)"
        case .pinned?: "into Pinned"
        case .favorites?: "into Favorites"
        case nil: "nothing"
        }
    }
}
#endif
