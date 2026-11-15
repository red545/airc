// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AircKit
import AppKit
#if canImport(AircCore)
import AircCore
#endif

/// `--script parityc08` (C08, docs/qa/parity-audit.md; docs/user/search-engine.md), both engines. One loopback server
/// stands in for every search engine (`SearchEngineStandIn`): a request's first path part is the engine's host, so the
/// check sees which engine was asked. Nothing reaches a real search engine.
///   A. The picker: Settings → Profiles lists Chromium's engines; two profiles keep their own (Personal DuckDuckGo, Work
///      Brave), drawn to parityc08-profiles(-chromium).png.
///   B. Suggestions: the Command Bar asks the Space's profile's engine (DuckDuckGo in Personal, Brave in Work); a
///      profile with "Include search engine suggestions" off asks nothing; the search row opens that engine.
///   C. ⌘L: typed words search the profile's engine. With AIRC_REAL_KEYS=1 (the build Mac's UI driver, a dedicated session), ⌘L, the letters (for the keyboard layout)
///      and Return are real key presses to this app's PID; without it, the bar's own typing path (labelled).
///   D. The page's context menu on selected text: Chromium's "Search Google for" replaced by "Search DuckDuckGo for
///      “…”" (WebKit: its "Search with Google" by "Search with DuckDuckGo"), which opens a new tab on the engine. The menu
///      is the engine's native one, opened by an in-app right click (labelled).
///   E. A link from another app opens as it is (Little Airc), never re-searched; its menu's search uses the default.
///   F. A private window: its Command Bar suggests from the profile's engine, none when the profile turned them off, and
///      its menu search names the profile's engine.
///   G. A site search made the default (P07d) is what the menu search names and opens.
extension SnapshotRunner {
    func parityC08Scenario() {
        let engineName = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        let tag = "parityc08 (\(engineName))"
        var server: LocalPageServer?
        var port: UInt16 = 0
        let lock = NSLock()
        var requests: [String] = []
        var home = "", work = "", homeSpace = "", workSpace = "", selTab = ""
        var bar: CommandBarView? { self.c.commandBar }
        func asked(_ prefix: String) -> Bool { lock.withLock { requests.contains { $0.hasPrefix(prefix) } } }
        func count(_ prefix: String) -> Int { lock.withLock { requests.filter { $0.hasPrefix(prefix) }.count } }
        let ddg = "/duckduckgo.com/", brave = "/search.brave.com/"
        let page = { self.c.engineTab(for: selTab) }
        func openURL(_ r: CommandResult?) -> String? {
            if case .open(let u)? = r?.action { return u.absoluteString }
            return nil
        }

        step { [self] done in
            server = LocalPageServer(pages: [:])
            server?.requestHandler = { req in
                lock.withLock { requests.append(req.target) }
                let parts = req.path.split(separator: "/")
                if req.path == "/sel.html" {
                    return .init(body: "<!doctype html><title>C08 select</title><style>p{font:20px sans-serif;margin:0;padding:8px}</style><p id=s>loopback flowers</p>")
                }
                if req.path == "/other.html" { return .init(body: "<!doctype html><title>C08 other app</title><p>from another app</p>") }
                // Suggestion endpoints: OpenSearch JSON naming the engine that answered.
                if req.target.contains("/ac/") || req.target.contains("suggest") || req.target.contains("osjson") || req.target.contains("sugg") {
                    let host = parts.first.map(String.init) ?? "?"
                    return .init(headers: ["Content-Type": "application/json"], body: #"["q",["\#(host) one","\#(host) two"]]"#)
                }
                return .init(body: "<!doctype html><title>C08 results</title><p>results</p>")
            }
            server?.start { p in
                port = p ?? 0
                SearchEngineStandIn.origin = "http://127.0.0.1:\(port)"
                done()
            }
        }
        run { [self] in
            check(port != 0, "\(tag): the loopback stand-in engine listens")
            app?.settings.values.suggestionsEnabled = true
            homeSpace = c.currentSpaceID
            home = c.store.profile(ofSpace: homeSpace).id
            try? c.store.updateProfile(home) { $0.searchEngine = .duckDuckGo }
            do {
                let p = try c.profiles.createProfile(name: "Work", emoji: "💼", color: RGBA(hex: "7EB6D5"))
                work = p.id
                try c.store.updateProfile(work) { $0.searchEngine = .brave }
                workSpace = try c.store.createSpace(name: "Work", icon: .emoji("💼"), profileID: p.id, after: homeSpace).id
            } catch { check(false, "\(tag): a Work profile and Space (\(error))") }
            note("\(tag): window on active Space \(c.window.isOnActiveSpace), real input \(UIDriverClient.available ? "requested" : "off"), layout \(UIDriverClient.layoutName)")
        }

        // A. The picker, per profile.
        run { [self] in
            let names = SearchEngine.allCases.map(\.name)
            check(names == ["Google", "Bing", "DuckDuckGo", "Ecosia", "Brave", "Yahoo", "Startpage", "Perplexity", "Kagi"],
                  "\(tag) A: the picker lists \(names.joined(separator: ", "))")
            check(c.store.profile(home)?.searchEngine == .duckDuckGo && c.store.profile(work)?.searchEngine == .brave,
                  "\(tag) A: Personal keeps DuckDuckGo, Work keeps Brave")
            app?.showSettings(page: .profiles)
        }
        wait(0.8)
        run { [self] in
            if let v = app?.settingsWindow?.window.contentView, let img = render(v), let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                let name = app?.engine is WebKitEngine ? "parityc08-profiles.png" : "parityc08-profiles-chromium.png"
                try? png.write(to: dir.appendingPathComponent(name))
                note("wrote \(name)")
            }
            app?.settingsWindow?.window.close()
        }

        // B. Suggestions from the Space's profile's engine.
        func suggest(space: @escaping () -> String, query: String, want: String?, label: String) {
            run { [self] in
                c.switchToSpace(space(), animated: false)
                c.closeCommandBar()
                c.openCommandBar(mode: .newTab)
            }
            wait(0.2)
            run { bar?.type(query) }
            step { [self] done in
                let ok = { want.map { w in bar?.results.contains { $0.title == w } == true } ?? false }
                waitUntil(ok, timeout: want == nil ? 1.5 : 5) {
                    let titles = bar?.results.map(\.title) ?? []
                    if let want {
                        self.check(ok(), "\(tag) B: \(label) suggests from its engine (“\(want)”; rows \(titles.prefix(5)))")
                    } else {
                        self.check(!titles.contains { $0.hasSuffix(" one") }, "\(tag) B: \(label) shows no suggestions (rows \(titles.prefix(5)))")
                    }
                    done()
                }
            }
        }
        suggest(space: { homeSpace }, query: "c08 personal", want: "duckduckgo.com one", label: "Personal (DuckDuckGo)")
        run { [self] in
            check(asked(ddg + "ac/") && !asked(brave), "\(tag) B: only DuckDuckGo was asked (\(count(ddg)) requests, Brave \(count(brave)))")
            let row = bar?.results.first { $0.badge == "Search" }
            check(openURL(row)?.hasPrefix("http://127.0.0.1:\(port)/duckduckgo.com/?q=c08%20personal") == true,
                  "\(tag) B: Personal's search row opens DuckDuckGo (\(openURL(row) ?? "-"))")
        }
        suggest(space: { workSpace }, query: "c08 work", want: "search.brave.com one", label: "Work (Brave)")
        run { [self] in
            check(asked(brave + "api/suggest"), "\(tag) B: Work asked Brave")
            try? c.store.updateProfile(work) { $0.searchSuggestions = false }
            lock.withLock { requests.removeAll() }
        }
        suggest(space: { workSpace }, query: "c08 quiet", want: nil, label: "Work with suggestions off")
        run { [self] in
            check(count(brave) == 0 && count(ddg) == 0, "\(tag) B: with Work's suggestions off nothing was sent (\(lock.withLock { requests }))")
            check(c.store.profile(home)?.includesSearchSuggestions == true, "\(tag) B: Personal's suggestions stay on")
            c.closeCommandBar()
            c.switchToSpace(homeSpace, animated: false)
        }

        // D. The context menu on a selection (before C, so the page is the one shown).
        step { [self] done in
            guard let t = try? c.store.openTab(url: "http://127.0.0.1:\(port)/sel.html", inSpace: homeSpace) else {
                check(false, "\(tag) D: the selection page opens"); return done()
            }
            selTab = t.id
            c.reloadAll(animated: false)
            c.show(t.id, focus: false)
            waitUntil({ page()?.title == "C08 select" && page()?.isLoading == false }, timeout: 15, then: done)
        }
        wait(1)
        // Real input (AIRC_REAL_KEYS=1, a dedicated session under the UI lock): a scripted run never activates the app,
        // so the check does, and records FAIL-ENV with the evidence when the window still isn't key.
        var realInput = false
        step { [self] done in
            guard UIDriverClient.available else { return done() }
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 3) {
                realInput = NSApp.isActive && self.c.window.isKeyWindow && self.c.window.isOnActiveSpace
                if !realInput {
                    self.note("FAIL-ENV \(tag): real input needs the window key (active \(NSApp.isActive), key \(self.c.window.isKeyWindow), "
                              + "on active Space \(self.c.window.isOnActiveSpace), front \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")); in-app input instead")
                }
                done()
            }
        }
        step { [self] done in
            guard let tab = page() else { check(false, "\(tag) D: the page"); return done() }
            var how = "in-app right click"
            let tabsBefore = Set(c.store.state.tabs.keys)
            func opened() -> String? {
                c.store.state.tabs.values.first { !tabsBefore.contains($0.id) && $0.url.contains("/duckduckgo.com/?q=loopback%20flowers") }?.url
            }
            func after() {
                waitUntil({ opened() != nil && asked(ddg + "?q=loopback%20flowers") }, timeout: 10) {
                    self.check(opened() != nil && asked(ddg + "?q=loopback%20flowers"),
                               "\(tag) D: the menu's search opens a new tab on DuckDuckGo (\(opened() ?? "none"); \(how))")
                    done()
                }
            }
            tab.evaluate("var r=document.createRange();r.selectNodeContents(document.getElementById('s'));getSelection().removeAllRanges();getSelection().addRange(r)") { _ in
                #if canImport(AircCore)
                if let cr = tab as? ChromiumTab, let engine = self.app?.engine as? ChromiumEngine {
                    var seen = false
                    cr.testPageMenu = { menu in
                        seen = true
                        let items = menu["items"] as? [[String: Any]] ?? []
                        let labels = items.compactMap { $0["label"] as? String }
                        let ours = items.first { ($0["label"] as? String) == "Search DuckDuckGo for “loopback flowers”" }
                        self.check(ours != nil, "\(tag) D: Chromium's menu says Search DuckDuckGo for “loopback flowers” (\(labels))")
                        self.check(!labels.contains { $0.contains("Google") }, "\(tag) D: and no Search Google item")
                        cr.testPageMenu = nil
                        return ours?["id"].map { ["command": $0] }
                    }
                    let click = { (type: String, then: @escaping () -> Void) in
                        engine.devToolsCall("Input.dispatchMouseEvent", params: ["type": type, "x": 40, "y": 18, "button": "right", "clickCount": 1], in: tab) { reply, error in
                            self.note("\(tag) D: \(type) reply \(String(describing: reply).prefix(80)) error \(String(describing: error).prefix(120)); shown \(self.c.shownTabID == selTab), in window \(tab.view.window != nil)")
                            then()
                        }
                    }
                    // One retry: the first right click can land before the page takes input.
                    func rightClick(_ attempt: Int) {
                        click("mousePressed") { click("mouseReleased") {
                            self.waitUntil({ seen }, timeout: 4) {
                                if !seen && attempt == 1 { self.note("\(tag) D: no menu on the first right click, retrying"); return rightClick(2) }
                                self.check(seen, "\(tag) D: the native menu opened (attempt \(attempt))")
                                seen ? after() : done()
                            }
                        } }
                    }
                    if realInput {
                        // A real ⌃-click from the UI driver: the HID stream, at the selected words.
                        let v = tab.view
                        let point = v.convert(NSPoint(x: 40, y: v.isFlipped ? 18 : v.bounds.height - 18), to: nil)
                        UIDriverClient.click(point, in: self.c.window, mods: "ctrl") { ok, out in
                            self.waitUntil({ seen }, timeout: 4) {
                                if seen {
                                    how = "real ⌃-click from the UI driver"
                                    self.check(true, "\(tag) D: the native menu opened (\(how))")
                                    return after()
                                }
                                self.note("\(tag) D: no menu from the real ⌃-click (driver ok \(ok): \(out.prefix(160))); in-app right click instead")
                                rightClick(1)
                            }
                        }
                    } else {
                        rightClick(1)
                    }
                    return
                }
                #endif
                guard let wk = tab as? WebKitTab, let view = wk.webView as? PageMenuWebView else { self.check(false, "\(tag) D: a page menu"); return done() }
                var seen = false
                view.testMenuOpened = { menu in
                    seen = true
                    view.testMenuOpened = nil
                    let titles = menu.items.map(\.title)
                    let ours = menu.items.first { $0.identifier == PageMenuWebView.searchWebItem }
                    self.check(ours?.title == "Search with DuckDuckGo" && !titles.contains { $0.contains("Google") },
                               "\(tag) D: WebKit's menu says Search with DuckDuckGo (\(titles))")
                    DispatchQueue.main.async {
                        menu.cancelTracking()
                        if let item = ours, let sel = item.action { NSApp.sendAction(sel, to: item.target, from: item) }
                    }
                }
                let point = view.convert(NSPoint(x: 40, y: view.isFlipped ? 18 : view.bounds.height - 18), to: nil)
                let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: self.c.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let cancel = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                    guard let menu = note.object as? NSMenu else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { menu.cancelTracking() }
                }
                DispatchQueue.main.async { self.c.window.sendEvent(event) }
                self.waitUntil({ seen }, timeout: 5) {
                    NotificationCenter.default.removeObserver(cancel)
                    self.check(seen, "\(tag) D: the native menu opened")
                    seen ? after() : done()
                }
            }
        }

        // C. ⌘L: words typed search the profile's engine.
        run { [self] in
            c.switchToSpace(homeSpace, animated: false)
            c.show(selTab, focus: true)
            lock.withLock { requests.removeAll() }
        }
        step { [self] done in
            let want = "/duckduckgo.com/?q=wool"
            let finish = { (how: String) in
                self.waitUntil({ asked(want) }, timeout: 10) {
                    self.check(asked(want), "\(tag) C: ⌘L, “wool”, Return searches DuckDuckGo (\(how); \(lock.withLock { requests }.prefix(4)))")
                    self.c.closeCommandBar()
                    done()
                }
            }
            if realInput, let typing = UIDriverClient.keys(typing: "wool") {
                let pid = ProcessInfo.processInfo.processIdentifier
                // ⌘L (L is where it is on every layout), then the letters for this layout, then Return: real key
                // presses from the UI driver to this app's PID.
                UIDriverClient.press(["cmd+l"], pid: pid) { ok1, out1 in
                    self.waitUntil({ self.c.commandBar?.mode == .editURL }, timeout: 2) {
                        UIDriverClient.press(typing, pid: pid) { ok2, out2 in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let b = self.c.commandBar
                                self.note("\(tag) C: before Return (layout \(UIDriverClient.layoutName), keys \(typing)): bar \(b != nil), "
                                          + "mode \(String(describing: b?.mode)), field “\(b?.fieldText ?? "-")”, rows \(b?.results.prefix(3).map { "\($0.title) [\($0.badge)]" } ?? []), "
                                          + "key \(NSApp.keyWindow === self.c.window); driver \(ok1) \(ok2) \(out1.prefix(60)) \(out2.prefix(60))")
                                UIDriverClient.press(["return"], pid: pid) { _, _ in finish("real keys from the UI driver") }
                            }
                        }
                    }
                }
            } else {
                c.openCommandBar(mode: .editURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.c.commandBar?.type("wool")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let r = self.c.commandBar?.results.first(where: { $0.badge == "Search" }) {
                            self.c.performCommand(r.action, newTab: false, typed: true)
                        }
                        finish("the bar's typing path, no UI driver")
                    }
                }
            }
        }

        // E. A link from another app opens as it is.
        run { [self] in
            lock.withLock { requests.removeAll() }
            app?.openFromOtherApp([URL(string: "http://127.0.0.1:\(port)/other.html")!], source: "org.airc.c08-test")
        }
        step { [self] done in
            func shown() -> Bool {
                app?.littleArcs.contains { $0.page?.url?.path == "/other.html" } == true
                    || c.store.state.tabs.values.contains { $0.url.hasSuffix("/other.html") }
            }
            waitUntil({ shown() && asked("/other.html") }, timeout: 10) {
                self.check(shown() && asked("/other.html") && !asked(ddg) && !asked(brave),
                           "\(tag) E: a link from another app opens as it is, nothing searched (\(lock.withLock { requests }))")
                if let l = self.app?.littleArcs.first(where: { $0.page?.url?.path == "/other.html" }), let p = l.page {
                    let items = l.tab(p, pageMenu: ["selection": "from little"])
                    self.check(items.first?["title"] == "Search DuckDuckGo for “from little”",
                               "\(tag) E: Little Airc's menu search names DuckDuckGo (\(items.first?["title"] ?? "-"))")
                    l.closeWindow()
                }
                done()
            }
        }

        // F. A private window.
        var priv: PrivateWindowController?
        step { [self] done in
            c.switchToSpace(homeSpace, animated: false)
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in priv = w; done() }
        }
        wait(0.5)
        run { [self] in
            guard let w = priv else { return check(false, "\(tag) F: a private window opens") }
            check(w.commandBarSuggestions?.engine == .duckDuckGo, "\(tag) F: the private window suggests from DuckDuckGo")
            let items = w.tab(w.shownPage ?? c.engineTab(for: selTab)!, pageMenu: ["selection": "private words"])
            check(items.first?["title"] == "Search DuckDuckGo for “private words”" && items.first?["replaces"] == "search",
                  "\(tag) F: its menu search names DuckDuckGo (\(items.first?["title"] ?? "-"))")
            try? c.store.updateProfile(home) { $0.searchSuggestions = false }
            check(w.commandBarSuggestions == nil, "\(tag) F: none once the profile turns suggestions off")
            try? c.store.updateProfile(home) { $0.searchSuggestions = nil }
            w.window.close()
        }

        // G. A site search made the default.
        run { [self] in
            guard let settings = app?.settings else { return }
            if case .success(let s) = settings.values.siteSearch.add(name: "Loopback Find", keyword: "lf",
                                                                     template: "http://127.0.0.1:\(port)/find?q=%s", to: home) {
                settings.values.siteSearch.setDefault(s.id, for: home)
                let items = c.tab(c.engineTab(for: selTab)!, pageMenu: ["selection": "a&b"])
                let url = SelectionSearchMenu.query(fromID: items.first?["id"] ?? "").flatMap { SelectionSearch.url($0, search: c.store.profile(home)!.defaultSearch) }
                check(items.first?["title"] == "Search Loopback Find for “a&b”" && url?.absoluteString == "http://127.0.0.1:\(port)/find?q=a%26b",
                      "\(tag) G: with a site search the default, the menu searches it (\(items.first?["title"] ?? "-"), \(url?.absoluteString ?? "-"))")
                check(c.commandBarSuggestions == nil, "\(tag) G: and the Command Bar asks no engine for suggestions")
                settings.values.siteSearch.remove(s.id, from: home)
            }
        }

        run { [self] in
            SearchEngineStandIn.origin = nil
            server?.stop()
            note("\(tag): done")
        }
    }
}
#endif
