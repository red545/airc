// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script multiselect` (SB-36, Sidebar/SpacePage.swift, Browser/SelectionActions.swift), both engines, on loopback
/// pages. Home has pinned P1 and P2, folder F (X loaded, Y) and Today A B C D (A shown); Work has W.
///   1. Selection: ⌘-click takes the clicked row and the shown one, the page stays; ⇧-click ranges stay in their
///      section (Today, the pinned top level, one folder's rows); ⌘-click toggles off; Esc, a click on the page and a
///      plain click on another row clear it. The rows draw Arc's secondary selection; the sidebar takes the keyboard.
///   2. The context menu's titles for 3 tabs, then each action and its undo: ⇧⌘C (the check's own pasteboard),
///      Duplicate, ⌘D, ⌘W with ⇧⌘T, Delete, Move to Space, Add to Folder, New Folder with N Tabs, Open in Split View.
///   3. Dragging a selected row carries the selection: onto a folder, across Spaces by the sidebar's edge, and onto a
///      second window's sidebar; each in order, one ⌘Z.
/// Clicks go to the rows' own mouseDown through `NSWindow.sendEvent`; keys and drags are posted through `NSApp`, so the
/// app's key monitor and the page's drag loop see them as a person's. Undo runs `WindowController.undo` (⌘Z's handler)
/// except for ⌘W's, which posts ⇧⌘T.
extension SnapshotRunner {
    private final class MSState {
        var home = "", work = ""
        var port: UInt16 = 0
        /// Name → Today tab ID, or pinned item / folder ID.
        var id: [String: String] = [:]
        var server: LocalPageServer?
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("org.airc.check.multiselect"))
        var w2: WindowController?
        /// The check's own window (`c` is the app's first controller, which a new window replaces).
        var w1: WindowController!
    }

    func multiSelectScenario() {
        let k = MSState()
        msSetUp(k)
        waitForPage()
        msSelection(k)
        msActions(k)
        msDrags(k)
        run { [self] in
            k.server?.stop()
            WindowController.selectionTestPasteboard = nil
            k.pasteboard.releaseGlobally()
            msTraceNow("finished")
            note("multiselect: done on \(app?.engine.name ?? "?") (window key \(k.w1.window.isKeyWindow), active Space \(k.w1.window.isOnActiveSpace), locked \(Self.screenLocked))")
        }
    }

    // MARK: Fixture and helpers

    private func msSetUp(_ k: MSState) {
        step { [self] done in
            k.w1 = c
            let names = ["p1", "p2", "x", "y", "a", "b", "c", "d", "w"]
            let pages = Dictionary(uniqueKeysWithValues: names.map { n in
                ("/\(n).html", "<!doctype html><title>\(n.uppercased())</title><body style='font:40px -apple-system;padding:40px'>\(n.uppercased())")
            })
            k.server = LocalPageServer(pages: pages)
            k.server?.start { port in
                guard let port else { self.check(false, "multiselect: the loopback page server starts"); return self.finish() }
                k.port = port
                let s = k.w1.store
                k.home = s.selectedSpace.id
                try? s.updateSpace(k.home) { $0.name = "Home" }
                k.work = (try? s.createSpace(name: "Work", icon: .emoji("💼"), profileID: s.selectedSpace.profileID, after: k.home).id) ?? ""
                func url(_ n: String) -> String { "http://127.0.0.1:\(port)/\(n).html" }
                func pin(_ n: String, parent: String? = nil, loaded: Bool) {
                    guard let t = try? s.openTab(url: url(n), inSpace: k.home, title: n.uppercased()) else { return }
                    let at = s.children(of: .pinned(spaceID: k.home), parent: parent).count
                    try? s.move(.tab(t.id), to: .pinned(spaceID: k.home, parentID: parent, index: at))
                    guard let iid = s.tab(t.id)?.itemID else { return }
                    try? s.renameItem(iid, to: n.uppercased())
                    if !loaded { _ = try? s.closeTab(t.id) }
                    k.id[n] = iid
                }
                pin("p1", loaded: false)
                pin("p2", loaded: false)
                if let f = try? s.createFolder(named: "F", inSpace: k.home) { k.id["f"] = f.id }
                pin("x", parent: k.id["f"], loaded: true)
                pin("y", parent: k.id["f"], loaded: false)
                for n in ["d", "c", "b", "a"] { k.id[n] = try? s.openTab(url: url(n), inSpace: k.home, title: n.uppercased()).id }
                k.id["w"] = try? s.openTab(url: url("w"), inSpace: k.work, title: "W").id
                WindowController.selectionTestPasteboard = k.pasteboard
                k.w1.switchToSpace(k.home, animated: false)
                k.w1.reloadAll(animated: false)
                k.w1.show(k.id["a"] ?? "", focus: false)
                done()
            }
        }
    }

    private func msPage(_ k: MSState) -> SpacePageView? {
        let p = k.w1.pageView(for: k.home)
        p?.layoutSubtreeIfNeeded()
        return p
    }

    /// Names for IDs, in the order given (the log reads "A B C").
    private func msNames(_ k: MSState, _ ids: [String]) -> String {
        ids.map { id in k.id.first { $0.value == id }?.key.uppercased() ?? "?" }.joined(separator: " ")
    }

    private func msToday(_ k: MSState, _ space: String) -> String {
        k.w1.store.todayRows(ofSpace: space).map { $0.split != nil ? "split" : $0.liveTab?.title ?? "?" }.joined(separator: " ")
    }

    private func msPinned(_ k: MSState, parent: String? = nil, space: String? = nil) -> String {
        k.w1.store.children(of: .pinned(spaceID: space ?? k.home), parent: parent).map(\.displayTitle).joined(separator: " ")
    }

    /// A click on the row of `name` with `mods`, as the row's own mouseDown gets it. A plain click's release is queued
    /// first: the press runs the page's drag loop until it sees one.
    private func msClick(_ k: MSState, _ name: String, _ mods: NSEvent.ModifierFlags = []) {
        step { [self] done in
            guard let page = msPage(k), let id = k.id[name], let row = page.rows[id] else {
                check(false, "multiselect: a row for \(name.uppercased())"); return done()
            }
            row.scrollToVisible(row.bounds)
            let p = row.convert(NSPoint(x: min(90, row.bounds.width / 2), y: row.bounds.midY), to: nil)
            // Only onto the row itself: a press elsewhere in the sidebar would start dragging the window.
            if let hit = k.w1.window.contentView?.hitTest(p), hit !== row, !hit.isDescendant(of: row) {
                check(false, "multiselect: \(name.uppercased())'s row is under its click point (hit \(type(of: hit)))"); return done()
            }
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: k.w1.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)
            }
            // The release is queued first: a plain press runs the page's drag loop until it sees one.
            if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown) { k.w1.window.sendEvent(down) }
            // Past the double-click interval, so the next click isn't a double click.
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.1, execute: done)
        }
    }

    /// A line in multiselect-progress.txt as each case starts (the log is written only at the end).
    private func msTrace(_ what: String) { run { [self] in msTraceNow(what) } }

    private func msTraceNow(_ what: String) {
        do {
            let url = dir.appendingPathComponent("multiselect-progress.txt")
            let line = "\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime)) \(what)\n"
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    private func msKey(_ k: MSState, _ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        step { [self] done in
            postWindowKey(chars, code: code, mods: mods, to: k.w1.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
        }
    }

    private func msExpectSelection(_ k: MSState, _ want: [String], _ what: String) {
        run { [self] in
            let got = msPage(k)?.selection ?? []
            check(got == want.compactMap { k.id[$0] }, "multiselect: \(what) (selected: \(msNames(k, got)))")
        }
    }

    /// Back to the start: nothing selected, A shown, every row drawn.
    private func msReset(_ k: MSState) {
        run { [self] in
            msPage(k)?.clearSelection()
            if k.w1.currentSpaceID != k.home { k.w1.switchToSpace(k.home, animated: false) }
            k.w1.reloadAll(animated: false)
            if let a = k.id["a"], k.w1.shownTabID != a { k.w1.show(a, focus: false) }
        }
        wait(0.3)
    }

    /// ⌘-clicks the rows of `names` (A, the shown row, joins on the first pick; `withoutA` ⌘-clicks it off again).
    private func msPick(_ k: MSState, _ names: [String], withoutA: Bool = true) {
        msClick(k, names[0], .command)
        if withoutA, !names.contains("a") { msClick(k, "a", .command) }
        for n in names.dropFirst() { msClick(k, n, .command) }
        msExpectSelection(k, Self.msDisplayOrder(names + (withoutA ? [] : ["a"])), "picked " + names.map { $0.uppercased() }.joined(separator: " "))
    }

    private static func msDisplayOrder(_ names: [String]) -> [String] {
        let order = ["p1", "p2", "f", "x", "y", "a", "b", "c", "d"]
        return order.filter(names.contains)
    }

    /// The selection's context menu, from the row's own `menu(for:)` as a right-click opens it.
    private func msMenu(_ k: MSState, on name: String) -> NSMenu? {
        guard let page = msPage(k), let row = page.rows[k.id[name] ?? ""],
              let e = NSEvent.mouseEvent(with: .rightMouseDown, location: row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil),
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: k.w1.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return nil }
        return row.menu(for: e)
    }

    /// Fires the menu item titled `path[0]` (› `path[1]` in its submenu).
    private func msFire(_ k: MSState, _ path: @escaping @autoclosure () -> [String], on name: String = "b") {
        run { [self] in
            let path = path()
            var menu = msMenu(k, on: name)
            for (i, title) in path.enumerated() {
                guard let item = menu?.items.first(where: { $0.title == title }) else {
                    check(false, "multiselect: the menu has “\(title)” (\(menu?.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", ") ?? "no menu"))")
                    return
                }
                if i == path.count - 1 { (item as? ClosureMenuItem)?.fire() } else { menu = item.submenu }
            }
        }
        wait(0.4)
    }

    private func msUndo(_ k: MSState, _ what: String, _ ok: @escaping () -> Bool, detail: @escaping () -> String) {
        run { [self] in
            let before = k.w1.store.undoStack.suffix(3).map(\.label).joined(separator: ", ")
            k.w1.undo()
            let line = "multiselect: undo of \(what): stack top was [\(before)], now [\(k.w1.store.undoStack.suffix(2).map(\.label).joined(separator: ", "))]"
            note(line)
            msTraceNow(line)
        }
        wait(0.4)
        run { [self] in check(ok(), "multiselect: one ⌘Z undoes \(what) (\(detail()))") }
    }

    /// EventTests' `drag`, in window 1: presses at `start`, drags to `end`, holds, optionally on to `then`, lets go.
    private func msDrag(_ k: MSState, from start: NSPoint, to end: NSPoint, hold: Double = 0.1, then: NSPoint? = nil,
                        _ done: @escaping () -> Void) {
        let w = k.w1.window
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let leg = 0.33, t0 = CACurrentMediaTime()
        var last = start
        func toward(_ a: NSPoint, _ b: NSPoint, _ f: CGFloat) -> NSPoint { NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            let dt = CACurrentMediaTime() - t0
            var p: NSPoint?
            if dt <= leg { p = toward(start, end, CGFloat(dt / leg)) }
            else if dt <= leg + hold { p = end }
            else if let then, dt <= 2 * leg + hold { p = toward(end, then, CGFloat((dt - leg - hold) / leg)) }
            else {
                t.invalidate()
                if let then, last != then, let e = mouse(.leftMouseDragged, then) { last = then; NSApp.postEvent(e, atStart: false) }
                if let e = mouse(.leftMouseUp, last) { NSApp.postEvent(e, atStart: false) }
                return
            }
            if let p, p != last || dt > leg, let e = mouse(.leftMouseDragged, p) { last = p; NSApp.postEvent(e, atStart: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Never leave the page's drag loop waiting: a release 3 s after the planned one. A run-loop timer, because the
        // loop runs inside this step's main-queue block, so no other main-queue block can run until it ends.
        let watchdog = Timer(timeInterval: 2 * leg + hold + 3, repeats: false) { _ in
            timer.invalidate()
            if let e = mouse(.leftMouseUp, last) { NSApp.postEvent(e, atStart: false) }
        }
        RunLoop.main.add(watchdog, forMode: .common)
        if let down = mouse(.leftMouseDown, start) { w.sendEvent(down) }   // returns after the release
        watchdog.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
    }

    // MARK: 1. Selection

    private func msSelection(_ k: MSState) {
        msTrace("selection")
        msClick(k, "b", .command)
        run { [self] in
            guard let page = msPage(k), let a = k.id["a"], let b = k.id["b"] else { return }
            check(page.selection == [a, b] && k.w1.shownTabID == a,
                  "multiselect: ⌘-click on B selects it and the shown A; A stays on screen (selected \(msNames(k, page.selection)))")
            check(k.w1.window.firstResponder === page, "multiselect: the sidebar takes the keyboard (\(type(of: k.w1.window.firstResponder)))")
            let pal = page.palette
            let bPlate = page.rows[b]?.plate.backgroundColor, aPlate = page.rows[a]?.plate.backgroundColor
            check(bPlate == pal.multiSelected.cgColor && aPlate == pal.selected.cgColor,
                  "multiselect: B draws Arc's secondary selection, A keeps the shown tab's plate")
        }
        msClick(k, "d", .shift)
        msExpectSelection(k, ["a", "b", "c", "d"], "⇧-click on D extends from B through D")
        msClick(k, "p2", .shift)
        msExpectSelection(k, ["p2", "f", "a", "b"], "⇧-click on P2 ranges in the pinned top level only (from its end nearest B), replacing the last range")
        msClick(k, "x", .command)
        msClick(k, "y", .shift)
        msExpectSelection(k, ["p2", "f", "x", "y", "a", "b"], "⌘-click X then ⇧-click Y: a range inside folder F")
        msClick(k, "f", .command)
        msExpectSelection(k, ["p2", "x", "y", "a", "b"], "⌘-click on a selected row (F) takes it out")
        msKey(k, "\u{1b}", 53)
        run { [self] in
            check(msPage(k)?.selection.isEmpty == true && k.w1.window.firstResponder !== msPage(k),
                  "multiselect: Esc clears the selection and gives the keyboard back (\(type(of: k.w1.window.firstResponder)))")
        }
        // A click on the page: posted through NSApp, so the click-away monitor sees it as a person's.
        msClick(k, "c", .command)
        step { [self] done in
            let card = k.w1.card.convert(NSPoint(x: k.w1.card.bounds.midX, y: k.w1.card.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: card, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: k.w1.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
            waitUntil({ self.msPage(k)?.selection.isEmpty == true }, timeout: 1.5) {
                self.check(self.msPage(k)?.selection.isEmpty == true, "multiselect: a plain click on the page clears the selection")
                done()
            }
        }
        msClick(k, "b", .command)
        msClick(k, "c")
        run { [self] in
            check(msPage(k)?.selection.isEmpty == true && k.w1.shownTabID == k.id["c"],
                  "multiselect: a plain click on another row clears the selection and shows that row (C)")
        }
        msReset(k)
    }

    // MARK: 2. The menu and the actions

    private func msActions(_ k: MSState) {
        msTrace("The menu for A B C")
        // The menu for A B C (A shown: it joins).
        msClick(k, "b", .command)
        msClick(k, "c", .command)
        run { [self] in
            let titles = msMenu(k, on: "b")?.items.map(\.title).filter { !$0.isEmpty } ?? []
            let want = ["Copy 3 Links", "Copy 3 Links as Markdown", "Share", "Duplicate 3 Tabs", "Open in Split View", "Pin 3 Tabs", "New Folder with 3 Tabs",
                        "Add to Folder", "Move to Space", "Close 3 Tabs", "Archive 3 Tabs"]
            check(titles == want, "multiselect: the context menu for 3 Today tabs (\(titles.joined(separator: ", ")))")
            let pinnedTitles = { () -> String in
                self.msPage(k)?.setSelection([k.id["p1"], k.id["f"]].compactMap { $0 })
                let t = self.msMenu(k, on: "p1")?.items.map(\.title).filter { $0.hasPrefix("Unpin") || $0.hasPrefix("Close") } ?? []
                return t.joined(separator: ", ")
            }()
            check(pinnedTitles == "Unpin 2 Items, Close 2 Items", "multiselect: pinned rows with a folder: “\(pinnedTitles)”")
        }
        msReset(k)

        msTrace("⇧⌘C:")
        // ⇧⌘C: every link, in order, on the check's own pasteboard.
        msPick(k, ["b", "c"], withoutA: false)
        run { [self] in k.pasteboard.clearContents() }
        msKey(k, "c", 8, [.command, .shift])
        run { [self] in
            let got = k.pasteboard.string(forType: .string) ?? ""
            let want = ["a", "b", "c"].map { "http://127.0.0.1:\(k.port)/\($0).html" }.joined(separator: "\n")
            check(got == want, "multiselect: ⇧⌘C copies the 3 links in order (\(got.split(separator: "\n").count) lines)")
        }
        msReset(k)

        msTrace("Duplicate (the menu).")
        // Duplicate (the menu).
        var before = Set<String>(), made = Set<String>()
        msPick(k, ["b", "c"])
        run { [self] in before = Set(k.w1.store.state.tabs.keys) }
        msFire(k, ["Duplicate 2 Tabs"])
        run { [self] in
            made = Set(k.w1.store.state.tabs.keys).subtracting(before)
            check(msToday(k, k.home) == "A B B C C D", "multiselect: Duplicate puts a copy below each (\(msToday(k, k.home)))")
        }
        msUndo(k, "Duplicate", { self.msToday(k, k.home) == "A B C D" }, detail: {
            let left = Set(k.w1.store.state.tabs.keys).subtracting(before)
            return self.msToday(k, k.home) + "; copies made \(made.count), left \(left.count), the same ones \(left == made)"
                + ", left: " + left.compactMap { k.w1.store.tab($0) }.map { "\($0.title) opener \($0.openerID == nil ? "none" : "set") item \($0.itemID == nil ? "none" : "set")" }.joined(separator: "; ")
        })
        msReset(k)

        msTrace("⌘D:")
        // ⌘D: pin, in order, then unpin.
        msPick(k, ["b", "c"])
        msKey(k, "d", 2, .command)
        run { [self] in
            check(msPinned(k) == "P1 P2 F B C" && msToday(k, k.home) == "A D",
                  "multiselect: ⌘D pins B and C at the end of Pinned, in order (\(msPinned(k)) | \(msToday(k, k.home)))")
        }
        msUndo(k, "Pin", { self.msPinned(k) == "P1 P2 F" && self.msToday(k, k.home) == "A B C D" }, detail: { self.msPinned(k) + " | " + self.msToday(k, k.home) })
        msReset(k)

        msTrace("⌘D with the keyboard on the page:")
        // The keyboard left the sidebar (⌃Tab, ⌘1–9 and the Command Bar focus a page) with B and C still drawn as
        // selected: ⌘D pins the shown A, not them.
        msPick(k, ["b", "c"])
        run { [self] in
            k.w1.engineTab(for: k.id["a"] ?? "")?.focus()
            check(k.w1.window.firstResponder !== msPage(k), "multiselect: the page takes the keyboard back (\(type(of: k.w1.window.firstResponder)))")
        }
        msKey(k, "d", 2, .command)
        step { [self] done in
            let pinnedA = { () -> Bool in
                let pinned = self.msPinned(k).split(separator: " ")
                return pinned.contains("A") && !pinned.contains("B") && !pinned.contains("C") && self.msToday(k, k.home) == "B C D"
            }
            waitUntil(pinnedA, timeout: 2) {
                self.check(pinnedA(), "multiselect: with the keyboard on the page, ⌘D pins the shown A only (\(self.msPinned(k)) | \(self.msToday(k, k.home)))")
                done()
            }
        }
        // Back to the fixture: A unpinned to the top of Today (one tab's ⌘D isn't a bulk action's undo step).
        run { [self] in
            try? k.w1.store.togglePin(k.id["a"] ?? "", inSpace: k.home)
            check(msPinned(k) == "P1 P2 F" && msToday(k, k.home) == "A B C D",
                  "multiselect: A unpinned again (\(msPinned(k)) | \(msToday(k, k.home)))")
        }
        msReset(k)

        msTrace("⌘W:")
        // ⌘W: A (shown), B and C close; D shows; ⇧⌘T brings all three back and A shows again.
        msPick(k, ["b", "c"], withoutA: false)
        msKey(k, "w", 13, .command)
        step { [self] done in
            waitUntil({ self.msToday(k, k.home) == "D" }, timeout: 2) {
                self.check(self.msToday(k, k.home) == "D" && k.w1.shownTabID == k.id["d"] && k.w1.store.archivedEntries.count == 3,
                           "multiselect: ⌘W closes A B C (Today: \(self.msToday(k, k.home)), shows \(self.msNames(k, [k.w1.shownTabID ?? ""])), \(k.w1.store.archivedEntries.count) archived)")
                done()
            }
        }
        msKey(k, "t", 17, [.command, .shift])
        step { [self] done in
            waitUntil({ self.msToday(k, k.home) == "A B C D" }, timeout: 3) {
                self.check(self.msToday(k, k.home) == "A B C D" && k.w1.shownTabID == k.id["a"] && k.w1.store.archivedEntries.isEmpty,
                           "multiselect: one ⇧⌘T reopens all three, A on screen again (\(self.msToday(k, k.home)), shows \(self.msNames(k, [k.w1.shownTabID ?? ""])))")
                done()
            }
        }
        msReset(k)

        msTrace("Delete:")
        // Delete: archive P1 (unloaded), X's folder row stays… P1 and B go to the Archive.
        msPick(k, ["p1", "b"])
        msKey(k, "\u{7f}", 51)
        run { [self] in
            let titles = Set(k.w1.store.archivedEntries.map(\.title))
            check(msPinned(k) == "P2 F" && msToday(k, k.home) == "A C D" && titles == ["P1", "B"],
                  "multiselect: Delete archives P1 and B (Pinned: \(msPinned(k)), Today: \(msToday(k, k.home)), Archive: \(titles.sorted().joined(separator: " ")))")
        }
        msUndo(k, "Archive", { self.msPinned(k) == "P1 P2 F" && self.msToday(k, k.home) == "A B C D" && k.w1.store.archivedEntries.isEmpty },
               detail: { self.msPinned(k) + " | " + self.msToday(k, k.home) })
        msReset(k)

        msTrace("Move to Space")
        // Move to Space › Work: P2 stays pinned there, B goes to the top of its Today.
        msPick(k, ["p2", "b"])
        msFire(k, ["Move to Space", k.w1.store.space(k.work).map { $0.iconLabel.isEmpty ? $0.name : "\($0.iconLabel)  \($0.name)" } ?? "Work"])
        run { [self] in
            check(msPinned(k, space: k.work) == "P2" && msToday(k, k.work) == "B W" && msPinned(k) == "P1 F" && msToday(k, k.home) == "A C D",
                  "multiselect: Move to Space › Work (Work: \(msPinned(k, space: k.work)) | \(msToday(k, k.work)); Home: \(msPinned(k)) | \(msToday(k, k.home)))")
        }
        msUndo(k, "Move to Space", { self.msPinned(k) == "P1 P2 F" && self.msToday(k, k.home) == "A B C D" && self.msToday(k, k.work) == "W" },
               detail: { self.msPinned(k) + " | " + self.msToday(k, k.home) + " | Work " + self.msToday(k, k.work) })
        msReset(k)

        msTrace("Add to Folder")
        // Add to Folder › F.
        msPick(k, ["b", "c"])
        msFire(k, ["Add to Folder", "F"])
        run { [self] in
            check(msPinned(k, parent: k.id["f"]) == "X Y B C" && msToday(k, k.home) == "A D",
                  "multiselect: Add to Folder › F appends B and C in order (F: \(msPinned(k, parent: k.id["f"])))")
        }
        msUndo(k, "Add to Folder", { self.msPinned(k, parent: k.id["f"]) == "X Y" && self.msToday(k, k.home) == "A B C D" },
               detail: { self.msPinned(k, parent: k.id["f"]) + " | " + self.msToday(k, k.home) })
        msReset(k)

        msTrace("New Folder with")
        // New Folder with 2 Tabs (its name field opens; Esc keeps "New Folder").
        msPick(k, ["b", "c"])
        msFire(k, ["New Folder with 2 Tabs"])
        run { [self] in
            // Its name field opens (the folder's row, ready to type). Esc can't reach it in a window that's never key:
            // the field's own cancel instead.
            let field = msPage(k)?.list.subviews.lazy.flatMap(\.subviews).compactMap { $0 as? InlineEditor.Field }.first
            check(field != nil, "multiselect: New Folder with 2 Tabs opens the folder's name to type")
            field?.cancelled = true
            k.w1.window.makeFirstResponder(nil)
        }
        run { [self] in
            let f = k.w1.store.pinnedRoots(ofSpace: k.home).last
            let inside = f.map { msPinned(k, parent: $0.id) } ?? ""
            check(f?.kind == .folder && f?.id != k.id["f"] && inside == "B C" && msToday(k, k.home) == "A D",
                  "multiselect: New Folder with 2 Tabs holds B and C (Pinned: \(msPinned(k)), inside: \(inside))")
        }
        msUndo(k, "New Folder", { self.msPinned(k) == "P1 P2 F" && self.msToday(k, k.home) == "A B C D" },
               detail: { self.msPinned(k) + " | " + self.msToday(k, k.home) })
        msReset(k)

        msTrace("Open in Split View")
        // Open in Split View with B and C.
        msPick(k, ["b", "c"])
        msFire(k, ["Open in Split View"])
        step { [self] done in
            waitUntil({ k.w1.shownSplitID != nil }, timeout: 2) {
                let x = k.w1.store.split(k.w1.shownSplitID)
                self.check(x?.tabIDs == [k.id["b"], k.id["c"]].compactMap { $0 } && self.msToday(k, k.home) == "A split D",
                           "multiselect: Open in Split View shows B and C side by side (Today: \(self.msToday(k, k.home)))")
                done()
            }
        }
        msUndo(k, "Split View", { k.w1.store.splits(ofSpace: k.home).isEmpty && self.msToday(k, k.home) == "A B C D" },
               detail: { self.msToday(k, k.home) })
        msReset(k)
    }

    // MARK: 3. Dragging a selection

    private func msDrags(_ k: MSState) {
        msTrace("Onto folder F")
        // Onto folder F's row: into it, at its end, in order.
        msPick(k, ["b", "c"])
        step { [self] done in
            guard let page = msPage(k), let b = page.rows[k.id["b"] ?? ""], let f = page.rows[k.id["f"] ?? ""] else {
                check(false, "multiselect: rows for the folder drag"); return done()
            }
            let start = b.convert(NSPoint(x: 90, y: b.bounds.midY), to: nil)
            let end = f.convert(NSPoint(x: 100, y: f.bounds.midY), to: nil)
            msDrag(k, from: start, to: end, hold: 0.2) {
                self.check(self.msPinned(k, parent: k.id["f"]) == "X Y B C" && self.msToday(k, k.home) == "A D",
                           "multiselect: dragging B (of B, C) onto folder F puts both in it, in order (F: \(self.msPinned(k, parent: k.id["f"])), Today: \(self.msToday(k, k.home)))")
                self.check(page.selection.isEmpty, "multiselect: the drop ends the selection")
                done()
            }
        }
        msUndo(k, "the folder drop", { self.msPinned(k, parent: k.id["f"]) == "X Y" && self.msToday(k, k.home) == "A B C D" },
               detail: { self.msPinned(k, parent: k.id["f"]) + " | " + self.msToday(k, k.home) })
        msReset(k)

        msTrace("Across Spaces")
        // Across Spaces: held at the sidebar's edge 0.5 s, Work's page comes in; dropped below its New Tab row.
        msPick(k, ["b", "c"])
        step { [self] done in
            guard let page = msPage(k), let b = page.rows[k.id["b"] ?? ""], let newTab = page.rows["newtab"] else {
                check(false, "multiselect: rows for the Space drag"); return done()
            }
            let start = b.convert(NSPoint(x: 90, y: b.bounds.midY), to: nil)
            let sidebar = k.w1.sidebar.convert(k.w1.sidebar.bounds, to: nil)
            let edge = NSPoint(x: k.w1.sidebarOnRight ? sidebar.minX + 4 : sidebar.maxX - 4, y: start.y)
            // Work's Today starts below its New Tab row, where Home's is.
            let drop = newTab.convert(NSPoint(x: 100, y: newTab.bounds.maxY + 12), to: nil)
            msDrag(k, from: start, to: edge, hold: SpacePageView.edgeDwell + 1.2, then: drop) {
                self.waitUntil({ self.msToday(k, k.work).contains("B C") }, timeout: 1.5) {
                    self.check(self.msToday(k, k.work).contains("B C") && self.msToday(k, k.home) == "A D",
                               "multiselect: dragging B (of B, C) to the sidebar's edge pages to Work and drops both there, in order (Work: \(self.msToday(k, k.work)), Home: \(self.msToday(k, k.home)), on \(k.w1.store.space(k.w1.currentSpaceID)?.name ?? "?"))")
                    done()
                }
            }
        }
        msUndo(k, "the move across Spaces", { self.msToday(k, k.home) == "A B C D" && self.msToday(k, k.work) == "W" },
               detail: { self.msToday(k, k.home) + " | Work " + self.msToday(k, k.work) })
        msReset(k)

        msTrace("Onto a second window")
        // Onto a second window's sidebar (Work), side by side with this one.
        step { [self] done in
            guard let app, let w2 = app.openNewWindow(from: c, spaceID: k.work, tab: .spaceLast, commandBar: false) else {
                check(false, "multiselect: a second window opens"); return done()
            }
            k.w2 = w2
            let v = (k.w1.window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let width = min(760, (v.width - 30) / 2), height = v.height - 20
            k.w1.window.setFrame(NSRect(x: v.minX + 10, y: v.maxY - height, width: width, height: height), display: true)
            w2.window.setFrame(NSRect(x: v.minX + 20 + width, y: v.maxY - height, width: width, height: height), display: true)
            k.w1.root.layoutSubtreeIfNeeded()
            w2.root.layoutSubtreeIfNeeded()
            done()
        }
        wait(0.6)
        msTrace("window 2 open")
        msPick(k, ["b", "c"])
        msTrace("window drag: picked")
        step { [self] done in
            guard let w2 = k.w2, let page = msPage(k), let b = page.rows[k.id["b"] ?? ""],
                  let page2 = w2.pageView(for: k.work), let wRow = page2.rows[k.id["w"] ?? ""] else {
                check(false, "multiselect: rows for the window drag"); return done()
            }
            page2.layoutSubtreeIfNeeded()
            let start = b.convert(NSPoint(x: 90, y: b.bounds.midY), to: nil)
            // Just above W's row in window 2 (its Today, not onto W, which would split).
            let target = wRow.convert(NSPoint(x: 100, y: wRow.bounds.minY + 3), to: nil)
            let screen = w2.window.convertPoint(toScreen: target)
            msDrag(k, from: start, to: k.w1.window.convertPoint(fromScreen: screen), hold: 0.3) {
                self.waitUntil({ w2.shownTabID == k.id["b"] }, timeout: 2) {
                    self.check(self.msToday(k, k.work) == "B C W" && self.msToday(k, k.home) == "A D",
                               "multiselect: dropped on window 2's sidebar, B and C land in Work's Today there, in order (Work: \(self.msToday(k, k.work)), Home: \(self.msToday(k, k.home)))")
                    self.check(w2.shownTabID == k.id["b"], "multiselect: window 2 shows B, its page moved there (shows \(self.msNames(k, [w2.shownTabID ?? ""])))")
                    done()
                }
            }
        }
        msTrace("window drag: dropped")
        msUndo(k, "the drop on window 2", { self.msToday(k, k.home) == "A B C D" && self.msToday(k, k.work) == "W" },
               detail: { self.msToday(k, k.home) + " | Work " + self.msToday(k, k.work) })
        msTrace("window 2 closing")
        step { [self] done in
            k.w2?.window.performClose(nil)
            waitUntil({ (self.app?.controllers.count ?? 0) == 1 }, timeout: 3) { done() }
        }
        msReset(k)
    }
}
#endif
