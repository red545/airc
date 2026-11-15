// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script paritylinkspaces` (both engines): a page link's "Open Link in Space ›" (SP-31) and Little Airc on a
/// ⌥⌘-click (V06), on a loopback page.
///   - the menu's rows: every Space of the window in sidebar order, another profile's included, with emoji; none for a
///     private window's page or a Little Airc page (Chromium: the engine's adapter; WebKit: its link menu);
///   - real input (AIRC_REAL_KEYS=1, a dedicated session with Airc in front): the UI driver ⌃-clicks the link (macOS's
///     context click), the engine's own menu opens with the item, real ↓/→/Return pick another profile's Space; a new
///     Today tab with the link opens there and the window switches to it; the page stays;
///   - a real ⌥⌘-click opens the link in Little Airc with the setting on; with it off, no Little Airc (the engine's own
///     ⌥⌘/⌘ handling); a plain click stays an ordinary click (the page follows the link).
/// Without AIRC_REAL_KEYS the real-input cases SKIP (posted events don't reach pages in `open -g` windows).
extension SnapshotRunner {
    func parityLinkSpacesScenario() {
        var server: LocalPageServer?
        var base = ""
        var home = "", dest = "", other = "", tab = ""
        var littleSetting = true
        func page(_ path: String) -> String { base + path }
        func mainPage() -> EngineTab? { c.engineTab(for: tab) }
        func littleArc(at path: String) -> LittleArcController? {
            app?.littleArcs.first { $0.page?.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } == path }
        }
        let engine = app?.engine is WebKitEngine ? "WebKit" : "Chromium"
        func label(_ s: String) -> String { "paritylinkspaces \(engine): " + s }
        /// The rows the page's link menu gets: Chromium's adapter closure, or WebKit's delegate (what its menu asks).
        func rows(for tab: EngineTab?) -> [[String: String]] {
            guard let tab else { return [] }
            if let p = tab as? WebKitTab { return p.delegate?.linkSpaces(for: p) ?? [] }
            return app?.engine.contextMenuSpaces?(tab, page("/dest")) ?? []
        }
        /// WebKit: the item its link menu gets, built on a stand-in link menu (WebKit's own identifiers).
        func webKitItem(for page: EngineTab?) -> NSMenuItem? {
            guard let view = (page as? WebKitTab)?.webView as? PageMenuWebView, let tab = page as? WebKitTab else { return nil }
            let menu = NSMenu()
            let open = NSMenuItem(title: "Open Link in New Window", action: nil, keyEquivalent: "")
            open.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
            menu.addItem(open)
            view.insertLinkSpaces(in: menu, tab: tab)
            return menu.items.first { $0.identifier == PageMenuWebView.linkSpacesItem }
        }

        step { [self] done in
            let link = { (id: String, top: Int, href: String) in
                "<a id=\(id) style=\"position:absolute;left:60px;top:\(top)px;width:240px;height:36px;display:block\" href=\"\(href)\">\(id)</a>"
            }
            server = LocalPageServer(pages: [
                "/ls": "<!doctype html><title>ls</title><style>body{margin:0;font:15px -apple-system,sans-serif}</style>"
                    + "<script>window.__ctx=[];addEventListener('contextmenu',e=>__ctx.push([e.button,e.ctrlKey,(e.target.id||e.target.localName)]),true);"
                    + "addEventListener('mousedown',e=>__ctx.push(['down',e.button,e.ctrlKey]),true)</script>"
                    + link("menu", 60, "/dest?menu") + link("la", 130, "/dest?la") + link("off", 200, "/dest?off")
                    + link("plain", 270, "/dest?plain"),
                "/dest": "<!doctype html><title>dest</title><p>Destination</p>"
            ])
            server?.start { port in
                if let port { base = "http://127.0.0.1:\(port)" } else { self.check(false, label("a loopback page server")) }
                done()
            }
        }
        closeLittleArcs()
        step { [self] done in
            app?.settingsWindow?.window.orderOut(nil)
            littleSetting = app?.settings.values.littleArcGlobal.opensOptionCommandClicks ?? true
            home = c.currentSpaceID
            dest = (try? c.store.createSpace(name: "Links here", icon: .emoji("🧭"), profileID: c.store.selectedSpace.profileID).id) ?? ""
            let profile = try? c.profiles.createProfile(name: "Links other", emoji: "", color: nil)
            other = profile.flatMap { try? c.store.createSpace(name: "Links other", icon: .emoji("🪐"), profileID: $0.id).id } ?? ""
            tab = (try? c.store.openTab(url: page("/ls"), inSpace: home, activate: true, title: "ls"))?.id ?? ""
            c.reloadAll(animated: false)
            c.switchToSpace(home, animated: false)
            c.show(tab, focus: false)
            waitUntil({ mainPage()?.isLoading == false && mainPage()?.title == "ls" }, timeout: 8) { done() }
        }

        // The rows.
        run { [self] in
            let r = rows(for: mainPage())
            let expected = c.windowSpaces.map(\.id)
            let otherProfile = c.store.space(other).map { $0.profileID != c.store.space(home)?.profileID } ?? false
            check(!dest.isEmpty && !other.isEmpty && r.compactMap { $0["id"] } == expected && otherProfile
                  && r.contains { $0["title"] == "🪐 Links other" } && r.contains { $0["title"] == "🧭 Links here" },
                  label("the link's Space rows are the window's Spaces in sidebar order (\(r.count) of \(expected.count)), another "
                        + "profile's included (\(otherProfile)), each with its emoji (\(r.compactMap { $0["title"] }))"))
            if engine == "WebKit" {
                let item = webKitItem(for: mainPage())
                check(item?.title == PageMenuWebView.linkSpacesTitle && item?.submenu?.items.map(\.title) == r.compactMap { $0["title"] },
                      label("WebKit's link menu gets “Open Link in Space ›” with those rows (\(item?.title ?? "none"), "
                            + "\(item?.submenu?.items.count ?? 0) rows)"))
            }
        }
        var privateWindow: PrivateWindowController?
        var privatePage: EngineTab?
        step { [self] done in
            guard let app else { return done() }
            PrivateBrowsing.shared.open(app: app) { w in
                privateWindow = w
                privatePage = w?.openPage(URL(string: page("/ls")))
                done()
            }
        }
        step { [self] done in
            waitUntil({ privatePage?.isLoading == false && privatePage?.title == "ls" }, timeout: 8) {
                let r = rows(for: privatePage)
                let item = engine == "WebKit" ? webKitItem(for: privatePage) : nil
                self.check(privatePage != nil && r.isEmpty && item == nil,
                           label("a private window's link has no Space rows (\(r.count)) and no “Open Link in Space” item"))
                done()
            }
        }
        run { privateWindow?.closeWindow() }
        step { [self] done in waitUntil({ PrivateBrowsing.shared.windows.isEmpty }, timeout: 5) { done() } }
        step { [self] done in
            let l = app?.openLittleArc(url: URL(string: page("/ls")), spaceID: home)
            waitUntil({ l?.page?.isLoading == false && l?.page?.title == "ls" }, timeout: 8) {
                let r = rows(for: l?.page)
                self.check(l?.page != nil && r.isEmpty && (engine == "Chromium" || webKitItem(for: l?.page) == nil),
                           label("a Little Airc page's link has no Space rows (\(r.count))"))
                done()
            }
        }
        closeLittleArcs()

        guard UIDriverClient.requested else {
            run { [self] in
                skip(label("real ⌃-click menu and ⌥⌘/plain clicks need AIRC_REAL_KEYS=1 in a dedicated session"))
                app?.settings.values.littleArcGlobal.opensOptionCommandClicks = littleSetting
                server?.stop()
            }
            return
        }

        /// The link's centre in window points, after layout, on the shown home page.
        var point: NSPoint?
        func locate(_ id: String) {
            step { [self] done in
                point = nil
                c.switchToSpace(home, animated: false)
                c.show(tab, focus: true)
                c.root.layoutSubtreeIfNeeded()
                guard let view = mainPage()?.view else { return done() }
                mainPage()?.evaluate("(function(){var r=document.getElementById('\(id)').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()") { v in
                    if let xy = (v as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }), xy.count == 2 {
                        point = view.convert(NSPoint(x: xy[0], y: view.isFlipped ? xy[1] : Double(view.bounds.height) - xy[1]), to: nil)
                    }
                    done()
                }
            }
            wait(0.6)   // past the double-click interval of the previous case
        }

        // Diagnosis (AIRC_LS_RIGHTCLICK=1): a secondary click as a rightMouseDown, posted in-app (NSApp.postEvent) and,
        // with posting access, as a CGEvent, compared with the ⌃-click below.
        if ProcessInfo.processInfo.environment["AIRC_LS_RIGHTCLICK"] == "1" {
            for method in ["nsapp", "cgevent"] {
                locate("menu")
                step { [self] done in
                    guard let p = point else { note(label("rightclick \(method): no point")); return done() }
                    var began = 0
                    let t = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in began += 1 }
                    #if canImport(AircCore)
                    (mainPage() as? ChromiumTab)?.testPageContext = [:]
                    #endif
                    let access = CGPreflightPostEventAccess()
                    if method == "nsapp" {
                        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                            if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: c.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                          pressure: type == .rightMouseDown ? 1 : 0) { NSApp.postEvent(e, atStart: false) }
                        }
                    } else if access, let primary = NSScreen.screens.first {
                        let s = c.window.convertPoint(toScreen: p), q = CGPoint(x: s.x, y: primary.frame.maxY - s.y)
                        DispatchQueue.global().async {
                            for type in [CGEventType.rightMouseDown, .rightMouseUp] {
                                CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: type, mouseCursorPosition: q, mouseButton: .right)?.post(tap: .cghidEventTap)
                                Thread.sleep(forTimeInterval: 0.05)
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                        if began > 0 { UIDriverClient.run(["--key", "esc"]) { _, _ in } }   // close it off the main queue
                        Thread.sleep(forTimeInterval: 0.5)
                        DispatchQueue.main.async {
                            var built = "-"
                            #if canImport(AircCore)
                            built = "\((mainPage() as? ChromiumTab)?.testPageContext["linkURL"] ?? "nothing")"
                            #endif
                            let windows = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))@\(Int($0.level.rawValue))" }
                            mainPage()?.evaluate("JSON.stringify(window.__ctx||null)") { v in
                                self.note(label("rightclick \(method) (post access \(access)): menus began \(began), engine built \(built), windows \(windows), page events \(v ?? "nil")"))
                                NotificationCenter.default.removeObserver(t)
                                mainPage()?.evaluate("window.__ctx=[]") { _ in }
                                done()
                            }
                        }
                    }
                }
            }
        }

        // Open Link in Space ›, by real input.
        locate("menu")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = point else { check(false, label("the menu link is on screen")); return done() }
                uiAttempt?.point = p
                let target = c.store.space(other).map(LinkSpaceMenu.title(of:)) ?? "-"
                var trace: [String] = []
                var opened: NSMenu?
                var token: NSObjectProtocol?
                // The menu's tracking loop may hold the main queue: the keys go from here, reading the menu on the run loop.
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
                func finish(_ picked: Bool, _ title: String) {
                    if let token { NotificationCenter.default.removeObserver(token) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.note(label("menu \"\(title)\", keys: \(trace.joined(separator: " "))"))
                        self.check(picked, label("real ⌃-click opens the engine's link menu with “\(title)” and real ↓ → Return pick “\(target)”"))
                        self.waitUntil({ self.c.store.todayTabs(ofSpace: other).contains { $0.url == page("/dest?menu") } && self.c.currentSpaceID == other }, timeout: 8) {
                            let t = self.c.store.todayTabs(ofSpace: other).first { $0.url == page("/dest?menu") }
                            let loaded = t.flatMap { self.c.engineTab(for: $0.id) }
                            self.check(t != nil && self.c.currentSpaceID == other && self.c.shownTabID == t?.id,
                                       label("the link opens as a new Today tab in the chosen Space, another profile's, and the window "
                                             + "switches to it (tab \(t != nil), Space \(self.c.currentSpaceID == other), shown \(self.c.shownTabID == t?.id))"))
                            self.check(mainPage()?.url?.path == "/ls" && self.c.store.todayTabs(ofSpace: home).allSatisfy { !$0.url.hasPrefix(page("/dest")) },
                                       label("the page stays and its Space gets no tab"))
                            self.waitUntil({ loaded?.isLoading == false && loaded?.title == "dest" }, timeout: 8) {
                                self.check(loaded?.title == "dest", label("the new tab loads the link (\(loaded?.title ?? "-"))"))
                                done()
                            }
                        }
                    }
                }
                #if canImport(AircCore)
                (mainPage() as? ChromiumTab)?.testPageContext = [:]
                #endif
                let endToken = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
                    trace.append("ended(\((n.object as? NSMenu)?.items.count ?? -1))")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NotificationCenter.default.removeObserver(endToken) }
                token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                    if let any = n.object as? NSMenu { trace.append("began(\(any.items.prefix(12).map(\.title).joined(separator: "|")))") }
                    // The root menu: WebKit adds its items (willOpenMenu) after tracking begins, so look again below.
                    guard opened == nil, let m = n.object as? NSMenu, m.supermenu == nil,
                          m.items.contains(where: { $0.title.hasPrefix("Open Link") || $0.title.hasPrefix("Open link") }) else { return }
                    opened = m
                    trace.append("[" + m.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: "|") + "]")
                    DispatchQueue.global(qos: .userInitiated).async {
                        var picked = false
                        Thread.sleep(forTimeInterval: 0.4)
                        let now: String?? = onMain { m.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: "|") }
                        trace.append("open[\((now ?? nil) ?? "?")]")
                        let found: String?? = onMain { m.items.first { $0.title.caseInsensitiveCompare("Open Link in Space") == .orderedSame }?.title }
                        let title: String = (found ?? nil) ?? "-"
                        defer { if !picked { _ = key("esc"); _ = key("esc") }; finish(picked, title) }
                        var onItem = false
                        for _ in 0..<40 {
                            guard key("down") else { trace.append("down failed"); return }
                            let h = onMain { m.highlightedItem?.title } ?? nil
                            trace.append("↓" + (h ?? "-"))
                            if h == title { onItem = true; break }
                        }
                        guard onItem, key("right") else { return }
                        Thread.sleep(forTimeInterval: 0.3)
                        guard let sub = onMain({ m.items.first { $0.title == title }?.submenu }) ?? nil else { trace.append("no submenu"); return }
                        for i in 0..<30 {
                            let h = onMain { sub.highlightedItem?.title } ?? nil
                            trace.append((i == 0 ? "→" : "↓") + (h ?? "-"))
                            if h == target { picked = key("return"); trace.append("⏎"); return }
                            guard key("down") else { return }
                        }
                    }
                }
                UIDriverClient.click(p, in: c.window, mods: "ctrl") { ok, output in
                    if !ok { self.check(false, label("real driver ⌃-click: \(output)")) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        guard opened == nil else { return }
                        let windows = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))@\(Int($0.level.rawValue))" }
                        #if canImport(AircCore)
                        if let cr = mainPage() as? ChromiumTab { trace.append("engine built menu for \(cr.testPageContext["linkURL"] ?? "nothing")") }
                        #endif
                        trace.append("visible windows \(windows), key \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "-"), active \(NSApp.isActive), point \(p)")
                        mainPage()?.evaluate("JSON.stringify(window.__ctx||null)") { v in
                            trace.append("page events \(v ?? "nil")")
                            DispatchQueue.global().async { _ = key("esc"); finish(false, "no menu opened") }
                        }
                    }
                }
            }
        }

        // ⌥⌘-click with the setting on: Little Airc.
        locate("la")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = point else { check(false, label("the ⌥⌘ link is on screen")); return done() }
                uiAttempt?.point = p
                app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
                UIDriverClient.click(p, in: c.window, mods: "opt,cmd") { ok, output in
                    self.waitUntil({ littleArc(at: "/dest?la") != nil }, timeout: 5) {
                        self.check(ok && littleArc(at: "/dest?la") != nil && mainPage()?.url?.path == "/ls" && littleArc(at: "/dest?la")?.spaceID == home,
                                   label("setting on: a real ⌥⌘-click opens the link in Little Airc in the page's Space, and the page stays "
                                         + "(driver \(ok ? "ok" : output), windows \(self.app?.littleArcs.count ?? 0))"))
                        done()
                    }
                }
            }
        }
        closeLittleArcs()

        // ⌥⌘-click with it off: the engine's own handling, no Little Airc.
        locate("off")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = point else { check(false, label("the second ⌥⌘ link is on screen")); return done() }
                uiAttempt?.point = p
                app?.settings.values.littleArcGlobal.opensOptionCommandClicks = false
                let before = Set(c.store.todayTabs(ofSpace: home).map(\.id))
                UIDriverClient.click(p, in: c.window, mods: "opt,cmd") { ok, output in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let added = self.c.store.todayTabs(ofSpace: home).filter { !before.contains($0.id) }.map(\.url)
                        self.note(label("setting off, ⌥⌘-click: new tabs \(added), page \(mainPage()?.url?.path ?? "-")"))
                        self.check(ok && self.app?.littleArcs.isEmpty == true,
                                   label("setting off: a real ⌥⌘-click opens no Little Airc (driver \(ok ? "ok" : output), windows "
                                         + "\(self.app?.littleArcs.count ?? 0))"))
                        self.app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
                        done()
                    }
                }
            }
        }

        // A plain click, setting on: an ordinary click.
        locate("plain")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = point else { check(false, label("the plain link is on screen")); return done() }
                uiAttempt?.point = p
                app?.settings.values.littleArcGlobal.opensOptionCommandClicks = true
                guard NSApp.isActive, c.window.isKeyWindow, let primary = NSScreen.screens.first else {
                    check(false, label("plain click: the window is the active key window")); return done()
                }
                // No --mods: the driver refuses an empty one.
                let screen = c.window.convertPoint(toScreen: p)
                UIDriverClient.run(["--click", String(Double(screen.x)), String(Double(primary.frame.maxY - screen.y))]) { ok, output in
                    self.waitUntil({ mainPage()?.url?.query == "plain" && mainPage()?.isLoading == false }, timeout: 5) {
                        self.check(ok && mainPage()?.url?.query == "plain" && self.app?.littleArcs.isEmpty == true,
                                   label("setting on: a real plain click is an ordinary click, the page follows the link and no Little Airc "
                                         + "opens (driver \(ok ? "ok" : output), page \(mainPage()?.url.map { $0.path + "?" + ($0.query ?? "") } ?? "-"))"))
                        done()
                    }
                }
            }
        }
        // The menu open while its tab closes (the menu must not outlive the page): no crash, no hang, the tab goes.
        var original = ""
        var closing = ""
        step { [self] done in
            original = tab
            closing = (try? c.store.openTab(url: page("/ls?close"), inSpace: home, activate: true, title: "ls close"))?.id ?? ""
            tab = closing
            c.reloadAll(animated: false)
            c.show(closing, focus: true)
            waitUntil({ mainPage()?.isLoading == false && mainPage()?.title == "ls" }, timeout: 8) { done() }
        }
        locate("menu")
        uiCase(window: { self.c.window }) {
            step { [self] done in
                guard let p = point else { check(false, label("close case: the link is on screen")); return done() }
                uiAttempt?.point = p
                var opened = false, ended = false, closedDuring = false
                var tokens: [NSObjectProtocol] = []
                tokens.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { n in
                    if (n.object as? NSMenu)?.supermenu == nil { ended = true }
                })
                tokens.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                    guard !opened, (n.object as? NSMenu)?.supermenu == nil else { return }
                    opened = true
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
                        // On the run loop, as a person's ⌘W would act, while the menu is still open.
                        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                            closedDuring = !ended
                            self.c.closeTab(closing)
                        }
                        CFRunLoopWakeUp(CFRunLoopGetMain())
                        Thread.sleep(forTimeInterval: 1.5)
                        if !ended { UIDriverClient.run(["--key", "esc"]) { _, _ in } }
                    }
                })
                UIDriverClient.click(p, in: c.window, mods: "ctrl") { ok, output in
                    if !ok { self.check(false, label("close case: real driver ⌃-click: \(output)")) }
                    self.waitUntil({ opened && ended && self.c.store.tab(closing) == nil }, timeout: 8) {
                        tokens.forEach(NotificationCenter.default.removeObserver)
                        self.check(opened && closedDuring && ended && self.c.store.tab(closing) == nil,
                                   label("the tab closes while its context menu is open: the menu goes, the app lives on (menu \(opened), "
                                         + "closed during it \(closedDuring), menu ended \(ended), tab gone \(self.c.store.tab(closing) == nil))"))
                        done()
                    }
                }
            }
        }
        run { [self] in
            tab = original
            app?.settings.values.littleArcGlobal.opensOptionCommandClicks = littleSetting
            server?.stop()
        }
    }
}
#endif
