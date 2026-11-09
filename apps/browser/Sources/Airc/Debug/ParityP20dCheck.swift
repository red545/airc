// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
import Darwin
import WebKit

/// `--script parityp20d` (P20d, docs/user/devmode.md): Arc's developer commands in the menu bar, on both engines.
///
/// - Menus: View has Clear Cookies and Refresh and Clear Cache and Refresh after Reload Ignoring Cache; View ›
///   Developer has Arc's six in Arc's order with Arc's keys; Help › Troubleshooting › Open Task Manager; the Command
///   Bar offers each; Settings › Shortcuts knows them by id.
/// - Clear Cookies and Refresh, from the View menu: the page's site loses its cookies only (its local storage and HTTP
///   cache stay) and reloads; another site (127.0.0.1 next to localhost) keeps its cookie.
/// - Clear Cache and Refresh: the site's HTTP cache goes (the fixture server sees the request again), its cookie and
///   storage stay, the other site's cache stays; the page reloads.
/// - A private window's own: both commands clear that session's cookie and cache, and the regular profile's cookie and
///   HTTP cache for the same site survive. Inspect Elements and Network Inspector there open the private page's own
///   DevTools, never the regular tab's.
/// - Inspect Elements and Network Inspector on a regular page: its DevTools (Web Inspector in Safari's engine, which
///   can't pick a panel), not another tab's.
/// - Task Manager: opens from Help; rows for the browser and the page with its profile, memory, CPU and process ID; a
///   regular window's shows the private page as "Private tab" without its title and can't end it; from the private
///   window it names it and can; End Process ends exactly the selected page's process (the other page's lives); ⌘W
///   closes the Task Manager, not a tab; closed, it samples nothing.
///
/// Menu commands run through their real menu items (CommandMenuItem.fire) with the shortcuts check's key-window stand-in,
/// since a scripted run is never key. Synthetic loopback pages only (LocalPageServer). Cache cases count only when the
/// store reused the response first. A scripted WebKit run's Space stores are non-persistent and keep no HTTP cache, so
/// on WebKit the cache cases run on an owned persistent store of the run's own (removed afterwards), through the same
/// EngineTab calls the menu commands make, and that store stands in as the regular cache next to the private window.
extension SnapshotRunner {
    func parityP20dScenario() {
        let tag = app?.engine is WebKitEngine ? "parityp20d (WebKit)" : "parityp20d (Chromium)"
        let isWebKit = app?.engine is WebKitEngine
        var server: LocalPageServer?
        var port: UInt16 = 0
        var idA = "", idB = ""
        var privateWindow: PrivateWindowController?
        var values: [String: String] = [:]
        let pageA = { self.c.engineTab(for: idA) }
        let pageB = { self.c.engineTab(for: idB) }
        let privatePage = { privateWindow?.shownPage }
        // WebKit: an owned persistent store, its localhost and 127.0.0.1 pages.
        let ownedStore = UUID()
        var owned: WebKitProfile?, ownedX: EngineTab?, ownedY: EngineTab?
        let pageX = { ownedX }, pageY = { ownedY }
        /// The regular profile's cache next to the private window: the Space's on Chromium, the owned store's on WebKit.
        let regularCache = { isWebKit ? ownedX : pageA() }
        let page = { (title: String) in "<title>\(title)</title><body style='font:15px -apple-system;padding:40px'><h1>\(title)</h1></body>" }

        // MARK: helpers

        func menuItem(_ path: [String]) -> NSMenuItem? {
            var menu = NSApp.mainMenu, item: NSMenuItem?
            for title in path { item = menu?.items.first { $0.title == title }; menu = item?.submenu }
            return item
        }
        /// Chooses the item as a click would (its menu validates it first).
        func choose(_ path: [String], key window: @escaping () -> NSWindow?) {
            run { [self] in
                if let window = window() { Self.emulateKeyWindow(window) { _ in } }
                guard let item = menuItem(path), let menu = item.menu, let i = menu.items.firstIndex(of: item) else {
                    return check(false, "\(tag): \(path.joined(separator: " › ")) is in the menu bar")
                }
                menu.update()
                check(item.isEnabled, "\(tag): \(path.joined(separator: " › ")) is enabled")
                if item.isEnabled { menu.performActionForItem(at: i) }
            }
        }
        /// Evaluates `code` until `ok` (or the timeout), then hands over what it got.
        func poll(_ tab: @escaping () -> EngineTab?, _ code: String, timeout: Double = 6, until ok: @escaping (String) -> Bool,
                  then: @escaping (String) -> Void) {
            step { done in
                let deadline = Date().addingTimeInterval(timeout)
                func again() {
                    guard let t = tab(), !t.isClosed else { then("no page"); return done() }
                    t.evaluate(code) { v in
                        let got = v.map { "\($0)" } ?? "nil"
                        if ok(got) || Date() > deadline { then(got); return done() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: again)
                    }
                }
                again()
            }
        }
        func expect(_ tab: @escaping () -> EngineTab?, _ code: String, _ what: String, timeout: Double = 6, _ ok: @escaping (String) -> Bool) {
            poll(tab, code, timeout: timeout, until: ok) { [self] got in check(ok(got), "\(tag): \(what) (\(got))") }
        }
        func js(_ tab: @escaping () -> EngineTab?, _ code: String) {
            step { done in
                guard let t = tab() else { return done() }
                t.evaluate(code) { _ in done() }
            }
        }
        /// fetch(path)'s text, into values[key].
        func fetch(_ tab: @escaping () -> EngineTab?, _ path: String, as key: String) {
            js(tab, "window.__p20dFetch = 'pending'; fetch('\(path)').then(r => r.text()).then(t => { window.__p20dFetch = t }, e => { window.__p20dFetch = 'error ' + e }); 'started'")
            poll(tab, "String(window.__p20dFetch)", timeout: 8, until: { $0 != "pending" }) { values[key] = $0 }
        }
        /// The page reloaded: the marker set before is gone and it has loaded again.
        func mark(_ tab: @escaping () -> EngineTab?) { js(tab, "window.__p20dMarker = 'set'; 'ok'") }
        func expectReloaded(_ tab: @escaping () -> EngineTab?, _ what: String) {
            expect(tab, "(window.__p20dMarker === undefined && document.readyState === 'complete') ? 'reloaded' : 'not yet'",
                   "\(what) reloaded", timeout: 10) { $0 == "reloaded" }
        }
        /// Cache cases count only when the store reused the response before (`a` the first, `b` the second fetch).
        /// `transient`: a WebKit non-persistent store, which keeps no HTTP cache (the owned store's case covers it).
        func reused(_ a: String, _ b: String, _ what: String, transient: Bool = false) -> Bool {
            let ok = values[a] != nil && values[a] == values[b] && values[a]?.hasPrefix("response-") == true
            if !ok {
                if transient { skip("\(tag): \(what): WebKit's non-persistent store keeps no HTTP cache (\(values[a] ?? "-"), \(values[b] ?? "-")); the owned store's case covers it") }
                else { note("FAIL-ENV \(tag): \(what): the store didn't reuse the cached response (\(values[a] ?? "-"), \(values[b] ?? "-"))") }
            }
            return ok
        }
        func clear(_ tab: @escaping () -> EngineTab?, _ types: Set<EngineSiteDataType>, _ what: String) {
            step { [self] done in
                guard let t = tab() else { check(false, "\(tag): \(what) (no page)"); return done() }
                t.clearSiteData(types, reload: true) { result in
                    if case .failure(let e) = result { self.check(false, "\(tag): \(what): \(e.localizedDescription)") }
                    done()
                }
            }
        }
        func waitDevTools(_ tab: @escaping () -> EngineTab?, _ other: @escaping () -> EngineTab?, _ what: String) {
            step { [self] done in
                waitUntil({ tab()?.isDevToolsOpen == true }, timeout: 8) {
                    self.check(tab()?.isDevToolsOpen == true && other()?.isDevToolsOpen != true,
                               "\(tag): \(what) opens the page's own developer tools, not the other tab's")
                    done()
                }
            }
        }
        func closeDevTools(_ tab: @escaping () -> EngineTab?) {
            step { [self] done in
                tab()?.closeDevTools()
                waitUntil({ tab()?.isDevToolsOpen != true }, timeout: 5) { done() }
            }
        }
        var tm: TaskManagerWindow? { TaskManagerWindow.shared }
        func rows(_ title: String) -> [TaskManager.Row] { tm?.model.rows.filter { $0.title.contains(title) } ?? [] }

        // MARK: setup

        step { [self] done in
            server = LocalPageServer(pages: ["/a": page("P20d A"), "/b": page("P20d B"), "/private": page("P20d private")])
            var count: [String: Int] = [:] // on the server's queue only
            server?.handler = { path in
                if path == "/owned" { return .init(body: page("P20d owned")) }
                guard path.hasPrefix("/http-cache-") else { return nil }
                count[path, default: 0] += 1
                return .init(headers: ["Cache-Control": "public, max-age=86400", "Content-Type": "text/plain"], body: "response-\(count[path]!)")
            }
            server?.start { p in
                port = p ?? 0
                self.check(port != 0, "\(tag): fixture server started")
                done()
            }
        }
        step { [self] done in
            guard port != 0, let a = try? c.store.openTab(url: "http://localhost:\(port)/a", inSpace: c.currentSpaceID),
                  let b = try? c.store.openTab(url: "http://127.0.0.1:\(port)/b", inSpace: c.currentSpaceID) else {
                check(false, "\(tag): fixture tabs"); return done()
            }
            idA = a.id; idB = b.id
            c.reloadAll(animated: false)
            c.show(idB, focus: false)
            waitUntil({ pageB()?.title == "P20d B" && pageB()?.isLoading == false }, timeout: 15) {
                self.c.show(idA, focus: false)
                self.waitUntil({ pageA()?.title == "P20d A" && pageA()?.isLoading == false }, timeout: 15) {
                    self.check(pageA()?.title == "P20d A" && pageB()?.title == "P20d B", "\(tag): localhost and 127.0.0.1 pages loaded")
                    done()
                }
            }
        }

        // MARK: 1. Menus

        run { [self] in
            let view = menuItem(["View"])?.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
            if let i = view.firstIndex(of: "Reload Ignoring Cache") {
                check(Array(view.dropFirst(i + 1).prefix(2)) == ["Clear Cookies and Refresh", "Clear Cache and Refresh"]
                      && menuItem(["View", "Clear Cookies and Refresh"])?.keyEquivalent == ""
                      && menuItem(["View", "Clear Cache and Refresh"])?.keyEquivalent == "",
                      "\(tag): View has Clear Cookies and Refresh, Clear Cache and Refresh after Reload Ignoring Cache, no keys (\(view))")
            } else { check(false, "\(tag): View has Reload Ignoring Cache (\(view))") }
            let dev = menuItem(["View", "Developer"])?.submenu?.items ?? []
            let keys = dev.map { i -> String in
                let m = i.keyEquivalentModifierMask
                return i.title + ":" + (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.command) ? "⌘" : "") + i.keyEquivalent
            }
            check(keys == ["View Source:⌥⌘u", "Developer Tools:⌥⌘i", "Inspect Elements:⌥⌘c", "JavaScript Console:⌥⌘j",
                           "Network Inspector:", "Developer Mode for This Site:⌃d"],
                  "\(tag): View › Developer in Arc's order with Arc's keys (\(keys))")
            check(!view.contains("Developer Tools") && !view.contains("View Source"), "\(tag): the developer commands moved out of View's top level")
            let trouble = menuItem(["Help", "Troubleshooting"])?.submenu?.items.map(\.title) ?? []
            check(trouble == ["Open Task Manager"], "\(tag): Help › Troubleshooting › Open Task Manager (\(trouble))")
            let ids = Set(CommandMenus.all.map(\.id))
            let want = ["view.clearCookies", "view.clearCache", "view.inspectElements", "view.networkInspector", "help.taskManager"]
            check(want.allSatisfy(ids.contains), "\(tag): Settings › Shortcuts knows them (\(want.filter { !ids.contains($0) }) missing)")
            Self.emulateKeyWindow(c.window) { _ in }
            ParityCommandCatalog.cache = nil
            let actions = c.commandActions()
            let titles = ["Clear Cookies and Refresh", "Clear Cache and Refresh", "Inspect Elements", "Network Inspector", "Open Task Manager"]
            let missing = titles.filter { t in !actions.contains { $0.title == t } }
            let task = actions.first { $0.title == "Open Task Manager" }
            let inspect = actions.first { $0.title == "Inspect Elements" }
            check(missing.isEmpty && task?.keywords.contains("troubleshooting") == true && inspect?.keywords.contains("developer") == true,
                  "\(tag): the Command Bar offers them, found by their menus (missing \(missing); Task Manager words \(task?.keywords ?? []))")
        }

        // MARK: 2. Clear Cookies and Refresh, Clear Cache and Refresh (a main window)

        js(pageA, "document.cookie = 'p20d_a=keep; Path=/'; localStorage.setItem('p20d', 'a'); 'ok'")
        js(pageB, "document.cookie = 'p20d_b=keep; Path=/'; 'ok'")
        fetch(pageA, "/http-cache-a", as: "a1")
        fetch(pageA, "/http-cache-a", as: "a2")
        fetch(pageB, "/http-cache-b", as: "b1")
        fetch(pageB, "/http-cache-b", as: "b2")
        mark(pageA)
        run { [self] in c.show(idA, focus: false) }
        choose(["View", "Clear Cookies and Refresh"], key: { self.c.window })
        expectReloaded(pageA, "Clear Cookies and Refresh: the page")
        expect(pageA, "document.cookie.includes('p20d_a=keep') ? 'kept' : 'gone'", "Clear Cookies and Refresh removes the site's cookie") { $0 == "gone" }
        expect(pageA, "String(localStorage.getItem('p20d'))", "Clear Cookies and Refresh keeps the site's local storage") { $0 == "a" }
        expect(pageB, "document.cookie.includes('p20d_b=keep') ? 'kept' : 'gone'", "Clear Cookies and Refresh keeps another site's cookie (127.0.0.1)") { $0 == "kept" }
        fetch(pageA, "/http-cache-a", as: "a3")
        run { [self] in
            if reused("a1", "a2", "cookies case", transient: isWebKit) {
                check(values["a3"] == values["a1"], "\(tag): Clear Cookies and Refresh keeps the site's HTTP cache (\(values["a3"] ?? "-"))")
            }
        }

        js(pageA, "document.cookie = 'p20d_a2=keep; Path=/'; 'ok'")
        mark(pageA)
        choose(["View", "Clear Cache and Refresh"], key: { self.c.window })
        expectReloaded(pageA, "Clear Cache and Refresh: the page")
        fetch(pageA, "/http-cache-a", as: "a4")
        fetch(pageB, "/http-cache-b", as: "b3")
        run { [self] in
            if reused("a1", "a2", "cache case", transient: isWebKit) {
                check(values["a4"] != values["a1"] && values["a4"]?.hasPrefix("response-") == true,
                      "\(tag): Clear Cache and Refresh empties the site's HTTP cache (\(values["a1"] ?? "-") → \(values["a4"] ?? "-"))")
            }
            if reused("b1", "b2", "other site's cache", transient: isWebKit) {
                check(values["b3"] == values["b1"], "\(tag): Clear Cache and Refresh keeps another site's HTTP cache (\(values["b3"] ?? "-"))")
            }
        }
        expect(pageA, "document.cookie.includes('p20d_a2=keep') ? 'kept' : 'gone'", "Clear Cache and Refresh keeps the site's cookie") { $0 == "kept" }
        expect(pageA, "String(localStorage.getItem('p20d'))", "Clear Cache and Refresh keeps the site's local storage") { $0 == "a" }

        // MARK: 2b. WebKit: the same calls on an owned persistent store, which keeps an HTTP cache

        if isWebKit {
            step { [self] done in
                note("\(tag): owned WebKit store \(ownedStore.uuidString)")
                let profile = WebKitProfile(directory: "p20d-" + ownedStore.uuidString, dataStore: WKWebsiteDataStore(forIdentifier: ownedStore))
                owned = profile
                ownedX = c.engineWindow.openTab(url: URL(string: "http://localhost:\(port)/owned"), profile: profile, foreground: false)
                ownedY = c.engineWindow.openTab(url: URL(string: "http://127.0.0.1:\(port)/owned"), profile: profile, foreground: false)
                waitUntil({ ownedX?.title == "P20d owned" && ownedY?.title == "P20d owned" && ownedX?.isLoading == false && ownedY?.isLoading == false }, timeout: 15) {
                    self.check(ownedX?.title == "P20d owned" && ownedY?.title == "P20d owned", "\(tag): owned-store pages loaded")
                    done()
                }
            }
            js(pageX, "document.cookie = 'p20d_x=keep; Path=/'; localStorage.setItem('p20d', 'x'); 'ok'")
            js(pageY, "document.cookie = 'p20d_y=keep; Path=/'; 'ok'")
            fetch(pageX, "/http-cache-x", as: "x1")
            fetch(pageX, "/http-cache-x", as: "x2")
            fetch(pageY, "/http-cache-y", as: "y1")
            fetch(pageY, "/http-cache-y", as: "y2")
            mark(pageX)
            clear(pageX, [.cookies], "owned store: Clear Cookies and Refresh")
            expectReloaded(pageX, "owned store: Clear Cookies and Refresh: the page")
            expect(pageX, "document.cookie.includes('p20d_x=keep') ? 'kept' : 'gone'", "owned store: cookies cleared") { $0 == "gone" }
            expect(pageY, "document.cookie.includes('p20d_y=keep') ? 'kept' : 'gone'", "owned store: another site's cookie kept") { $0 == "kept" }
            fetch(pageX, "/http-cache-x", as: "x3")
            run { [self] in
                if reused("x1", "x2", "owned store cookies case") { check(values["x3"] == values["x1"], "\(tag): owned store: Clear Cookies keeps the site's HTTP cache (\(values["x3"] ?? "-"))") }
            }
            js(pageX, "document.cookie = 'p20d_x2=keep; Path=/'; 'ok'")
            mark(pageX)
            clear(pageX, [.cache], "owned store: Clear Cache and Refresh")
            expectReloaded(pageX, "owned store: Clear Cache and Refresh: the page")
            fetch(pageX, "/http-cache-x", as: "x4")
            fetch(pageY, "/http-cache-y", as: "y3")
            run { [self] in
                if reused("x1", "x2", "owned store cache case") {
                    check(values["x4"] != values["x1"] && values["x4"]?.hasPrefix("response-") == true,
                          "\(tag): owned store: Clear Cache empties the site's HTTP cache (\(values["x1"] ?? "-") → \(values["x4"] ?? "-"))")
                }
                if reused("y1", "y2", "owned store, other site") { check(values["y3"] == values["y1"], "\(tag): owned store: another site's HTTP cache kept (\(values["y3"] ?? "-"))") }
            }
            expect(pageX, "document.cookie.includes('p20d_x2=keep') ? 'kept' : 'gone'", "owned store: Clear Cache keeps the site's cookie") { $0 == "kept" }
            expect(pageX, "String(localStorage.getItem('p20d'))", "owned store: Clear Cache keeps the site's local storage") { $0 == "x" }
        }

        // MARK: 3. A private window's own session

        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                _ = w?.openPage(URL(string: "http://localhost:\(port)/private"))
                done()
            }
        }
        step { [self] done in
            waitUntil({ privatePage()?.title == "P20d private" && privatePage()?.isLoading == false }, timeout: 15) {
                self.check(privatePage()?.title == "P20d private", "\(tag): the private window's localhost page loaded")
                done()
            }
        }
        js(pageA, "document.cookie = 'p20d_regular=keep; Path=/'; 'ok'")
        js(regularCache, "document.cookie = 'p20d_regular=keep; Path=/'; 'ok'")
        fetch(regularCache, "/http-cache-p", as: "r1")
        fetch(regularCache, "/http-cache-p", as: "r2")
        expect(privatePage, "document.cookie.includes('p20d_regular') ? 'sees regular' : 'own'", "the private session doesn't see the regular cookie") { $0 == "own" }
        js(privatePage, "document.cookie = 'p20d_private=keep; Path=/'; 'ok'")
        fetch(privatePage, "/http-cache-p", as: "p1")
        fetch(privatePage, "/http-cache-p", as: "p2")
        mark(privatePage)
        choose(["View", "Clear Cookies and Refresh"], key: { privateWindow?.window })
        expectReloaded(privatePage, "private Clear Cookies and Refresh: the private page")
        expect(privatePage, "document.cookie.includes('p20d_private=keep') ? 'kept' : 'gone'", "private Clear Cookies and Refresh removes the private session's cookie") { $0 == "gone" }
        expect(pageA, "document.cookie.includes('p20d_regular=keep') ? 'kept' : 'gone'", "private Clear Cookies and Refresh: the regular profile's cookie for the same site survives") { $0 == "kept" }
        mark(privatePage)
        choose(["View", "Clear Cache and Refresh"], key: { privateWindow?.window })
        expectReloaded(privatePage, "private Clear Cache and Refresh: the private page")
        fetch(privatePage, "/http-cache-p", as: "p3")
        fetch(regularCache, "/http-cache-p", as: "r3")
        run { [self] in
            if reused("p1", "p2", "private cache", transient: isWebKit) {
                check(values["p3"] != values["p1"], "\(tag): private Clear Cache and Refresh empties the private session's cache (\(values["p1"] ?? "-") → \(values["p3"] ?? "-"))")
            }
            if reused("r1", "r2", "regular cache next to the private one") {
                check(values["r3"] == values["r1"], "\(tag): private Clear Cache and Refresh: the regular profile's HTTP cache for the same site survives (\(values["r3"] ?? "-"))")
            }
        }
        expect(pageA, "document.cookie.includes('p20d_regular=keep') ? 'kept' : 'gone'", "after both private clears the regular cookie is still there") { $0 == "kept" }
        if isWebKit {
            expect(pageX, "document.cookie.includes('p20d_regular=keep') ? 'kept' : 'gone'", "after both private clears the owned store's cookie is still there") { $0 == "kept" }
        }
        choose(["View", "Developer", "Inspect Elements"], key: { privateWindow?.window })
        waitDevTools(privatePage, pageA, "private Inspect Elements")
        closeDevTools(privatePage)
        choose(["View", "Developer", "Network Inspector"], key: { privateWindow?.window })
        waitDevTools(privatePage, pageA, "private Network Inspector")
        closeDevTools(privatePage)

        // MARK: 4. Inspect Elements, Network Inspector (a main window)

        run { [self] in c.show(idA, focus: false) }
        choose(["View", "Developer", "Inspect Elements"], key: { self.c.window })
        waitDevTools(pageA, pageB, "Inspect Elements")
        closeDevTools(pageA)
        step { [self] done in
            guard let a = pageA() else { return done() }
            a.inspectElements { result in
                switch result {
                case .success: self.check(!isWebKit, "\(tag): Inspect Elements starts Chromium's element picker")
                case .failure(.unavailable): self.check(isWebKit, "\(tag): Safari's engine says it can't pick a panel (Web Inspector opens instead)")
                case .failure(let e): self.check(false, "\(tag): Inspect Elements: \(e.localizedDescription)")
                }
                done()
            }
        }
        closeDevTools(pageA)
        choose(["View", "Developer", "Network Inspector"], key: { self.c.window })
        waitDevTools(pageA, pageB, "Network Inspector")
        closeDevTools(pageA)

        // MARK: 5. Task Manager

        choose(["Help", "Troubleshooting", "Open Task Manager"], key: { self.c.window })
        step { [self] done in
            waitUntil({ (rows("P20d A").first?.memory ?? 0) > 0 }, timeout: 8) {
                self.check(tm?.window.isVisible == true && tm?.model.isRunning == true && tm?.model.viewer == nil && tm?.window.title == "Task Manager",
                           "\(tag): Help › Troubleshooting › Open Task Manager opens it, sampling, for a regular window")
                done()
            }
        }
        // Chromium has a process's CPU from its second sample on (1 s apart); a busy Mac takes longer than 2.5 s for it.
        step { [self] done in waitUntil({ rows("P20d A").first?.cpu != nil }, timeout: 8) { done() } }
        run { [self] in
            let all = tm?.model.rows ?? []
            let a = rows("P20d A").first, profile = c.store.profile(ofSpace: c.currentSpaceID).name
            check(all.contains { $0.title == "Browser" && $0.firstOfProcess && $0.pid > 0 },
                  "\(tag): the browser has a row (\(all.prefix(4).map(\.title)))")
            check(a != nil && a!.profile == profile && (a!.memory ?? 0) > 0 && a!.cpu != nil && a!.pid > 0 && a!.pid != getpid(),
                  "\(tag): the page's row: its profile, memory, CPU and its own process (\(a.map { "\($0.title) \($0.profile) \($0.memory ?? -1) B \($0.cpu ?? -1) % pid \($0.pid)" } ?? "none"))")
            if isWebKit, case .process(let pid)? = pageA()?.developerProcess {
                check(a?.pid == pid, "\(tag): the WebKit page's row is its web content process (\(pid))")
            }
            let hidden = all.filter(\.isPrivate)
            check(rows("P20d private").isEmpty && !hidden.isEmpty && hidden.allSatisfy { !$0.canEnd && $0.profile == "Private" }
                  && hidden.contains { $0.title == "Private tab" },
                  "\(tag): a regular window's Task Manager shows the private page as \"Private tab\", nameless, and can't end it (\(hidden.map(\.title)))")
            check(tm?.model.note.contains("Private windows") == true, "\(tag): it says why (\(tm?.model.note ?? ""))")
        }
        choose(["Help", "Troubleshooting", "Open Task Manager"], key: { privateWindow?.window })
        wait(1.5)
        run { [self] in
            let mine = rows("P20d private")
            check(tm?.model.viewer === privateWindow && tm?.window.title == "Task Manager — Private Window"
                  && !mine.isEmpty && mine.allSatisfy { $0.isPrivate && $0.canEnd },
                  "\(tag): from the private window it names its own page and can end it (\(mine.map(\.title)))")
        }
        choose(["Help", "Troubleshooting", "Open Task Manager"], key: { self.c.window })
        wait(1.5)
        run { [self] in
            check(tm?.model.viewer == nil && rows("P20d private").isEmpty, "\(tag): opened from a main window again, the private page is nameless again")
        }
        // End Process on B's row only, with the window's own button.
        var pidA: pid_t = 0, pidB: pid_t = 0
        run { [self] in
            guard let tm, let b = rows("P20d B").first(where: \.firstOfProcess) ?? rows("P20d B").first,
                  let i = tm.shown.firstIndex(where: { $0.key == b.key }) else { return check(false, "\(tag): B's row to end") }
            pidA = rows("P20d A").first?.pid ?? 0
            pidB = b.pid
            guard pidA != pidB else { return skip("\(tag): End Process: both pages share process \(pidB)") }
            tm.table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            check(tm.endButton.isEnabled, "\(tag): End Process is enabled for B's row")
            tm.endButton.performClick(nil)
        }
        step { [self] done in
            guard pidB != 0, pidA != pidB else { return done() }
            waitUntil({ kill(pidB, 0) != 0 }, timeout: 8) {
                self.check(kill(pidB, 0) != 0 && errno == ESRCH && kill(pidA, 0) == 0,
                           "\(tag): End Process ended B's process (\(pidB)) and only it (A's \(pidA) lives)")
                done()
            }
        }
        expect(pageA, "document.title", "A still answers after B's process ended") { $0 == "P20d A" }
        // ⌘W in the Task Manager closes it, not the browser window's tab.
        step { [self] done in
            guard let w = tm?.window else { return done() }
            Self.emulateKeyWindow(w) { _ in }
            postKey("w", keyCode: 13, modifiers: .command, to: w)
            waitUntil({ !w.isVisible }, timeout: 3) {
                if w.isVisible {
                    self.note("FAIL-ENV \(tag): the posted ⌘W didn't reach the Task Manager (\(self.inputBlocked ?? "no reason known")); its window's own key equivalent instead")
                    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: w.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                             isARepeat: false, keyCode: 13)
                    if let e { _ = w.performKeyEquivalent(with: e) }
                }
                self.check(!w.isVisible && pageA()?.isClosed == false && self.c.engineTab(for: idA) != nil,
                           "\(tag): ⌘W closes the Task Manager, and the browser window's tab stays")
                done()
            }
        }
        var frozen: [TaskManager.Row] = []
        run { frozen = tm?.model.rows ?? [] }
        wait(2.5)
        run { [self] in
            check(tm?.model.isRunning == false && tm?.model.rows == frozen, "\(tag): closed, the Task Manager samples nothing")
        }

        // MARK: cleanup

        step { done in
            privateWindow?.closeWindow()
            privateWindow = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: done)
        }
        run { server = nil }
        step { [self] done in
            guard isWebKit else { return done() }
            ownedX?.close(); ownedY?.close(); ownedX = nil; ownedY = nil; owned = nil
            func remove(_ left: Int) {
                WKWebsiteDataStore.remove(forIdentifier: ownedStore) { error in
                    if error != nil, left > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { remove(left - 1) }; return }
                    self.check(error == nil, "\(tag): owned WebKit store removed (\(error?.localizedDescription ?? "ok"))")
                    done()
                }
            }
            remove(10)
        }
    }
}
#endif
