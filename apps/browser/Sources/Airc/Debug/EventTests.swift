// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircDesign
import AircKit
import AppKit
import SwiftUI
#if canImport(AircCore)
import AircCore
#endif

/// `--script events`: real-event checks. Every step goes through the window the way a person's input does
/// (NSApp.postEvent → NSApplication.sendEvent → NSWindow.sendEvent → hit testing → the control), never through a
/// model call, so a control that looks right but doesn't respond fails here. Each check logs `PASS` or `FAIL`;
/// `scripts/build-app.sh --snapshots` fails the run on any `FAIL`.
///
/// Scripted runs never activate the app (the build Mac is someone's laptop), so the window is never key: these
/// checks also cover a first click on a background window. An app that was never active drops posted keys until its
/// window has had a mouse-down, so checks click into a field before typing, as a person would.
extension SnapshotRunner {
    func eventsScenario() {
        run { [self] in
            note("events: window key \(c.window.isKeyWindow), app active \(NSApp.isActive), on the active Space \(c.window.isOnActiveSpace), "
                 + "screen locked \(Self.screenLocked)")
        }
        waitForPage()
        // AIRC_EVENTS_ONLY=split,archive: just those checks (for working on them).
        if let only = ProcessInfo.processInfo.environment["AIRC_EVENTS_ONLY"]?.split(separator: ",").map(String.init) {
            if only.contains("split") { splitChecks() }
            if only.contains("archive") { autoArchiveLeaveCheck() }
            if only.contains("history") { historyMenuCheck() }
            if only.contains("sites") { commonSitesCheck() }
            if only.contains("defaultbrowser") { defaultBrowserCheck() }
            if only.contains("links") { linkRoutingCheck() }
            #if canImport(AircCore)
            if only.contains("miniplayer") { littleArcMiniPlayerCheck() }
            #endif
            return
        }
        trafficLights()
        // P0 (owner, 2026-11-05): clicks and keys reach the page (PageInputCheck.swift).
        pageInput()

        // P0 (owner, 2026-11-05): a name, then a real click on Create Space.
        openNewSpaceAndType("Test click")
        clickIn({ self.c.newSpacePanel?.hostingView }, "new.create")
        expectNewSpace("Test click", how: "click")

        // …and Return in the name field (the default action).
        openNewSpaceAndType("Test Return")
        key("\r", 36)
        expectNewSpace("Test Return", how: "Return")
        // The page check again where a person comes to a page from (clickbug report): a Space switch with real keys
        // (⌃1, then back), and the Command Bar opened and closed (⌘T, Esc).
        pageInput("after a Space switch") { [self] in
            var home = "", back = 0
            run { [self] in home = c.currentSpaceID; back = (c.store.orderedSpaces.firstIndex { $0.id == home } ?? -1) + 1 }
            key("1", 18, .control)
            step { [self] done in waitUntil({ self.c.currentSpaceID != home }, timeout: 3) { done() } }
            step { [self] done in
                let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
                guard (2...9).contains(back) else { check(false, "page input (after a Space switch): the page's Space is ⌃2…⌃9 (\(back))"); return done() }
                postKey("\(back)", keyCode: codes[back - 1], modifiers: .control)
                waitUntil({ self.c.currentSpaceID == home }, timeout: 3) {
                    self.check(self.c.currentSpaceID == home, "page input (after a Space switch): ⌃1, then ⌃\(back) back to the page's Space")
                    done()
                }
            }
            wait(0.6)
        }
        pageInput("after the Command Bar") { [self] in
            key("t", 17, .command)
            step { [self] done in waitUntil({ self.c.commandBar != nil }, timeout: 3) { done() } }
            key("\u{1b}", 53)
            step { [self] done in
                waitUntil({ self.c.commandBar == nil }, timeout: 3) {
                    self.check(self.c.commandBar == nil, "page input (after the Command Bar): ⌘T opens it, Esc closes it")
                    done()
                }
            }
        }

        // Esc cancels: no Space, and the card closes.
        var before = 0
        run { [self] in before = c.store.orderedSpaces.count }
        openNewSpaceAndType("Nope")
        key("\u{1b}", 53)
        step { [self] done in waitUntil({ self.c.newSpacePanel == nil }, timeout: 3) { done() } }
        run { [self] in
            check(c.store.orderedSpaces.count == before && c.newSpacePanel == nil,
                  "new space (Esc): spaces \(before) → \(c.store.orderedSpaces.count), card " + (c.newSpacePanel == nil ? "closed" : "still open"))
        }

        profileFlows()
        dragChecks()
        multiSelect()
        multiSelectDrag()
        footerReorder()
        extensionReviewCard()
        preferWebsite()
        findInPage()
        favoriteReset()
        fullScreenControls()
        unloading()
        credentialImportCheck()
        pictureInPictureSettingsCheck()
        aircDesignButtonCanary()
        #if canImport(AircCore)
        peekCheck()
        #endif
        // SV-1 Split View (SplitCheck.swift).
        splitChecks()
        // SB-43: auto-archive waits for "Leave site?" (ArchiveCheck.swift).
        autoArchiveLeaveCheck()
        // SB-1: Back and Forward's history menus (HistoryMenuCheck.swift).
        historyMenuCheck()
        #if canImport(AircCore)
        // LA-1: a Little Arc window closed while its video plays (MiniPlayerCheck.swift).
        littleArcMiniPlayerCheck()
        #endif
        // Spec §2.13 step 5 and the reminder card, on a stand-in for Launch Services (DefaultBrowserCheck.swift).
        defaultBrowserCheck()
        // CB-1: well-known sites before you have visited them, yours first (CommonSitesCheck.swift).
        commonSitesCheck()
        // Last: it adds a profile and a Space.
        linkRoutingCheck()
        run { [self] in note("events: done; spaces now " + c.store.orderedSpaces.map(\.name).joined(separator: ", ")) }
    }

    /// Visual review #1: the traffic lights stay at Arc's centres once the engine has installed its views and the
    /// page has loaded (on Chromium AppKit used to put them back at the macOS default spot).
    private func trafficLights() {
        run { [self] in
            let w = c.window
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let centers = types.compactMap { w.standardWindowButton($0) }.map { b -> CGPoint in
                let r = b.convert(b.bounds, to: nil)
                return CGPoint(x: r.midX, y: w.frame.height - r.midY)
            }
            let want = AircMetrics.Window.trafficLightCenters
            let ok = centers.count == 3 && zip(centers, want).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
            check(ok, "traffic lights at Arc's centres: " + centers.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) }.joined(separator: " "))
            // Owner P0 ("no Ampeln"): drawn and clickable, not just placed. Each button shows (no hidden ancestor, opaque),
            // a click at its centre reaches it, and no window of ours lies over it.
            let problems = types.compactMap { type -> String? in
                guard let b = w.standardWindowButton(type) else { return "\(type.rawValue): missing" }
                var chain: [NSView] = [b]
                while let s = chain.last?.superview { chain.append(s) }
                if b.isHiddenOrHasHiddenAncestor { return "\(type.rawValue): hidden" }
                if let faint = chain.first(where: { $0.alphaValue < 0.5 }) { return "\(type.rawValue): alpha \(faint.alphaValue) on \(Self.describe(faint))" }
                let centre = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
                guard let frame = w.contentView?.superview else { return "\(type.rawValue): no theme frame" }
                let hit = frame.hitTest(frame.convert(centre, from: nil))
                if hit !== b, hit?.isDescendant(of: b) != true { return "\(type.rawValue): a click hits \(Self.describe(hit))" }
                let top = NSWindow.windowNumber(at: w.convertPoint(toScreen: centre), belowWindowWithWindowNumber: 0)
                if top != w.windowNumber, Self.windowInfo(top).pid == getpid() { return "\(type.rawValue): under \(Self.windowInfo(top).text)" }
                return nil
            }
            check(problems.isEmpty && w.alphaValue >= 1 && w.isVisible,
                  "traffic lights show and take clicks (window alpha \(w.alphaValue), visible \(w.isVisible))"
                  + (problems.isEmpty ? "" : ": " + problems.joined(separator: ", ")))
            // The header's buttons share the titlebar band with them: a real press must reach each, not drag the window.
            let header = c.sidebar.header
            let dragged = [("toggle", header.toggle), ("back", header.back), ("forward", header.forward), ("reload", header.reload)]
                .filter { !$0.1.isHiddenOrHasHiddenAncestor }.compactMap { name, b -> String? in
                    let centre = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
                    let frame = w.contentView?.superview
                    let hit = frame.flatMap { $0.hitTest($0.convert(centre, from: nil)) }
                    if hit !== b { return "\(name): a click hits \(Self.describe(hit))" }
                    return Self.windowServerDrags(at: centre, hit: hit, in: w).map { "\(name): \($0)" }
                }
            check(dragged.isEmpty, "sidebar header buttons take real clicks (not a window-drag area)" + (dragged.isEmpty ? "" : ": " + dragged.joined(separator: ", ")))
        }
    }

    /// SB-35 (Arc parity): ⌥ held at the drop leaves the row and puts a copy there; a drag held at the sidebar's left
    /// edge pages into the previous Space and drops there. Real mouse events through the window's drag loop.
    private func dragChecks() {
        var tabID = ""
        var startSpace = ""
        run { [self] in
            startSpace = c.currentSpaceID
            guard let t = try? c.store.openTab(url: "about:blank", inSpace: startSpace, title: "Drag me") else { return }
            tabID = t.id
            c.reloadAll(animated: false)
        }
        wait(0.4)
        step { [self] done in
            guard let page = c.pageView(for: startSpace), let row = todayRow(tabID, in: page) else {
                check(false, "drag (⌥): the row to drag is shown"); return done()
            }
            let before = c.store.todayTabs(ofSpace: startSpace).count + c.store.pinnedRoots(ofSpace: startSpace).count
            let start = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
            // Into Today, just below the row itself.
            let end = row.convert(NSPoint(x: 110, y: row.bounds.maxY + 12), to: nil)
            drag(from: start, to: end, modifiers: .option) {
                let after = self.c.store.todayTabs(ofSpace: startSpace).count + self.c.store.pinnedRoots(ofSpace: startSpace).count
                self.check(self.c.store.tab(tabID)?.itemID == nil && after == before + 1,
                           "drag (⌥): the tab stays in Today and a copy lands where it was dropped (\(before) → \(after) rows)")
                done()
            }
        }
        wait(0.4)
        step { [self] done in
            let spaces = c.store.orderedSpaces
            guard let i = spaces.firstIndex(where: { $0.id == startSpace }), i > 0 else {
                note("drag (edge): the Space is the first; no page to its left"); return done()
            }
            let previous = spaces[i - 1].id
            guard let page = c.pageView(for: startSpace), let row = todayRow(tabID, in: page) else {
                check(false, "drag (edge): the row to drag is shown"); return done()
            }
            let start = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
            // The sidebar's edge as it shows in the window, and low in the list there (the previous Space's Today).
            let visible = c.sidebar.frame.intersection(c.root.bounds)
            let edge = NSPoint(x: c.root.convert(NSPoint(x: visible.minX + 4, y: 0), to: nil).x, y: start.y)
            let pager = c.sidebar.pager
            let land = NSPoint(x: edge.x + 100, y: pager.convert(NSPoint(x: 0, y: pager.bounds.maxY - 60), to: nil).y)
            drag(from: start, to: edge, hold: SpacePageView.edgeDwell + 0.25, then: land) {
                let name = { (id: String?) in id.flatMap { self.c.store.space($0)?.name } ?? "-" }
                self.check(self.c.currentSpaceID == previous && self.c.store.tab(tabID)?.spaceID == previous,
                           "drag (edge): held at the left edge it pages from \(name(startSpace)) to \(name(previous)) and drops there"
                           + " (now on \(name(self.c.currentSpaceID)), tab in \(name(self.c.store.tab(tabID)?.spaceID)))")
                done()
            }
        }
        wait(0.6)
    }

    /// SB-36: ⌘-click picks rows without changing the page shown; the selection's "New Folder with N Items" puts them
    /// in one folder. (Copy Links isn't run here: it would write to the owner's clipboard.)
    private func multiSelect() {
        var picked: [String] = []
        var sid = ""
        run { [self] in
            sid = c.currentSpaceID
            picked = ["Pick A", "Pick B"].compactMap { try? c.store.openTab(url: "about:blank", inSpace: sid, title: $0).id }
            c.reloadAll(animated: false)
        }
        wait(0.4)
        step { [self] done in
            guard let page = c.pageView(for: sid) else { note("multi-select: no page for \(sid)"); return done() }
            let shownBefore = c.shownTabID
            // One ⌘-click at a time, each on the row as it is then.
            func pick(_ k: Int) {
                guard k < picked.count else { return finish() }
                guard let row = todayRow(picked[k], in: page) else { note("multi-select: no row for pick \(k)"); return pick(k + 1) }
                let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
                for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                        c.window.sendEvent(e)
                    }
                }
                // Past the double-click interval, so the next ⌘-click isn't taken as a double click.
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15) { pick(k + 1) }
            }
            func finish() {
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let sel = page.selection
                self.check(picked.allSatisfy(sel.contains) && self.c.shownTabID == shownBefore,
                           "multi-select: ⌘-click picks rows (\(sel.count) selected) and the page shown stays")
                let menu = self.c.selectionMenu(ids: picked, spaceID: sid)
                guard let item = menu.items.first(where: { $0.title.hasPrefix("New Folder with") }) as? ClosureMenuItem else { return done() }
                item.fire()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let parents = Set(picked.compactMap { self.c.store.tab($0)?.itemID }.compactMap { self.c.store.item($0)?.parentID })
                    self.check(parents.count == 1 && self.c.store.item(parents.first!)?.kind == .folder,
                               "multi-select: New Folder with 2 Items puts both in one folder")
                    done()
                }
            }
            }
            pick(0)
        }
        key("\u{1b}", 53)
        wait(0.3)
    }

    /// The extension install review card (synthetic extension, nothing is installed): a real click on Cancel answers
    /// no and closes it; Return answers Add Extension.
    private func extensionReviewCard() {
        var answers: [Bool] = []
        let permissions = ["Read and change all your data on all websites", "Display notifications"]
        run { [self] in
            c.presentExtensionReview(name: "Example Blocker", icon: nil, permissions: permissions) { answers.append($0) }
        }
        wait(0.5)
        step { [self] done in
            guard let review = c.pendingExtensionReview else { check(false, "extension review: the card opens"); return done() }
            check(review.model.title == "Add “Example Blocker”?" && review.model.permissions.count == 2,
                  "extension review: the card opens with the name, the profile (\(review.model.profileName)) and 2 permissions")
            captureWindow(c.window, name: "30-extension-review", rounded: 10) { done() }
        }
        clickIn({ [weak self] in self?.c.pendingExtensionReview?.hostingView }, "extension.cancel")
        step { [self] done in waitUntil({ !answers.isEmpty }, timeout: 3) { done() } }
        run { [self] in
            check(answers == [false] && c.pendingExtensionReview == nil, "extension review: a click on Cancel answers no and closes it")
            // The Add button's anchor is recorded when SwiftUI first lays the new card out, which is also when its ↩
            // shortcut exists: a Return before that (a busy Mac) reaches nothing.
            TestAnchors.frames["extension.add"] = nil
            c.presentExtensionReview(name: "Example Blocker", icon: nil, permissions: []) { answers.append($0) }
        }
        step { [self] done in
            waitUntil({
                guard let host = self.c.pendingExtensionReview?.hostingView, TestAnchors.frames["extension.add"] != nil,
                      let r = self.c.window.firstResponder as? NSView else { return false }
                return r === host || r.isDescendant(of: host)
            }, timeout: 3) { done() }
        }
        key("\r", 36)
        step { [self] done in waitUntil({ answers.count >= 2 }, timeout: 3) { done() } }
        // In a window that was never key (scripted runs), SwiftUI's default-button shortcut sometimes misses the first
        // Return; a person would press it again.
        var again = false
        step { [self] done in
            guard answers.count < 2, c.pendingExtensionReview != nil else { return done() }
            again = true
            postKey("\r", keyCode: 36)
            waitUntil({ answers.count >= 2 }, timeout: 3) { done() }
        }
        run { [self] in
            check(answers == [false, true] && c.pendingExtensionReview == nil,
                  "extension review: Return answers Add Extension (answers \(answers)\(again ? ", on the second Return" : ""))")
            // Never leave the card open for the checks after this one (Esc in full screen ignores open cards).
            c.closeExtensionReview(answer: false)
        }
    }

    /// Arc: dragging a Space's icon along the footer reorders the Spaces; the sidebar stays on the dragged Space.
    private func footerReorder() {
        step { [self] done in
            let before = c.store.orderedSpaces.map(\.id)
            let cells = Array(c.sidebar.footer.cellViews.prefix(3))
            guard before.count >= 3, cells.count == 3 else {
                note("footer reorder: needs 3 Spaces"); return done()
            }
            if let why = realEventsBlocked { skip("footer reorder: \(why)"); return done() }
            let start = cells[0].convert(NSPoint(x: cells[0].bounds.midX, y: cells[0].bounds.midY), to: nil)
            // Past the third icon's centre: the first Space becomes the third.
            let end = cells[2].convert(NSPoint(x: cells[2].bounds.midX + 4, y: cells[2].bounds.midY), to: nil)
            drag(from: start, to: end) {
                let after = self.c.store.orderedSpaces.map(\.id)
                let names = { (ids: [String]) in ids.prefix(3).compactMap { self.c.store.space($0)?.name }.joined(separator: ", ") }
                self.check(after.count == before.count && after[2] == before[0] && after[0] == before[1] && self.c.currentSpaceID == before[0]
                           && abs(self.c.sidebar.pager.position - 2) < 0.01,
                           "footer reorder: dragging the first icon past the third moves its Space there (\(names(before)) → \(names(after))), shown on page \(self.c.sidebar.pager.position)")
                // Back where it was, for the checks after this one.
                self.c.reorderSpace(before[0], to: 0)
                done()
            }
        }
        wait(0.4)
    }

    /// SB-36: dragging a row of a multi-selection moves every selected row (here into the pinned section, in order),
    /// and one ⌘Z puts them all back.
    private func multiSelectDrag() {
        var picked: [String] = []
        var other = ""
        var sid = ""
        run { [self] in
            sid = c.currentSpaceID
            let made = ["Drag A", "Stay", "Drag B"].compactMap { try? c.store.openTab(url: "about:blank", inSpace: sid, title: $0).id }
            picked = [made[0], made[2]]
            other = made[1]
            c.reloadAll(animated: false)
            // With no selection, a ⌘-click also selects the shown tab's row (Arc): show none, so only the picks count.
            c.showEmpty()
        }
        wait(0.4)
        step { [self] done in
            guard let page = c.pageView(for: sid) else { check(false, "multi-drag: the page shows"); return done() }
            func pick(_ k: Int) {
                guard k < picked.count else { return drag() }
                guard let row = todayRow(picked[k], in: page) else { check(false, "multi-drag: row \(k) shows"); return done() }
                let p = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
                for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                    if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure) {
                        c.window.sendEvent(e)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.15) { pick(k + 1) }
            }
            func drag() {
                let pinnedBefore = c.store.pinnedRoots(ofSpace: sid).count
                guard page.selection.count >= 2, let row = todayRow(picked[1], in: page),
                      let divider = page.list.subviews.first(where: { $0 is DividerRowView }) else {
                    check(false, "multi-drag: two rows picked (\(page.selection.count))"); return done()
                }
                let start = row.convert(NSPoint(x: 90, y: row.bounds.midY), to: nil)
                // Just above the divider: the end of the pinned section.
                let end = divider.convert(NSPoint(x: 110, y: -4), to: nil)
                let order = page.selection   // display order (Today lists the newest first)
                self.drag(from: start, to: end) {
                    let s = self.c.store
                    let pinned = s.pinnedRoots(ofSpace: sid)
                    let ids = order.compactMap { s.tab($0)?.itemID }
                    let inOrder = ids.count == 2 && pinned.suffix(2).map(\.id) == ids
                    self.check(inOrder && pinned.count == pinnedBefore + 2 && s.tab(other)?.itemID == nil,
                               "multi-drag: dragging one of 2 selected rows pins both, in order (\(pinnedBefore) → \(pinned.count) pinned)")
                    done()
                }
            }
            pick(0)
        }
        key("z", 6, .command)
        wait(0.3)
        run { [self] in
            let back = picked.allSatisfy { c.store.tab($0)?.itemID == nil && c.store.tab($0)?.spaceID == sid }
            check(back, "multi-drag: one ⌘Z puts both back in Today")
        }
    }

    func todayRow(_ tabID: String, in page: SpacePageView) -> TabRowView? {
        page.layoutSubtreeIfNeeded()
        return page.list.subviews.compactMap { $0 as? TabRowView }.first { $0.tabID == tabID }
    }

    /// Presses at `start`, drags to `end` over 20 frames, holds `hold` seconds, optionally drags on to `then`, and
    /// lets go (with `modifiers` held throughout). The press runs the page's drag loop until the release.
    func drag(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = [], hold: Double = 0.1,
                      then: NSPoint? = nil, _ done: @escaping () -> Void) {
        let w = c.window
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        // Phases by the clock (the timer fires less often inside the drag loop than 60 Hz).
        let leg = 0.33
        let t0 = CACurrentMediaTime()
        var last = start
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            let dt = CACurrentMediaTime() - t0
            if dt <= leg {
                let f = CGFloat(dt / leg)
                last = NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
                if let e = mouse(.leftMouseDragged, last) { NSApp.postEvent(e, atStart: false) }
            } else if dt <= leg + hold {
                if last != end, let e = mouse(.leftMouseDragged, end) { last = end; NSApp.postEvent(e, atStart: false) }
            } else if let then, dt <= 2 * leg + hold {
                let f = CGFloat((dt - leg - hold) / leg)
                last = NSPoint(x: end.x + (then.x - end.x) * f, y: end.y + (then.y - end.y) * f)
                if let e = mouse(.leftMouseDragged, last) { NSApp.postEvent(e, atStart: false) }
            } else {
                t.invalidate()
                if let then, last != then, let e = mouse(.leftMouseDragged, then) { last = then; NSApp.postEvent(e, atStart: false) }
                if let e = mouse(.leftMouseUp, last) { NSApp.postEvent(e, atStart: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        if let down = mouse(.leftMouseDown, start) { w.sendEvent(down) }   // returns after the release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
    }

    /// ⌘F on both engines: typing into the find field finds every match on the page, ↩ moves on, Esc closes.
    private func findInPage() {
        run { [self] in
            let html = "<title>find</title><body><p>apple banana apple</p><p>cherry apple</p></body>"
            guard let t = try? c.store.openTab(url: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""),
                                               inSpace: c.currentSpaceID, title: "Find test") else { return }
            c.reloadAll(animated: false)
            c.show(t.id, focus: true)
        }
        waitForPage()
        key("f", 3, .command)
        step { [self] done in
            guard let bar = c.findBar else { check(false, "find: ⌘F opens the find bar"); return done() }
            let p = bar.field.convert(NSPoint(x: bar.field.bounds.midX, y: bar.field.bounds.midY), to: nil)
            click(at: p, in: c.window, done)
        }
        step { [self] done in
            typeText("apple")
            waitUntil({ self.c.findBar?.statusText.contains("3") == true }, timeout: 3) {
                self.check(self.c.findBar?.statusText.contains("3") == true,
                           "find: typing \"apple\" finds 3 matches (\(self.c.findBar?.statusText ?? "no bar"))")
                done()
            }
        }
        key("\r", 36)
        wait(0.3)
        run { [self] in note("find: after ↩ \(c.findBar?.statusText ?? "no bar")") }
        key("\u{1b}", 53)
        wait(0.2)
        run { [self] in check(c.findBar == nil, "find: Esc closes the find bar") }
    }

    /// CB-3: a page that uses ⌘D keeps it; a second ⌘D within a second runs the browser's (pin). ⌘L, which the page
    /// doesn't use, opens the Command Bar at once.
    private func preferWebsite() {
        var tabID = ""
        run { [self] in
            guard c.app?.engine.reportsPageShortcuts == true else { return note("prefer website: this engine doesn't report page shortcuts") }
            let html = "<title>page</title><body style='height:2000px'><p>Shortcut test</p><script>document.addEventListener('keydown',function(e){if(e.metaKey&&e.key==='d'){e.preventDefault();document.title='used'}})</script>"
            guard let t = try? c.store.openTab(url: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""),
                                               inSpace: c.currentSpaceID, title: "Shortcut test") else { return }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: true)
        }
        waitForPage()
        step { [self] done in
            guard !tabID.isEmpty else { return done() }
            let p = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
            click(at: p, in: c.window) { self.waitUntil({ self.c.focusedPage != nil }, timeout: 3) { done() } }
        }
        run { [self] in note("prefer website: page focused \(c.focusedPage != nil)") }
        key("d", 2, .command)
        // The page's answer decides; wait for it (a busy renderer takes a while), not for a fixed time.
        step { [self] done in
            waitUntil({ !KeyMonitor.isWaitingForPage && self.c.engineTab(for: tabID)?.title == "used" }, timeout: 3) { done() }
        }
        run { [self] in
            guard !tabID.isEmpty else { return }
            check(c.store.tab(tabID)?.itemID == nil && c.engineTab(for: tabID)?.title == "used",
                  "prefer website: the first ⌘D goes to the page (title \(c.engineTab(for: tabID)?.title ?? "-"), pinned \(c.store.tab(tabID)?.itemID != nil))")
        }
        key("d", 2, .command)
        step { [self] done in waitUntil({ self.c.store.tab(tabID)?.itemID != nil }, timeout: 2) { done() } }
        run { [self] in
            guard !tabID.isEmpty else { return }
            check(c.store.tab(tabID)?.itemID != nil, "prefer website: ⌘D again within a second pins the tab")
        }
        wait(1.1)
        key("l", 37, .command)
        step { [self] done in waitUntil({ self.c.commandBar != nil }, timeout: 2) { done() } }
        run { [self] in
            guard !tabID.isEmpty else { return }
            check(c.commandBar != nil, "prefer website: ⌘L, which the page doesn't use, opens the Command Bar")
            c.closeCommandBar()
        }
    }

    /// SB-12: a click on the Favorite you're on, after it wandered to another page, takes it back to its saved URL.
    private func favoriteReset() {
        func page(_ title: String) -> String {
            "data:text/html," + ("<title>\(title)</title><p>\(title)</p>".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        let home = page("Saved"), away = page("Elsewhere")
        var tabID = "", itemID = ""
        run { [self] in
            let pid = c.store.profile(ofSpace: c.currentSpaceID).id
            guard let t = try? c.store.openTab(url: home, inSpace: c.currentSpaceID, title: "Saved") else { return }
            try? c.store.move(.tab(t.id), to: .favorites(profileID: pid, index: 0))
            tabID = t.id
            itemID = c.store.tab(t.id)?.itemID ?? ""
            if !itemID.isEmpty { try? c.store.replaceSavedURL(ofItem: itemID, with: home, title: "Saved") }
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
        }
        waitForPage()
        run { [self] in c.engineTab(for: tabID)?.load(URL(string: away)!) }
        waitForPage()
        step { [self] done in
            c.pageView(for: c.currentSpaceID)?.layoutSubtreeIfNeeded()
            guard let tile = c.pageView(for: c.currentSpaceID)?.favorites.subviews.compactMap({ $0 as? FavoriteTileView })
                .first(where: { $0.item?.id == itemID }) else { check(false, "favorite reset: no tile"); return done() }
            let p = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
            // Through the window as the drag check does (a posted mouse-down doesn't reach AppKit sidebar rows in a
            // window that was never key): the row's mouse-down runs its own tracking loop until mouse-up.
            let w = c.window
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let up = mouse(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
            if let down = mouse(.leftMouseDown) { w.sendEvent(down) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
        }
        waitForPage()
        run { [self] in
            let url = c.engineTab(for: tabID)?.url?.absoluteString ?? "-"
            check(url == home, "favorite reset (SB-12): a click on the Favorite you're on takes it back to its saved URL (\(url == home ? "saved" : url.prefix(40) + "…"))")
        }
    }

    /// Native full screen (owner P0, 2026-11-05). Entering and leaving are the window delegate's calls, simulated:
    /// a real full screen would take over the build Mac's display, which someone may be using, and the titlebar only
    /// comes down when a real pointer reaches the top edge. The keys and the menu are real. FullScreenController.exit
    /// never toggles a window that isn't in full screen, so here it only counts.
    private func fullScreenControls() {
        var tabID = "", exits = 0
        let buttons = { [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { self.c.window.standardWindowButton($0) } }
        let toggleX = { self.c.sidebar.header.toggle.frame.minX }
        let viewMenu = { NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu }
        let pageTitle = { self.c.engineTab(for: tabID)?.title ?? "-" }
        /// Esc's key-down alone (a hold), or a key repeat of it.
        func escapeDown(isRepeat: Bool) {
            let w = c.window
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: isRepeat, keyCode: 53) { NSApp.postEvent(e, atStart: false) }
        }
        func escapeUp() {
            let w = c.window
            if let e = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53) { NSApp.postEvent(e, atStart: false) }
        }
        run { [self] in
            let html = "<title>esc 0</title><p>Esc test</p><script>var n=0;document.addEventListener('keydown',function(e){if(e.key==='Escape'){n++;document.title='esc '+n}})</script>"
            guard let t = try? c.store.openTab(url: "data:text/html," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""),
                                               inSpace: c.currentSpaceID, title: "Esc test") else { return }
            tabID = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: true)
        }
        waitForPage()
        step { [self] done in
            let p = c.card.convert(NSPoint(x: c.card.bounds.midX, y: c.card.bounds.midY), to: nil)
            click(at: p, in: c.window, done)
        }
        run { [self] in
            let n = Notification(name: NSWindow.willEnterFullScreenNotification, object: c.window)
            c.windowWillEnterFullScreen(n)
            c.windowDidEnterFullScreen(n)
            exits = c.fullScreen.exitRequests
            c.sidebar.header.layoutSubtreeIfNeeded()
            check(buttons().count == 3 && buttons().allSatisfy { !$0.isHidden },
                  "full screen: the traffic lights stay unhidden, for the titlebar that comes down with the menu bar")
            check(c.toast.shownText == FullScreenController.toastText, "full screen: entering shows \"\(c.toast.shownText ?? "no toast")\"")
            check(toggleX() == DesignGaps.toggleXFullscreen, "full screen: the sidebar toggle moves to the very left (x \(toggleX()))")
            // The titlebar's private revealAmount (FullScreenRevealAccessory) only comes in a real full screen: called here.
            c.fullScreen.revealChanged(1)
            c.sidebar.header.layoutSubtreeIfNeeded()
            let revealedX = toggleX()
            c.fullScreen.revealChanged(0)
            c.sidebar.header.layoutSubtreeIfNeeded()
            check(revealedX == AircMetrics.Sidebar.toggleX && toggleX() == DesignGaps.toggleXFullscreen,
                  "full screen: while the titlebar is down the toggle steps right of the traffic lights (x \(revealedX)), then back (x \(toggleX()))")
            // One item shows, for the window to answer (AppKit adds its own 🌐F copy and hides ours); ⌃⌘F still works.
            let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.filter { $0.action == FullScreenMenu.action }
            let shown = items.filter { !$0.isHidden }
            let ours = items.first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command, .control] }
            if let menu = viewMenu() { FullScreenMenu.shared.menuNeedsUpdate(menu) }
            check(shown.count == 1 && shown[0].menu === viewMenu() && shown[0].target == nil && c.window.validateMenuItem(shown[0])
                  && ours != nil && (ours!.isHidden == false || ours!.allowsKeyEquivalentWhenHidden),
                  "full screen: View shows one \"\(shown.first?.title ?? "-")\" for the window to toggle (\(items.count) items, ⌃⌘F "
                  + (ours == nil ? "missing" : "kept") + ")")
            // For the screenshot: the toast, with the header as it is while the titlebar is down (the window's own
            // traffic lights stand in for the titlebar's).
            c.fullScreen.revealChanged(1)
        }
        step { [self] done in captureWindow(c.window, name: "31-full-screen-toast", rounded: 10) { done() } }
        run { [self] in c.fullScreen.revealChanged(0) }
        // One Esc goes to the page (its title changes once the page has handled it; a busy Mac takes a while).
        key("\u{1b}", 53)
        wait(0.8)
        step { [self] done in
            waitUntil({ pageTitle() == "esc 1" }, timeout: 3) {
                self.check(self.c.fullScreen.exitRequests == exits, "full screen: one Esc doesn't leave full screen")
                self.check(pageTitle() == "esc 1", "full screen: one Esc goes to the page (page title \"\(pageTitle())\")")
                done()
            }
        }
        // Two within 0.5 s leave; the second stays here.
        key("\u{1b}", 53)
        key("\u{1b}", 53)
        step { [self] done in
            waitUntil({ pageTitle() == "esc 2" && self.c.fullScreen.exitRequests > exits }, timeout: 3) {
                self.check(self.c.fullScreen.exitRequests == exits + 1 && pageTitle() == "esc 2",
                           "full screen: Esc pressed twice leaves full screen (\(self.c.fullScreen.exitRequests - exits) exit, page title \"\(pageTitle())\")")
                done()
            }
        }
        wait(0.6)
        // Held for 0.6 s: leaves; the key repeats don't reach the page.
        run { escapeDown(isRepeat: false) }
        wait(0.3)
        run { escapeDown(isRepeat: true) }
        wait(0.1)
        run { escapeDown(isRepeat: true) }
        wait(0.4)
        run { escapeUp() }
        step { [self] done in waitUntil({ pageTitle() == "esc 3" }, timeout: 3) { done() } }
        wait(0.3)
        run { [self] in
            check(c.fullScreen.exitRequests == exits + 2 && pageTitle() == "esc 3",
                  "full screen: Esc held leaves full screen (\(c.fullScreen.exitRequests - exits) exits, page title \"\(pageTitle())\")")
            c.openCommandBar(mode: .newTab)
        }
        // Esc that closes the Command Bar is the bar's: a second one right after doesn't leave full screen.
        wait(0.4)
        key("\u{1b}", 53)
        key("\u{1b}", 53)
        wait(0.8)
        run { [self] in
            check(c.commandBar == nil && c.fullScreen.exitRequests == exits + 2,
                  "full screen: Esc that closes the Command Bar doesn't count (bar " + (c.commandBar == nil ? "closed" : "open")
                  + ", \(c.fullScreen.exitRequests - exits) exits)")
            // (View → Exit Full Screen goes to the window itself, which isn't really in full screen here: not sent.)
            let n = Notification(name: NSWindow.willExitFullScreenNotification, object: c.window)
            c.windowWillExitFullScreen(n)
            c.windowDidExitFullScreen(n)
        }
        wait(0.3)
        run { [self] in
            let w = c.window
            let centers = buttons().map { b -> CGPoint in
                let r = b.convert(b.bounds, to: nil)
                return CGPoint(x: r.midX, y: w.frame.height - r.midY)
            }
            let atArc = centers.count == 3 && zip(centers, AircMetrics.Window.trafficLightCenters).allSatisfy { abs($0.x - $1.x) <= 0.5 && abs($0.y - $1.y) <= 0.5 }
            c.sidebar.header.layoutSubtreeIfNeeded()
            if let menu = viewMenu() { FullScreenMenu.shared.menuNeedsUpdate(menu) }
            let title = viewMenu()?.items.first { $0.action == FullScreenMenu.action }?.title ?? "-"
            check(atArc && buttons().allSatisfy { !$0.isHidden } && toggleX() == AircMetrics.Sidebar.toggleX && title == "Enter Full Screen",
                  "full screen: back out, the traffic lights are at Arc's centres, the toggle beside them, the menu says \"\(title)\"")
            c.closeTab(tabID)
        }
        wait(0.3)
    }

    /// MEM-3 with a 1 s timeout: a hidden tab is freed; one with typed-in input and the visible one stay; the freed
    /// one comes back when shown.
    private func unloading() {
        var plain = "", typed = "", shown = ""
        run { [self] in
            WindowController.unloadOverride = 1
            c.applyUnloadSetting()
            let space = c.currentSpaceID
            func page(_ body: String) -> String { "data:text/html," + (body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") }
            plain = (try? c.store.openTab(url: page("<title>Plain</title><p>plain</p>"), inSpace: space, title: "Plain"))?.id ?? ""
            typed = (try? c.store.openTab(url: page("<title>Form</title><input id=f value=''>"), inSpace: space, title: "Form"))?.id ?? ""
            shown = (try? c.store.openTab(url: page("<title>Shown</title><p>shown</p>"), inSpace: space, title: "Shown"))?.id ?? ""
            c.reloadAll(animated: false)
            c.show(plain, focus: false)
        }
        wait(0.8)
        run { [self] in c.show(typed, focus: false) }
        wait(0.8)
        run { [self] in
            c.engineTab(for: typed)?.evaluate("document.getElementById('f').value = 'typed by hand'; true", completion: nil)
            c.show(shown, focus: false)
        }
        wait(3.5)
        run { [self] in
            let freed = isUnloaded(plain), kept = !isUnloaded(typed), visible = !isUnloaded(shown)
            let what = "unload (MEM-3): hidden tab freed \(freed), tab with typed input kept \(kept), visible tab kept \(visible)"
            if c.appUnloads {
                check(freed && kept && visible, what)
            } else {
                // Chromium unloads by itself (AircProfile.unloadTimeout): an engine result, reported, not an app failure.
                note((freed && kept && visible ? "ENGINE-PASS " : "ENGINE-FAIL ") + what)
            }
            c.show(plain, focus: false)
        }
        wait(0.6)
        run { [self] in
            check(!isUnloaded(plain) && c.shownTabID == plain, "unload (MEM-3): the freed tab loads again when shown")
            WindowController.unloadOverride = nil
            c.applyUnloadSetting()
        }
    }

    /// No page, or (Chromium) a discarded one.
    private func isUnloaded(_ tabID: String) -> Bool {
        guard let page = c.engineTab(for: tabID) else { return true }
        #if canImport(AircCore)
        if let chromium = c.app?.engine as? ChromiumEngine { return chromium.isDiscarded(page) }
        #endif
        _ = page
        return false
    }

    /// SP-10, SP-11, SP-13: the theme row, the Profile pill's menu, the one-step and two-step Create Profile cards.
    private func profileFlows() {
        let card = { self.c.newSpacePanel?.hostingView }
        let profileCard = { self.c.createProfilePanel?.hostingView }
        openNewSpaceAndType("Freelance work")
        // Choose a Theme → the picker beside the card.
        clickIn(card, "new.theme")
        step { [self] done in waitUntil({ self.c.themePopover?.isShown == true }, timeout: 3) { done() } }
        run { [self] in
            check(c.themePopover?.isShown == true, "new space: a click on Choose a Theme opens the theme picker")
            c.themePopover?.close()
        }
        wait(0.2)
        // The Profile pill → the native menu (avatar rows, ✓, New Profile…); New Profile… → the one-step card.
        step { [self] done in
            var titles: [String] = []
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                guard let menu = n.object as? NSMenu, titles.isEmpty else { return }
                titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.state == .on ? " ✓" : "") }
                let t = Timer(timeInterval: 0.15, repeats: false) { _ in
                    menu.cancelTracking()
                    if let i = menu.items.firstIndex(where: { $0.title == "New Profile…" }) {
                        DispatchQueue.main.async { menu.performActionForItem(at: i) }
                    }
                }
                RunLoop.main.add(t, forMode: .common)
            }
            guard let host = card() else { check(false, "new space: no card"); return done() }
            clickAnchor("new.profile", in: host) {
                self.waitUntil({ self.c.createProfilePanel != nil }, timeout: 3) {
                    token.map(NotificationCenter.default.removeObserver)
                    self.check(titles.last == "New Profile…" && titles.contains(where: { $0.hasSuffix(" ✓") }),
                               "new space: a click on the Profile pill opens its menu: " + titles.joined(separator: " | "))
                    self.check(self.c.createProfilePanel?.model.oneStep == true, "new space: New Profile… opens the one-step Create Profile card")
                    done()
                }
            }
        }
        clickIn(profileCard, "profile.name")
        run { [self] in typeText("Freelance") }
        step { [self] done in
            waitUntil({ self.c.createProfilePanel?.model.name == "Freelance" }) { done() }
        }
        clickIn(profileCard, "profile.primary")
        step { [self] done in
            waitUntil({ self.c.createProfilePanel == nil && self.c.newSpacePanel?.model.profile?.name == "Freelance" }, timeout: 3) { done() }
        }
        run { [self] in
            let p = c.newSpacePanel?.model.profile
            check(p?.name == "Freelance" && c.createProfilePanel == nil,
                  "create profile (one step): a click on Create Profile makes it and the pill shows \(p?.name ?? "-")")
        }
        run { [self] in
            // Diagnostics for the click below (it once didn't create): what's under it, and whether it can create.
            if let h = card(), let p = anchorPoint("new.create", in: h) {
                let hit = c.window.contentView?.superview?.hitTest(p)
                note("new space: before Create, card open \(c.newSpacePanel != nil), canCreate \(c.newSpacePanel?.model.canCreate ?? false), "
                     + "name “\(c.newSpacePanel?.model.name ?? "-")”, under the click \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), "
                     + "profile panel \(c.createProfilePanel != nil), root subviews \(c.root.subviews.map { String(describing: type(of: $0)) })")
            }
        }
        clickIn(card, "new.create")
        step { [self] done in
            waitUntil({ self.c.store.orderedSpaces.contains { $0.name == "Freelance work" } && self.c.newSpacePanel == nil }, timeout: 3) { done() }
        }
        run { [self] in
            let s = c.store.orderedSpaces.first { $0.name == "Freelance work" }
            check(s.map { c.store.profile(ofSpace: $0.id).name } == "Freelance",
                  "new space: created in the new profile (\(s.map { c.store.profile(ofSpace: $0.id).name } ?? "no Space"))")
        }
        // Space menu → Set Profile › New Profile…: both steps, real clicks on Next and on a Space tile.
        var target = ""
        run { [self] in
            target = c.store.orderedSpaces.first { $0.name == "Test click" }?.id ?? ""
            c.openCreateProfile(forSpace: nil)
        }
        wait(0.3)
        clickIn(profileCard, "profile.name")
        run { [self] in typeText("Studio two") }
        step { [self] done in waitUntil({ self.c.createProfilePanel?.model.name == "Studio two" }) { done() } }
        clickIn(profileCard, "profile.primary")
        step { [self] done in waitUntil({ self.c.createProfilePanel?.model.step == .spaces }, timeout: 3) { done() } }
        run { [self] in check(c.createProfilePanel?.model.step == .spaces, "create profile: a click on Next shows “Choose the Spaces for this Profile”") }
        clickIn(profileCard, "profile.space.Test click")
        step { [self] done in waitUntil({ self.c.createProfilePanel?.model.chosen.contains(target) == true }, timeout: 3) { done() } }
        run { [self] in check(c.createProfilePanel?.model.chosen.contains(target) == true, "create profile: a click on a Space tile ticks it") }
        // Step two's card resizes and its button turns into "Create Profile" (wider): let the layout settle first, as a
        // person's next click would.
        wait(0.5)
        clickIn(profileCard, "profile.primary")
        step { [self] done in
            waitUntil({ self.c.createProfilePanel == nil && self.c.store.space(target).map { self.c.store.profile(ofSpace: $0.id).name } == "Studio two" },
                      timeout: 3) { done() }
        }
        run { [self] in
            let name = c.store.space(target).map { c.store.profile(ofSpace: $0.id).name } ?? "-"
            let state = c.createProfilePanel.map { "card still open, can continue \($0.model.canContinue), step \($0.model.step), anchor \(TestAnchors.frames["profile.primary"] ?? .zero), "
                + "click \(TestAnchors.lastHit["profile.primary"] ?? "-"), card \(NSStringFromRect($0.hostingView.convert($0.hostingView.bounds, to: nil)))" } ?? "card closed"
            let ok = name == "Studio two" && c.createProfilePanel == nil
            let what = "create profile (two steps): the ticked Space now uses \(name) (\(state), on the active Space \(c.window.isOnActiveSpace))"
            // A window that isn't drawn (screen locked, or on no visible part of the screen) gets no display cycle, so
            // SwiftUI never lays out step two and its button stays below the step-one card (runs 2, 4, 5 on 2026-11-05).
            let drawn = !Self.screenLocked && c.window.occlusionState.contains(.visible)
            let clickMissed = TestAnchors.lastHit["profile.primary"]?.hasSuffix("outside the card") == true
            if !ok, !drawn, clickMissed { skip(what + ": the window isn't drawn") } else { check(ok, what) }
        }
    }

    func check(_ ok: Bool, _ what: String) {
        // Daytime ship runs (infra/nightly.sh --ship): a failure while our window can't take real input (covered by
        // the owner's windows, on another Space, or the screen locked) is FAIL-ENV, which the publish gate doesn't count.
        if !ok, ProcessInfo.processInfo.environment["AIRC_SHIP_GATE"] == "1", let why = inputBlocked {
            return note("FAIL-ENV " + what + " (\(why))")
        }
        note((ok ? "PASS " : "FAIL ") + what)
    }
    /// Why our window can't take real input right now, if it can't. Test runs are always launched in the background
    /// (`open -g`), so app activation says nothing; whether the window is on screen does.
    var inputBlocked: String? {
        if Self.screenLocked { return "the screen is locked" }
        guard let w = app?.controller?.window else { return nil }
        if !w.isOnActiveSpace { return "our window isn't on the active Space" }
        if !w.occlusionState.contains(.visible) { return "our window is covered by another app's window" }
        // The owner's own keyboard, mouse or trackpad (hardware events only; posted events don't count) interleaves
        // with posted clicks and drags.
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        return idle < 5 ? "the owner used the keyboard or mouse \(Int(idle)) s ago" : nil
    }
    /// A check this run can't make, and why (the summary lists SKIPs; they don't fail the run).
    func skip(_ what: String) { note("SKIP " + what) }
    /// Why posted real events can't reach our window in this run, if they can't: the screen is locked, or the owner is
    /// on another Space (a full-screen app). Checks that need them SKIP instead of failing the run (2026-11-06).
    var realEventsBlocked: String? {
        Self.screenLocked ? "the screen is locked" : c.window.isOnActiveSpace ? nil : "our window isn't on the active Space"
    }
    /// The login window is up (the owner locked the build Mac): windows don't draw, and AppKit doesn't link child windows.
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    // MARK: Steps

    /// Opens the Create a Space card, clicks into its name field and types `name` with real key events.
    private func openNewSpaceAndType(_ name: String) {
        run { [self] in c.openNewSpacePanel() }
        wait(0.3)
        run { [self] in check(c.window.firstResponder is NSTextView, "new space: the name field has focus when the card opens") }
        clickIn({ self.c.newSpacePanel?.hostingView }, "new.name")
        run { [self] in typeText(name) }
        step { [self] done in
            waitUntil({ self.c.newSpacePanel?.model.name == name }) {
                self.check(self.c.newSpacePanel?.model.name == name, "new space: typed \"\(self.c.newSpacePanel?.model.name ?? "-")\"")
                done()
            }
        }
    }

    /// A Space named `name` was created and switched to, and the card closed.
    private func expectNewSpace(_ name: String, how: String) {
        step { [self] done in
            waitUntil({ self.c.newSpacePanel == nil && self.c.store.orderedSpaces.first { $0.name == name }?.id == self.c.currentSpaceID },
                      timeout: 3) { done() }
        }
        run { [self] in
            let made = c.store.orderedSpaces.first { $0.name == name }
            check(made != nil && c.currentSpaceID == made?.id && c.newSpacePanel == nil,
                  "new space (\(how)): " + (made == nil ? "no Space created" : "created and shown") + ", card "
                  + (c.newSpacePanel == nil ? "closed" : "still open") + (c.newSpacePanel?.model.error.map { ", error: \($0)" } ?? ""))
            c.newSpacePanel?.model.onCancel?()
        }
    }

    /// A real click on the control anchored as `anchor` in the hosting view `host()` returns.
    func clickIn(_ host: @escaping () -> NSView?, _ anchor: String) {
        step { [self] done in
            guard let h = host() else { check(false, "click \(anchor): no such view"); return done() }
            // A person clicks a control once it has stopped moving: wait until the control and its hosting view keep
            // the same place for 0.25 s (at most 2 s). Under load (the full snapshot run), a card that resizes after a
            // step change, like Create Profile's, can still be moving when a fixed wait ends.
            waitForStillness(of: anchor, in: h) { self.clickAnchor(anchor, in: h, done) }
        }
    }

    private func waitForStillness(of anchor: String, in host: NSView, then: @escaping () -> Void) {
        let deadline = CACurrentMediaTime() + 2
        var last: (CGRect?, NSRect)?
        var stillSince = CACurrentMediaTime()
        func poll() {
            let now: (CGRect?, NSRect) = (TestAnchors.frames[anchor], host.convert(host.bounds, to: nil))
            let t = CACurrentMediaTime()
            if let l = last, l.0 == now.0, l.1 == now.1 {
                if t - stillSince >= 0.25 { return then() }
            } else {
                stillSince = t
            }
            last = now
            if t > deadline { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    func key(_ chars: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        step { [self] done in
            postKey(chars, keyCode: code, modifiers: modifiers)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
        }
    }

    /// The app's buttons are AircDesign's `.airc(…)` since its `aircShadow` keeps a fixed view structure (40911b3; the
    /// app's AppButtonStyle copy is gone). Create Space and Create Profile (both steps) are `.airc(.primary)` buttons, so
    /// their real-click checks above are the canary for it. A stand-alone canary in a hosting view added just for the
    /// check didn't fire on a real click even for a system `.borderedProminent` button, so it tested the harness, not
    /// the style, and was dropped.
    private func aircDesignButtonCanary() {
        run { [self] in
            note("canary: Create Space and Create Profile are .airc(.primary) buttons; their real-click checks above cover the style")
        }
    }

    /// Calls `then` once `condition` holds, or after `timeout` seconds.
    func waitUntil(_ condition: @escaping () -> Bool, timeout: Double = 2, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline { then() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
    }

    // MARK: Synthesized input

    /// Types `s` into the window's first responder, one key-down/up pair per character.
    func typeText(_ s: String) {
        for ch in s { postKey(String(ch), keyCode: 0) }
    }

    func postKey(_ chars: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        let w = c.window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// A left click at `p` (window coordinates): mouse-down, then mouse-up 60 ms later (a person's click, not both in
    /// the same instant: a SwiftUI button sometimes missed a release that came in the same run-loop turn as its press),
    /// through the app's event queue. The release is posted from a common-modes timer, so it also reaches a control
    /// that tracks the press in its own loop.
    func click(at p: NSPoint, in w: NSWindow, _ done: @escaping () -> Void) {
        func post(_ type: NSEvent.EventType) {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        post(.leftMouseDown)
        let release = Timer(timeInterval: 0.06, repeats: false) { _ in
            post(.leftMouseUp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: done)
        }
        RunLoop.main.add(release, forMode: .common)
    }

    /// The window point at the centre of a `testAnchor`.
    func anchorPoint(_ name: String, in host: NSView) -> NSPoint? {
        guard let f = TestAnchors.frames[name] else { return nil }
        let p = NSPoint(x: f.midX, y: host.isFlipped ? f.midY : host.bounds.height - f.midY)
        return host.convert(p, to: nil)
    }

    func clickAnchor(_ name: String, in host: NSView, _ done: @escaping () -> Void) {
        guard let w = host.window, let p = anchorPoint(name, in: host) else {
            note("FAIL click \(name): not on screen")
            return done()
        }
        // What the click reaches, for a failing check's message.
        let frame = w.contentView?.superview
        let hit = frame.flatMap { $0.hitTest($0.convert(p, from: nil)) }
        TestAnchors.lastHit[name] = String(format: "(%.0f, %.0f) hits ", p.x, p.y) + Self.describe(hit)
            + (hit.map { $0 === host || $0.isDescendant(of: host) } == true ? " in the card" : " outside the card")
        click(at: p, in: w, done)
    }
}

/// Where SwiftUI laid out named controls, for the real-event checks (scripted runs only). Frames are in the
/// coordinate space named `TestAnchors.space`, which a hosting view's root view declares at its top-left.
enum TestAnchors {
    static let enabled = LaunchOptions.current.snapshotDir != nil
    static let space = "airc-test-root"
    static var frames: [String: CGRect] = [:]
    /// What the last click on each anchor hit (clickAnchor).
    static var lastHit: [String: String] = [:]
}

extension View {
    /// Records this view's frame under `name` in scripted runs; does nothing otherwise.
    @ViewBuilder func testAnchor(_ name: String) -> some View {
        if TestAnchors.enabled {
            onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(TestAnchors.space)) }) { TestAnchors.frames[name] = $0 }
        } else {
            self
        }
    }

    /// The origin for `testAnchor` frames: put it on the root view of a hosting view.
    @ViewBuilder func testAnchorRoot() -> some View {
        if TestAnchors.enabled { coordinateSpace(name: TestAnchors.space) } else { self }
    }
}
#endif
