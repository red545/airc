// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING
import AppKit
import AircKit
import WebKit

/// `--script devmode` (both engines): DEV-1 Developer Mode as Arc did it, on a loopback fixture page.
///   - on by itself for localhost (Settings' automatic switch, on by default); turned off, nothing is installed at all;
///   - ⌃D turns it on for the site on screen and off again (posted while the owner is away, else the command itself),
///     remembered per host (settings read back from disk), in another tab and on another port of the same host, and on
///     the page already open without a reload; the full URL in the URL field, the selected row's outline;
///   - Site Controls' row turns an automatic site off (remembered as such) and on again;
///   - a remote site (Chromium: a mapped *.example host) is off until turned on, then on and remembered;
///   - the counter: two calls, the page's own scheduler untouched, identity restored when turned off, rapid on/off,
///     Hard Reload refetching, Inspect and Console;
///   - console call sites: with the inspector closed (a CDP session on the page, Chromium) and open (the real
///     frontend's links), a console.error from fixture.js points at fixture.js, never at Airc's script;
///   - the strip's Inspect, Network (Chromium) and console badge select their panel in the open inspector, which keeps
///     its state (P20a's EngineDeveloperCommands); WebKit offers no Network button;
///   - Clear data for the site and reload (the Reload button's menu, the Command Bar): its cookie and storage go;
///   - a private window's localhost page gets no Developer Mode: no wrapper, no count.
extension SnapshotRunner {
    func developerModeScenario() {
        var server: LocalPageServer?, port: UInt16 = 0, id = "", other = ""
        // Written only by the server queue; read by the app through /hits, not shared unsafely across queues.
        var hits = 0
        var webKit = false
        let mode = DeveloperMode.shared
        let page = { self.c.engineTab(for: id) }
        let strip = { self.c.pageView(for: self.c.currentSpaceID)?.developerStrip }
        let field = { self.c.pageView(for: self.c.currentSpaceID)?.urlField }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let local = { "http://localhost:\(port)/" }
        let remoteHost = "devmode-remote.example"
        let mapped = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--host-resolver-rules=") && $0.contains(remoteHost) }
        func expect(_ title: String, timeout: Double = 10, _ condition: @escaping () -> Bool) {
            step { [self] done in waitUntil(condition, timeout: timeout) { self.check(condition(), "devmode: " + title); done() } }
        }
        func native(_ title: String, _ tab: @escaping () -> EngineTab? = { self.c.engineTab(for: id) }) {
            step { [self] done in
                guard let t = tab() else { check(false, "devmode: " + title + " (no page)"); return done() }
                t.evaluate("/\\[native code\\]/.test(String(console.error))") { v in
                    self.check(v as? Bool == true, "devmode: " + title)
                    done()
                }
            }
        }
        /// ⌃D as a key while the owner is away (whenOwnerAway, SplitParityCheck.swift), else the command itself.
        func controlD(_ label: String) {
            step { [self] done in
                whenOwnerAway { why in
                    if let why {
                        self.failEnv("devmode: ⌃D (\(label)): the posted key", why)
                        CommandMenus.all.first { $0.id == "view.developerSite" }?.run(self.c)
                        return done()
                    }
                    self.postKey("d", keyCode: 2, modifiers: .control)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: done)
                }
            }
        }
        func saved() -> AppSettings.Values { AppSettings(directory: AppPaths.dataDirectory).values }

        step { done in
            // The site's own icon (inline), which its rows keep in Developer Mode.
            let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' rx='8' fill='#3B7BE0'/></svg>"
            let icon = "<link rel='icon' href='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())'>"
            server = LocalPageServer(pages: [
                "/": "<title>Developer fixture</title>\(icon)<script src='/asset'></script><script src='/fixture.js'></script><h1>Developer fixture</h1>"
            ])
            server?.handler = { path in
                if path == "/asset" { hits += 1; return .init(headers: ["Cache-Control": "public, max-age=3600", "Content-Type": "text/javascript"], body: "document.documentElement.dataset.assetHit = '\(hits)';") }
                if path == "/fixture.js" {
                    // Late enough that Airc has answered the document's "ready" before its two errors run.
                    return .init(headers: ["Content-Type": "text/javascript"], body: """
                    console.error('devmode-attribution-one');
                    console.error('devmode-attribution-two');
                    window.logFromFixture = function () {
                      console.error('devmode-closed-probe');
                    };
                    """, delay: 0.3)
                }
                if path == "/hits" { return .init(body: String(hits)) }
                return nil
            }
            server?.start { port = $0 ?? 0; done() }
            if server == nil { done() }
        }

        // Defaults: automatic for localhost (Arc), nothing turned on by hand.
        run { [self] in
            check(mode.automatic && mode.policy.isEmpty && app?.settings.values.developerAutomatic == true,
                  "devmode: on automatically for localhost by default, no site turned on by hand")
            check(PageScripts.shared?.contains("devmode") == true, "devmode: the page part is there while a site can be on")
            check(mode.applies(local()) && mode.applies("http://app.localhost:3000/") && mode.applies("http://127.0.0.1:5173/")
                  && !mode.applies("https://example.com/") && !mode.applies("http://192.168.1.20:8080/"),
                  "devmode: localhost, its subdomains and 127.0.0.1 automatically; other sites not")
            // Upgrading from the opt-in `developerMode` of 2026-11-07, on or off: localhost is automatic (Arc's default)
            // and no site is turned on from it, not even the .test, .local and LAN hosts that switch covered.
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("airc-devmode-upgrade-\(UUID().uuidString)")
            var upgraded = true
            for old in [true, false] {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try? Data(#"{"developerMode": \#(old), "suggestionsEnabled": false}"#.utf8).write(to: dir.appendingPathComponent("settings.json"))
                let v = AppSettings(directory: dir).values
                upgraded = upgraded && !v.suggestionsEnabled && v.developerAutomatic && v.developerSites.isEmpty
                    && v.developerSites.isOn("http://localhost:3000/", automatic: v.developerAutomatic)
                    && !v.developerSites.isOn("http://myapp.test:3000/", automatic: v.developerAutomatic)
                    && !v.developerSites.isOn("http://192.168.1.20:8080/", automatic: v.developerAutomatic)
            }
            try? fm.removeItem(at: dir)
            check(upgraded, "devmode: an older settings file's developerMode, on or off, becomes automatic localhost only, no site on")
            // Automatic off: nothing can be on, so nothing is installed.
            if let app { mode.setAutomatic(false, app: app) }
            check(PageScripts.shared?.contains("devmode") == false && saved().developerAutomatic == false,
                  "devmode: automatic off and no site on: no page part at all, and the switch is saved")
            guard let t = try? c.store.openTab(url: local(), inSpace: c.currentSpaceID) else { return }
            id = t.id
            c.reloadAll(animated: false)
            c.show(id, focus: false)
        }
        expect("a localhost page loads while nothing is on", { page()?.title == "Developer fixture" && page()?.isLoading == false })
        // fixture.js comes 0.3 s late: wait until it has run, so its two errors aren't counted after ⌃D below.
        step { [self] done in
            func poll(_ tries: Int) {
                page()?.evaluate("typeof window.logFromFixture === 'function'") { v in
                    if v as? Bool == true || tries > 40 { self.check(v as? Bool == true, "devmode: the fixture's script has run"); return done() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(tries + 1) }
                }
            }
            poll(0)
        }
        native("off leaves native console.error untouched")
        run { [self] in
            webKit = page() is WebKitTab
            check(strip()?.isHidden != false && field()?.displayedHost == URLRules.displayHost(local()),
                  "devmode: off, no strip and the usual host in the URL field (\(field()?.displayedHost ?? "-"))")
        }
        step { [self] done in page()?.evaluate("window.originalError = console.error; true") { _ in done() } }

        // ⌃D: on for this site, by hand (automatic is off), on the open page without a reload.
        controlD("on")
        expect("⌃D turns it on for localhost by hand, remembered", {
            mode.policy.enabledHosts == ["localhost"] && saved().developerSites.enabledHosts == ["localhost"]
        })
        expect("the open page is instrumented without a reload, and shows its full URL and strip", {
            mode.count(page()) != nil && page()?.title == "Developer fixture" && strip()?.isHidden == false
                && field()?.displayedHost == DeveloperMode.displayURL(local())
        })
        run { [self] in
            c.pageView(for: c.currentSpaceID)?.layoutSubtreeIfNeeded()
            let row = c.pageView(for: c.currentSpaceID).flatMap { todayRow(id, in: $0) }
            check(row?.isSelected == true && row?.plate.borderWidth == DeveloperMode.outlineWidth,
                  "devmode: the selected row takes the Developer Mode outline (\(row?.plate.borderWidth ?? -1) pt)")
        }
        // Its row keeps the site's own icon, as in Arc: Developer Mode never stands in for the favicon (favretry's rows).
        step { [self] done in
            func shown() -> (row: NSImage?, page: NSImage?) {
                c.pageView(for: c.currentSpaceID)?.layoutSubtreeIfNeeded()
                let row = c.pageView(for: c.currentSpaceID).flatMap { todayRow(id, in: $0) }
                return (row?.faviconViewForTesting.shownImage, page()?.favicon)
            }
            // The engine may hand over a new image object for the same icon: the same size counts.
            func same(_ s: (row: NSImage?, page: NSImage?)) -> Bool { s.page != nil && (s.row === s.page || s.row?.size == s.page?.size) }
            waitUntil({ same(shown()) }, timeout: 5) {
                let s = shown()
                self.check(same(s),
                           "devmode: its row shows the site's own icon (page icon \(s.page != nil), row \(s.row.map { "\($0.size)" } ?? "blank"))")
                done()
            }
        }
        wait(0.3)
        step { done in page()?.evaluate("window.savedScheduler = queueMicrotask; window.replacedSchedulerCalls = 0; queueMicrotask = function(f) { replacedSchedulerCalls++; savedScheduler(f); }; console.error('one'); console.error('two'); true") { _ in done() } }
        step { [self] done in
            waitUntil({ mode.count(page()) == 2 && strip()?.countTitle == "2" }, timeout: 10) {
                let ok = mode.count(page()) == 2 && strip()?.countTitle == "2"
                if !ok { self.note("devmode: page part trace \(DeveloperMode.trace.suffix(16))") }
                self.check(ok, "devmode: two calls reach the counter (count \(mode.count(page()).map(String.init) ?? "none"), badge \(strip()?.countTitle ?? "-"))")
                done()
            }
        }
        step { [self] done in page()?.evaluate("replacedSchedulerCalls === 0 && console.error !== window.originalError") { v in
            check(v as? Bool == true, "devmode: console instrumented while on; the page's scheduler doesn't intercept error reporting")
            done()
        } }
        // The same host on another port and in another tab follows it.
        run { [self] in
            check(mode.applies("http://localhost:\(port + 1)/elsewhere"), "devmode: the site is the host: every port and path")
            if let t = try? c.store.openTab(url: local() + "?other", inSpace: c.currentSpaceID, background: true, activate: false) {
                other = t.id
                c.reloadAll(animated: false)
            }
        }
        step { [self] done in
            // Load the background tab's page, then come back.
            if !other.isEmpty { c.show(other, focus: false) }
            waitUntil({ mode.count(self.c.engineTab(for: other)) != nil }, timeout: 8) {
                self.check(mode.count(self.c.engineTab(for: other)) != nil, "devmode: another tab of the same host is in Developer Mode")
                self.c.show(id, focus: false)
                done()
            }
        }

        // ⌃D again: off. Nothing can be on now: the page part goes, and the open page gets its own console.error back.
        controlD("off")
        expect("⌃D again turns it off and forgets the host", { mode.policy.isEmpty && saved().developerSites.isEmpty })
        step { [self] done in
            waitUntil({ PageScripts.shared?.contains("devmode") == false }, timeout: 3) {
                page()?.evaluate("console.error === window.originalError") { v in
                    self.check(v as? Bool == true && PageScripts.shared?.contains("devmode") == false && strip()?.isHidden == true,
                               "devmode: off restores the page's own console.error in place and installs nothing")
                    done()
                }
            }
        }
        run { page()?.load(URL(string: "http://localhost:\(port)/?off")!) }
        wait(1)
        native("a new document while off has no wrapper")

        // Automatic again: localhost on by itself; Site Controls' row turns it off (remembered) and on.
        run { [self] in if let app { mode.setAutomatic(true, app: app) } }
        run { page()?.load(URL(string: "http://localhost:\(port)/?auto")!) }
        expect("automatic on: a new localhost document is in Developer Mode", { mode.count(page()) != nil && strip()?.isHidden == false })
        run { [self] in
            check(DeveloperSiteRow.shows(page()) && mode.policy.isAutomaticallyOn(local()),
                  "devmode: Site Controls has a Developer Mode row, on automatically for this site")
            c.showSiteControls()
        }
        wait(0.5)
        step { [self] done in
            whenOwnerAway { why in
                if let why {
                    self.failEnv("devmode: a real click on Site Controls' Developer Mode switch", why)
                    if let app { mode.set(local(), on: false, app: app) }
                    return done()
                }
                guard let host = self.c.siteControls?.hostingView else { self.check(false, "devmode: Site Controls is open"); return done() }
                self.clickAnchor("site.developerSwitch", in: host) { done() }
            }
        }
        expect("Site Controls' switch turns the automatic site off, remembered as such", {
            mode.policy.disabledDefaultHosts == ["localhost"] && saved().developerSites.disabledDefaultHosts == ["localhost"] && mode.count(page()) == nil
        })
        run { [self] in
            _ = c.closeSiteControls()
            if let app { mode.set(local(), on: true, app: app) }
        }
        expect("and on again: back to automatic", { mode.policy.isEmpty && mode.count(page()) != nil })

        // A remote site: off until turned on, then on and remembered (Chromium maps the host to the fixture).
        run { [self] in
            if let app {
                check(!mode.applies("https://staging.example.org/") && mode.set("https://staging.example.org/app", on: true, app: app) == "staging.example.org"
                      && mode.applies("https://staging.example.org/other") && saved().developerSites.enabledHosts.contains("staging.example.org"),
                      "devmode: a remote site turned on is on for its whole host and saved")
                mode.forget(site: "staging.example.org", app: app)
            }
            if mapped { page()?.load(URL(string: "http://\(remoteHost):\(port)/")!) }
        }
        if mapped {
            expect("a remote page loads, not in Developer Mode", { page()?.title == "Developer fixture" && strip()?.isHidden == true })
            native("a remote site that's off has no wrapper")
            controlD("remote on")
            expect("⌃D turns the remote site on: strip, counter and full URL", {
                mode.policy.enabledHosts == [remoteHost] && mode.count(page()) != nil && field()?.displayedHost == "http://\(remoteHost):\(port)/"
            })
            run { [self] in if let app { mode.forget(site: remoteHost, app: app) } }
            run { page()?.load(URL(string: "http://localhost:\(port)/?back")!) }
            expect("back on localhost", { mode.count(page()) != nil })
        } else {
            run { [self] in skip("devmode: a remote page needs --host-resolver-rules for \(remoteHost) (Chromium launch)") }
        }

        // Hard Reload, Inspect and Console.
        run { page()?.load(URL(string: "http://localhost:\(port)/?again")!) }
        wait(1)
        step { [self] done in page()?.evaluate("Number(document.documentElement.dataset.assetHit)") { v in
            check(((v as? NSNumber)?.intValue ?? 0) >= 1, "devmode: the fixture's cached asset loaded (\(String(describing: v)))"); done() } }
        step { [self] done in
            page()?.evaluate("Number(document.documentElement.dataset.assetHit)") { before in
                strip()?.hardReload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    page()?.evaluate("Number(document.documentElement.dataset.assetHit)") { v in
                        self.check(((v as? NSNumber)?.intValue ?? 0) > ((before as? NSNumber)?.intValue ?? 0),
                                   "devmode: Hard Reload refetches the cached asset (\(String(describing: before)) → \(String(describing: v)))")
                        done()
                    }
                }
            }
        }
        expect("the count is the new document's", { mode.count(page()) == 2 })
        // Call sites with the inspector closed (Chromium: a CDP session on the page).
        step { [self] done in
            if webKit { skip("devmode: closed-inspector call sites are a Chromium check (WebKit keeps console messages only while its inspector is open)"); return done() }
            developerClosedInspectorAttribution(port: port, done)
        }
        run { strip()?.openInspector() }
        expect("Inspect opens the engine's inspector", { page()?.isDevToolsOpen == true })
        var marker = false
        step { [self] done in markInspector { ok in marker = ok; done() } }
        run { strip()?.openConsole() }
        expect("the console badge opens the console", { page()?.isDevToolsOpen == true })
        wait(2)
        step { [self] done in
            guard marker else { skip("devmode: Console keeping its state: the inspector couldn't be marked"); return done() }
            inspectorStillMarked { kept, detail in
                self.check(kept, "devmode: switching to Console keeps the inspector's state (\(detail))")
                done()
            }
        }
        // Network (Chromium), then Console again: the same inspector, at that panel.
        run { [self] in
            check(strip()?.offersNetwork == !webKit, "devmode: the strip offers Network on Chromium only (\(strip()?.offersNetwork == true))")
            if !webKit { strip()?.openNetwork() }
        }
        for panel in ["network", "console"] {
            wait(1.5)
            step { [self] done in
                guard !webKit else { return done() }
                selectedPanel { selected, marker in
                    self.check(selected == panel && marker == "kept",
                               "devmode: the strip's \(panel == "network" ? "Network" : "console badge") selects \(panel) in the same inspector (\(selected ?? "none"), marker \(marker ?? "none"))")
                    if panel == "network" { strip()?.openConsole() }
                    done()
                }
            }
        }
        // WebKit creates its local console backend when developer extras are enabled by Inspect.
        // Reload after opening it so these source-link assertions use that inspected document.
        run { if webKit { page()?.reloadIgnoringCache() } }
        wait(3)
        step { [self] done in
            if webKit { webInspectorAttribution(done) } else { developerConsoleAttribution(done) }
        }
        // Clear data for the site and reload (the Reload button's menu, the Command Bar; the engine's own call).
        step { [self] done in
            page()?.evaluate("document.cookie = 'devmodeClear=1; path=/'; localStorage.setItem('devmodeClear', '1'); window.devmodeBeforeClear = true; "
                             + "document.cookie.includes('devmodeClear') && localStorage.getItem('devmodeClear') === '1'") { v in
                self.check(v as? Bool == true, "devmode: the fixture stores a cookie and local storage")
                done()
            }
        }
        wait(2)
        run { [self] in c.reloadAll(animated: false) }   // the strip asks again (WebKit names a site once it has data)
        expect("the strip names the site the engine clears", { strip()?.clearLabel == "Clear data for localhost and its subdomains and reload" })
        run { [self] in
            let titles = c.developerCommandActions().map(\.title)
            check(titles.contains("Clear Data for localhost and Its Subdomains and Reload"),
                  "devmode: the Command Bar offers Clear Data for localhost and Its Subdomains and Reload (\(titles))")
            strip()?.clearSiteDataAndReload()
        }
        step { [self] done in
            var tries = 0
            func probe() {
                page()?.evaluate("[window.devmodeBeforeClear === true, document.cookie.includes('devmodeClear'), localStorage.getItem('devmodeClear')]") { v in
                    let a = v as? [Any]
                    let reloaded = a.flatMap { $0.first as? Bool } == false
                    if !reloaded, tries < 16 { tries += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: probe); return }
                    let cookie = a.flatMap { $0.count > 1 ? $0[1] as? Bool : nil }
                    let stored = a.flatMap { $0.count > 2 ? $0[2] : nil }
                    self.check(reloaded && cookie == false && (stored == nil || stored is NSNull),
                               "devmode: Clear data reloads the page without its cookie and local storage (reloaded \(reloaded), cookie \(cookie.map { "\($0)" } ?? "-"), storage \(stored.map { "\($0)" } ?? "-"), toast \(self.c.toast.shownText ?? "none"))")
                    done()
                }
            }
            probe()
        }
        run { [self] in
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front, "devmode: the inspector doesn't activate the app")
            if let app { mode.setAutomatic(false, app: app) }
            check(PageScripts.shared?.contains("devmode") == false, "devmode: nothing can be on: the page part goes")
            check(strip()?.isHidden == true && field()?.displayedHost == URLRules.displayHost("http://localhost:\(port)/?again"),
                  "devmode: off restores the URL field (\(field()?.displayedHost ?? "-"))")
        }
        native("off restores native console.error")
        run { [self] in
            if let app {
                mode.setAutomatic(true, app: app)
                mode.setAutomatic(false, app: app)
            }
        }
        wait(0.5)
        native("rapid on/off leaves no wrapper")

        // Private windows never use Developer Mode.
        var privateWindow: PrivateWindowController?, privatePage: EngineTab?
        run { [self] in
            guard let app else { return }
            mode.setAutomatic(true, app: app)
            PrivateBrowsing.shared.open(app: app) { w in privateWindow = w }
        }
        step { [self] done in waitUntil({ privateWindow != nil }, timeout: 8) { done() } }
        run { privatePage = privateWindow?.openPage(URL(string: "http://localhost:\(port)/?private")) }
        step { [self] done in waitUntil({ privatePage.map { !$0.isLoading && $0.title == "Developer fixture" } ?? false }, timeout: 10) { done() } }
        wait(0.5)
        run { [self] in
            check(privatePage.map { DeveloperMode.isPrivate($0) && !mode.applies(to: $0) && mode.count($0) == nil } ?? false
                  && !DeveloperSiteRow.shows(privatePage),
                  "devmode: a private window's localhost page isn't in Developer Mode (no count, no Site Controls row)")
        }
        native("a private page gets no wrapper", { privatePage })
        run { [self] in
            privateWindow?.closeWindow()
            if let app { mode.setAutomatic(true, app: app) }
            page()?.load(URL(string: "data:text/html,<title>Ordinary page</title><h1>Ordinary page</h1>")!)
        }
        expect("a page that isn't a site has no strip", { page()?.title == "Ordinary page" && strip()?.isHidden == true })
        run { [self] in
            check(c.pageView(for: c.currentSpaceID)?.developerAddress("https://example.com:8443/path") == URLRules.displayHost("https://example.com:8443/path"),
                  "devmode: a site that's off keeps the usual address")
            check(DeveloperMode.displayURL("http://user:secret@localhost:3000/a?q=1#x") == "http://localhost:3000/a?q=1#x",
                  "devmode: the full URL never shows a user name or password")
            server?.stop()
        }
    }

    // MARK: The inspector's state across the Console switch

    /// Marks the open inspector's frontend (a property on its window) so a later read can tell it's the same one.
    private func markInspector(_ done: @escaping (Bool) -> Void) {
        if let frontend = webInspectorFrontend() {
            frontend.evaluateJavaScript("window.__aircDevmodeMarker = 'kept'; true") { v, _ in done(v as? Bool == true) }
            return
        }
        devToolsFrontend(expression: "window.__aircDevmodeMarker = 'kept'; true") { value, _ in done(value as? Bool == true) }
    }

    private func inspectorStillMarked(_ done: @escaping (Bool, String) -> Void) {
        if let frontend = webInspectorFrontend() {
            frontend.evaluateJavaScript("[window.__aircDevmodeMarker, WI.tabBrowser?.selectedTabContentView?.type ?? WI.tabBrowser?.selectedTabContentView?.identifier]") { v, _ in
                let a = v as? [Any]
                done((a?.first as? String) == "kept", "marker \(a?.first ?? "none"), tab \(a?.last ?? "-")")
            }
            return
        }
        devToolsFrontend(expression: "window.__aircDevmodeMarker || 'none'") { value, detail in
            done((value as? String) == "kept", "marker \(value ?? "none"), \(detail)")
        }
    }

    /// Chromium: the open DevTools frontend's selected panel and the marker set on it.
    private func selectedPanel(_ done: @escaping (String?, String?) -> Void) {
        devToolsFrontend(expression: """
        (async () => {
          const UI = await import('./ui/legacy/legacy.js');
          return [UI.InspectorView.InspectorView.instance().tabbedPane.selectedTabId, window.__aircDevmodeMarker || 'none'];
        })()
        """, awaitPromise: true) { value, _ in
            let a = value as? [Any]
            done(a?.first as? String, a?.last as? String)
        }
    }

    private func webInspectorFrontend() -> WKWebView? {
        guard let id = c.shownTabID, let tab = c.engineTab(for: id) as? WebKitTab,
              let inspector = tab.webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: NSSelectorFromString("inspectorWebView")) else { return nil }
        return inspector.perform(NSSelectorFromString("inspectorWebView"))?.takeUnretainedValue() as? WKWebView
    }

    // MARK: Console call sites

    /// WebKit: the real Web Inspector's message links name fixture.js.
    private func webInspectorAttribution(_ done: @escaping () -> Void) {
        guard let frontend = webInspectorFrontend() else { check(false, "devmode: Web Inspector frontend available"); return done() }
        let readout = """
        (() => {
          // Background inspector animation frames can be suspended. Flush its own pending
          // message views, without focusing a window or fabricating source links.
          WI.consoleLogViewController.renderPendingMessages();
          const messages = [];
          function walk(root) {
            for (const e of root.querySelectorAll('*')) {
              if (e.classList.contains('console-message') && e.textContent.includes('devmode-'))
                messages.push({message:e.textContent,link:e.querySelector('.console-message-location')?.textContent});
              if (e.shadowRoot) walk(e.shadowRoot);
            }
          }
          walk(document);
          return {messages};
        })()
        """
        frontend.evaluateJavaScript(readout) { value, error in
            let rows = (value as? [String: Any])?["messages"] as? [[String: Any]] ?? []
            self.note("devmode: Web Inspector readout \(rows.count) rows; error \(String(describing: error))")
            let fixture = rows.filter { ($0["message"] as? String)?.contains("devmode-attribution-") == true }
            self.check(!fixture.isEmpty && fixture.allSatisfy { ($0["link"] as? String ?? "").contains("fixture.js") },
                  "devmode: with the inspector open, its console links point at fixture.js (\(fixture.compactMap { $0["link"] as? String }))")
            done()
        }
    }

    /// The test build's loopback CDP endpoint (`--remote-debugging-port`), or nil.
    private var remoteDebuggingPort: Int? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--remote-debugging-port=") }
            .flatMap { Int($0.split(separator: "=").last ?? "") }
    }

    /// One CDP connection to the browser endpoint: `call` sends and waits for the answer, keeping events it sees.
    private final class CDP {
        let socket: URLSessionWebSocketTask
        var serial = 0
        var events: [[String: Any]] = []
        init(_ socket: URLSessionWebSocketTask) { self.socket = socket }
        func call(_ method: String, _ params: [String: Any], session: String? = nil) async throws -> [String: Any] {
            serial += 1
            let id = serial
            var message: [String: Any] = ["id": id, "method": method, "params": params]
            if let session { message["sessionId"] = session }
            try await socket.send(.string(String(data: try JSONSerialization.data(withJSONObject: message), encoding: .utf8)!))
            while true {
                let object = try await next()
                if object["id"] as? Int == id { return object["result"] as? [String: Any] ?? object }
                events.append(object)
            }
        }
        func next() async throws -> [String: Any] {
            let response = try await socket.receive()
            let text: String
            switch response { case .string(let s): text = s; case .data(let d): text = String(decoding: d, as: UTF8.self); @unknown default: text = "{}" }
            return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        }
        static func open(port: Int) async throws -> CDP {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/json/version")!)
            let info = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let socket = URLSession.shared.webSocketTask(with: URL(string: info["webSocketDebuggerUrl"] as! String)!)
            socket.resume()
            return CDP(socket)
        }
    }

    /// Chromium, inspector closed: a CDP session on the page records fixture.js's console.error, whose top frame is
    /// fixture.js (the Proxy leaves no Airc frame above the page's call).
    private func developerClosedInspectorAttribution(port fixturePort: UInt16, _ done: @escaping () -> Void) {
        guard let port = remoteDebuggingPort else {
            skip("devmode: closed-inspector call sites need --remote-debugging-port in the scratch test build"); return done()
        }
        Task { @MainActor in
            guard let cdp = try? await CDP.open(port: port) else {
                skip("devmode: closed-inspector call sites: the test build's CDP endpoint on \(port) isn't listening"); return done()
            }
            defer { cdp.socket.cancel(with: .goingAway, reason: nil) }
            do {
                let targets = try await cdp.call("Target.getTargets", [:])
                let list = targets["targetInfos"] as? [[String: Any]] ?? []
                guard let target = list.first(where: { $0["type"] as? String == "page" && ($0["url"] as? String)?.contains("localhost:\(fixturePort)") == true }),
                      let tid = target["targetId"] as? String else {
                    check(false, "devmode: the fixture's page target (\(list.count) targets)"); return done()
                }
                let attached = try await cdp.call("Target.attachToTarget", ["targetId": tid, "flatten": true])
                let session = attached["sessionId"] as? String
                _ = try await cdp.call("Runtime.enable", [:], session: session)
                _ = try await cdp.call("Runtime.evaluate", ["expression": "logFromFixture()"], session: session)
                var found: [String: Any]?
                for _ in 0..<40 where found == nil {
                    found = cdp.events.first { e in
                        e["method"] as? String == "Runtime.consoleAPICalled"
                            && ((((e["params"] as? [String: Any])?["args"] as? [[String: Any]])?.first?["value"]) as? String) == "devmode-closed-probe"
                    }
                    if found == nil { cdp.events.append(try await cdp.next()) }
                }
                let frames = (((found?["params"] as? [String: Any])?["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]]) ?? []
                let top = frames.first
                note("devmode: closed-inspector console.error frames \(frames.map { "\(($0["url"] as? String).map { URL(string: $0)?.lastPathComponent ?? $0 } ?? "-"):\(($0["lineNumber"] as? Int).map { $0 + 1 } ?? 0)" })")
                check((top?["url"] as? String)?.hasSuffix("/fixture.js") == true && (top?["lineNumber"] as? Int) == 3,
                      "devmode: with the inspector closed, console.error's call site is fixture.js:4, not Airc's script")
                _ = try? await cdp.call("Target.detachFromTarget", ["sessionId": session ?? ""])
            } catch { check(false, "devmode: closed-inspector CDP read failed: \(error)") }
            done()
        }
    }

    /// Evaluates `expression` in the open DevTools frontend (Chromium, through the test build's CDP endpoint).
    private func devToolsFrontend(expression: String, awaitPromise: Bool = false, _ done: @escaping (Any?, String) -> Void) {
        guard let port = remoteDebuggingPort else { return done(nil, "no --remote-debugging-port") }
        Task { @MainActor in
            do {
                let cdp = try await CDP.open(port: port)
                defer { cdp.socket.cancel(with: .goingAway, reason: nil) }
                let list = (try await cdp.call("Target.getTargets", ["filter": [[:]]]))["targetInfos"] as? [[String: Any]] ?? []
                guard let target = list.first(where: { ($0["url"] as? String)?.hasPrefix("devtools://") == true }), let tid = target["targetId"] as? String else {
                    return done(nil, "no DevTools frontend target")
                }
                let session = (try await cdp.call("Target.attachToTarget", ["targetId": tid, "flatten": true]))["sessionId"] as? String
                let reply = try await cdp.call("Runtime.evaluate", ["expression": expression, "returnByValue": true, "awaitPromise": awaitPromise], session: session)
                done((reply["result"] as? [String: Any])?["value"], "frontend \(tid.prefix(8))")
            } catch { done(nil, "CDP: \(error)") }
        }
    }

    /// Chromium, inspector open: the real DevTools frontend's console links name fixture.js.
    private func developerConsoleAttribution(_ done: @escaping () -> Void) {
        guard remoteDebuggingPort != nil else {
            skip("devmode: source-link assertion needs --remote-debugging-port in the scratch test build"); return done()
        }
        let expression = """
        (() => {
          const nodes = [];
          function walk(root) {
            for (const e of root.querySelectorAll('*')) {
              if (e.classList.contains('console-message')) nodes.push(e);
              if (e.shadowRoot) walk(e.shadowRoot);
            }
          }
          walk(document);
          return nodes.filter(e => e.textContent.includes('devmode-attribution-')).map(e => ({
            message: e.textContent, link: e.querySelector('.console-message-anchor')?.textContent
          }));
        })()
        """
        devToolsFrontend(expression: expression) { value, detail in
            let rows = value as? [[String: Any]] ?? []
            self.note("devmode: DevTools source links \(rows.compactMap { $0["link"] as? String }) (\(detail))")
            self.check(rows.count >= 2 && rows.allSatisfy { ($0["link"] as? String)?.contains("fixture.js:") == true },
                       "devmode: with the inspector open, DevTools console links point at fixture.js, not injected script")
            done()
        }
    }
}
#endif
