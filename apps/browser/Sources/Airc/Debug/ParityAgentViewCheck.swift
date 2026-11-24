// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityagentview` (artifacts/agentview/REPORT.md): following an agent in Airc, end to end. The real `airc-mcp`
/// helper is the MCP client (agentspike's SpikeMCPClient), driving synthetic loopback sites ("Mailbox", "Corner Shop") in
/// the person's profile, while the person's window shows a page of their own. With the build Mac's UI driver
/// (`AIRC_UI_DEDICATED_SESSION=1 AIRC_REAL_KEYS=1 AIRC_LA_AS_OWNER=1`) the person's clicks are real clicks through the
/// window server; without it those cases are FAIL-ENV and run posted (each line says which).
///
/// It checks: the Agents folder and its rows appear in the profile's window; the start banner shows without changing
/// the key window, first responder or active app; the dot pulses while a call runs and stops after; folding is
/// remembered; Watch shows the agent's page live (frames, the page's own pixels) with captions for clicks and typing
/// that name labels and never typed text or a password; the agent works as before while watched (its clicks land,
/// round trips compared); Take over turns the agent's page into a normal tab (the same live page, its state kept) and
/// the client gets "took over"; Stop closes the app's windows, refuses its calls and new connections until Allow
/// again; the history has entries and no secrets (0600); "Show agent pages in front" opens Watch by itself; a private
/// window has no Agents folder and no banner. It measures watch frame rate and capture time, and CPU of the app and its
/// engine processes with the folder shown and nobody watching versus while watching (MEASURE lines,
/// agentview-<engine>.json).
extension SnapshotRunner {
    func parityAgentViewScenario() {
        let v = AgentViewCheck(runner: self)
        step { done in v.setUp(done) }
        step { done in v.connect(done) }
        step { done in v.folderAndBanner(done) }
        step { done in v.pulse(done) }
        step { done in v.fold(done) }
        step { done in v.watchChecks(done) }
        step { done in v.watchCost(done) }
        step { done in v.takeOver(done) }
        step { done in v.stop(done) }
        step { done in v.historyChecks(done) }
        step { done in v.showInFront(done) }
        step { done in v.privateWindow(done) }
        step { done in v.clear(done) }
        run { v.finish() }
    }
}

final class AgentViewCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var server: LocalPageServer?
    var port: UInt16 = 0
    var client: SpikeMCPClient!
    var spike: AgentSpike!
    var mailWindow = 0
    var mailRow = ""
    var shopRow = ""
    var measures: [String: Any] = [:]
    var activations = 0
    var activeObserver: NSObjectProtocol?
    var real = false
    let typed = "hello-agentview"
    let secret = "Fixture-Secret-Pw-4417"
    var personTab: String?

    init(runner: SnapshotRunner) { self.runner = runner }

    var base: String { "http://127.0.0.1:\(port)" }
    var activity: AgentActivity { .shared }
    var folder: SidebarAgentsView { c.sidebar.agents }

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "parityagentview \(engine): " + what) }
    func measure(_ name: String, _ value: Any) {
        measures[name] = value
        note("MEASURE parityagentview \(engine) \(name) \(value)")
    }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }

    // MARK: Fixtures

    static let mailPage = """
    <!doctype html><html><head><title>Inbox - Mailbox</title><style>
    body{margin:0;font:15px -apple-system,sans-serif;background:#fff}
    header{height:64px;background:#1f7a4d;color:#fff;display:flex;align-items:center;padding:0 20px;font-size:20px;font-weight:600}
    #q{position:absolute;left:20px;top:84px;width:400px;height:34px;box-sizing:border-box}
    #archive{position:absolute;left:440px;top:84px;width:120px;height:34px}
    #pw{position:absolute;left:20px;top:140px;width:300px;height:34px;box-sizing:border-box}
    .spin{position:absolute;left:620px;top:84px;width:40px;height:40px;background:#e85d3a;animation:s 1s linear infinite}
    @keyframes s{to{transform:rotate(360deg)}}
    ul{position:absolute;top:200px;left:20px;list-style:none;padding:0;margin:0}li{padding:10px 0;border-bottom:1px solid #eee;width:640px}
    #state{display:none}input,button{font:inherit}
    </style></head><body><header>Mailbox</header>
    <input id="q" aria-label="Search mail" placeholder="Search mail" autocomplete="off">
    <button id="archive">Archive</button>
    <input id="pw" type="password" aria-label="Password" autocomplete="off">
    <div class="spin"></div>
    <ul><li>Welcome to Mailbox</li><li>Your weekly digest</li><li>Lunch on Friday?</li></ul>
    <pre id="state"></pre>
    <script>var S={archived:0};function save(){document.getElementById('state').textContent=JSON.stringify(S);}
    document.getElementById('archive').addEventListener('click',function(){S.archived++;save();});save();</script>
    </body></html>
    """
    static let shopPage = """
    <!doctype html><html><head><title>Cart - Corner Shop</title><style>
    body{margin:0;font:15px -apple-system,sans-serif}header{height:64px;background:#7a3b1f;color:#fff;display:flex;align-items:center;padding:0 20px;font-size:20px}
    #add{position:absolute;left:20px;top:90px;width:160px;height:40px}</style></head>
    <body><header>Corner Shop</header><button id="add">Add to cart</button></body></html>
    """
    static let notesPage = """
    <!doctype html><html><head><title>My notes</title></head><body style="margin:0;font:15px -apple-system,sans-serif">
    <textarea id="t" style="width:90%;height:300px;margin:20px">The person's own page.</textarea></body></html>
    """

    // MARK: Real input

    /// The anchor's centre in Quartz global points, after layout.
    func point(_ name: String, in host: NSView) -> CGPoint? {
        host.window?.contentView?.layoutSubtreeIfNeeded()
        guard let v = TestAnchors.view(name, in: host), let w = v.window, let main = NSScreen.screens.first else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
    }

    /// A real click on an anchor when the driver is here (window key, app active), else the posted `fallback`. Calls
    /// `done` with "real" or "posted".
    func click(_ anchor: String, in host: @escaping () -> NSView?, _ what: String, fallback: @escaping () -> Void,
               _ done: @escaping (String) -> Void) {
        guard real, let h = host(), let p = point(anchor, in: h), NSApp.isActive, c.window.isKeyWindow else {
            if real { note("FAIL-ENV parityagentview \(engine): no real click for \(what) (anchor \(anchor) \(host().flatMap { point(anchor, in: $0) } == nil ? "missing" : "found"), active \(NSApp.isActive), key \(c.window.isKeyWindow)); posted") }
            else { note("FAIL-ENV parityagentview \(engine): \(what) posted (no UI driver or dedicated session)") }
            fallback()
            return done("posted")
        }
        UIDriverClient.run(["--click", "\(p.x)", "\(p.y)"]) { ok, out in
            if !ok {
                self.note("FAIL-ENV parityagentview \(self.engine): the driver refused \(what) (\(out)); posted")
                fallback()
                return done("posted")
            }
            done("real")
        }
    }

    func front(_ done: @escaping (Bool) -> Void) {
        guard real else { return done(false) }
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && self.c.window.isKeyWindow && self.c.window.isOnActiveSpace }, timeout: 6) {
            done(NSApp.isActive && self.c.window.isKeyWindow)
        }
    }

    // MARK: Steps

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        spike = AgentSpike(runner: runner)
        spike.engine = engine
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("parityagentview \(engine): input \(real ? "real (UI driver)" : "posted"), reduce motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)")
        UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
        folder.model.expanded = true
        server = LocalPageServer(responses: [
            "/mail.html": LocalPageServer.Page(body: Self.mailPage),
            "/shop.html": LocalPageServer.Page(body: Self.shopPage),
            "/notes.html": LocalPageServer.Page(body: Self.notesPage),
        ])
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fixture server on loopback")
            // The person's own page, shown and focused in their window.
            let profile = c.store.profile(ofSpace: c.currentSpaceID)
            if let t = try? c.store.openTab(url: "\(base)/notes.html", inSpace: c.currentSpaceID, title: "My notes") {
                personTab = t.id
                c.show(t.id)
            }
            app.profiles.whenLoaded(profile.id, { _ in
                AgentCenter.shared.app = self.app
                AgentCenter.shared.enableForCheck(grants: [], http: false)
                AgentCenter.shared.approvals.automatic = true
                AgentCenter.shared.setShowInFront(false)
                self.check(AgentCenter.shared.isServing, "the agent server listens")
                self.check(self.folder.height == 0 && self.folder.model.items.isEmpty, "no Agents folder before any agent works (it takes no space)")
                self.after(1.5) {
                    self.front { ok in
                        if self.real, !ok { self.note("FAIL-ENV parityagentview \(self.engine): the window isn't key and active (active \(NSApp.isActive), key \(self.c.window.isKeyWindow))") }
                        self.activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                                     queue: .main) { [weak self] _ in self?.activations += 1 }
                        done()
                    }
                }
            }, failed: { self.check(false, "the profile loads"); done() })
        }
    }

    func startClient(_ name: String = "agentview-check", _ done: @escaping (SpikeMCPClient?, String) -> Void) {
        let k = SpikeMCPClient(helper: spike.helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", name])
        guard k.start() else { return done(nil, "the helper didn't start") }
        k.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]], timeout: 15) { m in
            guard m["result"] != nil else { return done(nil, "\(m["error"] ?? "no answer") \(k.stderrText)") }
            k.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            done(k, "")
        }
    }

    func connect(_ done: @escaping () -> Void) {
        startClient { k, why in
            guard let k else { self.check(false, "the MCP client connects (\(why))"); return done() }
            self.client = k
            self.check(true, "the MCP client connects")
            done()
        }
    }

    func folderAndBanner(_ done: @escaping () -> Void) {
        let key = c.window.isKeyWindow, responder = c.window.firstResponder, active = NSApp.isActive
        let bannersBefore = activity.banners.count
        client.call("open_window", ["url": "\(base)/mail.html"]) { r, _ in
            let j = SpikeMCPClient.json(r)
            self.mailWindow = j["window"] as? Int ?? 0
            self.check(!SpikeMCPClient.isError(r) && self.mailWindow > 0, "open_window on the Mailbox fixture")
            self.client.call("list_tabs", ["window": self.mailWindow]) { r, _ in
                let tab = ((SpikeMCPClient.json(r)["tabs"] as? [[String: Any]])?.first?["tab"] as? Int) ?? 0
                self.mailRow = AgentActivityModel.rowID(window: self.mailWindow, tab: tab)
                self.runner.waitUntil({ self.activity.banners.count > bannersBefore && self.folder.height > 0 }, timeout: 5) {
                    self.c.root.layoutSubtreeIfNeeded()
                    let item = self.folder.model.items.first { $0.id == self.mailRow }
                    self.check(item != nil && self.folder.height > 0, "the Agents folder and the agent tab's row appear (\(self.folder.model.items.map(\.label)))")
                    self.check(item?.label.hasSuffix("· Mailbox") == true, "the row is labelled by client and site (\(item?.label ?? "-"))")
                    self.check(TestAnchors.view("agents-header", in: self.c.sidebar) != nil && TestAnchors.view("agents-row-\(self.mailRow)", in: self.c.sidebar) != nil,
                               "the folder and the row are on screen in the sidebar")
                    let banner = self.activity.banners.last ?? ""
                    self.check(banner.hasSuffix("is using Airc · Mailbox"), "the start banner names the app and site (\(banner))")
                    self.check(self.c.toast.shownText == banner, "the banner shows as a toast in the profile's window")
                    self.check(self.c.window.isKeyWindow == key && self.c.window.firstResponder === responder && NSApp.isActive == active && self.activations == 0,
                               "the banner and the folder take no focus (key \(self.c.window.isKeyWindow), same responder \(self.c.window.firstResponder === responder), activations \(self.activations))")
                    self.check(AgentCenter.shared.windows[self.mailWindow]?.window.isKeyWindow == false, "the agent window stays never-key")
                    done()
                }
            }
        }
    }

    func pulse(_ done: @escaping () -> Void) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var during = false, pulsing = 0, spinning = false
        client.call("wait", ["duration": 1.5]) { _, _ in
            self.after(AgentActivityModel.actingTail + 0.6) {
                let after = self.activity.model.isActing(self.mailRow, now: Date())
                self.check(during && !after, "the row acts while a call runs and goes idle after (during \(during), after \(after))")
                // agentrows: the row's one status is a spinner while the app acts (no pulsing dot), none once it's quiet.
                let still = TestAnchors.view("agents-spinner-\(self.mailRow)", in: self.folder) != nil
                self.check(spinning && pulsing == 0, "the row spins while the agent acts, no pulsing dot (spinner \(spinning), \(pulsing) pulsing)")
                self.check(!still && AgentPulseDot.pulsing.isEmpty, "no spinner and no pulse once it's idle (spinner \(still))")
                done()
            }
        }
        after(0.6) {
            during = self.activity.model.isActing(self.mailRow, now: Date())
            pulsing = AgentPulseDot.pulsing.count
            spinning = TestAnchors.view("agents-spinner-\(self.mailRow)", in: self.folder) != nil
        }
    }

    func fold(_ done: @escaping () -> Void) {
        let open = folder.height
        click("agents-header", in: { self.c.sidebar }, "fold the Agents folder", fallback: { self.folder.setExpanded(false) }) { how in
            self.runner.waitUntil({ !self.folder.model.expanded }, timeout: 2) {
                self.after(0.4) {
                    self.check(!self.folder.model.expanded && self.folder.height < open && UserDefaults.standard.object(forKey: SidebarAgentsView.expandedKey) as? Bool == false,
                               "[\(how)] a click on the header folds the folder, and that is remembered (\(open) → \(self.folder.height))")
                    self.click("agents-header", in: { self.c.sidebar }, "unfold", fallback: { self.folder.setExpanded(true) }) { how in
                        self.runner.waitUntil({ self.folder.model.expanded }, timeout: 2) {
                            self.after(0.4) {
                                self.check(self.folder.model.expanded && UserDefaults.standard.bool(forKey: SidebarAgentsView.expandedKey),
                                           "[\(how)] and unfolds again")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func watchChecks(_ done: @escaping () -> Void) {
        click("agents-row-\(mailRow)", in: { self.c.sidebar }, "Watch (a click on the row)", fallback: { self.folder.openWatch(self.mailRow) }) { how in
            self.runner.waitUntil({ (self.folder.watch?.framesShown ?? 0) >= 5 || self.folder.watch?.mode == "live" }, timeout: 5) {
                guard let watch = self.folder.watch else {
                    self.check(false, "[\(how)] a click on the row opens Watch")
                    return done()
                }
                self.check(watch.rowID == self.mailRow && watch.superview === self.c.card, "[\(how)] a click on the row opens Watch over the window's page")
                self.check(self.c.window.firstResponder === watch, "Watch takes the keys (nothing reaches the person's page under it)")
                #if canImport(AircCore)
                if let w = AgentCenter.shared.windows[self.mailWindow] {
                    self.note("parityagentview \(self.engine): agent window hosts: \(ChromiumAgentDriver.describeHosts(in: w.window))")
                }
                #endif
                self.measure("watch_mode", watch.mode)
                if self.engine == "chromium" { self.check(watch.mode == "live", "Chromium: Watch hosts the agent window's own compositor output (no copies; mode \(watch.mode))") }
                if watch.mode == "live" {
                    // The render server draws a hosted context: only the window server's picture of our own window shows it.
                    self.after(0.6) {
                        let px = self.ownWindowPixels(watch, CGPoint(x: 64, y: 12))
                        let green = px.filter { $0.g > $0.r + 30 && $0.g > $0.b + 10 }.count
                        if px.isEmpty { self.note("FAIL-ENV parityagentview \(self.engine): no window-server picture of our own window to see the hosted page") }
                        else { self.check(green * 2 > px.count, "Watch shows the agent's page live: its header, right way up, in our window's own picture (\(green)/\(px.count) green)") }
                        // It moves: the fixture's spinning square, three pictures 0.2 s apart (frozen content would match).
                        let occlusion = ProcessInfo.processInfo.environment["AIRC_KEEP_OCCLUSION"] == "1" ? "product occlusion (AIRC_KEEP_OCCLUSION=1)" : "test launch occlusion off"
                        let spin = CGPoint(x: 628, y: 92)
                        let a = self.ownWindowPixels(watch, spin)
                        self.after(0.2) {
                            let b = self.ownWindowPixels(watch, spin)
                            self.after(0.2) {
                                let c = self.ownWindowPixels(watch, spin)
                                func key(_ p: [(r: Int, g: Int, b: Int)]) -> [Int] { p.map { $0.r * 65536 + $0.g * 256 + $0.b } }
                                if !a.isEmpty {
                                    let moving = key(a) != key(b) || key(b) != key(c)
                                    self.measure("live_occlusion", occlusion)
                                    self.check(moving, "the live picture keeps moving with the agent window off screen (\(occlusion))")
                                }
                                self.watchedActions(watch, done)
                            }
                        }
                    }
                    return
                }
                let frame = watch.lastFrame
                // The fixture's green header (#1f7a4d), in the top left of the page's picture.
                let px = frame.flatMap { AgentImages.pixel($0, x: $0.width / 20, y: $0.height / 60) }
                let green = px.map { $0.g > $0.r + 30 && $0.g > $0.b + 10 } ?? false
                self.check(watch.framesShown >= 5 && green, "Watch shows the agent's page live (\(watch.framesShown) frames, header pixel \(px.map { "\($0)" } ?? "none"))")
                self.check(AgentCenter.shared.windows[self.mailWindow].map { w in !w.window.isKeyWindow && !NSScreen.screens.contains { $0.frame.intersects(w.window.frame) } } ?? false,
                           "the agent window stays off screen and never key while watched")
                self.watchedActions(watch, done)
            }
        }
    }

    func watchedActions(_ watch: AgentWatchView, _ done: @escaping () -> Void) {
        var captions: [String] = []
        var fieldSeen = false, pointerSeen = false
        let sample = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if let c = watch.caption, captions.last != c { captions.append(c) }
            if watch.fieldShown { fieldSeen = true }
            if watch.pointerShown { pointerSeen = true }
        }
        RunLoop.main.add(sample, forMode: .common)
        client.call("left_click", ["coordinate": [500, 101], "window": mailWindow]) { r1, ms1 in
            self.after(0.5) {
                self.check(!SpikeMCPClient.isError(r1) && captions.contains("Clicking ‘Archive’") && pointerSeen,
                           "a click shows the pointer and \"Clicking ‘Archive’\" (captions \(captions))")
                self.client.call("left_click", ["coordinate": [220, 101], "window": self.mailWindow]) { _, _ in
                    self.client.call("type", ["text": self.typed, "window": self.mailWindow]) { _, _ in
                        self.after(0.5) {
                            self.check(captions.contains("Typing in ‘Search mail’") && fieldSeen,
                                       "typing highlights the field and shows \"Typing in ‘Search mail’\" (\(captions.suffix(3)))")
                            self.client.call("left_click", ["coordinate": [170, 157], "window": self.mailWindow]) { _, _ in
                                self.client.call("type", ["text": self.secret, "window": self.mailWindow]) { _, _ in
                                    self.after(0.5) {
                                        sample.invalidate()
                                        self.check(captions.contains("Typing in ‘Password’ (hidden)"), "a password field is named, its value never (\(captions.suffix(2)))")
                                        let all = captions.joined(separator: " | ")
                                        self.check(!all.contains(self.typed) && !all.contains(self.secret) && !all.contains("Welcome"),
                                                   "no caption holds typed text, a password or page text")
                                        self.measure("click_ms_watched", AgentSpike.r1(ms1))
                                        self.agentUnchanged(done)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The agent works as before while watched: its click landed, its text is in the field, and click round trips
    /// watched and not watched.
    func agentUnchanged(_ done: @escaping () -> Void) {
        client.call("read_page", ["mode": "outline", "window": mailWindow]) { r, _ in
            let outline = SpikeMCPClient.text(r)
            self.check(outline.contains(self.typed) && !outline.contains(self.secret), "while watched, the agent's typing reached the page (and read_page still masks the password)")
            var watched: [Double] = [], unwatched: [Double] = []
            func clicks(_ n: Int, _ into: @escaping (Double) -> Void, _ then: @escaping () -> Void) {
                guard n > 0 else { return then() }
                self.client.call("left_click", ["coordinate": [500, 101], "window": self.mailWindow]) { _, ms in into(ms); clicks(n - 1, into, then) }
            }
            // Three rounds of 8 watched then 8 unwatched clicks (drift cancels out): 24 + 24 = 48 more clicks.
            func round(_ k: Int, _ then: @escaping () -> Void) {
                guard k > 0 else { return then() }
                if self.folder.watch == nil { self.folder.openWatch(self.mailRow) }
                self.after(0.8) {
                    clicks(8, { watched.append($0) }) {
                        self.folder.closeWatch()
                        self.after(0.8) { clicks(8, { unwatched.append($0) }) { round(k - 1, then) } }
                    }
                }
            }
            round(3) {
                    self.measure("click_ms_median_watched", AgentSpike.r1(AgentSpike.median(watched)))
                    self.measure("click_ms_median_unwatched", AgentSpike.r1(AgentSpike.median(unwatched)))
                    self.measure("click_ms_p90_watched", AgentSpike.r1(AgentSpike.p90(watched)))
                    self.measure("click_ms_p90_unwatched", AgentSpike.r1(AgentSpike.p90(unwatched)))
                    if self.engine == "chromium" {
                        let slower = AgentSpike.median(watched) - AgentSpike.median(unwatched)
                        self.check(slower < 1, "watched live, the agent's clicks are no slower (median \(slower >= 0 ? "+" : "")\(AgentSpike.r1(slower)) ms over 24 clicks each)")
                    }
                    self.client.call("find_element", ["text": "Archive", "role": "button", "window": self.mailWindow]) { _, _ in
                        self.mailState { s in
                            let n = s["archived"] as? Int ?? -1
                            self.check(n == 49, "every agent click landed, watched or not (\(n) of 49)")
                            done()
                        }
                    }
            }
        }
    }

    /// The fixture's own state (#state), read in the page by the agent's own read tool.
    func mailState(_ done: @escaping ([String: Any]) -> Void) {
        guard let w = AgentCenter.shared.windows[mailWindow], let tab = w.activeTab else { return done([:]) }
        w.driver.evaluate(tab, "document.getElementById('state').textContent") { v in
            done(agentJSON(v) ?? [:])
        }
    }

    /// Watch's cost: app and engine processes, 6 s with the folder shown and nobody watching, then 6 s watching (the
    /// fixture animates, so every frame is new). Frame rate and capture time while watching.
    func watchCost(_ done: @escaping () -> Void) {
        after(1.5) {
            let p0 = self.spike.processes(), mine0 = self.spike.ours(p0, extra: [])
            self.after(6) {
                let p1 = self.spike.processes()
                let idle = self.spike.cpu(self.spike.ours(p1, extra: []), since: mine0)
                let appIdle = self.appCPU(p1, p0)
                self.folder.openWatch(self.mailRow)
                self.after(1.5) {
                    guard let watch = self.folder.watch else { self.check(false, "Watch reopens"); return done() }
                    let f0 = watch.framesShown, t0 = Date(), p2 = self.spike.processes(), mine2 = self.spike.ours(p2, extra: [])
                    self.after(6) {
                        let p3 = self.spike.processes()
                        let busy = self.spike.cpu(self.spike.ours(p3, extra: []), since: mine2)
                        let appBusy = self.appCPU(p3, p2)
                        let fps = Double(watch.framesShown - f0) / Date().timeIntervalSince(t0)
                        let ms = watch.captureMs.suffix(150)
                        self.measure("cpu_percent_folder_shown_not_watching", AgentSpike.r1(idle / 6 * 100))
                        self.measure("cpu_percent_app_only_not_watching", AgentSpike.r1(appIdle / 6 * 100))
                        self.measure("cpu_percent_watching", AgentSpike.r1(busy / 6 * 100))
                        self.measure("cpu_percent_app_only_watching", AgentSpike.r1(appBusy / 6 * 100))
                        self.measure("watch_fps", AgentSpike.r1(fps))
                        self.measure("watch_capture_ms_median", AgentSpike.r1(AgentSpike.median(Array(ms))))
                        self.measure("watch_capture_ms_p90", AgentSpike.r1(AgentSpike.p90(Array(ms))))
                        self.measure("watch_target_fps", AgentWatchView.fps)
                        if watch.mode == "live" {
                            self.check(appBusy / 6 * 100 < 10, "watching live costs the app under 10 % CPU (\(AgentSpike.r1(appBusy / 6 * 100)) %, \(watch.liveChecks) context checks)")
                        } else {
                            self.check(fps >= AgentWatchView.fps * 0.85, "Watch runs smoothly (\(AgentSpike.r1(fps)) frames/s, target \(AgentWatchView.fps))")
                        }
                        self.check(appIdle / 6 * 100 < 2, "nobody watching: the app's CPU is about 0 (\(AgentSpike.r1(appIdle / 6 * 100)) %)")
                        self.measure("watch_pixel_scale", Double(AgentWatchView.pixelScale))
                        self.shot("agentview-watch-\(self.engine)") { self.costVariants(watch, done) }
                    }
                }
            }
        }
    }

    /// The same watch at other frame rates and pixel scales, 5 s each (for choosing the defaults), then back.
    func costVariants(_ watch: AgentWatchView, _ done: @escaping () -> Void) {
        let fps0 = AgentWatchView.fps, scale0 = AgentWatchView.pixelScale, live0 = AgentWatchView.allowsLive
        AgentWatchView.allowsLive = false   // the copying path, for comparison and for WebKit
        var left: [(Double, CGFloat)] = [(30, 1.0), (24, 1.0), (24, 0.75), (20, 0.5), (15, 0.5)]
        func next() {
            guard !left.isEmpty else {
                AgentWatchView.fps = fps0; AgentWatchView.pixelScale = scale0; AgentWatchView.allowsLive = live0
                return done()
            }
            let (fps, scale) = left.removeFirst()
            AgentWatchView.fps = fps; AgentWatchView.pixelScale = scale
            after(1.0) {
                let f0 = watch.framesShown, t0 = Date(), p0 = self.spike.processes(), mine0 = self.spike.ours(p0, extra: [])
                self.after(5) {
                    let p1 = self.spike.processes()
                    let all = self.spike.cpu(self.spike.ours(p1, extra: []), since: mine0), app = self.appCPU(p1, p0)
                    let got = Double(watch.framesShown - f0) / Date().timeIntervalSince(t0)
                    // The agent's clicks while this variant runs.
                    var ms: [Double] = []
                    func clicks(_ n: Int, _ then: @escaping () -> Void) {
                        guard n > 0 else { return then() }
                        self.client.call("mouse_move", ["coordinate": [700, 400], "window": self.mailWindow]) { _, t in ms.append(t); clicks(n - 1, then) }
                    }
                    clicks(6) {
                        self.measure("variant_fps\(Int(fps))_scale\(scale)", ["fps": AgentSpike.r1(got), "app_cpu": AgentSpike.r1(app / 5 * 100),
                                                                              "all_cpu": AgentSpike.r1(all / 5 * 100), "mode": watch.mode,
                                                                              "agent_move_ms_median": AgentSpike.r1(AgentSpike.median(ms))])
                        next()
                    }
                }
            }
        }
        next()
    }

    func appCPU(_ now: [AgentSpike.Proc], _ then: [AgentSpike.Proc]) -> Double {
        let me = getpid()
        guard let a = now.first(where: { $0.pid == me }), let b = then.first(where: { $0.pid == me }) else { return 0 }
        return max(0, a.cpuSeconds - b.cpuSeconds)
    }

    func takeOver(_ done: @escaping () -> Void) {
        // A second tab first, so the connection keeps working after the take-over.
        client.call("open_tab", ["url": "\(base)/shop.html", "window": mailWindow]) { r, _ in
            let shopTab = SpikeMCPClient.json(r)["tab"] as? Int ?? 0
            self.shopRow = AgentActivityModel.rowID(window: self.mailWindow, tab: shopTab)
            do {
                let page = AgentCenter.shared.windows[self.mailWindow]?.tab(Int(self.mailRow.split(separator: "-").last ?? "") ?? 0)
                if self.folder.watch?.rowID != self.mailRow { self.folder.openWatch(self.mailRow) }
                self.after(0.8) {
                    let tabsBefore = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).count
                    self.click("agentwatch-takeover", in: { self.folder.watch }, "Take over (Watch's button)", fallback: { self.folder.takeOver(self.mailRow) }) { how in
                        self.runner.waitUntil({ self.activity.model.row(self.mailRow)?.end == .takenOver }, timeout: 4) {
                            self.after(0.6) {
                                let shown = self.c.shownTabID.flatMap { self.c.engineTab(for: $0) }
                                self.check(page != nil && shown === page, "[\(how)] Take over: the agent's page is now the window's shown tab, the same live page")
                                let tabsAfter = self.c.store.todayTabs(ofSpace: self.c.currentSpaceID).count
                                self.check(tabsAfter == tabsBefore + 1 && self.c.shownTabID.flatMap { self.c.store.tab($0)?.url }?.contains("/mail.html") == true,
                                           "it's a normal tab in the sidebar (\(tabsBefore) → \(tabsAfter))")
                                // agentrows: one row per session; the app still works in its other tab, so that tab is its row.
                                self.check(self.folder.watch == nil && self.activity.model.row(self.mailRow)?.end == .takenOver
                                           && self.folder.model.items.map(\.id) == [self.shopRow],
                                           "Watch closes, the page is yours, and the app keeps one row, on its other tab (\(self.folder.model.items.map(\.id)))")
                                // Its state is kept: the agent's search text is still in the field.
                                shown?.evaluate("document.getElementById('q').value") { v in
                                    self.check((v as? String) == self.typed, "the page keeps its state (the field still holds the agent's text)")
                                    self.client.call("screenshot", ["window": self.mailWindow]) { r, _ in
                                        let text = SpikeMCPClient.text(r)
                                        self.check(SpikeMCPClient.isError(r) && text.contains("took over"), "the client gets \"the person took over\" (\(text.prefix(90)))")
                                        self.client.call("screenshot", ["window": self.mailWindow]) { r, _ in
                                            self.check(!SpikeMCPClient.isError(r), "the window's other tab is still the agent's")
                                            self.check(AgentCenter.shared.windows[self.mailWindow]?.tabs.count == 1, "the agent window lost only that tab")
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

    func stop(_ done: @escaping () -> Void) {
        folder.openWatch(shopRow)
        after(0.8) {
            self.click("agentwatch-stop", in: { self.folder.watch }, "Stop (Watch's button)", fallback: { self.folder.stop(self.shopRow) }) { how in
                self.runner.waitUntil({ AgentCenter.shared.windows.isEmpty }, timeout: 4) {
                    self.check(AgentCenter.shared.windows.isEmpty, "[\(how)] Stop closes the app's agent windows")
                    self.check(self.activity.model.row(self.shopRow)?.end == .stopped, "its row says Stopped")
                    self.client.call("open_window", ["url": "\(self.base)/shop.html"]) { r, _ in
                        let text = SpikeMCPClient.text(r)
                        self.check(SpikeMCPClient.isError(r) && text.contains("stopped"), "later calls fail with a clear message (\(text.prefix(80)))")
                        self.check(AgentCenter.shared.windows.isEmpty, "and open nothing")
                        self.startClient("agentview-check") { k, why in
                            self.check(k == nil && why.contains("stopped"), "a new connection from that app is refused (\(why.prefix(100)))")
                            k?.stop()
                            // Allow again (the row's menu item: posted, the driver has no menu clicks for SwiftUI context menus here).
                            self.folder.allowAgain(self.shopRow)
                            self.client.stop()
                            self.startClient("agentview-check") { k, why in
                                self.check(k != nil, "Allow again: the app connects again (\(why))")
                                self.client = k
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func historyChecks(_ done: @escaping () -> Void) {
        activity.saveNow()
        let file = activity.historyFile
        let data = (try? Data(contentsOf: file)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        let entries = activity.history.entries
        check(!entries.isEmpty && entries.contains { $0.site == "127.0.0.1" && $0.line.contains("Clicked") }, "the history has entries (\(entries.map(\.line).prefix(3)))")
        check(!text.contains(typed) && !text.contains(secret) && !text.contains("Archive") && !text.contains("Search mail")
              && !text.contains("mail.html") && !text.contains("Welcome"), "the history holds no typed text, password, labels, paths or page text")
        var st = stat()
        check(stat(file.path, &st) == 0 && st.st_mode & 0o777 == 0o600, "the history file is 0600")
        let log = (try? String(contentsOf: AgentCenter.shared.logFile, encoding: .utf8)) ?? ""
        check(!log.contains(typed) && !log.contains(secret), "the call log holds no typed text or password either")
        done()
    }

    func showInFront(_ done: @escaping () -> Void) {
        AgentCenter.shared.setShowInFront(true)
        let key = c.window.isKeyWindow, responder = c.window.firstResponder
        let before = activations
        client.call("open_window", ["url": "\(base)/shop.html"]) { r, _ in
            let id = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.runner.waitUntil({ self.folder.watch != nil }, timeout: 4) {
                let watch = self.folder.watch
                self.check(watch?.rowID.hasPrefix("agent-\(id)-") == true, "show in front: the agent's page opens live in the window by itself")
                self.check(self.c.window.isKeyWindow == key && self.activations == before && AgentCenter.shared.windows[id]?.window.isKeyWindow == false
                           && self.c.window.firstResponder === responder,
                           "without activating anything, moving the keyboard focus or making the agent window key")
                self.runner.waitUntil({ (self.folder.watch?.framesShown ?? 0) > 3 }, timeout: 3) {
                    self.shot("agentview-front-\(self.engine)") {
                        self.folder.closeWatch()
                        AgentCenter.shared.setShowInFront(false)
                        self.client.call("open_window", ["url": "\(self.base)/mail.html"]) { _, _ in
                            self.after(1.2) {
                                self.check(self.folder.watch == nil, "off (the default): an agent page doesn't open by itself")
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func privateWindow(_ done: @escaping () -> Void) {
        let bannersBefore = activity.banners.count
        PrivateBrowsing.shared.open(app: app) { pw in
            guard let pw else { self.check(false, "a private window opens"); return done() }
            // A new connection's first page while the private window is in front.
            self.startClient("agentview-private") { k, why in
                guard let k else { self.check(false, "a second client connects (\(why))"); return done() }
                k.call("open_window", ["url": "\(self.base)/mail.html"]) { _, _ in
                    self.after(3.5) {
                        let root = pw.window.contentView
                        let agentsViews = root.map { self.descendants(of: $0).filter { $0 is SidebarAgentsView || $0 is AgentWatchView } } ?? []
                        self.check(agentsViews.isEmpty && root.flatMap { TestAnchors.view("agents-header", in: $0) } == nil,
                                   "a private window has no Agents folder and no Watch")
                        let toast = root.map { self.descendants(of: $0).compactMap { ($0 as? ToastView)?.shownText } } ?? []
                        self.check(self.activity.banners.count > bannersBefore && !toast.contains { $0.contains("is using Airc") },
                                   "the start banner never shows in a private window (\(toast))")
                        self.check(!self.activity.windows(showing: pw.profileID).contains { $0.window === pw.window }, "private windows are never among the profile's windows")
                        k.stop()
                        pw.window.close()
                        self.after(1) { self.front { _ in done() } }
                    }
                }
            }
        }
    }

    /// A 5×5 grid of pixels around a page point, from the window server's image of our own window (no Screen Recording:
    /// an app may picture its own windows). Empty when unavailable or switched off (AIRC_DISABLE_LEGACY_WINDOW_CAPTURE).
    func ownWindowPixels(_ watch: AgentWatchView, _ page: CGPoint) -> [(r: Int, g: Int, b: Int)] {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1", let w = watch.window,
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return [] }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), (1 << 3) | (1 << 0))?.takeRetainedValue(),
              img.width > 8 else { return [] }
        let s = CGFloat(img.width) / w.frame.width
        let v = watch.viewPoint(page)
        let inWindow = watch.convert(v, to: nil)
        var out: [(r: Int, g: Int, b: Int)] = []
        for dx in -2...2 { for dy in -2...2 {
            if let p = AgentImages.pixel(img, x: Int((inWindow.x + CGFloat(dx * 3)) * s), y: Int((w.frame.height - inWindow.y + CGFloat(dy * 3)) * s)) { out.append(p) }
        } }
        return out
    }

    func descendants(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { descendants(of: $0) } }

    func clear(_ done: @escaping () -> Void) {
        client.stop()
        runner.waitUntil({ !self.folder.model.items.contains(where: \.live) }, timeout: 5) {
            self.after(0.6) {
                self.check(self.folder.model.items.allSatisfy { !$0.live } && self.folder.model.items.contains { $0.status == "Done" },
                           "when the client disconnects its rows say Done")
                self.click("agents-clear", in: { self.c.sidebar }, "Clear", fallback: { AgentActivity.shared.clearEnded() }) { how in
                    self.runner.waitUntil({ self.folder.model.items.isEmpty }, timeout: 3) {
                        self.after(0.5) {
                            self.check(self.folder.model.items.isEmpty && self.folder.height == 0, "[\(how)] Clear removes them and the folder goes")
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: Shots and the end

    /// The window as the person sees it: the sidebar and chrome (layers), and Watch's own render over the card (its
    /// picture is a layer's contents; the engine's own page views don't render here).
    func shot(_ name: String, _ done: @escaping () -> Void) {
        // Live, the page is drawn by the render server: only the window server's picture of our own window shows it.
        if folder.watch?.mode == "live", ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1" {
            runner.captureOwnWindow(c.window, name: name)
            return done()
        }
        let root = c.root
        root.layoutSubtreeIfNeeded()
        let size = root.bounds.size
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return done() }
        ctx.scaleBy(x: scale, y: scale)
        if let l = (root.superview ?? root).layer { l.render(in: ctx) }
        if let watch = folder.watch, let image = MarketingAgentsState.render(watch)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let f = watch.convert(watch.bounds, to: root)   // root is flipped; the context's origin is the bottom left
            ctx.draw(image, in: CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height))
        }
        guard let image = ctx.makeImage() else { return done() }
        let rep = NSBitmapImageRep(cgImage: image)
        let url = runner.dir.appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        note("wrote \(name).png")
        done()
    }

    func finish() {
        client?.stop()
        AgentCenter.shared.setShowInFront(false)
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        measures["engine"] = engine
        measures["input"] = real ? "real" : "posted"
        if let data = try? JSONSerialization.data(withJSONObject: measures, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runner.dir.appendingPathComponent("agentview-\(engine).json"))
        }
        server?.stop()
        runner.finish()
    }
}
#endif
