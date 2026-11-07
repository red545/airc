// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircDesign
import AircKit

/// `--script windows` (WIN-7, Browser/MultiWindow.swift) on loopback pages, both engines: ⌘N opens a second window with
/// the sidebar; each window keeps its own Space and tab; a tab picked in one window that another shows moves its page
/// (no reload) and leaves "Open in another window" there; ⌘W and ⇧⌘W act on the window the key is for; the last
/// window closes with Airc still running and comes back; links from other apps (real GURL Apple events) go to the
/// window used last, or open one. Then (multiwindow2) the titles, a tab dragged out of the sidebar (posted drags, both
/// sidebar sides) into a new window and onto another window's sidebar, and ⌃⌘N's blank window. `windows-write` /
/// `windows-read`: four windows survive a relaunch (frames, Spaces, tabs, sidebar widths, which one was used last, the
/// one whose page was in another window, and a blank window with its own tab).
extension SnapshotRunner {
    private final class WindowsState {
        var server: LocalPageServer?
        var base = ""
        var home = "", work = ""
        var tabs: [String: String] = [:]   // page name → tab ID
        weak var w1: WindowController?
        weak var w2: WindowController?
        weak var closed: WindowController?
        var marker = ""
        var page: EngineTab?
        var linkTabs: Set<String> = []
    }

    private static let windowsPages: [String: String] = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d", "e", "f", "g"].map { n in
        ("/\(n).html", "<!doctype html><title>Page \(n.uppercased())</title><body style='font:40px -apple-system;padding:40px'>Page \(n.uppercased())"
            + "<script>window.__mw = String(Math.random()).slice(2)</script>")
    })

    /// A key as the keyboard sends it to `window` (the app's key monitor routes it by the event's window).
    func postWindowKey(_ chars: String, code: UInt16, mods: NSEvent.ModifierFlags, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            NSApp.postEvent(e, atStart: false)
        }
    }

    /// ⌘N through the main menu (the menu bar's item; no window need be key).
    @discardableResult
    func menuNewWindow() -> Bool {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n",
                                       isARepeat: false, keyCode: 45) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
    }

    private func windowsSetUp(_ s: WindowsState, pages names: [(String, String)]) {
        step { [self] done in
            s.server = LocalPageServer(pages: Self.windowsPages)
            s.server?.start { port in
                guard let port else { self.check(false, "windows: the loopback page server starts"); return self.finish() }
                s.base = "http://127.0.0.1:\(port)"
                let store = self.c.store
                s.home = store.selectedSpace.id
                try? store.updateSpace(s.home) { $0.name = "Home" }
                s.work = (try? store.createSpace(name: "Work", icon: .emoji("💼"), theme: DesignTheme.preset("sky")!.model,
                                                 profileID: store.selectedSpace.profileID, after: s.home))?.id ?? ""
                for (name, space) in names {
                    if let t = try? store.openTab(url: s.base + "/\(name).html", inSpace: space == "work" ? s.work : s.home) { s.tabs[name] = t.id }
                }
                s.w1 = self.c
                self.c.switchToSpace(s.home, animated: false)
                self.c.show(s.tabs["a"] ?? "", focus: false)
                done()
            }
        }
        waitForPage()
    }

    private func pageMarker(_ page: EngineTab?, _ done: @escaping (String) -> Void) {
        guard let page else { return done("") }
        page.evaluate("window.__mw || ''") { done(($0 as? String) ?? "") }
    }

    func windowsScenario() {
        let s = WindowsState()
        windowsSetUp(s, pages: [("a", "home"), ("b", "home"), ("c", "work"), ("d", "work")])

        // ⌘N: a second window on this Space, with the sidebar and the Command Bar, the empty Space behind it.
        step { [self] done in
            guard let w1 = s.w1 else { return done() }
            note("windows: \(app?.engine.name ?? "?"), window 1 key \(w1.window.isKeyWindow)")
            postWindowKey("n", code: 45, mods: .command, to: w1.window)
            waitUntil({ (self.app?.controllers.count ?? 0) >= 2 }, timeout: 3) {
                let w2 = self.app?.controllers.first(where: { $0 !== w1 })
                s.w2 = w2
                self.check(w2 != nil, "windows: ⌘N opens a second browser window")
                guard let w2 else { return done() }
                self.check(w2.window.isVisible && w2.sidebar.frame.width >= 160 && w2.sidebarFraction == 1,
                           "windows: the new window has the sidebar (width \(Int(w2.sidebar.frame.width)), visible \(w2.window.isVisible))")
                self.check(w2.currentSpaceID == w1.currentSpaceID && w2.shownTabID == nil,
                           "windows: the new window is on the same Space with no tab yet (shows \(w2.shownTabID ?? "none"))")
                self.check(w2.commandBar != nil, "windows: the new window opens the Command Bar, as ⌘T")
                let dx = w2.window.frame.minX - w1.window.frame.minX, dy = w2.window.frame.maxY - w1.window.frame.maxY
                self.check(w2.window.frame.size == w1.window.frame.size && dx > 0 && dy < 0,
                           "windows: it cascades from the first window, same size (offset \(Int(dx)), \(Int(dy)))")
                self.check(self.app?.controller === w2, "windows: the new window is the one used last")
                self.check(w1.shownTabID == s.tabs["a"] && w1.engineTab(for: s.tabs["a"] ?? "") != nil,
                           "windows: the first window keeps its tab")
                w2.closeCommandBar()
                done()
            }
        }
        capture("windows-new")
        // The menu bar's New Window (no key window: the window used last).
        step { [self] done in
            let before = app?.controllers.count ?? 0
            let handled = menuNewWindow()
            waitUntil({ (self.app?.controllers.count ?? 0) > before }, timeout: 3) {
                self.check((self.app?.controllers.count ?? 0) == before + 1, "windows: File › New Window opens another (handled \(handled))")
                guard let w3 = self.app?.controller, w3 !== s.w1, w3 !== s.w2 else { return done() }
                s.closed = w3
                w3.window.performClose(nil)
                self.waitUntil({ (self.app?.controllers.count ?? 0) == before }, timeout: 4) {
                    self.check((self.app?.controllers.count ?? 0) == before, "windows: the third window closes")
                    done()
                }
            }
        }
        wait(1)
        run { [self] in
            if s.closed == nil { note("windows: the closed window was freed") } else { note("windows: note: the closed window is still in memory") }
        }

        // Each window its own Space and tab.
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let c = s.tabs["c"] else { return done() }
            w2.switchToSpace(s.work, animated: false)
            w2.show(c, focus: false)
            waitUntil({ w2.engineTab(for: c)?.isLoading == false }, timeout: 8) {
                self.check(w1.currentSpaceID == s.home && w1.shownTabID == s.tabs["a"],
                           "windows: window 1 stays on Home with page A")
                self.check(w2.currentSpaceID == s.work && w2.shownTabID == c && w2.engineTab(for: c) != nil && w1.engineTab(for: c) == nil,
                           "windows: window 2 is on Work with page C, its page in window 2 only")
                // Window 1 to Work: page C is on screen in window 2, so window 1 doesn't take it.
                w1.switchToSpace(s.work, animated: false)
                self.check(w1.currentSpaceID == s.work && w1.shownTabID != c && w2.visibleTabIDs.contains(c),
                           "windows: window 1 on Work leaves C to window 2 (shows \(w1.shownTabID.map { id in s.tabs.first(where: { $0.value == id })?.key ?? id } ?? "the empty Space"))")
                w1.switchToSpace(s.home, animated: false)
                self.check(w1.shownTabID == s.tabs["a"] && w1.multiWindow.elsewhereTabID == nil,
                           "windows: window 1 back on Home shows its own tab A")
                w2.switchToSpace(s.home, animated: false)
                self.check(w2.shownTabID != s.tabs["a"] && w1.visibleTabIDs.contains(s.tabs["a"] ?? ""),
                           "windows: window 2 on Home doesn't take A from window 1")
                w2.switchToSpace(s.work, animated: false)
                self.check(w2.shownTabID == c, "windows: window 2 back on Work shows its own tab C")
                done()
            }
        }
        capture("windows-spaces")

        // A tab another window shows: picking it moves its live page (no reload); the other window says where it went.
        step { [self] done in
            guard let w1 = s.w1, let a = s.tabs["a"] else { return done() }
            s.page = w1.engineTab(for: a)
            pageMarker(s.page) { m in s.marker = m; done() }
        }
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let a = s.tabs["a"], let tab = c.store.tab(a) else { return done() }
            w2.switchToSpace(s.home, animated: false)
            w2.activate(entry: .today(tab))
            let page = w2.engineTab(for: a)
            check(w2.shownTabID == a && page != nil && page === s.page,
                  "windows: picking A in window 2 moves its page there (the same page: \(page === s.page))")
            check(w1.engineTab(for: a) == nil && w1.multiWindow.elsewhereTabID == a && w1.shownTabID == a,
                  "windows: window 1 keeps A selected and says it's open in another window")
            check(w1.multiWindow.elsewhereView?.isHidden == false && w1.multiWindow.elsewhereView?.title == "Page A",
                  "windows: window 1's card shows “Open in another window” (\(w1.multiWindow.elsewhereView?.title ?? "none"))")
            pageMarker(page) { m in
                self.check(!s.marker.isEmpty && m == s.marker, "windows: the moved page didn't reload (marker \(s.marker) → \(m))")
                self.check(page?.url?.absoluteString == s.base + "/a.html", "windows: the moved page keeps its address")
                done()
            }
        }
        step { [self] done in
            // Window 1 in front for the picture of its card.
            if let w1 = s.w1 { app?.browserWindowBecameKey(w1) }
            done()
        }
        capture("windows-elsewhere")
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let a = s.tabs["a"] else { return done() }
            w1.showHere()
            check(w1.engineTab(for: a) === s.page && w1.multiWindow.elsewhereTabID == nil && w2.multiWindow.elsewhereTabID == a,
                  "windows: Show Here brings A back to window 1; window 2 now says it's elsewhere")
            // A Space switch never takes it: window 2 to Work and back keeps "Open in another window".
            w2.switchToSpace(s.work, animated: false)
            w2.switchToSpace(s.home, animated: false)
            check(w1.engineTab(for: a) === s.page && w2.multiWindow.elsewhereTabID == a,
                  "windows: window 2's Space switch back to Home doesn't take A (it shows the placeholder)")
            // Become key with A no longer on screen in window 1: it comes back to window 2 by itself.
            w1.show(s.tabs["b"] ?? "", focus: false)
            app?.browserWindowBecameKey(w2)
            check(w2.engineTab(for: a) === s.page && w2.multiWindow.elsewhereTabID == nil,
                  "windows: window 2 becoming key takes A back once window 1 shows another tab")
            w2.switchToSpace(s.work, animated: false)
            w1.show(a, focus: false)
            done()
        }
        waitForPage()
        #if canImport(AircCore)
        if app?.engine is ChromiumEngine { windowsChromiumMoves(s) }
        #endif
        windowsTitles(s)
        windowsDragOut(s)
        windowsBlank(s)
        windowsProfileKeeper(s)

        // ⌘W and ⇧⌘W act on the window the key is for.
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let c = s.tabs["c"] else { return done() }
            check(w2.shownTabID == c, "windows: window 2 shows C before ⌘W")
            postWindowKey("w", code: 13, mods: .command, to: w2.window)
            waitUntil({ self.c.store.tab(c) == nil }, timeout: 3) {
                self.check(self.c.store.tab(c) == nil && w1.shownTabID == s.tabs["a"] && self.c.store.tab(s.tabs["a"] ?? "") != nil,
                           "windows: ⌘W in window 2 archives its tab C, window 1's A stays")
                self.check(w2.shownTabID == s.tabs["d"], "windows: window 2 goes on to D (shows \(w2.shownTabID ?? "none"))")
                done()
            }
        }
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2 else { return done() }
            let d = s.tabs["d"] ?? ""
            postWindowKey("W", code: 13, mods: [.command, .shift], to: w2.window)
            waitUntil({ (self.app?.controllers.count ?? 0) == 1 }, timeout: 4) {
                self.check(self.app?.controllers.count == 1 && self.app?.controller === w1 && w1.window.isVisible,
                           "windows: ⇧⌘W closes window 2 only")
                self.check(self.c.store.tab(d) != nil, "windows: closing a window keeps its tabs (D is still in Work)")
                done()
            }
        }
        wait(1)
        run { [self] in check(s.w2 == nil, "windows: the closed window is freed (its pages with it)") }

        // The last window closes; Airc stays; the Dock brings the window back as it was.
        step { [self] done in
            guard let w1 = s.w1 else { return done() }
            w1.window.performClose(nil)
            waitUntil({ self.app?.controllers.isEmpty == true }, timeout: 4) {
                self.check(self.app?.controllers.isEmpty == true && self.app?.controller == nil,
                           "windows: the last window closes and Airc keeps running")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    _ = self.app?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
                    let w = self.app?.controller
                    self.check(self.app?.controllers.count == 1 && w?.currentSpaceID == s.home && w?.shownTabID == s.tabs["a"],
                               "windows: a click on the Dock icon brings it back on Home with A")
                    s.w1 = w
                    done()
                }
            }
        }
        waitForPage()
        // Its page loads again, in its profile (Chromium keeps profiles only while a browser window has them).
        step { [self] done in
            let page = s.w1.flatMap { w in w.shownTabID.flatMap { w.engineTab(for: $0) } }
            guard let page else { check(false, "windows: the reopened window has a page"); return done() }
            page.evaluate("document.title") { title in
                self.check((title as? String) == "Page A", "windows: the reopened window's page loads (title \(title as? String ?? "none"))")
                done()
            }
        }

        // Links from other apps (GURL Apple events): to the window used last, as a tab ("Most recent Space").
        step { [self] done in
            guard let w1 = s.w1, let app else { return done() }
            app.settings.values.externalLinks = .recentSpace
            s.w2 = app.openNewWindow(from: w1, spaceID: s.work, tab: .spaceLast, commandBar: false)
            let before = Set(c.store.state.tabs.keys)
            let err = Self.sendGetURLEvent(URL(string: s.base + "/e.html")!)
            waitUntil({ Set(self.c.store.state.tabs.keys).subtracting(before).count == 1 }, timeout: 5) {
                let new = Set(self.c.store.state.tabs.keys).subtracting(before).first
                self.check(new != nil && s.w2?.shownTabID == new && w1.shownTabID == s.tabs["a"],
                           "windows: a link from another app opens in the window used last (window 2)\(err.map { " (\($0))" } ?? "")")
                app.browserWindowBecameKey(w1)
                let before2 = Set(self.c.store.state.tabs.keys)
                _ = Self.sendGetURLEvent(URL(string: s.base + "/f.html")!)
                self.waitUntil({ Set(self.c.store.state.tabs.keys).subtracting(before2).count == 1 }, timeout: 5) {
                    let new2 = Set(self.c.store.state.tabs.keys).subtracting(before2).first
                    self.check(new2 != nil && w1.shownTabID == new2, "windows: after window 1 is used, the next link opens there")
                    done()
                }
            }
        }
        // With every window closed: a link brings the windows back with it; with Little Arc, only Little Arc opens.
        step { [self] done in
            guard let app else { return done() }
            app.controllers.forEach { $0.window.performClose(nil) }
            waitUntil({ app.controllers.isEmpty }, timeout: 5) {
                let before = app.store.state.tabs.count
                _ = Self.sendGetURLEvent(URL(string: s.base + "/b.html?closed")!)
                self.waitUntil({ !app.controllers.isEmpty && app.store.state.tabs.count > before }, timeout: 6) {
                    let shown = app.controller?.shownTabID.flatMap { app.store.tab($0) }
                    self.check(shown?.url == s.base + "/b.html?closed", "windows: with no window open, a link opens one with it")
                    s.page = app.controller.flatMap { w in w.shownTabID.flatMap { w.engineTab(for: $0) } }
                    done()
                }
            }
        }
        step { [self] done in
            waitUntil({ s.page?.isLoading == false && s.page?.title.isEmpty == false }, timeout: 8) {
                self.check(s.page?.title == "Page B", "windows: the link's page loads in the reopened window (\(s.page?.title ?? "no page"))")
                s.page = nil
                done()
            }
        }
        step { [self] done in
            guard let app else { return done() }
            app.settings.values.externalLinks = .littleArc
            app.controllers.forEach { $0.window.performClose(nil) }
            waitUntil({ app.controllers.isEmpty }, timeout: 5) {
                _ = Self.sendGetURLEvent(URL(string: s.base + "/d.html?little")!)
                self.waitUntil({ !app.littleArcs.isEmpty }, timeout: 6) {
                    self.check(app.littleArcs.count == 1 && app.controllers.isEmpty,
                               "windows: with no window open and Little Arc on, the link opens Little Arc only")
                    let page = app.littleArcs.first?.page
                    self.waitUntil({ page?.isLoading == false && page?.title.isEmpty == false }, timeout: 8) {
                        self.check(page?.title == "Page D", "windows: Little Arc's page loads with no browser window (\(page?.title ?? "no page"))")
                        app.littleArcs.forEach { $0.closeWindow() }
                        // ⌘N from the menu bar with no window: a new one.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.menuNewWindow()
                            self.waitUntil({ !app.controllers.isEmpty }, timeout: 3) {
                                self.check(app.controllers.count == 1 && app.controller?.commandBar != nil,
                                           "windows: ⌘N with no window open opens one, with the Command Bar")
                                app.controller?.closeCommandBar()
                                done()
                            }
                        }
                    }
                }
            }
        }
        run { s.server?.stop() }
    }

    #if canImport(AircCore)
    /// Chromium: a split moves between windows whole (every pane, live), and so does a page the build plays in Safari's
    /// engine (HybridEngine.swift: each window's own WebKit window).
    private func windowsChromiumMoves(_ s: WindowsState) {
        var split: Split?
        step { [self] done in
            guard let w1 = s.w1, let a = s.tabs["a"], let b = s.tabs["b"] else { return done() }
            split = try? c.store.createSplit([a, b], inSpace: s.home, focused: a)
            waitUntil({ w1.shownSplitID == split?.id && w1.engineTab(for: b)?.isLoading == false }, timeout: 8) {
                self.check(split != nil && w1.shownSplitID == split?.id, "windows: window 1 shows the split of A and B")
                done()
            }
        }
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let a = s.tabs["a"], let b = s.tabs["b"], let x = split else { return done() }
            let pages = (w1.engineTab(for: a), w1.engineTab(for: b))
            w2.switchToSpace(s.home, animated: false)
            check(w2.multiWindow.elsewhereTabID != nil && w1.shownSplitID == x.id,
                  "windows: window 2 on Home leaves the split to window 1 (open in another window)")
            w2.showHere()
            check(w2.shownSplitID == x.id && w2.engineTab(for: a) === pages.0 && w2.engineTab(for: b) === pages.1
                  && w1.engineTab(for: a) == nil && w1.engineTab(for: b) == nil && w1.multiWindow.elsewhereTabID != nil,
                  "windows: Show Here moves the whole split to window 2, both panes live")
            w1.showHere()
            check(w1.shownSplitID == x.id && w1.engineTab(for: a) === pages.0 && w2.multiWindow.elsewhereTabID != nil,
                  "windows: and back to window 1")
            try? c.store.separateSplit(x.id)
            w2.switchToSpace(s.work, animated: false)
            done()
        }
        wait(0.5)
        step { [self] done in
            guard let w1 = s.w1 else { return done() }
            ProtectedMedia.shared.testHosts = ["localhost"]
            let port = URL(string: s.base)?.port ?? 0
            if let t = try? c.store.openTab(url: "http://localhost:\(port)/g.html", inSpace: s.home) { s.tabs["g"] = t.id; w1.show(t.id, focus: false) }
            let id = s.tabs["g"] ?? ""
            waitUntil({ w1.engineTab(for: id)?.isLoading == false && w1.engineTab(for: id)?.title.isEmpty == false }, timeout: 10) {
                s.page = w1.engineTab(for: id)
                self.check(ProtectedMedia.isWebKitPage(s.page), "windows: a listed site's page plays in Safari's engine in window 1")
                self.pageMarker(s.page) { m in s.marker = m; done() }
            }
        }
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let g = s.tabs["g"], let tab = c.store.tab(g) else { return done() }
            w2.switchToSpace(s.home, animated: false)
            w2.activate(entry: .today(tab))
            let page = w2.engineTab(for: g)
            check(page === s.page && ProtectedMedia.isWebKitPage(page) && w1.engineTab(for: g) == nil,
                  "windows: picking it in window 2 moves the Safari-engine page there")
            pageMarker(page) { m in
                self.check(!s.marker.isEmpty && m == s.marker, "windows: the Safari-engine page didn't reload (\(s.marker) → \(m))")
                ProtectedMedia.shared.testHosts = []
                w2.closeTab(g)
                w2.switchToSpace(s.work, animated: false)
                w1.show(s.tabs["a"] ?? "", focus: false)
                done()
            }
        }
        waitForPage()
    }
    #endif

    // MARK: Titles, drag-out, blank windows (multiwindow2)

    /// Each window's title is its Space's name and its page's title.
    private func windowsTitles(_ s: WindowsState) {
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2 else { return done() }
            waitUntil({ w1.window.title == "Home — Page A" && w2.window.title == "Work — Page C" }, timeout: 4) {
                self.check(w1.window.title == "Home — Page A" && w2.window.title == "Work — Page C",
                           "windows titles: each window is titled by its Space and page (“\(w1.window.title)”, “\(w2.window.title)”)")
                let menu = NSApp.windowsMenu?.items.map(\.title) ?? []
                self.check(menu.isEmpty || (menu.contains(w1.window.title) && menu.contains(w2.window.title)),
                           "windows titles: the Window menu lists them apart (\(menu.filter { $0.contains("Page") }))")
                w2.switchToSpace(s.home, animated: false)
                let onHome = w2.window.title
                w2.switchToSpace(s.work, animated: false)
                self.check(onHome.hasPrefix("Home") && w2.window.title == "Work — Page C",
                           "windows titles: a Space switch retitles the window (“\(onHome)” → “\(w2.window.title)”)")
                done()
            }
        }
    }

    /// A posted drag in `w` (as the split and drag checks post theirs): press at `start`, move to `end` over a third of a
    /// second, hold, release. `w`'s window coordinates, which may lie outside it.
    private func windowsDrag(in w: NSWindow, from start: NSPoint, to end: NSPoint, _ done: @escaping () -> Void) {
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let leg = 0.33, hold = 0.15
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
            } else {
                t.invalidate()
                if let e = mouse(.leftMouseUp, last) { NSApp.postEvent(e, atStart: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        if let down = mouse(.leftMouseDown, start) { w.sendEvent(down) }   // returns after the release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
    }

    /// The centre of `tabID`'s Today row in window `w` (its window coordinates).
    private func rowPoint(_ tabID: String, in w: WindowController) -> NSPoint? {
        guard let page = w.pageView(for: w.currentSpaceID), let row = todayRow(tabID, in: page) else { return nil }
        return row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    }

    /// SB-35: a row dragged out of the sidebar, dropped where no Airc window is, makes a window there with the same live
    /// page; dropped on another window's sidebar, it moves there. The sidebar on the left, then on the right.
    private func windowsDragOut(_ s: WindowsState) {
        var drop = NSPoint.zero
        var w3: WindowController?
        // Two windows side by side at the top of the screen, room below them.
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let a = s.tabs["a"] else { return done() }
            let v = (w1.window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let width = min(760, (v.width - 30) / 2), height = min(560, v.height - 240)
            w1.window.setFrame(NSRect(x: v.minX + 10, y: v.maxY - height, width: width, height: height), display: true)
            w2.window.setFrame(NSRect(x: v.minX + 20 + width, y: v.maxY - height, width: width, height: height), display: true)
            drop = NSPoint(x: v.minX + width * 0.7, y: v.minY + 90)
            w1.root.layoutSubtreeIfNeeded()
            w2.root.layoutSubtreeIfNeeded()
            check(w1.shownTabID == a && w2.shownTabID == s.tabs["c"], "drag-out: window 1 shows A, window 2 shows C")
            s.page = w1.engineTab(for: a)
            pageMarker(s.page) { m in s.marker = m; done() }
        }
        step { [self] done in
            guard let w1 = s.w1, let a = s.tabs["a"], let start = rowPoint(a, in: w1) else {
                check(false, "drag-out: A's row in window 1")
                return done()
            }
            let before = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            windowsDrag(in: w1.window, from: start, to: w1.window.convertPoint(fromScreen: drop)) {
                self.waitUntil({ (self.app?.controllers.count ?? 0) == 3 }, timeout: 3) {
                    w3 = self.app?.controllers.first { !before.contains(ObjectIdentifier($0)) }
                    self.check(w3 != nil, "drag-out: dropping A's row outside every window opens a window")
                    guard let w3 else { return done() }
                    let page = w3.engineTab(for: a)
                    self.check(w3.shownTabID == a && page != nil && page === s.page && w1.engineTab(for: a) == nil,
                               "drag-out: the new window has A's page, the same page object (\(page === s.page))")
                    self.check(w3.window.frame.contains(drop) && w3.window.isOnActiveSpace && w3.window.screen == w1.window.screen,
                               "drag-out: it opens at the drop point, on this Space (frame \(w3.window.frame), drop \(drop))")
                    self.check(w3.currentSpaceID == s.home && w3.sidebarWidth == w1.sidebarWidth && !w3.isBlankWindow,
                               "drag-out: on A's Space, with window 1's sidebar width")
                    self.check(w1.shownTabID == s.tabs["b"] && w1.multiWindow.elsewhereTabID == nil,
                               "drag-out: window 1 goes on to B (shows \(w1.shownTabID.flatMap { id in s.tabs.first { $0.value == id }?.key } ?? "none"))")
                    self.pageMarker(page) { m in
                        self.check(!s.marker.isEmpty && m == s.marker, "drag-out: the page didn't reload (marker \(s.marker) → \(m))")
                        done()
                    }
                }
            }
        }
        capture("windows-dragout")
        // Onto window 2's sidebar (Work's Today, below C): A moves there, page and all.
        step { [self] done in
            guard let w2 = s.w2, let w3, let a = s.tabs["a"], let c = s.tabs["c"],
                  let start = rowPoint(a, in: w3), let page2 = w2.pageView(for: s.work), let row = todayRow(c, in: page2) else {
                check(false, "drag-out: rows for the drop onto window 2")
                return done()
            }
            // A point below C's row that lands in Work's Today (not onto C, which would split).
            let candidates = [row.bounds.height * 0.45, -row.bounds.height * 0.45, row.bounds.height * 1.2, -row.bounds.height * 1.2]
                .map { row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY + $0), to: nil) }
            let target = candidates.first { p in
                if case .today(let sid, _)? = page2.dropDestination(at: page2.convert(p, from: nil), source: .tab(a), entry: .today(self.c.store.tab(a)!)) { return sid == s.work }
                return false
            }
            page2.hideDropIndicator()
            guard let target else { check(false, "drag-out: a Today drop point in window 2"); return done() }
            let screen = w2.window.convertPoint(toScreen: target)
            windowsDrag(in: w3.window, from: start, to: w3.window.convertPoint(fromScreen: screen)) {
                self.waitUntil({ w2.shownTabID == a }, timeout: 3) {
                    let page = w2.engineTab(for: a)
                    self.check(w2.shownTabID == a && page === s.page && w3.engineTab(for: a) == nil,
                               "drag-out: dropped on window 2's sidebar, A's page moves there (same page \(page === s.page))")
                    self.check(self.c.store.tab(a)?.spaceID == s.work && self.c.store.todayRows(ofSpace: s.work).map(\.id).contains(a),
                               "drag-out: A is in Work's Today where the line showed")
                    self.check(w3.shownTabID == nil || w3.multiWindow.elsewhereTabID == nil,
                               "drag-out: the window it left goes on (shows \(w3.shownTabID ?? "the empty Space"))")
                    self.pageMarker(page) { m in
                        self.check(m == s.marker, "drag-out: still no reload (\(m))")
                        done()
                    }
                }
            }
        }
        // Back as it was: A in Home in window 1, C in window 2, window 3 closed.
        step { [self] done in
            guard let w1 = s.w1, let w2 = s.w2, let a = s.tabs["a"] else { return done() }
            _ = try? c.store.moveTab(a, toSpace: s.home)
            w3?.window.performClose(nil)
            waitUntil({ (self.app?.controllers.count ?? 0) == 2 }, timeout: 4) {
                w1.show(a, focus: false)
                w2.show(s.tabs["c"] ?? "", focus: false)
                done()
            }
        }
        // The sidebar on the right: B's row out of window 1 the same way.
        step { [self] done in
            guard let w1 = s.w1, let b = s.tabs["b"] else { return done() }
            app?.setSidebarOnRight(true)
            app?.controllers.forEach { $0.root.layoutSubtreeIfNeeded() }
            w1.show(b, focus: false)
            waitUntil({ w1.engineTab(for: b)?.isLoading == false }, timeout: 6) {
                s.page = w1.engineTab(for: b)
                self.pageMarker(s.page) { m in s.marker = m; done() }
            }
        }
        step { [self] done in
            guard let w1 = s.w1, let b = s.tabs["b"], let start = rowPoint(b, in: w1) else {
                check(false, "drag-out (right): B's row")
                return done()
            }
            check(w1.sidebarOnRight && start.x > w1.window.frame.width / 2, "drag-out (right): the sidebar is on the right (row at x \(Int(start.x)))")
            let before = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            windowsDrag(in: w1.window, from: start, to: w1.window.convertPoint(fromScreen: drop)) {
                self.waitUntil({ (self.app?.controllers.count ?? 0) == 3 }, timeout: 3) {
                    let w4 = self.app?.controllers.first { !before.contains(ObjectIdentifier($0)) }
                    let page = w4?.engineTab(for: b)
                    self.check(w4?.shownTabID == b && page === s.page && w4?.sidebarOnRight == true && w4?.window.frame.contains(drop) == true,
                               "drag-out (right): a window at the drop point with B's page (same page \(page === s.page))")
                    self.pageMarker(page) { m in
                        self.check(!s.marker.isEmpty && m == s.marker, "drag-out (right): no reload (\(m))")
                        self.app?.setSidebarOnRight(false)
                        w4?.window.performClose(nil)
                        self.waitUntil({ (self.app?.controllers.count ?? 0) == 2 }, timeout: 4) {
                            w1.show(s.tabs["a"] ?? "", focus: false)
                            done()
                        }
                    }
                }
            }
        }
        waitForPage()
    }

    /// ⌃⌘N: a blank window, on a Space of its own (Arc: blank windows are separate). Its tabs are its own; it closes with
    /// its Space, its tabs in the Archive.
    private func windowsBlank(_ s: WindowsState) {
        var wb: WindowController?
        var blankTab = ""
        step { [self] done in
            guard let w1 = s.w1 else { return done() }
            let before = Set((app?.controllers ?? []).map(ObjectIdentifier.init))
            postWindowKey("n", code: 45, mods: [.command, .control], to: w1.window)
            waitUntil({ (self.app?.controllers.count ?? 0) == before.count + 1 }, timeout: 3) {
                wb = self.app?.controllers.first { !before.contains(ObjectIdentifier($0)) }
                guard let wb else { self.check(false, "blank window: ⌃⌘N opens a window"); return done() }
                let store = self.c.store
                let sid = wb.currentSpaceID
                self.check(wb.isBlankWindow && store.space(sid)?.isBlankWindow == true && !store.orderedSpaces.contains { $0.id == sid },
                           "blank window: ⌃⌘N opens a window on a Space of its own, not in the Space bar")
                self.check(wb.windowSpaces.map(\.id) == [sid] && store.todayTabs(ofSpace: sid).isEmpty && wb.shownTabID == nil && wb.commandBar != nil,
                           "blank window: empty, paging through its own Space only, with the Command Bar")
                self.check(store.space(sid)?.profileID == store.space(w1.currentSpaceID)?.profileID && store.selectedSpace.id != sid,
                           "blank window: window 1's profile; the selection stays on a listed Space")
                self.check(!w1.windowSpaces.contains { $0.id == sid } && w1.pageView(for: sid) == nil,
                           "blank window: other windows don't list it")
                wb.closeCommandBar()
                if let t = try? store.openTab(url: s.base + "/e.html", inSpace: sid) { blankTab = t.id; wb.show(t.id, focus: false) }
                done()
            }
        }
        waitForPage()
        step { [self] done in
            guard let wb, let w1 = s.w1 else { return done() }
            let store = c.store
            waitUntil({ wb.window.title == "Blank Window — Page E" }, timeout: 4) {
                self.check(wb.shownTabID == blankTab && wb.engineTab(for: blankTab) != nil && wb.window.title == "Blank Window — Page E",
                           "blank window: its own tab loads (title “\(wb.window.title)”)")
                self.check(store.tab(blankTab)?.spaceID == wb.currentSpaceID && !store.todayTabs(ofSpace: s.home).contains { $0.id == blankTab }
                           && w1.pageView(for: s.home).flatMap { self.todayRow(blankTab, in: $0) } == nil,
                           "blank window: its Today tab isn't in Home's Today in window 1")
                // Picking it from another window (as the Command Bar's Switch to Tab does) shows it in its own window.
                w1.show(blankTab, focus: false)
                self.check(w1.currentSpaceID == s.home && w1.shownTabID == s.tabs["a"] && wb.shownTabID == blankTab,
                           "blank window: its tab picked in window 1 stays in the blank window (window 1 still shows \(w1.shownTabID.flatMap { id in s.tabs.first { $0.value == id }?.key } ?? "none"))")
                // ⌘N from a blank window: an ordinary window.
                let before = Set((self.app?.controllers ?? []).map(ObjectIdentifier.init))
                self.postWindowKey("n", code: 45, mods: .command, to: wb.window)
                self.waitUntil({ (self.app?.controllers.count ?? 0) == before.count + 1 }, timeout: 3) {
                    let n = self.app?.controllers.first { !before.contains(ObjectIdentifier($0)) }
                    self.check(n != nil && n?.isBlankWindow == false && n?.currentSpaceID != wb.currentSpaceID,
                               "blank window: ⌘N there opens an ordinary window (on \(n.flatMap { store.space($0.currentSpaceID)?.name } ?? "?"))")
                    n?.closeCommandBar()
                    n?.window.performClose(nil)
                    done()
                }
            }
        }
        capture("windows-blank")
        step { [self] done in
            guard let wb else { return done() }
            let sid = wb.currentSpaceID
            let count = app?.controllers.count ?? 0
            wb.window.performClose(nil)
            waitUntil({ self.c.store.space(sid) == nil && (self.app?.controllers.count ?? 0) == count - 1 }, timeout: 4) {
                let store = self.c.store
                self.check(store.space(sid) == nil && store.tab(blankTab) == nil && store.state.archive.values.contains { $0.tab.id == blankTab },
                           "blank window: closing it removes its Space; its tab goes to the Archive")
                done()
            }
        }
        wait(0.5)
    }

    /// review2 P1: closing a window that alone used a profile leaves the profile loaded (Chromium destroys a profile with
    /// its last browser; AppDelegate.keepProfilesLoaded holds one for each). Window 1 then loads that profile's tabs, and
    /// Little Arc opens in it. Deleting the profile still works.
    private func windowsProfileKeeper(_ s: WindowsState) {
        var spaceID = "", profileID = "", tabID = ""
        var other: WindowController?
        var little: LittleArcController?
        step { [self] done in
            guard let app, let w1 = s.w1 else { return done() }
            let store = app.store!
            guard let p = try? app.profiles.createProfile(name: "Second", emoji: "🧪", color: nil),
                  let space = try? store.createSpace(name: "Second", icon: .emoji("🧪"), profileID: p.id, after: s.work),
                  let t = try? store.openTab(url: s.base + "/f.html", inSpace: space.id) else {
                check(false, "profile keeper: a second profile with a Space and a tab")
                return done()
            }
            (profileID, spaceID, tabID) = (p.id, space.id, t.id)
            check(w1.engineTab(for: t.id) == nil && store.profile(ofSpace: w1.currentSpaceID).id != p.id,
                  "profile keeper: window 1 has never used the second profile")
            // The Space's Open in New Window, once the profile has loaded: the only window with that profile's page.
            app.profiles.whenLoaded(p.id, { _ in
                other = app.openNewWindow(from: w1, spaceID: space.id, tab: .spaceLast, commandBar: false)
                self.waitUntil({ other?.engineTab(for: t.id)?.isLoading == false && other?.engineTab(for: t.id)?.title.isEmpty == false }, timeout: 10) {
                    let page = other?.engineTab(for: t.id)
                    self.check(page?.title == "Page F", "profile keeper: the new window loads the second profile's page "
                               + "(\(page.map { "“\($0.title)” \($0.url?.absoluteString ?? "")" } ?? "no page"), shows \(other?.shownTabID == t.id))")
                    done()
                }
            }, failed: { self.check(false, "profile keeper: the second profile loads"); done() })
        }
        step { [self] done in
            guard let app, let other else { return done() }
            let count = app.controllers.count
            other.window.performClose(nil)
            waitUntil({ app.controllers.count == count - 1 }, timeout: 4) {
                // Chromium destroys an unkept profile right after its last browser closes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: done)
            }
        }
        step { [self] done in
            guard let w1 = s.w1 else { return done() }
            w1.switchToSpace(spaceID, animated: false)
            w1.show(tabID, focus: false)
            let page = w1.engineTab(for: tabID)
            waitUntil({ page?.isLoading == false && page?.title.isEmpty == false }, timeout: 10) {
                guard let page else { self.check(false, "profile keeper: window 1 has the tab's page"); return done() }
                page.evaluate("document.title") { title in
                    self.check((title as? String) == "Page F",
                               "profile keeper: after that window closed, window 1 loads the second profile's tab (title \(title as? String ?? "none"))")
                    done()
                }
            }
        }
        step { [self] done in
            guard let app else { return done() }
            little = app.openLittleArc(url: URL(string: s.base + "/g.html?little"), spaceID: spaceID)
            let page = little?.page
            waitUntil({ page?.isLoading == false && page?.title.isEmpty == false }, timeout: 10) {
                self.check(page?.title == "Page G", "profile keeper: Little Arc opens in the second profile (\(page?.title ?? "no page"))")
                little?.closeWindow()
                done()
            }
        }
        // Deleting it still works (the engine closes the keeper's browser for it too).
        step { [self] done in
            guard let app, let w1 = s.w1 else { return done() }
            w1.switchToSpace(s.home, animated: false)
            w1.show(s.tabs["a"] ?? "", focus: false)
            try? app.store.deleteSpace(spaceID)
            var result: Bool?
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                app.profiles.deleteProfile(profileID) { result = $0 }
            }
            waitUntil({ result != nil }, timeout: 8) {
                self.check(result == true && app.store.profile(profileID) == nil, "profile keeper: the second profile can still be deleted (\(result.map(String.init) ?? "no answer"))")
                done()
            }
        }
        waitForPage()
    }

    // MARK: Session restore

    private struct WindowsExpected: Codable {
        struct W: Codable { var frame: [Double]; var spaceID: String; var tabID: String?; var elsewhere: Bool; var sidebarWidth: Double; var blank: Bool? }
        var windows: [W]
    }

    private var windowsExpectedFile: URL { dir.appendingPathComponent("windows-session.json") }

    /// Four windows: Home with A, Work with C (wider sidebar, used last), Home again with A's page in the first, and a
    /// blank window with its own tab.
    func windowsSessionWrite() {
        let s = WindowsState()
        windowsSetUp(s, pages: [("a", "home"), ("b", "home"), ("c", "work")])
        step { [self] done in
            guard let app, let w1 = s.w1 else { return done() }
            let screen = (w1.window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            w1.window.setFrame(NSRect(x: screen.minX + 30, y: screen.maxY - 760, width: 1100, height: 720), display: false)
            let w3 = app.openNewWindow(from: w1, spaceID: s.home, tab: .id(s.tabs["a"] ?? ""), commandBar: false)
            w3?.window.setFrame(NSRect(x: screen.minX + 400, y: screen.maxY - 700, width: 900, height: 640), display: false)
            let wb = app.openBlankWindow(from: w1)
            wb?.closeCommandBar()
            if let wb, let t = try? c.store.openTab(url: s.base + "/b.html?blank", inSpace: wb.currentSpaceID) { wb.show(t.id, focus: false) }
            wb?.window.setFrame(NSRect(x: screen.minX + 300, y: screen.maxY - 660, width: 860, height: 600), display: false)
            let w2 = app.openNewWindow(from: w1, spaceID: s.work, tab: .id(s.tabs["c"] ?? ""), commandBar: false)
            w2?.window.setFrame(NSRect(x: screen.minX + 200, y: screen.maxY - 820, width: 1000, height: 700), display: false)
            w2?.setSidebarWidth(260)
            check(w3?.multiWindow.elsewhereTabID == s.tabs["a"], "windows-write: the third window shows A as open in another window")
            check(app.controllers.count == 4 && app.controller === w2 && wb?.isBlankWindow == true && wb?.shownTabID != nil,
                  "windows-write: four windows (one blank, with its own tab), Work's used last")
            let expected = WindowsExpected(windows: app.controllers.map {
                let f = $0.window.frame
                return .init(frame: [f.minX, f.minY, f.width, f.height], spaceID: $0.currentSpaceID, tabID: $0.shownTabID,
                             elsewhere: $0.multiWindow.elsewhereTabID != nil, sidebarWidth: Double($0.sidebarWidth), blank: $0.isBlankWindow)
            })
            try? JSONEncoder().encode(expected).write(to: windowsExpectedFile)
            done()
        }
        wait(1.5)
        run { s.server?.stop() }
    }

    func windowsSessionRead() {
        step { [self] done in
            guard let app, let data = try? Data(contentsOf: windowsExpectedFile),
                  let expected = try? JSONDecoder().decode(WindowsExpected.self, from: data) else {
                check(false, "windows-read: the write run left its expectations")
                return done()
            }
            check(app.controllers.count == expected.windows.count, "windows-read: \(expected.windows.count) windows come back (\(app.controllers.count))")
            for (i, (c, e)) in zip(app.controllers, expected.windows).enumerated() {
                let f = c.window.frame
                let close = zip([f.minX, f.minY, f.width, f.height], e.frame).allSatisfy { abs($0 - $1) <= 2 }
                check(close, "windows-read: window \(i + 1)'s frame (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))")
                check(c.currentSpaceID == e.spaceID && c.shownTabID == e.tabID,
                      "windows-read: window \(i + 1)'s Space and tab (\(c.store.space(c.currentSpaceID)?.name ?? "?"))")
                check((c.multiWindow.elsewhereTabID != nil) == e.elsewhere,
                      "windows-read: window \(i + 1) \(e.elsewhere ? "says its tab is in another window" : "has its page")")
                check(abs(Double(c.sidebarWidth) - e.sidebarWidth) < 0.5, "windows-read: window \(i + 1)'s sidebar width \(Int(c.sidebarWidth))")
                if let blank = e.blank {
                    check(c.isBlankWindow == blank && (!blank || (c.store.todayTabs(ofSpace: c.currentSpaceID).map(\.id) == [e.tabID].compactMap { $0 }
                                                                  && !c.store.orderedSpaces.contains { $0.id == c.currentSpaceID })),
                          "windows-read: window \(i + 1) \(blank ? "is the blank window, with its own tab" : "is an ordinary window")")
                }
            }
            done()
        }
        capture("windows-restored")
    }
}
#endif
