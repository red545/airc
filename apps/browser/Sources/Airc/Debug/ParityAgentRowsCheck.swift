// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityagentrows` (artifacts/agentrows/REPORT.md): the Agents folder only shows agents that did something,
/// titles them by what happened, and lets finished ones go by themselves. The real `airc-mcp` helper is the MCP client
/// (agentspike's SpikeMCPClient) on synthetic loopback pages, on either engine.
///
/// It checks: a client that only connects (initialize, tools/list, list_profiles, like a Claude Code session starting)
/// gets no row, nor one that opens a blank window and looks at it; a client that opens a fixture page, clicks, types,
/// reads and goes to a second page gets a row titled "Corner Shop · filled a form, read 2 pages" (no typed text, path or
/// port), with "<app> · <status>" under it; when the clients end, the rows read Done and go after the keep time
/// (shortened to 6 s here), still listed in Activity; a row the person watches stays until they stop watching; the
/// folder hides itself once empty; a private window's page is never named anywhere (rows, banner, history); the
/// "Keep finished agents for" setting is saved.
/// agentrows (2026-11-23): an app with two pages is one row (one per session, AgentRowsCensus), before and after Show
/// all, with one status (the spinner while it works) and only its name under the title; All tasks lists the session
/// once; a click on the row (real with the UI driver in a dedicated session) opens Watch on it, and a click on its All
/// tasks row too.
extension SnapshotRunner {
    func parityAgentRowsScenario() {
        let v = AgentRowsCheck(runner: self)
        step { done in v.setUp(done) }
        step { done in v.connectOnly(done) }
        step { done in v.blankWindow(done) }
        step { done in v.titledRow(done) }
        step { done in v.oneRowPerSession(done) }
        step { done in v.watchedStays(done) }
        step { done in v.autoClose(done) }
        step { done in v.setting(done) }
        run { v.finish() }
    }
}

final class AgentRowsCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var server: LocalPageServer?
    var port: UInt16 = 0
    var spike: AgentSpike!
    var worker: SpikeMCPClient?
    var watched: SpikeMCPClient?
    var workRow = ""
    var watchRow = ""
    var privateWindow: PrivateWindowController?
    let typed = "hello-rows-typed-7731"
    static let keep: TimeInterval = 6
    var real = false

    init(runner: SnapshotRunner) { self.runner = runner }

    var base: String { "http://127.0.0.1:\(port)" }
    var activity: AgentActivity { .shared }
    var folder: SidebarAgentsView { c.sidebar.agents }

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "parityagentrows \(engine): " + what) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    func descendants(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { descendants(of: $0) } }

    static let shopPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Corner Shop</title><style>
    body{margin:0;font:15px -apple-system,sans-serif}header{height:64px;background:#7a3b1f;color:#fff;display:flex;align-items:center;padding:0 20px;font-size:20px}
    #order{position:absolute;left:40px;top:100px;width:160px;height:40px}#note{position:absolute;left:40px;top:180px;width:240px;height:36px}
    </style></head><body><header>Corner Shop</header>
    <button id="order" onclick="document.title='Corner Shop';this.textContent='Added'">Order again</button>
    <input id="note" aria-label="Note for the shop" placeholder="Note" autocomplete="off">
    <p style="position:absolute;top:240px;left:40px">Fixture text the row must never show.</p></body></html>
    """
    static let helpPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Pickup help - Corner Shop</title></head>
    <body style="font:15px -apple-system,sans-serif"><h1>Pickup help</h1><p>Open 8 to 18.</p></body></html>
    """
    static let privatePage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Private Diary</title></head>
    <body><h1>Private Diary</h1><p>Never named by agents.</p></body></html>
    """

    // MARK: Steps

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        spike = AgentSpike(runner: runner)
        spike.engine = engine
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("parityagentrows \(engine): input \(real ? "real (UI driver)" : "posted")")
        UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
        folder.model.expanded = true
        server = LocalPageServer(responses: [
            "/shop.html": LocalPageServer.Page(body: Self.shopPage),
            "/help.html": LocalPageServer.Page(body: Self.helpPage),
            "/private.html": LocalPageServer.Page(body: Self.privatePage),
        ])
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fixture server on loopback")
            let profile = c.store.profile(ofSpace: c.currentSpaceID)
            app.profiles.whenLoaded(profile.id, { _ in
                AgentCenter.shared.app = self.app
                AgentCenter.shared.enableForCheck(grants: [], http: false)
                AgentCenter.shared.approvals.automatic = true
                AgentCenter.shared.setShowInFront(false)
                self.activity.keepOverrideForCheck = Self.keep
                self.check(AgentCenter.shared.isServing, "the agent server listens")
                self.check(self.folder.height == 0 && self.folder.model.items.isEmpty, "no Agents folder before any agent works")
                // A private window of the same profile, on a page of its own: it must never be named.
                PrivateBrowsing.shared.open(app: self.app) { pw in
                    self.privateWindow = pw
                    self.check(pw != nil, "a private window opens")
                    pw?.navigate(URL(string: "http://localhost:\(self.port)/private.html")!)
                    self.after(1.5) { done() }
                }
            }, failed: { self.check(false, "the profile loads"); done() })
        }
    }

    func startClient(_ name: String, _ done: @escaping (SpikeMCPClient?, String) -> Void) {
        let k = SpikeMCPClient(helper: spike.helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", name])
        guard k.start() else { return done(nil, "the helper didn't start") }
        k.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]], timeout: 15) { m in
            guard m["result"] != nil else { return done(nil, "\(m["error"] ?? "no answer") \(k.stderrText)") }
            k.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            done(k, "")
        }
    }

    /// Nothing about the person's private page anywhere an agent row, banner or history line could say it.
    func privateNeverNamed() -> Bool {
        var said = activity.model.rows.flatMap { [$0.rowTitle, $0.label, $0.title, $0.url?.absoluteString ?? ""] }
        said += folder.model.items.flatMap { [$0.title, $0.subtitle, $0.label] }
        said += activity.banners
        said += activity.history.entries.flatMap { [$0.site, $0.line] }
        return !said.contains { $0.contains("localhost") || $0.contains("Private Diary") || $0.contains("private.html") }
    }

    /// (1) A client that connects and lists, like a Claude Code session starting (it connects to every MCP server it has).
    func connectOnly(_ done: @escaping () -> Void) {
        let historyBefore = activity.history.entries.count
        startClient("rows-connect-only") { k, why in
            guard let k else { self.check(false, "the connect-only client connects (\(why))"); return done() }
            k.request("tools/list", [:]) { _ in
                k.call("list_profiles") { _, _ in
                    self.after(2) {
                        self.check(self.folder.model.items.isEmpty && self.folder.height == 0 && self.activity.model.rows.isEmpty,
                                   "a client that only connects and lists gets no row (items \(self.folder.model.items.map(\.title)))")
                        k.stop()
                        self.after(1.5) {
                            self.check(self.folder.model.items.isEmpty && self.folder.height == 0,
                                       "and none when it disconnects")
                            self.check(self.activity.history.entries.count == historyBefore,
                                       "nothing in Activity for it (\(self.activity.history.entries.count - historyBefore) new)")
                            done()
                        }
                    }
                }
            }
        }
    }

    /// (1b) A blank window that the client only looks at: still no row.
    func blankWindow(_ done: @escaping () -> Void) {
        startClient("rows-blank") { k, why in
            guard let k else { self.check(false, "the blank-window client connects (\(why))"); return done() }
            k.call("open_window") { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                self.check(!SpikeMCPClient.isError(r) && w > 0, "open_window without an address")
                k.call("screenshot", ["window": w]) { _, _ in
                    k.call("list_tabs", ["window": w]) { _, _ in
                        self.after(1) {
                            let hidden = self.activity.model.rows.filter { $0.window == w }
                            self.check(self.folder.model.items.isEmpty && self.folder.height == 0 && hidden.allSatisfy { !$0.shown },
                                       "a blank window the agent only looks at gets no row (pending \(hidden.count), shown \(self.folder.model.items.count))")
                            k.call("close_window", ["window": w]) { _, _ in
                                k.stop()
                                self.after(1.5) {
                                    self.check(self.folder.model.items.isEmpty && !self.activity.model.rows.contains { $0.window == w },
                                               "it leaves nothing behind")
                                    self.check(self.activity.banners.isEmpty, "no start banner for it (\(self.activity.banners))")
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// (2) Real work on a fixture page: a titled row.
    func titledRow(_ done: @escaping () -> Void) {
        startClient("rows-worker") { k, why in
            guard let k else { self.check(false, "the worker client connects (\(why))"); return done() }
            self.worker = k
            k.call("open_window", ["url": "\(self.base)/shop.html"]) { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                self.check(!SpikeMCPClient.isError(r) && w > 0, "open_window on the Corner Shop fixture")
                k.call("list_tabs", ["window": w]) { r, _ in
                    let tab = ((SpikeMCPClient.json(r)["tabs"] as? [[String: Any]])?.first?["tab"] as? Int) ?? 0
                    self.workRow = AgentActivityModel.rowID(window: w, tab: tab)
                    self.runner.waitUntil({ self.folder.model.items.contains { $0.id == self.workRow } && self.folder.height > 0 }, timeout: 6) {
                        let first = self.folder.model.items.first { $0.id == self.workRow }
                        self.check(first?.title == "Corner Shop", "the row shows with its page, titled by the site (\(first?.title ?? "none"))")
                        self.check((self.activity.banners.last ?? "").hasSuffix("is using Airc · Corner Shop"),
                                   "the start banner shows for it (\(self.activity.banners.last ?? "-"))")
                        k.call("left_click", ["window": w, "coordinate": [120, 120]]) { _, _ in
                            k.call("left_click", ["window": w, "coordinate": [160, 198]]) { _, _ in
                                k.call("type", ["window": w, "text": self.typed]) { _, _ in
                                    k.call("read_page", ["window": w]) { _, _ in
                                        k.call("navigate", ["window": w, "url": "\(self.base)/help.html"]) { _, _ in
                                            // Until the acting tail ends: the subtitle is checked quiet.
                                            self.runner.waitUntil({ self.folder.model.items.first { $0.id == self.workRow }?.acting == false }, timeout: 6) {
                                                self.after(0.3) { self.checkTitle(done) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func checkTitle(_ done: @escaping () -> Void) {
        c.root.layoutSubtreeIfNeeded()
        let item = folder.model.items.first { $0.id == workRow }
        let title = item?.title ?? ""
        check(title == "Corner Shop · filled a form, read 2 pages", "the title says what happened (\(title))")
        check(!title.contains(typed) && !title.contains("Order again") && !title.contains("Note") && !title.contains("Fixture")
              && !title.contains("\(port)") && !title.contains(".html") && !title.contains("127.0.0.1"),
              "the title holds no typed text, label, page text, address or port")
        let sub = item?.subtitle ?? ""
        // agentrows: the app's name alone while it works between calls ("· Waiting" said nothing the icon doesn't).
        check(sub == item?.client && item?.client.contains("rows-worker") == true,
              "under it: the app's name only (\(sub))")
        check(TestAnchors.view("agents-title-\(workRow)", in: c.sidebar) != nil, "the titled row is on screen in the sidebar")
        check(privateNeverNamed(), "the private window's page is never named")
        if let pw = privateWindow?.window.contentView {
            check(!descendants(of: pw).contains { $0 is SidebarAgentsView }, "the private window has no Agents folder")
        }
        done()
    }

    /// (2b) agentrows: the worker opens a second page and works there: still one row for it, in the folder and on All
    /// tasks, before and after Show all; one status; a click on either opens Watch. The second page closes again.
    func oneRowPerSession(_ done: @escaping () -> Void) {
        guard let k = worker, let row = activity.model.row(workRow) else { check(false, "agentrows: the worker's row for one-row-per-session"); return done() }
        let key = row.sessionKey, w = row.window
        k.call("open_tab", ["url": "\(base)/help.html", "window": w]) { r, _ in
            let tab = SpikeMCPClient.json(r)["tab"] as? Int ?? 0
            let second = AgentActivityModel.rowID(window: w, tab: tab)
            k.call("select_tab", ["window": w, "tab": tab]) { _, _ in
                self.runner.waitUntil({ self.activity.model.row(second)?.shown == true }, timeout: 5) {
                    k.call("left_click", ["window": w, "coordinate": [60, 60]]) { _, _ in
                        let pages = self.activity.model.rows.filter { $0.sessionKey == key && $0.shown && $0.isLive }.count
                        let census = AgentRowsCensus.folderSession(self.c, session: key)
                        self.check(pages == 2 && census.ok, "agentrows: an app working on two pages is one row (\(census.detail))")
                        let item = self.folder.model.items.first { $0.id == census.row }
                        self.check(item?.acting == true && census.row.map { TestAnchors.view("agents-spinner-\($0)", in: self.folder) != nil } == true
                                   && census.row.map { TestAnchors.view("agents-waiting-\($0)", in: self.folder) == nil } == true,
                                   "agentrows: one status while it works: the spinner (acting \(item?.acting ?? false))")
                        self.check(census.row.map { TestAnchors.view("agents-favicon-\($0)", in: self.folder) != nil || TestAnchors.view("agents-sparkle-\($0)", in: self.folder) != nil } == true,
                                   "agentrows: the row has an icon (the page's, else ✦)")
                        let page = AgentRowsCensus.pageSession(self.c, session: key)
                        self.check(page.ok, "agentrows: All tasks lists the app's session once (\(page.detail))")
                        self.shot(self.c.sidebar, "agentrows-outside")
                        self.front { _ in
                            self.press(census.row.map { "agents-row-\($0)" } ?? "-", in: self.folder, "the app's row",
                                       fallback: { census.row.map { self.folder.openWatch($0) } }) { how in
                                self.runner.waitUntil({ self.folder.watch != nil }, timeout: 4) {
                                    self.check(self.folder.watch != nil && self.folder.watch?.rowID == census.row,
                                               "agentrows: a click on the app's row opens Watch on its page [\(how) click]")
                                    self.folder.closeWatch()
                                    self.showAll(key) {
                                        k.call("close_tab", ["window": w, "tab": tab]) { _, _ in
                                            self.after(1) {
                                                let after = AgentRowsCensus.folderSession(self.c, session: key)
                                                self.check(after.ok && after.row == self.workRow,
                                                           "agentrows: its second page closed: still one row, on the first page (\(after.detail))")
                                                done()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Show all: the session's row stays one in the folder and on All tasks; its All tasks row opens Watch.
    func showAll(_ key: String, _ done: @escaping () -> Void) {
        let before = folder.model.items.map(\.id)
        let tasksBefore = folder.model.tasks.map(\.id)
        let open: () -> Void = { [self] in _ = AgentTasksPage.open(in: c) }
        // The folder lists New Task and Show all once there are Airc Agent tasks; without, All tasks opens from ◷.
        let go: (@escaping (String) -> Void) -> Void = { [self] k in
            if TestAnchors.view("agents-showall", in: folder) == nil { open(); return after(0.3) { k("direct: no Show all row without Airc tasks") } }
            press("agents-showall", in: folder, "Show all", fallback: open, k)
        }
        go { how in
            self.runner.waitUntil({ AgentTasksPage.existing(self.c.shownTabID) != nil }, timeout: 4) {
                self.after(0.6) {
                    let census = AgentRowsCensus.folderSession(self.c, session: key)
                    self.check(AgentTasksPage.existing(self.c.shownTabID) != nil && census.ok && self.folder.model.items.map(\.id) == before
                               && self.folder.model.tasks.map(\.id) == tasksBefore,
                               "agentrows: after Show all [\(how)] the folder has the same rows, the app once (\(census.detail))")
                    let page = AgentRowsCensus.pageSession(self.c, session: key)
                    self.check(page.ok, "agentrows: All tasks lists it once (\(page.detail))")
                    guard let p = AgentTasksPage.existing(self.c.shownTabID), let id = page.row else { return done() }
                    self.press("agenttasks.row.\(id)", in: p.host, "the app on All tasks",
                               fallback: { if let r = AgentRowsCensus.pageRows(self.c).first(where: { $0.id == id }) { p.model.open(r) } }) { how in
                        self.runner.waitUntil({ self.folder.watch != nil }, timeout: 4) {
                            let want = String(id.dropFirst("session-".count))
                            self.check(self.folder.watch?.rowID == want, "agentrows: a click on its All tasks row opens Watch on it [\(how) click]")
                            self.folder.closeWatch()
                            if let t = self.c.shownTabID { _ = try? self.c.store.closeTab(t) }
                            done()
                        }
                    }
                }
            }
        }
    }

    func shot(_ v: NSView, _ name: String) {
        v.layoutSubtreeIfNeeded()
        if let image = runner.render(v), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: runner.dir.appendingPathComponent("\(name)-\(engine).png"))
        }
    }

    // MARK: Real input

    func front(_ done: @escaping (Bool) -> Void) {
        guard real else { return done(false) }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow }, timeout: 6) { done(NSApp.isActive && self.c.window.isKeyWindow) }
    }

    /// A real click on an anchor (UI driver, app active), else `fallback`; "real" or "posted".
    func press(_ anchor: String, in host: NSView, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        host.window?.contentView?.layoutSubtreeIfNeeded()
        guard real, NSApp.isActive, let v = TestAnchors.view(anchor, in: host), let w = v.window, let main = NSScreen.screens.first else {
            if real { note("FAIL-ENV parityagentrows \(engine): no real click for \(what) (anchor \(TestAnchors.view(anchor, in: host) == nil ? "missing" : "found"), active \(NSApp.isActive)); posted") }
            fallback()
            return after(0.3) { done("posted") }
        }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        // A point in the row's title, left of the hover buttons.
        let x = (r.minX + min(r.width * 0.35, 90)).rounded(), y = (main.frame.maxY - r.midY).rounded()
        UIDriverClient.run(["--move", "\(Int(x))", "\(Int(y))"]) { _, _ in
            UIDriverClient.run(["--click", "\(Int(x))", "\(Int(y))"]) { ok, out in
                DispatchQueue.main.async {
                    if !ok { self.note("FAIL-ENV parityagentrows \(self.engine): the driver refused \(what) (\(out)); posted"); fallback() }
                    self.after(0.4) { done(ok ? "real" : "posted") }
                }
            }
        }
    }

    /// (3) A second app's row that the person watches; both apps end.
    func watchedStays(_ done: @escaping () -> Void) {
        startClient("rows-watched") { k, why in
            guard let k else { self.check(false, "the watched client connects (\(why))"); return done() }
            self.watched = k
            k.call("open_window", ["url": "\(self.base)/shop.html"]) { r, _ in
                let w = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                k.call("list_tabs", ["window": w]) { r, _ in
                    let tab = ((SpikeMCPClient.json(r)["tabs"] as? [[String: Any]])?.first?["tab"] as? Int) ?? 0
                    self.watchRow = AgentActivityModel.rowID(window: w, tab: tab)
                    self.runner.waitUntil({ self.folder.model.items.contains { $0.id == self.watchRow } }, timeout: 6) {
                        self.folder.openWatch(self.watchRow, takeKeys: false)
                        self.check(self.folder.watch?.rowID == self.watchRow, "Watch opens on the second row (in-app)")
                        self.worker?.stop()
                        k.stop()
                        self.runner.waitUntil({ !self.folder.model.items.contains(where: \.live) }, timeout: 6) {
                            let items = self.folder.model.items
                            self.check(items.count == 2 && items.allSatisfy { $0.status == "Done" && $0.subtitle.hasSuffix(" · Done") },
                                       "both rows read Done when their apps end (\(items.map(\.subtitle)))")
                            done()
                        }
                    }
                }
            }
        }
    }

    /// (4) After the keep time the unwatched row goes, the watched one stays; once Watch closes it goes too, and the
    /// folder with it. Activity keeps both.
    func autoClose(_ done: @escaping () -> Void) {
        let t0 = Date()
        runner.waitUntil({ !self.folder.model.items.contains { $0.id == self.workRow } }, timeout: Self.keep + 6) {
            let s = Date().timeIntervalSince(t0)
            self.check(!self.folder.model.items.contains { $0.id == self.workRow } && s >= Self.keep - 2.5,
                       "the finished row goes by itself after the keep time (\(String(format: "%.1f", s)) s, keep \(Int(Self.keep)) s)")
            self.check(self.folder.model.items.contains { $0.id == self.watchRow } && self.folder.watch?.rowID == self.watchRow,
                       "the row the person watches stays, and Watch with it")
            self.after(Self.keep) {
                self.check(self.folder.model.items.contains { $0.id == self.watchRow }, "still there while watched, a keep time later")
                self.folder.closeWatch()
                let t1 = Date()
                self.runner.waitUntil({ self.folder.model.items.isEmpty }, timeout: Self.keep + 25) {
                    let s = Date().timeIntervalSince(t1)
                    self.check(self.folder.model.items.isEmpty && s >= Self.keep - 2.5,
                               "once nobody watches, it goes after the keep time (\(String(format: "%.1f", s)) s)")
                    self.after(0.8) {
                        self.c.root.layoutSubtreeIfNeeded()
                        self.check(self.folder.height == 0 && self.folder.model.items.isEmpty,
                                   "the empty folder hides itself (height \(self.folder.height))")
                        self.activity.saveNow()
                        let clients = Set(self.activity.history.entries.map(\.client))
                        self.check(clients.contains { $0.contains("rows-worker") } && clients.contains { $0.contains("rows-watched") },
                                   "Settings › Agents › Activity still lists both (\(clients.sorted()))")
                        self.check(!clients.contains { $0.contains("rows-connect-only") || $0.contains("rows-blank") },
                                   "and nothing for the clients that did nothing")
                        let file = (try? String(contentsOf: self.activity.historyFile, encoding: .utf8)) ?? ""
                        self.check(!file.isEmpty && !file.contains(self.typed) && !file.contains("Order again") && !file.contains(".html"),
                                   "the history file holds no typed text, labels or paths")
                        self.check(self.privateNeverNamed(), "the private window's page is never named, after it all")
                        done()
                    }
                }
            }
        }
    }

    /// (5) Settings › Agents › "Keep finished agents for" is saved (1/5/30 min, Until I clear).
    func setting(_ done: @escaping () -> Void) {
        let center = AgentCenter.shared
        check(center.settings.keepFinishedMinutes == 5 && center.settings.keepFinished == 300, "5 minutes by default")
        center.setKeepFinished(minutes: 0)
        let file = AppPaths.dataDirectory.appendingPathComponent("Agents.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let minutes = saved?["keepFinishedMinutes"] as? Int
        check(center.settings.keepFinished == nil && minutes == 0, "Until I clear is saved (keepFinishedMinutes \(minutes.map(String.init) ?? "missing"))")
        center.setKeepFinished(minutes: 30)
        check(center.settings.keepFinished == 1800, "30 minutes")
        center.setKeepFinished(minutes: 5)
        done()
    }

    func finish() {
        activity.keepOverrideForCheck = nil
        privateWindow?.window.close()
        server?.stop()
        runner.finish()
    }
}
#endif
