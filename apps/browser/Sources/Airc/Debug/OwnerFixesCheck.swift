// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// Two items from the owner's own use (2026-11-13), proved with real input from the build Mac's stable UI driver
/// (keys PID-targeted at Airc in front, clicks and drags through the window server). Needs a dedicated UI session
/// under the UI lock: `AIRC_UI_DEDICATED_SESSION=1 AIRC_REAL_KEYS=1 AIRC_LA_AS_OWNER=1` (a scripted run otherwise never
/// activates Airc or makes a new window key). Without them every case is FAIL-ENV.
///
/// `--script ownerfs` (Browser/FullScreen.swift, NewWindowFullScreen): with the window in native full screen (a real
/// ⌃⌘F), a real ⌘N, ⌘⇧N and a tab's Move to New Window (a real ⌃-click on its row, real ↓ and Return in the menu) each
/// open a window that is in native full screen, on a Space of its own (the source window isn't on the active Space),
/// key, at the normal level, whose windowed frame is a normal window's; out of full screen a real ⌘N opens an ordinary
/// window on the same Space, as before.
///
/// `--script ownerquote` (Browser/SelectionShare.swift, C06): a real drag selects words on a page and a real ⌘C copies
/// them: "Share a link directly to this text instead?" shows, and a real click on its Copy Link copies the page's link
/// to that text (`#:~:text=`); that link, opened in a tab, scrolls to the text and highlights it (`::target-text`
/// pixels in the page's own snapshot). Then a real ⌃-click on the selected text opens the engine's page menu: its
/// "Copy Link to Highlight" (Chrome) / "Copy Link with Highlight" (WebKit) item, picked with real ↓ and Return, copies
/// a link to the text.
extension SnapshotRunner {
    // MARK: Shared

    /// Real input is possible here: the driver, a dedicated session, and the run acting as the owner's build.
    private var ownerFixesReal: Bool {
        let env = ProcessInfo.processInfo.environment
        return UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
    }

    /// `w` key, in front, on the active Space, Airc active; `done(false)` with a FAIL-ENV line when it can't be.
    private func ownerFront(_ w: NSWindow, _ tag: String, _ done: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        waitUntil({ NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace }, timeout: 6) {
            let ok = NSApp.isActive && w.isKeyWindow && w.isOnActiveSpace
            if !ok {
                self.note("FAIL-ENV \(tag): window not key/active (active=\(NSApp.isActive), key=\(w.isKeyWindow), space=\(w.isOnActiveSpace), "
                          + "front app \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"))")
            }
            done(ok)
        }
    }

    /// One real key combo, PID-targeted at this (foreground) app.
    private func ownerKey(_ combo: String, _ done: @escaping (Bool, String) -> Void) {
        UIDriverClient.press([combo], pid: ProcessInfo.processInfo.processIdentifier, done)
    }

    /// While a menu tracks (its own run loop on the main thread), from a background thread: real keys, one driver
    /// process each (synchronous), and the menu read on the main run loop in common modes.
    private static func syncKey(_ combo: String) -> Bool {
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

    private static func onMain<T>(_ body: @escaping () -> T) -> T? {
        var value: T?
        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { value = body(); sem.signal() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        return sem.wait(timeout: .now() + 2) == .success ? value : nil
    }

    /// A real ⌃-click at `point` (window points of `w`), then, in the root menu it opens, real ↓ until an item whose
    /// title `matches` is highlighted, and Return. `done(picked title or nil, the menu's titles, trace)` on main. The menu
    /// is always closed (Esc) when nothing was picked; the whole step is bounded (watchdog 20 s).
    private func ownerMenuPick(at point: NSPoint, in w: NSWindow, posted: Bool = false, matching matches: @escaping (String) -> Bool,
                               _ done: @escaping (String?, [String], String) -> Void) {
        var trace: [String] = []
        var titles: [String] = []
        var opened: NSMenu?
        var token: NSObjectProtocol?
        var finished = false
        func finish(_ picked: String?) {
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                if let token { NotificationCenter.default.removeObserver(token) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done(picked, titles, trace.joined(separator: " ")) }
            }
        }
        token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
            guard opened == nil, let m = n.object as? NSMenu, m.supermenu == nil, m !== NSApp.mainMenu else { return }
            opened = m
            DispatchQueue.global(qos: .userInitiated).async {
                // WebKit adds its items (willOpenMenu) and Chromium updates its own after tracking begins.
                Thread.sleep(forTimeInterval: 0.5)
                let all: [String] = (Self.onMain { m.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title) } ?? nil) ?? []
                titles = all
                let target: String? = (Self.onMain { m.items.first { !$0.isHidden && matches($0.title) }?.title } ?? nil) ?? nil
                trace.append("menu[\(all.joined(separator: "|"))]")
                guard let target else {
                    _ = Self.syncKey("esc"); _ = Self.syncKey("esc")
                    return finish(nil)
                }
                for _ in 0..<40 {
                    guard Self.syncKey("down") else { trace.append("down failed"); break }
                    let h: String? = (Self.onMain { m.highlightedItem?.title } ?? nil) ?? nil
                    trace.append("↓" + (h ?? "-"))
                    if h == target {
                        let ok = Self.syncKey("return")
                        trace.append(ok ? "⏎" : "⏎ failed")
                        return finish(ok ? target : nil)
                    }
                }
                _ = Self.syncKey("esc"); _ = Self.syncKey("esc")
                finish(nil)
            }
        }
        func clicked(_ ok: Bool, _ out: String) {
            if !ok { trace.append("driver ⌃-click: \(out)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard opened == nil, !finished else { return }
                trace.append("no menu opened (key \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "-"), active \(NSApp.isActive))")
                finish(nil)
            }
        }
        if posted {
            trace.append("posted right-click")
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .rightMouseDown ? 1 : 0) { NSApp.postEvent(e, atStart: false) }
            }
            clicked(true, "")
        } else {
            UIDriverClient.click(point, in: w, mods: "ctrl", clicked)
        }
        // The step's own bound: a menu left open would hold the UI.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            guard (Self.onMain { finished } ?? false) == false else { return }
            _ = Self.syncKey("esc"); _ = Self.syncKey("esc")
            trace.append("menu step watchdog (20 s)")
            finish(nil)
        }
    }

    // MARK: ownerfs

    func ownerFullScreenScenario() {
        let tag = "ownerfs"
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "\(tag) \(engine): " + s }
        var server: LocalPageServer?
        var base = ""
        var tabA = "", tabB = "", favItem = "", folder = ""
        let source = c!
        let real = ownerFixesReal
        func controllers() -> [WindowController] { app?.controllers ?? [] }
        func screenSize(_ w: NSWindow) -> NSSize { (w.screen ?? NSScreen.main)?.frame.size ?? .zero }

        step { [self] done in
            let page = { (t: String) in "<!doctype html><title>\(t)</title><body style='font:16px -apple-system;margin:60px'><p>\(t)</p>" }
            server = LocalPageServer(pages: ["/a": page("fs A"), "/b": page("fs B")])
            server?.start { port in
                guard let port else { self.check(false, label("a loopback page server")); return done() }
                base = "http://127.0.0.1:\(port)"
                let s = source.store
                let space = source.currentSpaceID
                tabB = (try? s.openTab(url: base + "/b", inSpace: space, title: "fs B").id) ?? ""
                tabA = (try? s.openTab(url: base + "/a", inSpace: space, title: "fs A").id) ?? ""
                _ = try? s.move(.tab(tabA), to: .today(spaceID: space, index: 0))
                _ = try? s.move(.tab(tabB), to: .today(spaceID: space, index: 1))
                if let f = try? s.openTab(url: base + "/b?fav", inSpace: space, title: "fs Fav") {
                    try? s.move(.tab(f.id), to: .favorites(profileID: s.selectedSpace.profileID, index: 0))
                    favItem = s.tab(f.id)?.itemID ?? ""
                }
                folder = (try? s.createFolder(named: "fs Folder", inSpace: space).id) ?? ""
                source.reloadAll(animated: false)
                source.show(tabA, focus: false)
                done()
            }
        }
        guard real else {
            run { [self] in
                note("FAIL-ENV \(label("real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1, AIRC_LA_AS_OWNER=1 and the stable UI driver"))")
                server?.stop()
            }
            return
        }
        run { [self] in note(label("keyboard layout \(UIDriverClient.layoutName), engine \(engine)")) }

        /// Closes `w` (a check's window, posted: not what's under test) and waits for the source to be back in front.
        func closeAndReturn(_ w: NSWindow?, _ done: @escaping () -> Void) {
            if let cb = controllers().first(where: { $0.window === w }), cb.commandBar != nil { cb.closeCommandBar() }
            w?.performClose(nil)
            waitUntil({ w?.isVisible != true && source.window.isOnActiveSpace }, timeout: 8) {
                self.ownerFront(source.window, tag) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: done) }
            }
        }

        /// A new window from full screen: in native full screen, its own Space, key, normal level, a windowed frame.
        func assertFullScreenWindow(_ w: NSWindow?, _ what: String) {
            guard let w else { return check(false, label("\(what): a new window opens")) }
            let windowed = NewWindowFullScreen.windowedFrame(of: w), screen = screenSize(w)
            check(w.styleMask.contains(.fullScreen), label("\(what): the new window is in native full screen"))
            check(w.isOnActiveSpace && !source.window.isOnActiveSpace,
                  label("\(what): it is on a Space of its own (new window on the active Space \(w.isOnActiveSpace), source \(source.window.isOnActiveSpace))"))
            check(w.isKeyWindow && NSApp.isActive, label("\(what): it is the key window (key \(w.isKeyWindow), active \(NSApp.isActive))"))
            check(w.level == .normal && w.collectionBehavior.contains(.fullScreenPrimary) && !w.collectionBehavior.contains(.fullScreenAuxiliary),
                  label("\(what): a primary full-screen window at the normal level, not a panel over the Space (level \(w.level.rawValue))"))
            check(windowed.width < screen.width - 20 && windowed.height < screen.height - 20,
                  label("\(what): out of full screen it is a normal window (\(NSStringFromRect(windowed)) on a \(NSStringFromSize(screen)) screen)"))
        }

        /// A sidebar view of `source`: a row by its entry ID, or the Favorite tile of `item`.
        func sidebarView(_ id: String, favorite: Bool = false) -> NSView? {
            guard let page = source.pageView(for: source.currentSpaceID) else { return nil }
            page.layoutSubtreeIfNeeded()
            if favorite { return page.favorites.subviews.compactMap { $0 as? FavoriteTileView }.first { $0.item?.id == id } }
            return page.rows[id]
        }
        func center(_ v: NSView) -> NSPoint { v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
        /// A real ⌃-click on `view` opens a context menu with `item` (closed with real Esc), and the press selects,
        /// activates and closes nothing.
        func controlClick(_ what: String, _ view: @escaping () -> NSView?, item: String, or other: String? = nil, at point: ((NSView) -> NSPoint)? = nil) {
            step { [self] done in
                ownerFront(source.window, tag) { ok in
                    guard ok else { return done() }
                    guard let v = view() else { self.check(false, label("⌃-click \(what): it is in the sidebar")); return done() }
                    let p = point?(v) ?? center(v)
                    let shown = source.shownTabID, tabs = source.store.state.tabs.count
                    self.ownerMenuPick(at: p, in: source.window, matching: { _ in false }) { _, titles, trace in
                        self.note(label("⌃-click \(what): \(trace)"))
                        let selection = source.pageView(for: source.currentSpaceID)?.selection ?? []
                        self.check(titles.contains(item) || other.map(titles.contains) == true, label("a real ⌃-click on \(what) opens its context menu, as a right-click (with “\(item)”: \(titles.prefix(8).joined(separator: " | ")))"))
                        self.check(source.shownTabID == shown && selection.isEmpty && source.store.state.tabs.count == tabs && source.app?.controllers.count == 1,
                                   label("⌃-click \(what): nothing is selected, shown, closed or dragged out (shown kept \(source.shownTabID == shown), selection \(selection.count))"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)   // past the double-click interval
                    }
                }
            }
        }
        controlClick("a tab row", { sidebarView(tabB) }, item: "Move to New Window")
        controlClick("a Favorite", { sidebarView(favItem, favorite: true) }, item: "Remove Favorite", or: "Remove from Favorites")
        controlClick("a folder", { sidebarView(folder) }, item: "Rename…")
        // A row's ✕ (shown under a resting pointer): its row's menu, never a close.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok, let row = sidebarView(tabB) else { return done() }
                UIDriverClient.hover(NSPoint(x: center(row).x + row.bounds.width / 2 - 14, y: center(row).y), in: source.window, dwell: 300) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        controlClick("a tab row's ✕", { sidebarView(tabB) }, item: "Move to New Window", at: { row in
            let buttons = row.subviews.compactMap { $0 as? GlyphButton }.filter { !$0.isHidden }
            guard let x = buttons.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return center(row) }
            return x.convert(NSPoint(x: x.bounds.midX, y: x.bounds.midY), to: nil)
        })
        run { [self] in check(source.store.tab(tabB) != nil, label("⌃-click on a row's ✕: the tab is still open")) }

        // The source window in native full screen, by a real ⌃⌘F.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok else { return done() }
                self.ownerKey("ctrl+cmd+f") { ok, out in
                    if !ok { self.note("FAIL-ENV \(label("driver ⌃⌘F: \(out)"))") }
                    self.waitUntil({ source.window.styleMask.contains(.fullScreen) && source.isFullscreen }, timeout: 8) {
                        self.check(source.window.styleMask.contains(.fullScreen), label("a real ⌃⌘F puts the window in native full screen"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done)   // past the Space animation
                    }
                }
            }
        }

        // ⌘N.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok else { return done() }
                let before = controllers(), requests = NewWindowFullScreen.requests
                self.ownerKey("cmd+n") { ok, out in
                    if !ok { self.note("FAIL-ENV \(label("driver ⌘N: \(out)"))") }
                    func made() -> WindowController? { controllers().first { c in !before.contains { $0 === c } } }
                    self.waitUntil({ made().map { $0.window.styleMask.contains(.fullScreen) && $0.window.isOnActiveSpace && $0.window.isKeyWindow } == true },
                                   timeout: 10) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let w = made()
                            self.check(NewWindowFullScreen.requests == requests + 1, label("⌘N: the new window was sent into full screen once"))
                            assertFullScreenWindow(w?.window, "⌘N")
                            self.check(w?.commandBar != nil, label("⌘N: the new window opens with the Command Bar, as before"))
                            self.check(source.window.styleMask.contains(.fullScreen), label("⌘N: the source window stays in full screen"))
                            closeAndReturn(w?.window, done)
                        }
                    }
                }
            }
        }

        // ⌘⇧N.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok else { return done() }
                let before = PrivateBrowsing.shared.windows
                self.ownerKey("cmd+shift+n") { ok, out in
                    if !ok { self.note("FAIL-ENV \(label("driver ⌘⇧N: \(out)"))") }
                    func made() -> PrivateWindowController? { PrivateBrowsing.shared.windows.first { p in !before.contains { $0 === p } } }
                    self.waitUntil({ made().map { $0.window.styleMask.contains(.fullScreen) && $0.window.isOnActiveSpace && $0.window.isKeyWindow } == true },
                                   timeout: 12) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let w = made()
                            assertFullScreenWindow(w?.window, "⌘⇧N (private window)")
                            self.check(source.window.styleMask.contains(.fullScreen), label("⌘⇧N: the source window stays in full screen"))
                            closeAndReturn(w?.window, done)
                        }
                    }
                }
            }
        }

        // Move to New Window: a real ⌃-click on the tab's row, real ↓ and Return.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok else { return done() }
                source.show(tabA, focus: false)
                guard let page = source.pageView(for: source.currentSpaceID) else { self.check(false, label("the sidebar's page")); return done() }
                page.layoutSubtreeIfNeeded()
                guard let row = page.rows[tabB] else { self.check(false, label("Move to New Window: tab B's row is in the sidebar")); return done() }
                let p = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
                let before = controllers()
                self.ownerMenuPick(at: p, in: source.window, matching: { $0 == "Move to New Window" }) { picked, titles, trace in
                    self.note(label("row menu: \(trace)"))
                    self.check(picked != nil, label("in full screen, a real ⌃-click on a tab's row opens its menu, and real ↓ Return pick Move to New Window"))
                    func made() -> WindowController? { controllers().first { c in !before.contains { $0 === c } } }
                    self.waitUntil({ made().map { $0.window.styleMask.contains(.fullScreen) && $0.window.isOnActiveSpace && $0.window.isKeyWindow } == true },
                                   timeout: 10) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let w = made()
                            assertFullScreenWindow(w?.window, "Move to New Window")
                            self.check(w?.shownTabID == tabB && !source.visibleTabIDs.contains(tabB),
                                       label("Move to New Window: the new window shows the tab, and the source doesn't"))
                            closeAndReturn(w?.window, done)
                        }
                    }
                }
            }
        }

        // Out of full screen (a real ⌃⌘F), ⌘N is an ordinary window on the same Space, as before.
        step { [self] done in
            ownerFront(source.window, tag) { ok in
                guard ok else { return done() }
                self.ownerKey("ctrl+cmd+f") { _, _ in
                    self.waitUntil({ !source.window.styleMask.contains(.fullScreen) && !source.isFullscreen }, timeout: 8) {
                        self.check(!source.window.styleMask.contains(.fullScreen), label("a real ⌃⌘F leaves full screen"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.ownerFront(source.window, tag) { ok in
                                guard ok else { return done() }
                                let before = controllers(), requests = NewWindowFullScreen.requests
                                self.ownerKey("cmd+n") { _, _ in
                                    func made() -> WindowController? { controllers().first { c in !before.contains { $0 === c } } }
                                    self.waitUntil({ made()?.window.isKeyWindow == true }, timeout: 8) {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            let w = made()?.window
                                            self.check(w != nil && w?.styleMask.contains(.fullScreen) == false && NewWindowFullScreen.requests == requests,
                                                       label("windowed ⌘N: an ordinary window, not full screen (full \(w?.styleMask.contains(.fullScreen) ?? false))"))
                                            self.check(w?.isOnActiveSpace == true && source.window.isOnActiveSpace && w?.isKeyWindow == true,
                                                       label("windowed ⌘N: on the same Space as the source, key"))
                                            closeAndReturn(w, done)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        run { [self] in
            if source.window.styleMask.contains(.fullScreen) { source.window.toggleFullScreen(nil) }
            server?.stop()
        }
        wait(1.5)
    }

    // MARK: ownerquote

    func ownerQuoteScenario() {
        let tag = "ownerquote"
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "\(tag) \(engine): " + s }
        var server: LocalPageServer?
        var base = ""
        var tab = "", opened = ""
        var selection = ""
        var want = ""
        let board = NSPasteboard(name: NSPasteboard.Name("airc.ownerquote.\(getpid())"))
        let oldLinkBoard = WindowController.linkPasteboard
        let general = NSPasteboard.general
        let generalBefore = general.string(forType: .string)
        let real = ownerFixesReal
        let sentence = "Quiet harbours keep their lanterns lit long after the ferries stop"
        func page() -> EngineTab? { c.engineTab(for: tab) }

        step { [self] done in
            let html = "<!doctype html><title>quote</title><style>body{margin:0;font:22px -apple-system,sans-serif}"
                + "::target-text{background-color:rgb(0,200,0);color:rgb(0,200,0)}</style>"
                + "<div style='height:2600px'></div><p id=q style='margin:0 80px;line-height:40px'>\(sentence).</p>"
                + "<div style='height:2600px'></div>"
            server = LocalPageServer(pages: ["/quote": html])
            server?.start { port in
                guard let port else { self.check(false, label("a loopback page server")); return done() }
                base = "http://127.0.0.1:\(port)"
                tab = (try? self.c.store.openTab(url: base + "/quote", inSpace: self.c.currentSpaceID, title: "quote").id) ?? ""
                WindowController.linkPasteboard = board
                self.app?.settings.values.sharedQuotes = true
                self.c.show(tab, focus: true)
                self.waitUntil({ page()?.isLoading == false && page()?.title == "quote" }, timeout: 10) { done() }
            }
        }
        guard real else {
            run { [self] in
                note("FAIL-ENV \(label("real input needs AIRC_UI_DEDICATED_SESSION=1, AIRC_REAL_KEYS=1, AIRC_LA_AS_OWNER=1 and the stable UI driver"))")
                WindowController.linkPasteboard = oldLinkBoard
                server?.stop()
            }
            return
        }

        /// The sentence's text on screen, in window points: its first and last line's ends (left, right) at mid-line.
        var start = NSPoint.zero, end = NSPoint.zero, middle = NSPoint.zero
        func locate() {
            step { [self] done in
                c.root.layoutSubtreeIfNeeded()
                guard let view = page()?.view else { check(false, label("the page's view")); return done() }
                let js = "(function(){var p=document.getElementById('q');p.scrollIntoView({block:'center'});getSelection().removeAllRanges();"
                    + "var r=document.createRange();r.selectNodeContents(p.firstChild);var b=r.getClientRects();var f=b[0],l=b[b.length-1];"
                    + "return [f.left+3,(f.top+f.bottom)/2,l.right-14,(l.top+l.bottom)/2]})()"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    page()?.evaluate(js) { v in
                        // Let the scroll paint before the drag.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            page()?.evaluate(js) { v2 in
                                let xy = ((v2 ?? v) as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                                if xy.count == 4 {
                                    func pt(_ x: Double, _ y: Double) -> NSPoint {
                                        view.convert(NSPoint(x: x, y: view.isFlipped ? y : Double(view.bounds.height) - y), to: nil)
                                    }
                                    start = pt(xy[0], xy[1]); end = pt(xy[2], xy[3])
                                    middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                                    self.note(label("text from \(NSStringFromPoint(start)) to \(NSStringFromPoint(end))"))
                                } else {
                                    self.check(false, label("the sentence is on screen (\(String(describing: v2)))"))
                                }
                                done()
                            }
                        }
                    }
                }
            }
        }
        /// A real drag across the sentence; `selection` is what the page has selected after it.
        func dragSelect() {
            step { [self] done in
                ownerFront(c.window, tag) { ok in
                    guard ok, start != .zero, let primary = NSScreen.screens.first else { return done() }
                    func cg(_ p: NSPoint) -> NSPoint { let s = self.c.window.convertPoint(toScreen: p); return NSPoint(x: s.x, y: primary.frame.maxY - s.y) }
                    let a = cg(start), b = cg(end)
                    UIDriverClient.run(["--drag", String(Double(a.x)), String(Double(a.y)), String(Double(b.x)), String(Double(b.y))]) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver drag: \(out)"))") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            page()?.evaluate("String(getSelection())") { v in
                                selection = (v as? String) ?? ""
                                self.check(selection.split(separator: " ").count >= 4 && sentence.contains(selection.trimmingCharacters(in: .whitespaces)),
                                           label("a real drag selects the sentence's words (\"\(selection)\")"))
                                self.check(self.c.focusedPage.map { ObjectIdentifier($0 as AnyObject) } == page().map { ObjectIdentifier($0 as AnyObject) }, label("the page has the focus after the drag"))
                                done()
                            }
                        }
                    }
                }
            }
            wait(0.8)   // past the double-click interval
        }

        // 1. Real ⌘C → the offer → a real click on Copy Link.
        locate()
        dragSelect()
        step { [self] done in
            c.quoteLinkOffer?.hide()
            let before = general.changeCount
            ownerKey("cmd+c") { ok, out in
                if !ok { self.note("FAIL-ENV \(label("driver ⌘C: \(out)"))") }
                self.waitUntil({ self.c.quoteLinkOffer?.isHidden == false }, timeout: 4) {
                    let copied = general.changeCount != before ? general.string(forType: .string) ?? "" : ""
                    self.check(!copied.isEmpty && copied.trimmingCharacters(in: .whitespacesAndNewlines) == selection.trimmingCharacters(in: .whitespacesAndNewlines),
                               label("a real ⌘C copies the page's selection (\"\(copied)\")"))
                    let offer = self.c.quoteLinkOffer
                    // The selection ends inside a word ("…ferries sto"): the link takes whole words (a text fragment only
                    // matches at word boundaries).
                    let sentenceWords = Set(sentence.split(separator: " ").map(String.init))
                    let start = sentence.range(of: selection.trimmingCharacters(in: .whitespaces))
                    let whole = start.map { r -> String in
                        var lo = r.lowerBound, hi = r.upperBound
                        while lo > sentence.startIndex, sentence[sentence.index(before: lo)] != " " { lo = sentence.index(before: lo) }
                        while hi < sentence.endIndex, sentence[hi] != " " { hi = sentence.index(after: hi) }
                        return String(sentence[lo..<hi])
                    } ?? selection
                    want = LinkCopyPolicy.textFragmentURL(base + "/quote", selection: whole) ?? "-"
                    let fragment = want.components(separatedBy: "#:~:text=").last?.removingPercentEncoding ?? ""
                    self.check(fragment.split(whereSeparator: { $0 == " " || $0 == "," }).allSatisfy { sentenceWords.contains(String($0)) },
                               label("the link's text is whole words (\"\(fragment)\")"))
                    self.check(offer?.isHidden == false && offer?.label.stringValue == QuoteLinkOfferView.message,
                               label("after the real ⌘C, \"\(QuoteLinkOfferView.message)\" shows"))
                    self.check(offer?.link == want && want.contains("#:~:text="), label("its link is the page's link to that text (\(offer?.link ?? "-"))"))
                    guard let button = offer?.button, offer?.isHidden == false else { return done() }
                    let p = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let linkBefore = board.changeCount
                    guard let primary = NSScreen.screens.first else { return done() }
                    let s = self.c.window.convertPoint(toScreen: p)
                    // A plain click: the driver refuses an empty --mods.
                    UIDriverClient.run(["--click", String(Double(s.x)), String(Double(primary.frame.maxY - s.y))]) { ok, out in
                        if !ok { self.note("FAIL-ENV \(label("driver click on Copy Link: \(out)"))") }
                        self.waitUntil({ board.changeCount != linkBefore }, timeout: 3) {
                            self.check(board.string(forType: .string) == want && self.c.toast.shownText == "Copied a link to this text",
                                       label("a real click on Copy Link copies the link (\(board.string(forType: .string) ?? "-")) and says so"))
                            done()
                        }
                    }
                }
            }
        }
        // 2. The link, opened in a tab, scrolls to the text and highlights it.
        step { [self] done in
            guard want.contains("#:~:text=") else { check(false, label("a link to open")); return done() }
            opened = (try? c.store.openTab(url: want, inSpace: c.currentSpaceID, title: "quote link").id) ?? ""
            c.show(opened, focus: true)
            let p = { self.c.engineTab(for: opened) }
            waitUntil({ p()?.isLoading == false && p()?.title == "quote" }, timeout: 10) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    p()?.evaluate("[window.scrollY, document.getElementById('q').getBoundingClientRect().top, innerHeight]") { v in
                        let n = (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                        self.check(n.count == 3 && n[0] > 1500 && n[1] >= 0 && n[1] < n[2],
                                   label("the opened link scrolls to the text (scrollY, top, height: \(n))"))
                        p()?.snapshot { image in
                            var green = 0, total = 0
                            var probe = "-"
                            if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let rep = Optional(NSBitmapImageRep(cgImage: cg)) {
                                total = rep.pixelsWide * rep.pixelsHigh
                                try? rep.representation(using: .png, properties: [:])?.write(to: self.dir.appendingPathComponent("ownerquote-opened.png"))
                                // The colour where the text is (its top, from the page, in the snapshot's pixels).
                                if n.count == 3, n[2] > 0 {
                                    let scale = Double(rep.pixelsHigh) / n[2]
                                    let y = Int((n[1] + 20) * scale), x = Int(100 * scale)
                                    if y >= 0, y < rep.pixelsHigh, x < rep.pixelsWide, let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                                        probe = String(format: "%.2f,%.2f,%.2f at %d,%d of %dx%d", col.redComponent, col.greenComponent, col.blueComponent, x, y, rep.pixelsWide, rep.pixelsHigh)
                                    }
                                }
                                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                                    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                                        guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                                        // Strongly green: the page's rgb(0,200,0) comes back as (0.41, 0.80, 0.29) from Chromium's snapshot, whose
                                        // pixels are in another colour space (WebKit's: 0, 0.80, 0).
                                        if col.greenComponent > 0.6, col.greenComponent - col.redComponent > 0.25, col.greenComponent - col.blueComponent > 0.3 { green += 1 }
                                    }
                                }
                            }
                            self.check(green > 200, label("and highlights it (::target-text pixels in the page's snapshot: \(green) of \(total / 4) sampled; at the text \(probe))"))
                            done()
                        }
                    }
                }
            }
        }
        // 3. The page menu's Copy Link to Highlight, by a real ⌃-click on the selection and real ↓ Return.
        run { [self] in
            if !opened.isEmpty { _ = try? c.store.closeTab(opened) }
            c.show(tab, focus: true)
        }
        wait(0.8)
        locate()
        dragSelect()
        step { [self] done in
            ownerFront(c.window, tag) { ok in
                guard ok, middle != .zero else { return done() }
                let before = general.changeCount
                self.ownerMenuPick(at: middle, in: self.c.window, matching: { $0.range(of: "Link to Highlight", options: .caseInsensitive) != nil
                    || $0.range(of: "Link with Highlight", options: .caseInsensitive) != nil }) { picked, titles, trace in
                    self.note(label("page menu: \(trace)"))
                    self.check(picked != nil, label("a real ⌃-click on selected text opens the page menu with a Copy Link to Highlight item, picked by real ↓ Return "
                                                    + "(\(picked ?? "none of " + titles.joined(separator: " | ")))"))
                    guard picked != nil else { return done() }
                    self.waitUntil({ general.changeCount != before && (general.string(forType: .string) ?? "").contains("#:~:text=") }, timeout: 5) {
                        let link = general.string(forType: .string) ?? ""
                        let words = selection.split(separator: " ").prefix(2).joined(separator: "%20")
                        self.check(link.hasPrefix(base + "/quote#:~:text=") && link.contains(words),
                                   label("it copies a link to the selected text (\(link))"))
                        done()
                    }
                }
            }
        }
        run { [self] in
            WindowController.linkPasteboard = oldLinkBoard
            general.clearContents()
            if let generalBefore { general.setString(generalBefore, forType: .string) }
            board.releaseGlobally()
            server?.stop()
        }
    }
}
#endif
