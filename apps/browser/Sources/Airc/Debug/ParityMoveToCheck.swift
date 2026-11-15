// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script paritymoveto` (both engines), S09/S11 (docs/qa/parity-audit.md) on loopback pages:
///   - the Favorite, pinned tab and folder menus in Arc 1.171's order and titles (decoded from its binary,
///     artifacts/moveto/REPORT.md); Move to › grouped by profile, another profile's rows with the cookies tooltip;
///   - real input (AIRC_REAL_KEYS=1, a dedicated session with Airc in front): the menus open on a real driver ⌃-click
///     (a posted right-click when the sidebar doesn't open one yet; the log says which), real ↓/→/Return pick:
///       Favorite › Move to › Desk (pinned there), Folder › Move to › another profile's Space (nesting intact, the
///       loaded page asks first and reopens in that profile), Reset Folder, Turn “Spare” into Space;
///     and a real ⌘Z undoes each;
///   - a two-folder selection's menu: Reset 2 Folders, Move to Space › grouped by profile; both move in one ⌘Z.
/// Without AIRC_REAL_KEYS the real-input cases SKIP.
extension SnapshotRunner {
    func parityMoveToScenario() {
        var server: LocalPageServer?
        var base = ""
        var home = "", desk = "", club = "", pid = "", clubPID = ""
        var fav = "", favTab = "", trip = "", tickets = "", spare = "", alpha = "", bravo = "", alphaItem = "", spareTab = ""
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "paritymoveto \(engine): " + s }
        let watchdog = DispatchWorkItem { [weak self] in
            self?.note("FAIL paritymoveto: still running after 280 s (off-main watchdog)")
            exit(70)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 280, execute: watchdog)

        func titles(_ m: NSMenu?) -> [String] {
            guard let m else { return [] }
            m.update()
            return m.items.filter { !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        func item(_ m: NSMenu?, _ title: String) -> NSMenuItem? { m?.items.first { $0.title == title } }
        func spaceRow(_ sid: String) -> String { c.store.space(sid).map { $0.iconLabel.isEmpty ? $0.name : "\($0.iconLabel)  \($0.name)" } ?? "?" }
        func page() -> SpacePageView? { c.pageView(for: c.currentSpaceID) }
        func entryMenu(_ id: String) -> NSMenu? {
            guard let it = c.store.item(id) else { return nil }
            switch it.kind {
            case .folder: return c.menu(for: .folder(it, depth: 0))
            default: return it.isFavorite ? c.menu(for: .favorite(it, c.store.liveTab(forItem: id)))
                                          : c.menu(for: .pinned(it, depth: 0, c.store.liveTab(forItem: id)))
            }
        }

        step { [self] done in
            var pages: [String: String] = [:]
            for n in ["mail", "alpha", "bravo", "spare", "away"] { pages["/\(n)"] = "<!doctype html><title>\(n)</title><p>\(n)</p>" }
            server = LocalPageServer(pages: pages)
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, label("a loopback page server")) }
                done()
            }
        }

        // Home: Favorite Mail; pinned Trip › [Alpha, Tickets › [Bravo]], Spare › [Note]. Desk (same profile), Club (another).
        step { [self] done in
            home = c.currentSpaceID
            pid = c.store.profile(ofSpace: home).id
            desk = (try? c.store.createSpace(name: "Desk", icon: .emoji("🗂"), profileID: pid, after: home))?.id ?? ""
            let other = try? c.profiles.createProfile(name: "Moveto Club", emoji: "", color: nil)
            clubPID = other?.id ?? ""
            club = other.flatMap { try? c.store.createSpace(name: "Club", icon: .emoji("🪐"), profileID: $0.id) }?.id ?? ""
            func pin(_ n: String) -> (tab: String, item: String) {
                let t = (try? c.store.openTab(url: base + "/\(n)", inSpace: home, activate: false, title: n))?.id ?? ""
                c.performDrop(.tab(t), to: .pinned(spaceID: home, parentID: nil, index: c.store.pinnedRoots(ofSpace: home).count))
                return (t, c.store.tab(t)?.itemID ?? "")
            }
            let m = (try? c.store.openTab(url: base + "/mail", inSpace: home, activate: false, title: "mail"))?.id ?? ""
            c.performDrop(.tab(m), to: .favorites(profileID: pid, index: 0))
            favTab = m
            fav = c.store.tab(m)?.itemID ?? ""
            let a = pin("alpha"), b = pin("bravo"), n = pin("spare")
            alpha = a.tab; alphaItem = a.item; bravo = b.tab; spareTab = n.item
            tickets = (try? c.store.createFolder(named: "Tickets", inSpace: home, containing: [.item(b.item)]))?.id ?? ""
            trip = (try? c.store.createFolder(named: "Trip", inSpace: home, index: 0, containing: [.item(a.item), .item(tickets)]))?.id ?? ""
            spare = (try? c.store.createFolder(named: "Spare", inSpace: home, containing: [.item(n.item)]))?.id ?? ""
            c.reloadAll(animated: false)
            c.switchToSpace(home, animated: false)
            // Bravo loaded: a move to another profile asks first and reopens it there.
            c.show(bravo, focus: false)
            waitUntil({ self.c.engineTab(for: bravo)?.isLoading == false }, timeout: 8) {
                self.check(!desk.isEmpty && !club.isEmpty && !fav.isEmpty && !trip.isEmpty && !spare.isEmpty
                           && self.c.store.item(tickets)?.parentID == trip,
                           label("setup: Favorite, Trip › [Alpha, Tickets › [Bravo]], Spare, Desk and another profile's Club"))
                done()
            }
        }

        // The menus, in Arc's order.
        run { [self] in
            let f = titles(entryMenu(fav))
            check(f == ["Show Hover Preview", "—", "Copy Link", "Share", "—", "Change Icon…", "Edit Pinned Page", "—", "Open in Split View",
                        "Move to", "—", "Unfavorite", "Close Favorite", "Remove Favorite"],
                  label("an unloaded Favorite's menu in Arc's order (\(f.joined(separator: ", ")))"))
            let mv = item(entryMenu(fav), "Move to")?.submenu
            let rows = titles(mv)
            let want = [spaceRow(home), spaceRow(desk), "—", "Moveto Club", "Favorites", spaceRow(club), "—", "New Space…"]
            let cross = mv?.items.filter { $0.toolTip == MoveToPlan.crossProfileTooltip }.map(\.title) ?? []
            check(rows == want && cross == ["Favorites", spaceRow(club)] && item(mv, "Moveto Club")?.isEnabled == false,
                  label("Favorite › Move to › lists its profile's Spaces, then the other profile (header, its Favorites and Spaces, "
                        + "with the cookies tooltip) (\(rows.joined(separator: ", ")); tooltips on \(cross))"))
            let p = titles(entryMenu(c.store.tab(bravo)?.itemID ?? ""))
            check(p == ["Show Hover Preview", "—", "Copy Link", "Share", "—", "Change Icon…", "Rename…", "Mute", "Edit Pinned Page", "—",
                        "Open in Split View", "Duplicate", "Move to", "—", "Unpin", "Add to Favorites", "Close Tab", "Remove Pin", "—",
                        "Customize Page…"],
                  label("a loaded pinned tab's menu in Arc's order (\(p.joined(separator: ", ")))"))
            let t = titles(entryMenu(trip))
            check(t == ["Share Folder…", "—", "New Nested Folder…", "Turn “Trip” into Space", "Copy All Links", "Copy All Links as Markdown", "—",
                        "Change Icon…", "Rename…", "—", "Duplicate", "Move to", "Reset Folder", "—", "Delete Folder"]
                  && item(entryMenu(trip), "Reset Folder")?.isEnabled == false,
                  label("a folder's menu in Arc's order, Reset Folder off with nothing to reset (\(t.joined(separator: ", ")))"))
            let fm = titles(item(entryMenu(trip), "Move to")?.submenu)
            check(fm == [spaceRow(desk), "—", "Moveto Club", spaceRow(club), "—", "Spare", "—", "New Space…"],
                  label("Folder › Move to › leaves out its own Space, then the other profile, then this Space's folders "
                        + "(\(fm.joined(separator: ", ")))"))
        }

        guard UIDriverClient.requested else {
            run { [self] in
                skip(label("real ⌃-click menus, keys and ⌘Z need AIRC_REAL_KEYS=1 in a dedicated session"))
                server?.stop()
                watchdog.cancel()
            }
            return
        }

        /// Opens the row's menu by real input and picks `path` with real ↓/→/Return. `onOpen` is the point of the row
        /// (window coordinates, at click time). A real driver ⌃-click first; a posted right-click if no menu opens.
        func pick(_ what: String, _ path: [String], at point: @escaping () -> NSPoint?, then: @escaping (Bool) -> Void) {
            guard let p = point() else { check(false, label("\(what): the row is on screen")); return then(false) }
            var trace: [String] = []
            var opened = false
            var token: NSObjectProtocol?
            func onMain<T>(_ body: @escaping () -> T) -> T? {
                var value: T?
                let sem = DispatchSemaphore(value: 0)
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { value = body(); sem.signal() }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                return sem.wait(timeout: .now() + 2) == .success ? value : nil
            }
            func key(_ combo: String) -> Bool {
                let pr = Process()
                pr.executableURL = URL(fileURLWithPath: UIDriverClient.path)
                pr.arguments = ["--json", "--key", combo]
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "CFFIXED_USER_HOME")
                pr.environment = env
                let pipe = Pipe()
                pr.standardOutput = pipe; pr.standardError = pipe
                guard (try? pr.run()) != nil else { return false }
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                pr.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.15)
                return pr.terminationStatus == 0 && out.replacingOccurrences(of: " ", with: "").contains("\"ok\":true")
            }
            var how = "real ⌃-click"
            func finish(_ picked: Bool) {
                if let token { NotificationCenter.default.removeObserver(token) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.note(label("\(what): opened by \(how); keys \(trace.joined(separator: " "))"))
                    self.check(picked, label("\(what): \(how) opens the menu and real ↓ → Return pick \(path.joined(separator: " › "))"))
                    then(picked)
                }
            }
            token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                guard !opened, let m = n.object as? NSMenu, m.supermenu == nil, m.items.contains(where: { $0.title == path[0] }) else { return }
                opened = true
                DispatchQueue.global(qos: .userInitiated).async {
                    var picked = false
                    defer { if !picked { _ = key("esc"); _ = key("esc") }; finish(picked) }
                    Thread.sleep(forTimeInterval: 0.4)
                    var menu: NSMenu = m
                    for (level, title) in path.enumerated() {
                        var on = false
                        // A menu opened near the pointer may start highlighted low down: ↓ until it stops moving, then ↑.
                        var dir = "down", last: String? = nil
                        for _ in 0..<40 {
                            let h = onMain { menu.highlightedItem?.title } ?? nil
                            if h == title { on = true; break }
                            guard key(dir) else { trace.append("\(dir) failed"); return }
                            let now = onMain { menu.highlightedItem?.title } ?? nil
                            trace.append((dir == "down" ? "↓" : "↑") + (now ?? "-"))
                            if now == last, now != nil { dir = dir == "down" ? "up" : "down" }
                            last = now
                        }
                        guard on else { trace.append("no \(title)"); return }
                        if level == path.count - 1 { picked = key("return"); trace.append("⏎"); return }
                        guard key("right") else { return }
                        trace.append("→")
                        Thread.sleep(forTimeInterval: 0.3)
                        guard let sub = onMain({ menu.items.first { $0.title == title }?.submenu }) ?? nil else { trace.append("no submenu"); return }
                        menu = sub
                    }
                }
            }
            UIDriverClient.click(p, in: c.window, mods: "ctrl") { ok, out in
                if !ok { trace.append("driver: \(out)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard !opened else { return }
                    // Sidebar ⌃-click isn't a context click yet on main (ownerfixes); a posted right-click, after a posted
                    // move onto the row (a posted press may miss without one, airc-posted-click-real-pointer).
                    how = "posted right-click (⌃-click opened no menu)"
                    for type in [NSEvent.EventType.mouseMoved, .rightMouseDown, .rightMouseUp] {
                        if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: self.c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                      pressure: type == .rightMouseDown ? 1 : 0) { NSApp.postEvent(e, atStart: false) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        guard !opened else { return }
                        DispatchQueue.global().async { _ = key("esc"); finish(false) }
                    }
                }
            }
        }
        func rowPoint(_ id: String) -> () -> NSPoint? {
            { [self] in
                guard let pg = page() else { return nil }
                pg.layoutSubtreeIfNeeded()
                let v: NSView? = pg.tileView(id).map { $0 as NSView } ?? pg.rows[id]
                guard let v, v.window === c.window else { return nil }
                v.scrollToVisible(v.bounds)
                let pt = v.convert(NSPoint(x: min(60, v.bounds.width / 2), y: v.bounds.midY), to: nil)
                guard let hit = c.window.contentView?.hitTest(pt), hit === v || hit.isDescendant(of: v) else { return nil }
                return pt
            }
        }
        func undoKey(_ what: String, then: @escaping (Bool) -> Void) {
            UIDriverClient.press(["cmd+z"], pid: ProcessInfo.processInfo.processIdentifier) { ok, out in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if !ok { self.check(false, label("\(what): real ⌘Z (\(out))")) }
                    then(ok)
                }
            }
        }

        activateForRealInput()
        step { [self] done in
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ self.c.window.isKeyWindow && NSApp.isActive }, timeout: 5) {
                self.note(label("real input: key \(self.c.window.isKeyWindow), active \(NSApp.isActive), layout \(UIDriverClient.layoutName)"))
                done()
            }
        }

        // 1. Favorite › Move to › Desk, then ⌘Z.
        uiCase(window: { self.c.window }) {
            step { [self] done in
                uiAttempt?.point = rowPoint(fav)()
                pick("Favorite", ["Move to", spaceRow(desk)], at: rowPoint(fav)) { ok in
                    self.waitUntil({ self.c.store.item(fav)?.container == .pinned(spaceID: desk) }, timeout: 3) {
                        self.check(self.c.store.item(fav)?.container == .pinned(spaceID: desk) && self.c.store.pinnedRoots(ofSpace: desk).last?.id == fav,
                                   label("Favorite › Move to › Desk makes it Desk's last pinned tab (\(String(describing: self.c.store.item(fav)?.container)))"))
                        undoKey("Favorite") { _ in
                            self.check(self.c.store.item(fav)?.container == .favorites(profileID: pid),
                                       label("a real ⌘Z makes it a Favorite again"))
                            done()
                        }
                    }
                }
            }
        }
        wait(0.6)

        // 2. Folder › Move to › Club (another profile): the loaded page asks; Return moves; nesting intact; ⌘Z.
        uiCase(window: { self.c.window }) {
            step { [self] done in
                uiAttempt?.point = rowPoint(trip)()
                pick("Folder", ["Move to", spaceRow(club)], at: rowPoint(trip)) { ok in
                    self.waitUntil({ self.c.window.attachedSheet != nil }, timeout: 3) {
                        let asked = self.c.window.attachedSheet != nil
                        UIDriverClient.press(["return"], pid: ProcessInfo.processInfo.processIdentifier) { _, _ in
                            self.waitUntil({ self.c.store.item(trip)?.container == .pinned(spaceID: club) }, timeout: 4) {
                                let s = self.c.store
                                self.check(asked && s.item(trip)?.container == .pinned(spaceID: club) && s.item(tickets)?.parentID == trip
                                           && s.item(tickets)?.container == .pinned(spaceID: club) && s.tab(bravo)?.profileID == clubPID
                                           && s.tab(alpha)?.spaceID == club,
                                           label("Folder › Move to › Club asks first (\(asked)), then moves Trip with Tickets › Bravo inside, "
                                                 + "Bravo in Club's profile (\(s.tab(bravo)?.profileID == clubPID))"))
                                undoKey("Folder") { _ in
                                    self.check(s.item(trip)?.container == .pinned(spaceID: home) && s.item(tickets)?.parentID == trip
                                               && s.tab(bravo)?.profileID == pid && s.tab(bravo)?.spaceID == home,
                                               label("a real ⌘Z brings the folder back with its nesting and profile"))
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
        wait(0.6)

        // 3. Folder › Reset Folder (Alpha away from its pinned URL), then ⌘Z.
        uiCase(window: { self.c.window }) {
            step { [self] done in
                c.store.updateTab(alpha, url: base + "/away")
                c.reloadAll(animated: false)
                uiAttempt?.point = rowPoint(trip)()
                pick("Reset Folder", ["Reset Folder"], at: rowPoint(trip)) { ok in
                    self.waitUntil({ self.c.store.tab(alpha)?.url == base + "/alpha" }, timeout: 3) {
                        self.check(self.c.store.tab(alpha)?.url == base + "/alpha",
                                   label("Reset Folder takes Alpha back to its pinned URL (\(self.c.store.tab(alpha)?.url ?? "-"))"))
                        undoKey("Reset Folder") { _ in
                            self.check(self.c.store.tab(alpha)?.url == base + "/away", label("a real ⌘Z puts Alpha where it was"))
                            done()
                        }
                    }
                }
            }
        }
        wait(0.6)

        // 4. Turn “Spare” into Space, then ⌘Z.
        uiCase(window: { self.c.window }) {
            step { [self] done in
                let before = Set(c.store.state.spaces.keys)
                uiAttempt?.point = rowPoint(spare)()
                pick("Turn into Space", ["Turn “Spare” into Space"], at: rowPoint(spare)) { ok in
                    self.waitUntil({ self.c.store.item(spare) == nil }, timeout: 3) {
                        let made = self.c.store.orderedSpaces.first { !before.contains($0.id) }
                        self.check(made?.name == "Spare" && self.c.store.item(spare) == nil
                                   && self.c.store.pinnedRoots(ofSpace: made?.id ?? "").map(\.id) == [spareTab],
                                   label("Turn “Spare” into Space makes Space “\(made?.name ?? "-")” holding its tab as pinned; the folder goes"))
                        undoKey("Turn into Space") { _ in
                            self.check(made.map { self.c.store.space($0.id) == nil } == true && self.c.store.item(spareTab)?.parentID == spare,
                                       label("a real ⌘Z removes the Space and brings the folder back"))
                            self.c.switchToSpace(home, animated: false)
                            done()
                        }
                    }
                }
            }
        }
        wait(0.6)

        // 5. A two-folder selection: Reset 2 Folders, Move to Space › grouped; both move as one ⌘Z.
        uiCase(window: { self.c.window }) {
            step { [self] done in
                c.switchToSpace(home, animated: false)
                let ids = [trip, spare]
                let m = c.selectionMenu(ids: ids, spaceID: home)
                let t = titles(m)
                let rows = titles(item(m, "Move to Space")?.submenu)
                check(t.contains("Reset 2 Folders") && rows == [spaceRow(desk), "—", "Moveto Club", spaceRow(club)],
                      label("a two-folder selection's menu has Reset 2 Folders and Move to Space › by profile (\(rows.joined(separator: ", ")))"))
                c.moveSelected(ids, from: home, to: desk)
                let moved = c.store.item(trip)?.container == .pinned(spaceID: desk) && c.store.item(spare)?.container == .pinned(spaceID: desk)
                undoKey("selection") { _ in
                    let back = self.c.store.item(trip)?.container == .pinned(spaceID: home) && self.c.store.item(spare)?.container == .pinned(spaceID: home)
                    self.check(moved && back, label("Move to Space › Desk moves both (\(moved)); one real ⌘Z brings both back (\(back))"))
                    done()
                }
            }
        }

        run { [self] in
            _ = alphaItem
            server?.stop()
            watchdog.cancel()
        }
    }
}
#endif
