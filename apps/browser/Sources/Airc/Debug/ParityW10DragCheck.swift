// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityw10drag` (both engines; a dedicated UI session under the UI lock, `AIRC_UI_DEDICATED_SESSION=1`,
/// `AIRC_REAL_KEYS=1`): W10's tear-out (Sidebar/TabDragOut.swift) with **real** drags from the build Mac's stable UI
/// driver (infra/ui-driver; HID events through the window server). Every drag starts on a sidebar row of the source
/// window, the key window of the active app, and is released on the desktop (no Airc window under the pointer) unless
/// a case says otherwise:
///   1. tear-out at two drop points: a new window whose frame puts the pressed point under the drop point (within 3 pt);
///      the page moved live (the same engine page object, its JS state and history length kept, no new request to
///      the page server); the source window no longer shows it; the new window is on the tab's Space and profile;
///   2. a drop on a second window's sidebar: no new window, that window shows the tab, live, and comes to the front;
///   3. ⌥ (driver `--mods opt`): a copy opens in a new window; the dragged tab stays shown in the source; one real ⌘Z
///      ("Undo Duplicate") removes the copy;
///   4. a split row: both panes go to the new window, live; 5. a folder row: nothing leaves (no new window);
///   6. a Favorite tile: its live page opens in the new window; the Favorite stays;
///   7. Esc mid-drag (posted into the app's queue while the real drag is outside the window; the driver's requests are
///      serial, so it can't press Esc during its own drag): nothing changes, and the page is not reloaded;
///   8. a drop on a Little Airc window: nothing happens there; 9. in native full screen a drag can't leave the window:
///      no new window, still full screen.
extension SnapshotRunner {
    func parityW10DragScenario() {
        let tag = "parityw10drag"
        var server: LocalPageServer?
        var base = ""
        let counts = NSLock()
        var requests: [String: Int] = [:]
        func hits(_ path: String) -> Int { counts.lock(); defer { counts.unlock() }; return requests[path] ?? 0 }
        var tabs: [String: String] = [:]          // path → tab ID
        var real = false
        var home = NSRect.zero
        var drops: [NSPoint] = []                 // two desktop points (AppKit screen coordinates)
        var opened: [WindowController] = []       // windows the cases opened (closed between cases)
        var w2: WindowController?
        let source = c!

        func n(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        func screenTop() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
        func cg(_ s: NSPoint) -> NSPoint { NSPoint(x: s.x, y: screenTop() - s.y) }
        func controllers() -> [WindowController] { app?.controllers ?? [] }
        func ident(_ t: EngineTab?) -> ObjectIdentifier? { t.map { ObjectIdentifier($0 as AnyObject) } }
        func row(_ id: String, in w: WindowController) -> NSView? {
            guard let page = w.pageView(for: w.currentSpaceID) else { return nil }
            page.layoutSubtreeIfNeeded()
            if let r = page.rows[id] { return r }
            return page.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == id }
        }
        func center(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        /// The source window key, in front, on the active Space; `done(false)` (FAIL-ENV) when it can't be.
        func front(_ w: WindowController, _ done: @escaping (Bool) -> Void) {
            // Back where the drops were planned from (a stray system drag could have moved or tiled it).
            if w === source, !w.window.styleMask.contains(.fullScreen), w.window.frame != home { w.window.setFrame(home, display: true) }
            NSApp.activate(ignoringOtherApps: true)
            w.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && w.window.isKeyWindow && w.window.isOnActiveSpace }, timeout: 3) {
                let ok = NSApp.isActive && w.window.isKeyWindow && w.window.isOnActiveSpace
                if !ok {
                    self.note("FAIL-ENV \(tag): window not key/active (active=\(NSApp.isActive), key=\(w.window.isKeyWindow), "
                              + "space=\(w.window.isOnActiveSpace), locked=\(Self.screenLocked))")
                }
                done(ok)
            }
        }
        /// A real drag from a window point of `w` to screen point `to`; `done(ok)` on main, after the app settled.
        func drag(_ from: NSPoint, in w: WindowController, to: NSPoint, mods: String? = nil, _ done: @escaping (Bool) -> Void) {
            front(w) { ok in
                guard ok else { return done(false) }
                let frameView = w.window.contentView?.superview
                let hit = frameView?.hitTest(frameView!.convert(from, from: nil))
                // The press must be on the row it means (not a part of the list scrolled out of sight).
                guard let hit, sequence(first: hit, next: { $0.superview }).contains(where: { $0 is SidebarRowView }) else {
                    self.check(false, "\(tag): the press at \(NSStringFromPoint(from)) is on a sidebar row (hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
                    return done(false)
                }
                self.note("\(tag) drag: press \(NSStringFromPoint(from)) hits \(String(describing: type(of: hit))), "
                          + "window \(NSStringFromRect(w.window.frame)), to \(NSStringFromPoint(to))\(mods.map { " mods " + $0 } ?? "")")
                let s = cg(w.window.convertPoint(toScreen: from)), e = cg(to)
                UIDriverClient.run(["--drag", n(s.x), n(s.y), n(e.x), n(e.y)] + (mods.map { ["--mods", $0] } ?? [])) { ok, out in
                    if !ok { self.note("FAIL-ENV \(tag): the driver refused the drag (\(out))") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { done(ok) }
                }
            }
        }
        /// Shows `id` in the source window, waits for its page, and marks it: a JS value and a same-document history
        /// entry a reload would lose. `done(token)`.
        func mark(_ id: String, _ done: @escaping (String) -> Void) {
            // At the top of Today, so its row is on screen in the short window.
            if source.store.tab(id)?.isToday == true, source.store.split(containing: id) == nil {
                _ = try? source.store.move(.tab(id), to: .today(spaceID: source.currentSpaceID, index: 0))
            }
            source.show(id)
            let deadline = Date().addingTimeInterval(12)
            func poll() {
                let page = source.engineTab(for: id)
                if let page, !page.isLoading || Date() > deadline {
                    let token = "w10-" + String(Int.random(in: 100_000...999_999))
                    page.evaluate("window.__w10='\(token)';history.pushState({w10:1},'','#w10');history.length") { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done(token) }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                }
            }
            poll()
        }
        /// The page's mark and history length, as `window.__w10|history.length|location.hash`.
        func state(_ page: EngineTab?, _ done: @escaping (String) -> Void) {
            guard let page else { return done("no page") }
            page.evaluate("(window.__w10||'')+'|'+history.length+'|'+location.hash") { v in done((v as? String) ?? "\(v ?? "nil")") }
        }
        func closeOpened() {
            for w in opened where controllers().contains(where: { $0 === w }) { w.window.performClose(nil) }
            opened.removeAll()
        }
        func newWindows(_ before: [WindowController]) -> [WindowController] {
            controllers().filter { w in !before.contains { $0 === w } }
        }

        // Setup: a loopback server that counts requests per page, ten tabs, the window on the left of the main screen,
        // two drop points on the desktop to its right.
        step { [self] done in
            let page = { (p: String) in "<!doctype html><title>w10 \(p)</title><body style='margin:0;font:16px -apple-system'>"
                + "<p style='margin:60px'>W10 \(p)</p><input id=i value='\(p)'>" }
            server = LocalPageServer(pages: [:])
            server?.handler = { path in
                counts.lock(); requests[path, default: 0] += 1; counts.unlock()
                return LocalPageServer.Page(headers: ["Cache-Control": "no-store", "Content-Type": "text/html"], body: page(path))
            }
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, "\(tag): a loopback page server") }
                done()
            }
        }
        run { [self] in
            TabDragOut.trace = { [weak self] in self?.note("\(tag) trace: " + $0) }
            real = UIDriverClient.requested && ProcessInfo.processInfo.environment["AIRC_UI_DEDICATED_SESSION"] == "1"
                && FileManager.default.isExecutableFile(atPath: UIDriverClient.path)
            if !real { note("FAIL-ENV \(tag): real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1 and the stable UI driver") }
            let sid = source.currentSpaceID
            for p in ["/a", "/b", "/c", "/d", "/e", "/f", "/g", "/h", "/i", "/j", "/k"] {
                if let t = try? source.store.openTab(url: base + p, inSpace: sid, activate: false, title: "w10 " + p) { tabs[p] = t.id }
            }
            source.reloadAll(animated: false)
            guard let main = NSScreen.screens.first else { return }
            let v = main.visibleFrame
            let width = min(620, (v.width - 160) / 2.3), height = min(560, v.height - 160)
            home = NSRect(x: v.minX + 20, y: v.minY + (v.height - height) / 2, width: width, height: height)
            source.window.setFrame(home, display: true)
            drops = [NSPoint(x: home.maxX + 200, y: v.midY + 60), NSPoint(x: home.maxX + 260, y: v.midY - 90)]
            note("\(tag): engine=\(app?.engine is WebKitEngine ? "webkit" : "chromium"), screen=\(NSStringFromRect(main.frame)) visible=\(NSStringFromRect(v)), "
                 + "source=\(NSStringFromRect(home)), drops=\(drops.map { NSStringFromPoint($0) }), real=\(real)")
        }

        // 1. Tear-out at two points.
        for (i, path) in ["/a", "/b"].enumerated() {
            step { [self] done in
                guard real, let id = tabs[path] else { return done() }
                mark(id) { token in
                    guard let r = row(id, in: source) else { self.check(false, "\(tag): tear-out \(i + 1): the row"); return done() }
                    let press = center(r), drop = drops[i]
                    let expected = source.newWindowFrame(at: drop, pressInWindow: press)
                    let page = ident(source.engineTab(for: id)), loads = hits(path)
                    let before = controllers(), tab = source.store.tab(id)
                    drag(press, in: source, to: drop) { ok in
                        guard ok else { return done() }
                        let made = newWindows(before)
                        opened += made
                        guard made.count == 1, let w = made.first else {
                            self.check(false, "\(tag): tear-out \(i + 1) at \(NSStringFromPoint(drop)) opens one new window (\(made.count))")
                            return done()
                        }
                        let f = w.window.frame
                        let near = abs(f.minX - expected.minX) <= 3 && abs(f.maxY - expected.maxY) <= 3 && f.size == expected.size
                        self.check(near && f.contains(drop),
                                   "\(tag): tear-out \(i + 1): the new window's frame \(NSStringFromRect(f)) is at the drop point "
                                   + "\(NSStringFromPoint(drop)) (expected \(NSStringFromRect(expected)))")
                        self.check(w.shownTabID == id && source.shownTabID != id && !source.visibleTabIDs.contains(id),
                                   "\(tag): tear-out \(i + 1): the tab is in the new window and gone from the source "
                                   + "(new shows \(w.shownTabID ?? "-"), source shows \(source.shownTabID ?? "-"))")
                        let now = source.store.tab(id)
                        self.check(w.currentSpaceID == tab?.spaceID && now?.profileID == tab?.profileID && now?.spaceID == tab?.spaceID,
                                   "\(tag): tear-out \(i + 1): the new window is on the tab's Space and profile")
                        state(w.engineTab(for: id)) { s in
                            self.check(s.hasPrefix(token + "|") && s.hasSuffix("#w10") && ident(w.engineTab(for: id)) == page
                                       && hits(path) == loads,
                                       "\(tag): tear-out \(i + 1): the page moved live, no reload (state \(s), mark \(token), "
                                       + "same page object \(ident(w.engineTab(for: id)) == page), requests \(loads) → \(hits(path)))")
                            if i == 0 { closeOpened() } else { w2 = w }
                            done()
                        }
                    }
                }
            }
            wait(0.6)
        }

        // 2. A drop on the second window's sidebar.
        step { [self] done in
            guard real, let w = w2, let id = tabs["/c"] else { return done() }
            mark(id) { token in
                guard let r = row(id, in: source) else { self.check(false, "\(tag): drop into a window: the row"); return done() }
                // Just past the middle of the second window's row for /b (the tab it shows): a slot after it, not
                // onto the row (which would make a split).
                guard let b = tabs["/b"], let under = row(b, in: w) else { self.check(false, "\(tag): drop into a window: its row"); return done() }
                let t = under.convert(under.bounds, to: nil)
                let drop = w.window.convertPoint(toScreen: NSPoint(x: t.midX, y: t.minY + 3))
                let page = ident(source.engineTab(for: id)), loads = hits("/c"), before = controllers()
                drag(center(r), in: source, to: drop) { ok in
                    guard ok else { return done() }
                    // In front of the source (scripted runs order a window front without making it key: MultiWindow.present).
                    let order = NSApp.orderedWindows
                    let inFront = (order.firstIndex(of: w.window) ?? .max) < (order.firstIndex(of: source.window) ?? .max)
                    self.check(newWindows(before).isEmpty && w.shownTabID == id && !source.visibleTabIDs.contains(id) && inFront,
                               "\(tag): a drop on the second window's sidebar moves the tab there (no new window: "
                               + "\(newWindows(before).isEmpty), it shows the tab: \(w.shownTabID == id), source still shows it: "
                               + "\(source.visibleTabIDs.contains(id)), in front of the source: \(inFront))")
                    state(w.engineTab(for: id)) { s in
                        self.check(s.hasPrefix(token + "|") && ident(w.engineTab(for: id)) == page && hits("/c") == loads,
                                   "\(tag): the dropped page moved live (state \(s), requests \(loads) → \(hits("/c")))")
                        done()
                    }
                }
            }
        }
        run { closeOpened(); w2 = nil }
        wait(0.6)

        // 3. ⌥: a copy opens in the new window, the tab stays; ⌘Z takes the copy back.
        step { [self] done in
            guard real, let id = tabs["/d"] else { return done() }
            mark(id) { _ in
                guard let r = row(id, in: source) else { self.check(false, "\(tag): ⌥ tear-out: the row"); return done() }
                let before = controllers(), ids = Set(source.store.state.tabs.keys)
                drag(center(r), in: source, to: drops[0], mods: "opt") { ok in
                    guard ok else { return done() }
                    let made = newWindows(before)
                    opened += made
                    let copies = Set(source.store.state.tabs.keys).subtracting(ids)
                    let copy = copies.first
                    self.check(made.count == 1 && copies.count == 1 && made.first?.shownTabID == copy
                               && source.store.tab(copy)?.url.contains("/d") == true && copy != id,
                               "\(tag): ⌥ tear-out opens a copy in a new window (windows +\(made.count), tabs +\(copies.count), "
                               + "it shows \(made.first?.shownTabID.flatMap { source.store.tab($0)?.url } ?? "-"))")
                    self.check(source.store.tab(id) != nil && source.shownTabID == id,
                               "\(tag): ⌥ tear-out leaves the dragged tab shown in the source (\(source.shownTabID ?? "-"))")
                    self.check(source.store.undoLabel == "Duplicate", "\(tag): the copy is undoable as Duplicate (\(source.store.undoLabel ?? "-"))")
                    front(source) { ok in
                        guard ok else { return done() }
                        UIDriverClient.press(["cmd+z"], pid: ProcessInfo.processInfo.processIdentifier) { ok, out in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                if !ok { self.note("FAIL-ENV \(tag): real ⌘Z refused (\(out))"); return done() }
                                self.check(copy.map { source.store.tab($0) == nil } == true && source.store.tab(id) != nil,
                                           "\(tag): a real ⌘Z removes the copy and keeps the original")
                                done()
                            }
                        }
                    }
                }
            }
        }
        run { closeOpened() }
        wait(0.6)

        // 4. A split row: both panes go, live.
        var split: Split?
        run { [self] in
            guard real, let e = tabs["/e"], let f = tabs["/f"] else { return }
            split = try? source.store.createSplit([e, f], inSpace: source.currentSpaceID)
            // At the top of Today, so its row is on screen.
            if let x = split { _ = try? source.store.move(.split(x.id), to: .today(spaceID: source.currentSpaceID, index: 0)) }
            source.reloadAll(animated: false)
        }
        step { [self] done in
            guard real, let x = split, let e = tabs["/e"], let f = tabs["/f"] else {
                if real { check(false, "\(tag): a split to drag") }
                return done()
            }
            mark(f) { _ in
            mark(e) { token in
                guard let r = row(x.id, in: source) else { self.check(false, "\(tag): split tear-out: the split row"); return done() }
                let before = controllers(), page = ident(source.engineTab(for: e))
                drag(center(r), in: source, to: drops[1]) { ok in
                    guard ok else { return done() }
                    let made = newWindows(before)
                    opened += made
                    let w = made.first
                    self.check(made.count == 1 && w?.shownSplitID == x.id && w?.visibleTabIDs.isSuperset(of: [e, f]) == true
                               && source.visibleTabIDs.isDisjoint(with: [e, f]),
                               "\(tag): a split row tears out whole: both panes in the new window, none left in the source "
                               + "(new split \(w?.shownSplitID ?? "-"), source shows \(source.visibleTabIDs.sorted()))")
                    state(w?.engineTab(for: e)) { s in
                        self.check(s.hasPrefix(token + "|") && ident(w?.engineTab(for: e)) == page,
                                   "\(tag): the split's pane moved live (state \(s))")
                        done()
                    }
                }
            }
            }
        }
        run { closeOpened() }
        wait(0.6)

        // 5. A folder row stays.
        step { [self] done in
            guard real, let g = tabs["/g"] else { return done() }
            guard let folder = try? source.store.createFolder(named: "W10 folder", inSpace: source.currentSpaceID, containing: [.tab(g)]) else {
                check(false, "\(tag): a folder to drag"); return done()
            }
            source.reloadAll(animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let r = row(folder.id, in: source) else { self.check(false, "\(tag): folder: the row"); return done() }
                let before = controllers(), parent = source.store.item(folder.id)?.container
                drag(center(r), in: source, to: drops[0]) { ok in
                    guard ok else { return done() }
                    self.check(newWindows(before).isEmpty && source.store.item(folder.id)?.container == parent,
                               "\(tag): a folder row doesn't leave the window (no new window, the folder stays in its section)")
                    opened += newWindows(before)
                    done()
                }
            }
        }
        run { closeOpened() }

        // 6. A Favorite tile: its live page tears out, the Favorite stays.
        var favorite: String?
        run { [self] in
            guard real, let h = tabs["/h"] else { return }
            let pid = source.store.profile(ofSpace: source.currentSpaceID).id
            _ = try? source.store.move(.tab(h), to: .favorites(profileID: pid, index: 0))
            favorite = source.store.favorites(ofProfile: pid).first { source.store.liveTab(forItem: $0.id)?.id == h || $0.savedURL?.hasSuffix("/h") == true }?.id
            source.reloadAll(animated: false)
        }
        wait(0.4)
        step { [self] done in
            guard real else { return done() }
            guard let fav = favorite, let r = row(fav, in: source) else { check(false, "\(tag): a Favorite tile to drag"); return done() }
            let before = controllers(), pid = source.store.profile(ofSpace: source.currentSpaceID).id
            drag(center(r), in: source, to: drops[1]) { ok in
                guard ok else { return done() }
                let made = newWindows(before)
                opened += made
                let live = source.store.liveTab(forItem: fav)?.id
                self.check(made.count == 1 && live != nil && made.first?.shownTabID == live
                           && source.store.favorites(ofProfile: pid).contains { $0.id == fav },
                           "\(tag): a Favorite tile tears out its page into a new window and stays a Favorite "
                           + "(new shows \(made.first?.shownTabID ?? "-"), live \(live ?? "-"))")
                done()
            }
        }
        run { closeOpened() }
        wait(0.6)

        // 7. Esc mid-drag: nothing changes.
        step { [self] done in
            guard real, let id = tabs["/i"] else { return done() }
            mark(id) { token in
                guard let r = row(id, in: source) else { self.check(false, "\(tag): Esc: the row"); return done() }
                let order = source.store.todayTabs(ofSpace: source.currentSpaceID).map(\.id)
                let before = controllers(), loads = hits("/i"), page = ident(source.engineTab(for: id))
                var posted = false
                TabDragOut.onLeftWindow = {
                    // Into the app's own queue, which the sidebar's tracking loop reads (never a direct sendEvent).
                    for type in [NSEvent.EventType.keyDown, .keyUp] {
                        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: source.window.windowNumber, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                            NSApp.postEvent(e, atStart: false)
                        }
                    }
                    posted = true
                }
                drag(center(r), in: source, to: drops[0]) { ok in
                    TabDragOut.onLeftWindow = nil
                    guard ok else { return done() }
                    let now = source.store.todayTabs(ofSpace: source.currentSpaceID).map(\.id)
                    self.check(posted && newWindows(before).isEmpty && now == order && source.shownTabID == id,
                               "\(tag): Esc during a real drag outside the window leaves everything as it was (Esc posted: \(posted), "
                               + "new windows \(newWindows(before).count), order kept \(now == order), shown \(source.shownTabID == id))")
                    opened += newWindows(before)
                    state(source.engineTab(for: id)) { s in
                        self.check(s.hasPrefix(token + "|") && ident(source.engineTab(for: id)) == page && hits("/i") == loads,
                                   "\(tag): the cancelled drag's page wasn't reloaded (state \(s), requests \(loads) → \(hits("/i")))")
                        done()
                    }
                }
            }
        }
        run { closeOpened() }

        // 8. A drop on a Little Airc window: nothing happens there.
        var little: LittleArcController?
        step { [self] done in
            guard real, let id = tabs["/j"] else { return done() }
            mark(id) { _ in
                little = self.app?.openLittleArc(url: URL(string: base + "/little"), spaceID: source.currentSpaceID)
                guard let l = little else { self.check(false, "\(tag): a Little Airc window"); return done() }
                let size = NSSize(width: 420, height: 320)
                l.window.setFrame(NSRect(x: drops[0].x - size.width / 2, y: drops[0].y - size.height / 2, width: size.width, height: size.height),
                                  display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let r = row(id, in: source) else { self.check(false, "\(tag): Little Airc: the row"); return done() }
                    let before = controllers(), frame = l.window.frame, littleTabs = self.app?.littleArcs.count ?? 0
                    drag(center(r), in: source, to: drops[0]) { ok in
                        guard ok else { return done() }
                        self.check(newWindows(before).isEmpty && source.store.tab(id) != nil && source.shownTabID == id
                                   && l.window.isVisible && l.window.frame == frame && (self.app?.littleArcs.count ?? 0) == littleTabs,
                                   "\(tag): a drop on a Little Airc window does nothing (no new window, the tab stays shown in the "
                                   + "source, Little Airc unchanged at \(NSStringFromRect(l.window.frame)))")
                        opened += newWindows(before)
                        l.closeWindow()
                        done()
                    }
                }
            }
        }
        run { closeOpened() }
        wait(0.6)

        // 9. Native full screen: a drag can't leave the window.
        step { [self] done in
            guard real, let id = tabs["/k"] else { return done() }
            front(source) { ok in
                guard ok else { return done() }
                source.window.toggleFullScreen(nil)
                self.waitUntil({ source.window.styleMask.contains(.fullScreen) }, timeout: 6) {
                    guard source.window.styleMask.contains(.fullScreen) else {
                        self.note("FAIL-ENV \(tag): native full screen didn't start (space=\(source.window.isOnActiveSpace))"); return done()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard let r = row(id, in: source) else { self.check(false, "\(tag): full screen: the row"); return done() }
                        let f = source.window.frame, before = controllers()
                        drag(center(r), in: source, to: NSPoint(x: f.maxX - 4, y: f.midY)) { ok in
                            guard ok else { return done() }
                            self.check(newWindows(before).isEmpty && source.window.styleMask.contains(.fullScreen) && source.store.tab(id) != nil,
                                       "\(tag): in native full screen a drag to the screen's edge opens no window and stays full screen")
                            opened += newWindows(before)
                            source.window.toggleFullScreen(nil)
                            self.waitUntil({ !source.window.styleMask.contains(.fullScreen) }, timeout: 6) {
                                self.check(!source.window.styleMask.contains(.fullScreen), "\(tag): full screen exits after the drag")
                                done()
                            }
                        }
                    }
                }
            }
        }
        wait(1)
        run { closeOpened(); server?.stop(); TabDragOut.trace = nil }
    }
}
#endif
