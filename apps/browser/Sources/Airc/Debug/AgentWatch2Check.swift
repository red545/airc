// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentwatch2` (watchfix, owner report 2026-11-23): an outside agent's window in Watch, and its passkey
/// prompt. The real `airc-mcp` helper is the MCP client (as Claude Code connects), on synthetic loopback pages; the
/// person's clicks are real clicks through the window server with the build Mac's UI driver
/// (`AIRC_UI_DEDICATED_SESSION=1 AIRC_REAL_KEYS=1 AIRC_LA_AS_OWNER=1`), else posted and said so (FAIL-ENV lines).
///
/// - Watch: the agent's page shows within 1 s of opening (the window server's picture of our own window: a hosted
///   context draws nothing in-app), it moves, and it stays shown across 3 cross-site navigations (no blank sample at
///   20 Hz once it showed) and after Airc was in the background while the agent worked. "Waiting for …" goes once the
///   page shows.
/// - Prompts: a passkey request from the agent's page shows "<client> wants to use your passkey for localhost" with
///   its origin in Watch; the agent's own clicks and keys can't answer it; Not now keeps it in Needs you; a click on
///   the row opens it again; Allow completes it (Chromium: against a virtual authenticator, DevTools WebAuthn; WebKit
///   has no passkeys: the request goes on to the engine, which refuses). With Watch closed it waits in Needs you (toast,
///   row), opens Watch with the prompt, and after Take over it's still answerable over the page in the person's window.
/// - Chromium's own passkey sheet (when this build shows one) hangs over Watch, never off on another Space.
/// `AIRC_WATCH_LEGACY=1`: Watch as 0.1.54 had it (the before arm); `AIRC_AGENTWATCH2_ONLY=watch|prompts` runs one part.
extension SnapshotRunner {
    func agentWatch2Scenario() {
        let v = AgentWatch2Check(runner: self)
        let only = ProcessInfo.processInfo.environment["AIRC_AGENTWATCH2_ONLY"] ?? ""
        step { done in v.setUp(done) }
        step { done in v.connect(done) }
        if only.isEmpty || only.contains("watch") {
            step { done in v.watchOpens(done) }
            step { done in v.navigations(done) }
            step { done in v.back(done) }
            step { done in v.background(done) }
        }
        // Passkey requests only against a virtual authenticator (no real WebAuthn: hybrid discovery asks macOS for
        // Bluetooth, a consent prompt on the build Mac). 0.1.54's driver can't keep one attached: no prompt part then.
        if (only.isEmpty || only.contains("prompts")) && !AgentWatchView.legacy {
            step { done in v.promptInWatch(done) }
            step { done in v.promptNeedsYouAndTakeOver(done) }
            step { done in v.engineSheet(done) }
        }
        step { done in v.clear(done) }
        run { v.finish() }
    }
}

final class AgentWatch2Check {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var c: WindowController { runner.c }
    var engine = "?"
    var server: LocalPageServer?
    var port: UInt16 = 0
    var client: SpikeMCPClient!
    var spike: AgentSpike!
    var real = false
    var window = 0
    var row = ""
    var events: [String] = []
    var tools: [String] = []
    var passes = 0, fails = 0
    let legacy = AgentWatchView.legacy
    let name = "agentwatch2-check"

    init(runner: SnapshotRunner) { self.runner = runner }

    var folder: SidebarAgentsView { c.sidebar.agents }
    var arm: String { legacy ? "before" : "after" }
    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { fails += 1 }
        note((ok ? "PASS " : "FAIL ") + "agentwatch2 \(engine) \(arm): " + what)
    }
    func measure(_ k: String, _ v: Any) { note("MEASURE agentwatch2 \(engine) \(arm) \(k) \(v)") }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    func wait(_ cond: @escaping () -> Bool, _ timeout: Double, _ done: @escaping (Bool) -> Void) {
        let end = Date().addingTimeInterval(timeout)
        func poll() {
            if cond() { return done(true) }
            if Date() > end { return done(false) }
            after(0.05, poll)
        }
        poll()
    }

    // MARK: Fixtures

    /// A page: a solid header band in `color` (page y 0–110), a block that spins (moving pixels), and for the passkey
    /// page, buttons that ask for a passkey (create at y 150, get at y 230) with the result in #state.
    static func page(_ title: String, _ color: String, passkey: Bool = false) -> String {
        """
        <!doctype html><html><head><title>\(title)</title><style>
        body{margin:0;font:18px -apple-system,sans-serif;background:#fafafa}
        header{position:fixed;left:0;top:0;right:0;height:110px;background:\(color)}
        .spin{position:absolute;left:560px;top:300px;width:60px;height:120px;background:#e85d3a}
        button{position:absolute;left:40px;width:300px;height:60px;font:18px sans-serif}
        #state{position:absolute;left:40px;top:320px}</style></head><body><header></header><div class="spin" id="spin"></div>
        <script>(function(){var e=document.getElementById('spin'),t0=Date.now();
        setInterval(function(){var x=((Date.now()-t0)/1700*240)%480;e.style.left=(560+(x>240?480-x:x))+'px';},30);})();</script>
        \(passkey ? """
        <button id="create" style="top:150px">Create a passkey</button><button id="get" style="top:230px">Sign in with a passkey</button>
        <div id="state">idle</div>
        <script>
        var aborts=[];window.abortAll=function(){aborts.forEach(function(a){a.abort();});aborts=[];};
        function b64(buf){return btoa(String.fromCharCode.apply(null,new Uint8Array(buf))).replace(/=+$/,'');}
        function set(s){document.getElementById('state').textContent=s;}
        function rnd(n){var a=new Uint8Array(n);crypto.getRandomValues(a);return a;}
        document.getElementById('create').onclick=function(){set('waiting');var ac=new AbortController();aborts.push(ac);
          navigator.credentials.create({signal:ac.signal,publicKey:{challenge:rnd(32),rp:{id:'localhost',name:'Fixture'},
            user:{id:rnd(16),name:'fixture@example.com',displayName:'Fixture'},pubKeyCredParams:[{type:'public-key',alg:-7}],
            authenticatorSelection:{residentKey:'required',userVerification:'required'},timeout:120000}})
          .then(function(c){set('created:'+b64(c.rawId));},function(e){set('error:'+e.name+':'+e.message);});};
        document.getElementById('get').onclick=function(){set('waiting');var ac=new AbortController();aborts.push(ac);
          navigator.credentials.get({signal:ac.signal,publicKey:{challenge:rnd(32),rpId:'localhost',userVerification:'required',timeout:120000}})
          .then(function(c){set('got:'+b64(c.rawId));},function(e){set('error:'+e.name+':'+e.message);});};
        </script>
        """ : "")
        </body></html>
        """
    }
    static let colors: [String: (Int, Int, Int)] = ["green": (0x1f, 0x7a, 0x4d), "blue": (0x2a, 0x5b, 0xd7), "orange": (0xd7, 0x83, 0x2a),
                                                     "purple": (0x7a, 0x2a, 0xd7)]
    static let hex = ["green": "#1f7a4d", "blue": "#2a5bd7", "orange": "#d7832a", "purple": "#7a2ad7"]

    var ip: String { "http://127.0.0.1:\(port)" }
    var lh: String { "http://localhost:\(port)" }

    // MARK: Real input

    func point(_ anchor: String, in host: NSView) -> CGPoint? {
        host.window?.contentView?.layoutSubtreeIfNeeded()
        guard let v = TestAnchors.view(anchor, in: host), let w = v.window, let main = NSScreen.screens.first else { return nil }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: r.midX.rounded(), y: (main.frame.maxY - r.midY).rounded())
    }

    /// A real click on the anchor when the UI driver is here (window key, app active), else `fallback`.
    func click(_ anchor: String, in host: @escaping () -> NSView?, _ what: String, fallback: @escaping () -> Void, _ done: @escaping (String) -> Void) {
        guard real, let h = host(), let p = point(anchor, in: h), NSApp.isActive, c.window.isKeyWindow else {
            note("FAIL-ENV agentwatch2 \(engine) \(arm): \(what) posted (\(real ? "anchor \(anchor) \(host().flatMap { point(anchor, in: $0) } == nil ? "missing" : "found"), active \(NSApp.isActive), key \(c.window.isKeyWindow)" : "no UI driver or dedicated session"))")
            fallback()
            return done("posted")
        }
        UIDriverClient.run(["--click", "\(p.x)", "\(p.y)"]) { ok, out in
            if !ok {
                self.note("FAIL-ENV agentwatch2 \(self.engine) \(self.arm): the driver refused \(what) (\(out)); posted")
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
        wait({ NSApp.isActive && self.c.window.isKeyWindow }, 6) { done($0) }
    }

    // MARK: Pixels

    /// The header band's look in Watch now: the named colour it matches, "blank" (Watch's own background across the
    /// page's place), "other", or nil (no picture).
    func look(_ w: AgentWatchView) -> String? {
        let r = w.imageRect()
        let pts = [CGPoint(x: r.minX - AgentWatchView.inset / 2, y: r.midY)]
            + [0.15, 0.5, 0.85].map { CGPoint(x: r.minX + r.width * $0, y: r.minY + r.height * 0.06) }
            + [0.3, 0.7].flatMap { fx in [0.4, 0.75].map { fy in CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy) } }
        guard let px = w.windowPixels(pts), px.count == pts.count else { return nil }
        let bg = px[0], head = Array(px[1...3]), body = Array(px[4...])
        func near(_ a: (r: Int, g: Int, b: Int), _ b: (Int, Int, Int), _ tol: Int) -> Bool { abs(a.r - b.0) <= tol && abs(a.g - b.1) <= tol && abs(a.b - b.2) <= tol }
        for (name, col) in Self.colors where head.allSatisfy({ near($0, col, 24) }) { return name }
        if (head + body).allSatisfy({ near($0, (bg.r, bg.g, bg.b), 3) }) { return "blank" }
        return "other(\(head[1]))"
    }

    /// The spinning block's pixels, three times 0.2 s apart: do they change?
    func moving(_ w: AgentWatchView, _ done: @escaping (Bool?) -> Void) {
        // Along the sliding block's track (x 560–860): it covers a different part of it every moment.
        let spin = stride(from: 570, through: 850, by: 40).map { w.viewPoint(CGPoint(x: CGFloat($0), y: 360)) }
        func key() -> [Int]? { w.windowPixels(spin).map { $0.map { $0.r * 65536 + $0.g * 256 + $0.b } } }
        let a = key()
        after(0.2) {
            let b = key()
            self.after(0.2) {
                let c = key()
                guard let a, let b, let c else { return done(nil) }
                done(a != b || b != c)
            }
        }
    }

    func describe(_ w: AgentWatchView) -> String {
        var s = "mode \(w.mode), frames \(w.framesShown), live installs \(w.liveInstalls), commit swaps \(w.swapsByCommit), blank fallbacks \(w.blankFallbacks), screenshot copies \(w.screenshotCopies), hasFrame \(w.hasFrame)"
        #if canImport(AircCore)
        if let aw = AgentCenter.shared.windows[window] {
            s += ", hosts \(ChromiumAgentDriver.describeHosts(in: aw.window))"
            if let d = aw.driver as? ChromiumAgentDriver, let t = aw.activeTab { s += ", kept \(d.isKept(t))" }
        }
        #endif
        return s
    }

    // MARK: Steps

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        spike = AgentSpike(runner: runner)
        spike.engine = engine
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("agentwatch2 \(engine) \(arm): input \(real ? "real (UI driver)" : "posted"), occlusion \(env["AIRC_KEEP_OCCLUSION"] == "1" ? "product" : "test launch off")")
        UserDefaults.standard.set(true, forKey: SidebarAgentsView.expandedKey)
        folder.model.expanded = true
        server = LocalPageServer(responses: [
            "/a.html": LocalPageServer.Page(body: Self.page("Alpha", Self.hex["green"]!)),
            "/b.html": LocalPageServer.Page(body: Self.page("Bravo", Self.hex["blue"]!)),
            "/c.html": LocalPageServer.Page(body: Self.page("Charlie", Self.hex["orange"]!)),
            "/pk.html": LocalPageServer.Page(body: Self.page("Passkey fixture", Self.hex["purple"]!, passkey: true)),
            "/notes.html": LocalPageServer.Page(body: "<title>My notes</title><textarea style='width:90%;height:300px'>The person's own page.</textarea>"),
        ])
        let previous = AgentCenter.shared.onEvent
        AgentCenter.shared.onEvent = { [weak self] e in
            if let self, self.events.count < 4000 { self.events.append(e) }
            previous?(e)
        }
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fixture server on loopback")
            let profile = c.store.profile(ofSpace: c.currentSpaceID)
            if let t = try? c.store.openTab(url: "\(ip)/notes.html", inSpace: c.currentSpaceID, title: "My notes") { c.show(t.id) }
            app.profiles.whenLoaded(profile.id, { _ in
                AgentCenter.shared.app = self.app
                AgentCenter.shared.enableForCheck(grants: [], http: false)
                AgentCenter.shared.approvals.automatic = true
                AgentCenter.shared.setShowInFront(false)
                AgentAttention.resetForTesting()
                self.after(1.5) {
                    self.front { ok in
                        if self.real, !ok { self.note("FAIL-ENV agentwatch2 \(self.engine) \(self.arm): the window isn't key and active") }
                        done()
                    }
                }
            }, failed: { self.check(false, "the profile loads"); done() })
        }
    }

    func connect(_ done: @escaping () -> Void) {
        let k = SpikeMCPClient(helper: spike.helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--client", name])
        guard k.start() else { check(false, "the MCP helper starts"); return done() }
        k.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": name, "version": "1"]], timeout: 15) { m in
            self.check(m["result"] != nil, "the fake MCP client (airc-mcp) connects (\(m["error"] ?? "ok"))")
            k.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            self.client = k
            k.request("tools/list", [:], timeout: 15) { m in
                self.tools = (((m["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                done()
            }
        }
    }

    /// open_window, then Watch from the row: the page within 1 s, moving; no "Waiting for …" with the page shown.
    func watchOpens(_ done: @escaping () -> Void) {
        guard client != nil else { return done() }
        client.call("open_window", ["url": "\(ip)/a.html"]) { r, _ in
            self.window = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.check(!SpikeMCPClient.isError(r) && self.window > 0, "open_window on a loopback page")
            self.client.call("list_tabs", ["window": self.window]) { r, _ in
                let tab = ((SpikeMCPClient.json(r)["tabs"] as? [[String: Any]])?.first?["tab"] as? Int) ?? 0
                self.row = AgentActivityModel.rowID(window: self.window, tab: tab)
                self.wait({ self.folder.model.items.contains { $0.id == self.row } }, 5) { shown in
                    self.check(shown, "the agent's row is in the Agents folder")
                    self.c.root.layoutSubtreeIfNeeded()
                    // The agent works a moment before the person looks (as the owner did).
                    self.after(2) {
                        let opened = Date()
                        self.click("agents-row-\(self.row)", in: { self.c.sidebar }, "Watch (a click on the row)", fallback: { self.folder.openWatch(self.row) }) { how in
                            self.wait({ self.folder.watch.map { self.look($0) == "green" } ?? false }, 1.0) { ok in
                                let ms = Int(Date().timeIntervalSince(opened) * 1000)
                                guard let w = self.folder.watch else { self.check(false, "[\(how)] Watch opens"); return done() }
                                self.measure("first_page_ms", ok ? ms : -1)
                                self.saveWindow("watch-open")
                                self.check(ok, "[\(how)] Watch shows the agent's page within 1 s (\(ok ? "\(ms) ms" : "look \(self.look(w) ?? "no picture")"); \(self.describe(w)))")
                                self.moving(w) { m in
                                    if let m { self.check(m, "the page moves in Watch (the agent window off screen)") }
                                    else { self.note("FAIL-ENV agentwatch2 \(self.engine) \(self.arm): no window-server picture of our own window") }
                                    self.check(AgentCenter.shared.windows[self.window].map { aw in !aw.window.isKeyWindow && !NSScreen.screens.contains { $0.frame.intersects(aw.window.frame) } } ?? false,
                                               "the agent window stays off screen and never key")
                                    self.after(AgentActivityModel.actingTail + 0.5) {
                                        let cap = w.caption ?? ""
                                        self.check(!cap.hasPrefix("Waiting for"), "with the page shown, no \"Waiting for …\" (\(cap))")
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

    /// Three cross-site navigations (127.0.0.1 ↔ localhost: a new renderer, a new compositor context each time): the
    /// new page within 1 s of the load, no blank picture at 20 Hz on the way, moving after.
    func navigations(_ done: @escaping () -> Void) {
        let hops: [(String, String)] = [("\(lh)/b.html", "blue"), ("\(ip)/c.html", "orange"), ("\(lh)/a.html", "green")]
        var i = 0
        func hop() {
            guard i < hops.count, let w = folder.watch else { return done() }
            let (url, color) = hops[i]
            i += 1
            var looks: [String] = []
            var sampling = true
            func sample() {
                guard sampling else { return }
                if let l = look(w) { looks.append(l) }
                after(0.05, sample)
            }
            sample()
            client.call("navigate", ["url": url, "window": window]) { r, _ in
                let loaded = Date()
                self.wait({ self.look(w) == color }, 1.0) { ok in
                    let ms = Int(Date().timeIntervalSince(loaded) * 1000)
                    self.after(0.5) {
                        sampling = false
                        let blanks = looks.filter { $0 == "blank" }.count
                        let others = looks.filter { $0.hasPrefix("other") }
                        self.measure("nav\(i)_samples", "\(looks.count) blank \(blanks) other \(others.count) page \(ms) ms")
                        self.check(!SpikeMCPClient.isError(r) && ok, "navigation \(i) (\(color)): the new page shows within 1 s of its load (\(ok ? "\(ms) ms" : "look \(self.look(w) ?? "none")"); \(self.describe(w)))")
                        self.check(blanks == 0, "navigation \(i): Watch never blank on the way (\(blanks) of \(looks.count) samples blank\(others.isEmpty ? "" : ", other: \(Set(others).prefix(3))"))")
                        self.moving(w) { m in
                            if let m { self.check(m, "navigation \(i): the page keeps moving") }
                            hop()
                        }
                    }
                }
            }
        }
        hop()
    }

    /// go_back across sites: the back-forward cache restores the old page (a new DevTools target for the page on Chromium).
    /// Watch shows it within 1 s, and it still moves 4 s later (the page is kept drawing).
    func back(_ done: @escaping () -> Void) {
        guard let w = folder.watch, client != nil else { return done() }
        client.call("go_back", ["window": window]) { r, _ in
            let t = Date()
            self.wait({ self.look(w) == "orange" }, 1.5) { ok in
                self.saveWindow("watch-goback")
                self.check(!SpikeMCPClient.isError(r) && ok, "go_back: Watch shows the restored page (\(ok ? "\(Int(Date().timeIntervalSince(t) * 1000)) ms" : "look \(self.look(w) ?? "none")"); \(self.describe(w)))")
                self.after(4) {
                    self.moving(w) { m in
                        if let m { self.check(m, "go_back: 4 s later the page still moves in Watch (\(self.describe(w)))") }
                        self.client.call("screenshot", ["window": self.window]) { _, _ in
                            self.after(1) {
                                self.moving(w) { m in
                                    if let m { self.check(m, "go_back: and after the agent's screenshot (\(self.describe(w)))") }
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Airc in the background while the agent works (the owner's case: Claude Code in front), then back: Watch shows the
    /// agent's current page within 1 s.
    func background(_ done: @escaping () -> Void) {
        guard real, let w = folder.watch, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            note("agentwatch2 \(engine) \(arm): background case needs the dedicated session (skipped)")
            return done()
        }
        finder.activate()
        wait({ !NSApp.isActive }, 3) { inactive in
            if !inactive { self.note("FAIL-ENV agentwatch2 \(self.engine) \(self.arm): Airc stayed active") }
            self.client.call("navigate", ["url": "\(self.ip)/c.html", "window": self.window]) { _, _ in
                self.after(3) {
                    self.front { _ in
                        let back = Date()
                        self.wait({ self.look(w) == "orange" }, 1.0) { ok in
                            #if canImport(AircCore)
                            if let aw = AgentCenter.shared.windows[self.window], let d = aw.driver as? ChromiumAgentDriver, let t = aw.activeTab {
                                self.check(d.isKept(t), "after Airc was in the background, the agent's page is still kept visible for the engine (0.1.54: kept false)")
                            }
                            #endif
                            self.check(ok, "after Airc was in the background while the agent navigated, Watch shows its page within 1 s (\(ok ? "\(Int(Date().timeIntervalSince(back) * 1000)) ms" : "look \(self.look(w) ?? "none")"); \(self.describe(w)))")
                            self.moving(w) { m in
                                if let m { self.check(m, "and it moves") }
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Prompts

    func pageState(_ done: @escaping (String) -> Void) {
        guard let aw = AgentCenter.shared.windows[window], let t = aw.activeTab else { return done("no page") }
        aw.driver.evaluate(t, "document.getElementById('state') ? document.getElementById('state').textContent : 'none'") { v in done(v as? String ?? "\(v ?? "nil")") }
    }

    func state(of tab: EngineTab, _ done: @escaping (String) -> Void) {
        tab.evaluate("document.getElementById('state') ? document.getElementById('state').textContent : 'none'") { v in done(v as? String ?? "\(v ?? "nil")") }
    }

    /// Chromium: a virtual authenticator on the agent's page (DevTools WebAuthn, in the page's kept session), user
    /// verification simulated. WebKit has none.
    func virtualAuthenticator(ui: Bool = false, _ done: @escaping (Bool) -> Void) {
        #if canImport(AircCore)
        guard let aw = AgentCenter.shared.windows[window], let t = aw.activeTab, let d = aw.driver as? ChromiumAgentDriver else { return done(false) }
        d.call(t, "WebAuthn.enable", ["enableUI": ui]) { _, e1 in
            let options: [String: Any] = ["protocol": "ctap2", "transport": "internal", "hasResidentKey": true, "hasUserVerification": true,
                                          "isUserVerified": true, "automaticPresenceSimulation": true]
            d.call(t, "WebAuthn.addVirtualAuthenticator", ["options": options]) { r, e2 in
                self.check(e1 == nil && e2 == nil && r?["authenticatorId"] != nil, "a virtual authenticator on the agent's page (\(e1 ?? e2 ?? "ok"))")
                self.authenticator = (e1 == nil && e2 == nil) ? r?["authenticatorId"] as? String : nil
                done(self.authenticator != nil)
            }
        }
        #else
        done(false)
        #endif
    }

    var authenticator: String?

    /// The virtual authenticator still answers on this page (its DevTools session is alive): only then may a passkey
    /// request go to the engine (else it would be a real one: hybrid discovery asks macOS for Bluetooth).
    func authenticatorAlive(_ page: EngineTab, _ done: @escaping (Bool) -> Void) {
        if engine == "webkit" { return done(true) }
        #if canImport(AircCore)
        guard let id = authenticator, let d = AgentCenter.shared.driver as? ChromiumAgentDriver else { return done(false) }
        d.call(page, "WebAuthn.getCredentials", ["authenticatorId": id]) { _, e in done(e == nil) }
        #else
        done(false)
        #endif
    }

    var promptRequests: [String] { events.filter { $0.hasPrefix("prompt-ask ") } }
    var agentAnswers: [(id: String, go: Bool, why: String)] { AgentPrompts.shared.answered.filter { $0.why != "not an agent page" } }

    /// In Watch: the attributed prompt; the agent can't answer it; Not now keeps it in Needs you; the row opens it again;
    /// Allow completes it.
    func promptInWatch(_ done: @escaping () -> Void) {
        guard client != nil, window > 0 else { return done() }
        if folder.watch == nil { folder.openWatch(row) }
        client.call("navigate", ["url": "\(lh)/pk.html", "window": window]) { _, _ in
            self.virtualAuthenticator { ok in
                guard ok || self.engine == "webkit" else {
                    self.check(false, "a virtual authenticator on the agent's page (no passkey request without one)"); return done()
                }
                let asked = self.promptRequests.count
                self.client.call("left_click", ["coordinate": [190, 180], "window": self.window]) { _, _ in
                    self.wait({ self.folder.watch?.promptShown != nil }, 3) { shown in
                        guard let w = self.folder.watch, let p = w.promptShown else {
                            self.check(false, "a passkey request from the agent's page shows its prompt in Watch (events \(self.promptRequests.count - asked))")
                            return done()
                        }
                        self.check(shown, "a passkey request from the agent's page shows its prompt in Watch")
                        self.check(p.title == "\(self.name) wants to use your passkey for localhost" && TestAnchors.view("agentprompt-card", in: w) != nil,
                                   "the prompt says who, for which site: \"\(p.title)\"")
                        self.check(p.origin == self.lh && p.op == "create", "with the requesting origin as the engine committed it (\(p.origin), \(p.op))")
                        self.check(AgentActivity.shared.model.row(self.row)?.needsYou == AgentPrompts.reason, "the row says Needs you · Passkey")
                        self.pageState { s in
                            self.check(s == "waiting", "the page's request waits for the person (\(s))")
                            self.agentCantAnswer(w) { self.notNowAndReopen(done) }
                        }
                    }
                }
            }
        }
    }

    /// The agent's input goes to its page, never to Airc's prompt: Return, Escape and a click where the card is.
    func agentCantAnswer(_ w: AgentWatchView, _ done: @escaping () -> Void) {
        let before = agentAnswers.count
        client.call("left_click", ["coordinate": [640, 700], "window": window]) { _, _ in
            self.client.call("key", ["text": "Return", "window": self.window]) { _, _ in
                self.client.call("key", ["text": "Escape", "window": self.window]) { _, _ in
                    self.after(0.8) {
                        self.pageState { s in
                            self.check(w.promptShown != nil && self.agentAnswers.count == before && s == "waiting",
                                       "the agent's own keys and clicks can't answer the prompt (shown \(w.promptShown != nil), answers \(self.agentAnswers.count - before), page \(s))")
                            let tools = self.tools.joined(separator: " ")
                            self.check(!tools.isEmpty && !tools.contains("prompt") && !tools.contains("passkey") && !tools.contains("allow") && !tools.contains("approve"),
                                       "no agent tool answers prompts (\(self.tools.count) tools)")
                            done()
                        }
                    }
                }
            }
        }
    }

    func notNowAndReopen(_ done: @escaping () -> Void) {
        click("agentprompt-notnow", in: { self.folder.watch }, "Not now", fallback: { self.folder.watch?.answerPrompt(allow: false) }) { how in
            self.wait({ self.folder.watch?.promptShown == nil }, 2) { gone in
                let item = AgentAttention.items().first { if case .prompt = $0.kind { return true }; return false }
                self.check(gone && item != nil && item?.rowID == self.row, "[\(how)] Not now puts it away, and it waits in Needs you (\(AgentAttention.items().map(\.title)))")
                self.pageState { s in
                    self.check(s == "waiting", "the page still waits after Not now (\(s))")
                    self.click("agentwatch-close", in: { self.folder.watch }, "close Watch", fallback: { self.folder.closeWatch() }) { _ in
                        self.wait({ self.folder.watch == nil }, 2) { _ in
                            self.after(0.4) {
                                self.click("agents-row-\(self.row)", in: { self.c.sidebar }, "the Needs you row", fallback: { _ = AgentAttention.go(row: self.row, from: "row") }) { how in
                                    self.wait({ self.folder.watch?.promptShown != nil }, 3) { back in
                                        self.check(back, "[\(how)] a click on the Needs you row opens Watch with the prompt again")
                                        self.allowInWatch(done)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var refusedPrompt: AgentPrompts.Prompt? { AgentPrompts.shared.prompts.first { $0.refused } }

    func allowInWatch(_ done: @escaping () -> Void) {
        guard folder.watch?.promptShown != nil else { return done() }
        click("agentprompt-allow", in: { self.folder.watch }, "Allow", fallback: { self.folder.watch?.answerPrompt(allow: true) }) { how in
            var last = ""
            self.wait({
                self.pageState { last = $0 }
                return last.hasPrefix("created:") || last.hasPrefix("error:") || self.refusedPrompt != nil
            }, 6) { _ in
                if let r = self.refusedPrompt {
                    // Chromium runs no passkey request for a page it counts as out of view (the off-screen agent window
                    // with occlusion on): the request stays open, and Watch says why and offers Take over.
                    let why = self.events.last { $0.hasPrefix("prompt-refused") } ?? ""
                    self.measure("allow_in_agent_window", "refused by the engine (\(why))")
                    self.wait({ self.folder.watch?.promptShown?.refused == true }, 2) { shown in
                        let w = self.folder.watch
                        self.check(shown && w.map { TestAnchors.view("agentprompt-takeover", in: $0) != nil } == true && r.detail.contains("Take over"),
                                   "[\(how)] Allow: the engine refused the out-of-view page, so Watch says why and offers Take Over (the request stays open)")
                        self.pageState { s in
                            self.check(s == "waiting", "the page's request is still open for the person (\(s))")
                            done()
                        }
                    }
                    return
                }
                if self.engine == "chromium" {
                    self.check(last.hasPrefix("created:"), "[\(how)] Allow: the request completes against the virtual authenticator (\(last))")
                } else {
                    self.check(self.agentAnswers.contains { $0.go && $0.why == "the person allowed it" } && last.hasPrefix("error:"),
                               "[\(how)] Allow hands the request to WebKit, which has no passkeys without Apple's entitlement (\(last))")
                }
                self.check(AgentAttention.items().allSatisfy { if case .prompt = $0.kind { return false }; return true }
                           && AgentActivity.shared.model.row(self.row)?.needsYou != AgentPrompts.reason, "once answered, nothing waits in Needs you")
                done()
            }
        }
    }

    /// Watch closed: Needs you (toast, row) → Watch with the prompt → Take over → still answerable in the person's window.
    func promptNeedsYouAndTakeOver(_ done: @escaping () -> Void) {
        guard client != nil, window > 0 else { return done() }
        let finish = { if self.folder.watch != nil { self.folder.closeWatch() } }
        finish()
        let toasts = events.filter { $0.hasPrefix("attention-toast prompt-") }.count
        // The refused create is still open: it's the one to finish after Take over; else the agent asks to sign in.
        let pending = refusedPrompt != nil
        guard engine == "webkit" || authenticator != nil else { note("agentwatch2 \(engine) \(arm): no virtual authenticator: no passkey request (skipped)"); return done() }
        let ask: (@escaping () -> Void) -> Void = { go in
            if pending { return go() }
            self.client.call("left_click", ["coordinate": [190, 260], "window": self.window]) { _, _ in go() }
        }
        ask {
            self.wait({ AgentAttention.items().contains { if case .prompt = $0.kind { return true }; return false } }, 3) { waits in
                self.check(waits && self.folder.watch == nil, "with Watch closed, the request waits in Needs you (\(AgentAttention.items().map(\.title)))")
                self.after(0.3) {
                    if !pending { self.check(self.events.filter { $0.hasPrefix("attention-toast prompt-") }.count > toasts, "Airc's toast says it in the person's window") }
                    self.click("agents-row-\(self.row)", in: { self.c.sidebar }, "the Needs you row", fallback: { _ = AgentAttention.go(row: self.row, from: "row") }) { how in
                        self.wait({ self.folder.watch?.promptShown != nil }, 3) { shown in
                            self.check(shown, "[\(how)] Needs you opens Watch with the prompt")
                            guard let page = AgentCenter.shared.windows[self.window]?.activeTab else { return done() }
                            self.click("agentwatch-takeover", in: { self.folder.watch }, "Take over", fallback: { self.folder.watch?.takeOver() }) { how in
                                self.wait({ AgentPrompts.shared.pageOverlay(in: self.c) != nil }, 4) { over in
                                    self.check(over && AgentPrompts.controller(holding: page)?.0 === self.c,
                                               "[\(how)] after Take over the page is the person's tab and the prompt is over it (\(AgentAttention.items().map(\.title)))")
                                    self.front { _ in
                                      self.authenticatorAlive(page) { alive in
                                        guard alive else {
                                            self.check(false, "after Take over the virtual authenticator is still there (else no Allow: it would be a real request)")
                                            page.evaluate("window.abortAll && window.abortAll(); 'ok'") { _ in done() }
                                            return
                                        }
                                        self.click("agentprompt-allow", in: { AgentPrompts.shared.pageOverlay(in: self.c) }, "Allow over the taken-over page",
                                                   fallback: { if let p = AgentPrompts.shared.pageOverlay(in: self.c)?.prompt { AgentPrompts.shared.allow(p.id) } }) { how in
                                            var last = ""
                                            self.wait({
                                                self.state(of: page) { last = $0 }
                                                return last.hasPrefix("got:") || last.hasPrefix("created:") || last.hasPrefix("error:")
                                            }, 6) { _ in
                                                if self.engine == "chromium" {
                                                    let focusNote = self.c.window.isKeyWindow ? "" : " (window not key: the engine wants a focused page)"
                                                    self.check(last.hasPrefix(pending ? "created:" : "got:"),
                                                               "[\(how)] after Take over, Allow completes the same request against the virtual authenticator (\(last))\(focusNote)")
                                                } else {
                                                    self.check(self.agentAnswers.contains { $0.go && $0.why == "the person allowed it" } && last.hasPrefix("error:"), "[\(how)] Allow after Take over hands the request to WebKit (\(last))")
                                                }
                                                self.check(AgentPrompts.shared.pageOverlay(in: self.c) == nil, "the prompt goes once answered")
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
    }

    /// Chromium's own passkey sheet, when this build shows one (a request without a virtual authenticator): over Watch,
    /// on our window's Space; off screen while Watch is closed (Needs you · Prompt), and gone with the request.
    func engineSheet(_ done: @escaping () -> Void) {
        guard engine == "chromium", client != nil else { return done() }
        client.call("open_window", ["url": "\(lh)/pk.html"]) { r, _ in
            self.window = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            self.client.call("list_tabs", ["window": self.window]) { r, _ in
                let tab = ((SpikeMCPClient.json(r)["tabs"] as? [[String: Any]])?.first?["tab"] as? Int) ?? 0
                self.row = AgentActivityModel.rowID(window: self.window, tab: tab)
                // Chromium's own WebAuthn UI on (DevTools enableUI): its sheet shows for the request, as for a real passkey.
                self.virtualAuthenticator(ui: true) { ok in
                guard ok else { self.check(false, "a virtual authenticator for the sheet case (no passkey request without one)"); return done() }
                self.client.call("left_click", ["coordinate": [190, 180], "window": self.window]) { _, _ in
                    self.wait({ AgentPrompts.shared.prompts.contains { $0.rowID == self.row } }, 3) { asked in
                        self.check(asked, "a second agent page's request waits for the person")
                        self.folder.openWatch(self.row)
                        self.wait({ self.folder.watch?.promptShown != nil }, 3) { _ in
                            self.click("agentprompt-allow", in: { self.folder.watch }, "Allow (engine sheet case)", fallback: { self.folder.watch?.answerPrompt(allow: true) }) { _ in
                                self.wait({ AgentPrompts.shared.sheets.contains { $0.window?.isVisible == true } }, 4) { sheet in
                                    self.describeChildren("after Allow")
                                    guard sheet, let s = AgentPrompts.shared.sheets.first(where: { $0.window?.isVisible == true })?.window else {
                                        self.pageState { st in
                                            self.note("agentwatch2 \(self.engine) \(self.arm): this build showed no engine passkey sheet (no platform authenticator; fresh agent window: page \(st), refused \(self.refusedPrompt != nil)); sheet placement not exercised")
                                            self.abortPage(done)
                                        }
                                        return
                                    }
                                    self.after(0.4) {
                                        // What the window is, for the report (its picture from the window server).
                                        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                                            typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                                            if let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(s.windowNumber), 1 << 0)?.takeRetainedValue() {
                                                let url = self.runner.dir.appendingPathComponent("engine-sheet.png")
                                                if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                                            }
                                        }
                                        self.note("agentwatch2 \(self.engine) \(self.arm): engine sheet \(NSStringFromClass(type(of: s))) \(s.frame) opaque \(s.isOpaque); \(self.events.filter { $0.hasPrefix("engine-child") }.suffix(4))")
                                        let onOurs = s.parent === self.c.window && self.c.window.frame.intersects(s.frame) && s.isOnActiveSpace
                                        self.check(onOurs, "Chromium's passkey sheet hangs over Watch in the person's window (frame \(s.frame), window \(self.c.window.frame))")
                                        self.folder.closeWatch()
                                        self.after(0.6) {
                                            let away = !NSScreen.screens.contains { $0.frame.intersects(s.frame) }
                                            self.check(away && AgentActivity.shared.model.row(self.row)?.needsYou == "Prompt",
                                                       "with Watch closed it waits off screen, never on another Space (Needs you · \(AgentActivity.shared.model.row(self.row)?.needsYou ?? "-"))")
                                            self.folder.openWatch(self.row)
                                            self.after(0.6) {
                                                self.check(s.parent === self.c.window && self.c.window.frame.intersects(s.frame), "Watch again: the sheet is back over it")
                                                self.abortPage {
                                                    self.wait({ !s.isVisible }, 3) { gone in
                                                        self.check(gone, "the sheet goes with the page's request")
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
            }
        }
    }

    /// Our own window's picture from the window server (what the person sees, hosted page included), for the report.
    func saveWindow(_ name: String) {
        guard ProcessInfo.processInfo.environment["AIRC_DISABLE_LEGACY_WINDOW_CAPTURE"] != "1",
              let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(c.window.windowNumber), 1 << 0)?.takeRetainedValue() else { return }
        let url = runner.dir.appendingPathComponent("\(name)-\(engine)-\(arm).png")
        if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
    }

    /// Every window the engine hung on an agent window: what it is, and its picture from the window server (out folder).
    func describeChildren(_ when: String) {
        var n = 0
        for weak in AgentPrompts.shared.seenChildren {
            guard let w = weak.window else { continue }
            n += 1
            func tree(_ v: NSView?, _ depth: Int) -> String {
                guard let v, depth < 4 else { return "" }
                return NSStringFromClass(type(of: v)) + "\(Int(v.frame.width))x\(Int(v.frame.height))" + (v.subviews.isEmpty ? "" : "[" + v.subviews.prefix(4).map { tree($0, depth + 1) }.joined(separator: ",") + "]")
            }
            note("agentwatch2 \(engine) \(arm): engine window \(n) \(when): \(NSStringFromClass(type(of: w))) frame \(w.frame) visible \(w.isVisible) opaque \(w.isOpaque) alpha \(w.alphaValue) bg \(w.backgroundColor.map { "\($0)" } ?? "-") mouse \(!w.ignoresMouseEvents) level \(w.level.rawValue) parent \(w.parent.map { NSStringFromClass(type(of: $0)) } ?? "none") views \(tree(w.contentView, 0))")
            if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
                typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let img = unsafeBitCast(sym, to: Fn.self)(.null, 1 << 3, UInt32(w.windowNumber), 1 << 0)?.takeRetainedValue() {
                    let url = runner.dir.appendingPathComponent("engine-window-\(n)-\(when.replacingOccurrences(of: " ", with: "-")).png")
                    if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d) }
                }
            }
        }
        if n == 0 { note("agentwatch2 \(engine) \(arm): no engine window on the agent window \(when)") }
    }

    func abortPage(_ done: @escaping () -> Void) {
        guard let aw = AgentCenter.shared.windows[window], let t = aw.activeTab else { return done() }
        aw.driver.evaluate(t, "window.abortAll && window.abortAll(); 'ok'") { _ in self.after(1.0) { self.describeChildren("after abort"); done() } }
    }

    func clear(_ done: @escaping () -> Void) {
        if folder.watch != nil { folder.closeWatch() }
        client?.stop()
        after(1.0) {
            self.check(AgentPrompts.shared.prompts.isEmpty, "no prompt is left once the agent is gone (\(AgentPrompts.shared.prompts.count))")
            done()
        }
    }

    func finish() {
        note("agentwatch2 \(engine) \(arm): events \(events.filter { $0.hasPrefix("watch-") || $0.hasPrefix("prompt") || $0.hasPrefix("engine-sheet") }.prefix(60).joined(separator: " | "))")
        if passes + fails == 0 { note("FAIL agentwatch2 \(engine) \(arm): zero-guard: no assertions ran") }
        server?.stop()
    }
}
#endif
