// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script agentspike` (artifacts/agentspike/REPORT.md): the agent server end to end, as an MCP client would use it.
/// The check starts the real `airc-mcp` helper (`--agent-helper=<path>`, else Contents/Helpers) and speaks MCP over its
/// stdio to the server in this app, on loopback fixture pages, in a profile it grants ("Agent"; the default profile
/// stays ungranted). It checks: both MCP eras, the profile scope, agent windows that are never key or front and are
/// off every screen, screenshots of the engine's picture at the window's size (a red block's pixels), trusted clicks,
/// typing, keys, scrolling, drags, right clicks without a menu, zoom, page reads without passwords or cookies, the
/// loopback HTTP transport's token / Origin / Host checks, the log's lack of content, the Dock badge and Stop.
/// It measures screenshot and input round trips, the page's visibility in kept-visible and engine-hidden windows, and
/// one idle agent window's CPU and memory. MEASURE lines and agentspike-<engine>.json carry the numbers.
extension SnapshotRunner {
    func agentSpikeScenario() {
        let spike = AgentSpike(runner: self)
        step { done in spike.setUp(done) }
        step { done in spike.protocolChecks(done) }
        step { done in spike.windowChecks(done) }
        step { done in spike.inputChecks(done) }
        step { done in spike.readChecks(done) }
        step { done in spike.navigationChecks(done) }
        step { done in spike.hiddenComparison(done) }
        step { done in spike.idleCost(done) }
        step { done in spike.httpChecks(done) }
        step { done in spike.logAndStop(done) }
        run { spike.finish() }
    }
}

/// A minimal MCP client over a helper's stdio.
final class SpikeMCPClient {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data()
    private var waiting: [Int: ([String: Any]) -> Void] = [:]
    private var nextID = 1
    private(set) var stderrText = ""
    private(set) var exitCode: Int32?
    var onExit: (() -> Void)?

    init(helper: String, args: [String]) {
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = args
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }   // end of file: stop, or it fires forever
            DispatchQueue.main.async { self?.received(data) }
        }
        let errors = self.errors
        process.terminationHandler = { [weak self] p in
            // All of stderr first, so onExit sees why it ended.
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self?.stderrText += text
                self?.exitCode = p.terminationStatus
                self?.onExit?()
            }
        }
    }

    func start() -> Bool { (try? process.run()) != nil }

    private func received(_ data: Data) {
        buffer.append(data)
        while let i = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<i])
            buffer.removeSubrange(buffer.startIndex...i)
            guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = m["id"] as? Int else { continue }
            waiting.removeValue(forKey: id)?(m)
        }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ method: String, _ params: [String: Any] = [:], timeout: Double = 30, _ done: @escaping ([String: Any]) -> Void) {
        let id = nextID
        nextID += 1
        waiting[id] = done
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.waiting.removeValue(forKey: id)?(["error": ["message": "timed out"]])
        }
    }

    /// tools/call: the result and the round trip in ms.
    func call(_ tool: String, _ args: [String: Any] = [:], timeout: Double = 30, _ done: @escaping ([String: Any], Double) -> Void) {
        let t = CFAbsoluteTimeGetCurrent()
        request("tools/call", ["name": tool, "arguments": args], timeout: timeout) { m in
            done((m["result"] as? [String: Any]) ?? ["isError": true, "content": [["type": "text", "text": "\(m["error"] ?? "no result")"]]],
                 (CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    static func text(_ r: [String: Any]) -> String {
        ((r["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    static func isError(_ r: [String: Any]) -> Bool { r["isError"] as? Bool == true }
    static func json(_ r: [String: Any]) -> [String: Any] {
        if let s = r["structuredContent"] as? [String: Any] { return s }
        let first = ((r["content"] as? [[String: Any]]) ?? []).first?["text"] as? String ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]) ?? [:]
    }
    static func image(_ r: [String: Any]) -> CGImage? {
        guard let b64 = ((r["content"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "image" })?["data"] as? String,
              let data = Data(base64Encoded: b64), let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

final class AgentSpike {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var engine = "?"
    var port: UInt16 = 0
    var client: SpikeMCPClient!
    var windowID = 0
    var measures: [String: Any] = [:]
    var personWindowKeyAtStart = false
    var frontAtStart: String?
    /// Every time macOS made Airc the active app during the run (it must never happen: agents never activate Airc).
    var activations = 0
    var activeObserver: NSObjectProtocol?
    var airIsFront: Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() || NSApp.isActive }
    var front: String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }
    let secretPassword = "hunter2-agentspike"
    let secretCookie = "secret-cookie-value"
    let typed = "hello agent"
    var server: LocalPageServer?

    init(runner: SnapshotRunner) { self.runner = runner }

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "agentspike \(engine): " + what) }
    func measure(_ name: String, _ value: Any) {
        measures[name] = value
        note("MEASURE agentspike \(engine) \(name) \(value)")
    }
    var base: String { "http://127.0.0.1:\(port)" }

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
    static func p90(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * 0.9))] }
    static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    // MARK: Fixtures

    static let agentPage = """
    <!doctype html><html><head><title>Agentspike</title><style>
    body{margin:0;font:16px -apple-system,sans-serif;height:3200px}
    #red{position:absolute;left:0;top:0;width:200px;height:100px;background:#ff0000}
    .b{position:absolute;display:flex;align-items:center;justify-content:center;box-sizing:border-box;border:1px solid #888}
    #btn{left:300px;top:30px;width:160px;height:50px}
    #name{position:absolute;left:300px;top:110px;width:300px;height:36px;box-sizing:border-box}
    #pw{position:absolute;left:300px;top:170px;width:300px;height:36px;box-sizing:border-box}
    #dbl{left:640px;top:30px;width:160px;height:50px}
    #ctx{left:640px;top:110px;width:160px;height:50px}
    #newtab{left:640px;top:170px;width:160px;height:40px}
    #drag{left:300px;top:240px;width:500px;height:200px;background:#eef}
    #inner{position:absolute;left:850px;top:30px;width:300px;height:200px;overflow:auto;border:1px solid #888}
    #alert{left:850px;top:250px;width:160px;height:40px}
    #text{position:absolute;left:0;top:470px}
    #state{display:none}
    </style></head><body>
    <div id="red"></div>
    <button id="btn" class="b">Press me</button>
    <form id="f"><input id="name" placeholder="Your name" autocomplete="off"></form>
    <input id="pw" type="password" autocomplete="current-password">
    <button id="alert" class="b">Alert</button>
    <div id="dbl" class="b">Double me</div><div id="ctx" class="b">Right me</div>
    <a id="newtab" class="b" href="/second.html" target="_blank">New tab</a>
    <div id="drag" class="b">Drag here</div>
    <div id="inner"><div style="height:2000px">Inner scroller</div></div>
    <p id="text">Agentspike fixture: the quick brown fox jumps over the lazy dog.</p>
    <pre id="state"></pre>
    <script>
    var S={clicks:0,trusted:true,keys:0,keyTrusted:true,lastKey:'',submits:0,dbl:0,ctx:0,drag:[],dragButtons:[],raf:0,vis:[],value:'',alerted:0};
    var down=false;
    function save(){document.getElementById('state').textContent=JSON.stringify(S);}
    document.getElementById('pw').value='hunter2-agentspike';
    document.getElementById('btn').addEventListener('click',function(e){S.clicks++;S.trusted=S.trusted&&e.isTrusted;save();});
    var n=document.getElementById('name');
    n.addEventListener('keydown',function(e){S.keys++;S.keyTrusted=S.keyTrusted&&e.isTrusted;S.lastKey=e.key;save();});
    n.addEventListener('input',function(){S.value=n.value;save();});
    document.getElementById('f').addEventListener('submit',function(e){e.preventDefault();S.submits++;save();});
    document.getElementById('dbl').addEventListener('dblclick',function(){S.dbl++;save();});
    document.getElementById('ctx').addEventListener('contextmenu',function(e){e.preventDefault();S.ctx++;save();});
    var d=document.getElementById('drag');
    d.addEventListener('mousedown',function(e){down=true;S.drag=[[e.clientX,e.clientY]];S.dragButtons=[];save();});
    d.addEventListener('mousemove',function(e){if(down){S.drag.push([e.clientX,e.clientY]);S.dragButtons.push(e.buttons);save();}});
    d.addEventListener('mouseup',function(e){down=false;S.dragEnd=[e.clientX,e.clientY];save();});
    document.getElementById('alert').addEventListener('click',function(){alert('agent');confirm('agent?');S.alerted++;save();});
    document.addEventListener('visibilitychange',function(){S.vis.push(document.visibilityState);save();});
    (function tick(){S.raf++;if(S.raf%10===0)save();requestAnimationFrame(tick);})();
    save();
    </script></body></html>
    """
    static let secondPage = "<!doctype html><title>Second</title><body><p>Second page</p></body>"
    static let idlePage = "<!doctype html><title>Idle</title><body><h1>Idle page</h1><p>Static text, no scripts.</p></body>"

    // MARK: Steps

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        frontAtStart = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in self?.activations += 1 }
        personWindowKeyAtStart = runner.c?.window.isKeyWindow ?? false
        // The profile agents may use; the default one stays closed to them.
        let store = app.store!
        let agent: Profile
        if let p = store.orderedProfiles.first(where: { $0.name == "Agent" }) { agent = p }
        else { agent = try! runner.c.profiles.createProfile(name: "Agent", emoji: "🤖", color: nil) }
        _ = agent
        let pages: [String: LocalPageServer.Page] = [
            "/agent.html": LocalPageServer.Page(headers: ["Set-Cookie": "agentspike=\(secretCookie); Path=/"], body: Self.agentPage),
            "/second.html": LocalPageServer.Page(body: Self.secondPage),
            "/idle.html": LocalPageServer.Page(body: Self.idlePage),
        ]
        server = LocalPageServer(responses: pages)
        server?.start { [self] p in
            port = p ?? 0
            check(port != 0, "fixture server on loopback")
            app.profiles.whenLoaded(agent.id, { _ in
                AgentCenter.shared.app = self.app
                AgentCenter.shared.enableForCheck(grants: ["Agent"], http: true)
                self.check(AgentCenter.shared.isServing, "the agent server listens (\(AgentCenter.shared.socketPath.count) byte path)")
                var st = stat()
                let mode = stat(AgentCenter.shared.socketPath, &st) == 0 ? Int(st.st_mode & 0o777) : -1
                self.check(mode == 0o600, "the socket is 0600 (\(String(mode, radix: 8)))")
                self.startClient(profile: "Agent") { ok in
                    self.check(ok, "airc-mcp connects with --profile Agent")
                    done()
                }
            }, failed: { self.check(false, "the Agent profile loads"); done() })
        }
    }

    var helperPath: String {
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--agent-helper=") }) { return String(a.dropFirst("--agent-helper=".count)) }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/airc-mcp").path
    }

    func helper(_ profile: String) -> SpikeMCPClient {
        SpikeMCPClient(helper: helperPath, args: ["--data-dir", AppPaths.dataDirectory.path, "--profile", profile, "--client", "agentspike-check"])
    }

    func startClient(profile: String, _ done: @escaping (Bool) -> Void) {
        client = helper(profile)
        guard client.start() else { return done(false) }
        client.request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                      "clientInfo": ["name": "agentspike-check", "version": "1"]]) { m in
            let r = m["result"] as? [String: Any]
            self.client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            done(r?["protocolVersion"] as? String == "2025-11-25")
        }
    }

    func protocolChecks(_ done: @escaping () -> Void) {
        let modernMeta: [String: Any] = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
                                                    "io.modelcontextprotocol/clientInfo": ["name": "agentspike-check", "version": "1"]]]
        client.request("server/discover", modernMeta) { m in
            let r = m["result"] as? [String: Any]
            self.check((r?["supportedVersions"] as? [String])?.contains("2026-07-28") == true, "server/discover names 2026-07-28 and the legacy versions")
            self.client.request("tools/list", modernMeta) { m in
                let tools = ((m["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                let members = ["screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click",
                               "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position", "scroll",
                               "type", "key", "hold_key", "wait"]
                self.check(members.allSatisfy { tools.contains($0) }, "tools/list has all 17 computer-use members (\(tools.count) tools)")
                self.check(["list_profiles", "use_profile", "open_window", "navigate", "read_page", "find_element", "computer"].allSatisfy { tools.contains($0) },
                           "tools/list has the profile, window and browser tools")
                self.measure("tools", tools.count)
                self.client.request("tools/call", ["name": "list_profiles", "arguments": [:], "_meta": ["io.modelcontextprotocol/protocolVersion": "1999-01-01"]]) { m in
                    self.check((m["error"] as? [String: Any])?["code"] as? Int == -32022, "an unknown protocol version gets UnsupportedProtocolVersionError")
                    self.client.call("list_profiles") { r, _ in
                        let names = ((SpikeMCPClient.json(r)["profiles"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                        self.check(names == ["Agent"], "list_profiles shows only the granted profile (\(names))")
                        let defaultName = self.app.store.defaultProfile.name
                        self.client.call("use_profile", ["profile": defaultName]) { r, _ in
                            self.check(SpikeMCPClient.isError(r), "use_profile refuses the ungranted default profile")
                            // A helper asking for the ungranted profile is turned away at the door.
                            let other = self.helper(defaultName)
                            other.onExit = {
                                self.check(other.exitCode == 77 && other.stderrText.contains("isn't open to agents"),
                                           "airc-mcp --profile <ungranted> is refused (exit \(other.exitCode ?? -1))")
                                done()
                            }
                            if !other.start() { self.check(false, "second helper starts"); done() }
                        }
                    }
                }
            }
        }
    }

    var agentWindow: AgentWindow? { AgentCenter.shared.windows[windowID] }

    /// The fixture page's own record of what reached it, read in the engine's script world.
    func pageState(_ done: @escaping ([String: Any]) -> Void) {
        guard let w = agentWindow, let tab = w.activeTab else { return done([:]) }
        w.driver.evaluate(tab, """
        (function(){var s={};try{s=JSON.parse(document.getElementById('state').textContent||'{}');}catch(e){}
        s.visibility=document.visibilityState;s.hasFocus=document.hasFocus();s.scrollY=scrollY;
        var i=document.getElementById('inner');s.innerScroll=i?i.scrollTop:0;var n=document.getElementById('name');s.value=n?n.value:'';
        return JSON.stringify(s);})()
        """) { done(agentJSON($0) ?? [:]) }
    }

    func onScreen(_ w: NSWindow) -> Bool { NSScreen.screens.contains { $0.frame.intersects(w.frame) } }

    func windowChecks(_ done: @escaping () -> Void) {
        client.call("open_window", ["url": "\(base)/agent.html"]) { r, ms in
            let j = SpikeMCPClient.json(r)
            self.windowID = j["window"] as? Int ?? 0
            self.measure("open_window_ms", Int(ms))
            self.check(self.windowID > 0 && j["width"] as? Int == 1280 && j["height"] as? Int == 800, "open_window: an agent window, 1280x800")
            guard let w = self.agentWindow else { return done() }
            self.check(!w.window.isKeyWindow && !w.window.isMainWindow && !w.window.canBecomeKey, "the agent window is never key or main")
            self.check(!self.onScreen(w.window), "the agent window is off every screen (\(NSStringFromRect(w.window.frame)))")
            self.check(w.window.isVisible, "the agent window is ordered in (live pages)")
            self.check(!self.airIsFront, "Airc isn't the active or frontmost app with an agent window open (front: \(self.front))")
            self.check(AgentCenter.shared.badgeShown, "the Dock icon shows ✦ while an agent is connected")
            self.measure("occlusion_visible", w.window.occlusionState.contains(.visible))
            self.client.call("screenshot") { r, _ in
                let image = SpikeMCPClient.image(r)
                self.check(image?.width == 1280 && image?.height == 800, "screenshot is 1280x800 (\(image.map { "\($0.width)x\($0.height)" } ?? "none"))")
                let red = image.flatMap { AgentImages.pixel($0, x: 100, y: 50) }
                self.check(red.map { $0.r > 220 && $0.g < 40 && $0.b < 40 } ?? false, "screenshot shows the page (red block: \(red.map { "\($0)" } ?? "none"))")
                let white = image.flatMap { AgentImages.pixel($0, x: 250, y: 460) }
                self.check(white.map { $0.r > 230 && $0.g > 230 } ?? false, "screenshot background is the page's (\(white.map { "\($0)" } ?? "none"))")
                let s = SpikeMCPClient.json(r)
                self.measure("device_pixels", s["devicePixels"] ?? "?")
                // Latency: 10 screenshots through the helper.
                var trips: [Double] = [], engineMs: [Double] = []
                func next(_ i: Int) {
                    if i == 10 {
                        self.measure("screenshot_ms_median", Self.r1(Self.median(trips)))
                        self.measure("screenshot_ms_p90", Self.r1(Self.p90(trips)))
                        self.measure("screenshot_engine_ms_median", Self.r1(Self.median(engineMs)))
                        self.pageState { st in
                            self.measure("visible_page_visibility", st["visibility"] ?? "?")
                            self.measure("visible_page_hasFocus", st["hasFocus"] ?? "?")
                            let raf0 = st["raf"] as? Int ?? 0
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                self.pageState { st in
                                    let fps = (st["raf"] as? Int ?? 0) - raf0
                                    self.measure("visible_page_raf_per_s", fps)
                                    // Chromium's visible capturer makes the page visible off screen; WebKit's page stays
                                    // hidden in a window off every screen (it still pictures, takes input, reads).
                                    if self.engine == "chromium" {
                                        self.check(st["visibility"] as? String == "visible" && fps > 30,
                                                   "the kept-visible page reads visible and animates (\(fps) frames/s)")
                                    }
                                    done()
                                }
                            }
                        }
                        return
                    }
                    self.client.call("screenshot") { r, ms in
                        trips.append(ms)
                        engineMs.append((SpikeMCPClient.json(r)["engineMs"] as? NSNumber)?.doubleValue ?? 0)
                        next(i + 1)
                    }
                }
                next(0)
            }
        }
    }

    func inputChecks(_ done: @escaping () -> Void) {
        var trips: [Double] = []
        func clicks(_ i: Int, _ then: @escaping () -> Void) {
            if i == 10 { return then() }
            client.call("left_click", ["coordinate": [380, 55]]) { _, ms in trips.append(ms); clicks(i + 1, then) }
        }
        clicks(0) {
            self.measure("click_ms_median", Self.r1(Self.median(trips)))
            self.measure("click_ms_p90", Self.r1(Self.p90(trips)))
            self.pageState { st in
                self.check(st["clicks"] as? Int == 10, "10 left_clicks reach the button (\(st["clicks"] ?? "nil"))")
                self.check(st["trusted"] as? Bool == true, "the clicks are trusted events (isTrusted)")
                self.client.call("left_click", ["coordinate": [450, 128]]) { _, _ in
                    let t = CFAbsoluteTimeGetCurrent()
                    self.client.call("type", ["text": self.typed]) { r, _ in
                        self.measure("type_11_chars_ms", Int((CFAbsoluteTimeGetCurrent() - t) * 1000))
                        self.pageState { st in
                            self.check(st["value"] as? String == self.typed, "type fills the field (\(st["value"] ?? "nil"))")
                            if self.engine == "chromium" {
                                self.check(st["keys"] as? Int == self.typed.count && st["keyTrusted"] as? Bool == true,
                                           "each typed character is a trusted keydown (\(st["keys"] ?? "nil"))")
                            }
                            self.measure("typed_keydowns", "\(st["keys"] ?? "nil") of \(self.typed.count), trusted \(st["keyTrusted"] ?? "nil")")
                            self.client.call("key", ["text": "Return"]) { _, _ in
                                self.pageState { st in
                                    self.check(st["submits"] as? Int == 1, "key Return submits the form (\(st["submits"] ?? "nil"))")
                                    self.client.call("key", ["text": "super+a"]) { r, _ in
                                        self.client.call("type", ["text": "replaced"]) { _, _ in
                                            self.pageState { st in
                                                self.check(st["value"] as? String == "replaced", "super+a selects all, type replaces (\(st["value"] ?? "nil"))")
                                                self.moreInput(done)
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

    func moreInput(_ done: @escaping () -> Void) {
        client.call("key", ["text": "super+v"]) { r, _ in
            self.check(SpikeMCPClient.isError(r) && SpikeMCPClient.text(r).contains("clipboard"), "paste is refused (no clipboard in agent windows)")
            self.client.call("double_click", ["coordinate": [720, 55]]) { _, _ in
                self.client.call("right_click", ["coordinate": [720, 135]]) { _, _ in
                    self.client.call("left_click_drag", ["start_coordinate": [350, 300], "coordinate": [700, 400]]) { _, ms in
                        self.measure("drag_ms", Int(ms))
                        self.client.call("scroll", ["coordinate": [1000, 130], "scroll_direction": "down", "scroll_amount": 3]) { _, _ in
                            self.client.call("scroll", ["coordinate": [100, 600], "scroll_direction": "down", "scroll_amount": 2]) { _, _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    self.pageState { st in
                                        self.check(st["dbl"] as? Int == 1, "double_click fires dblclick (\(st["dbl"] ?? "nil"))")
                                        self.check(st["ctx"] as? Int == 1, "right_click fires contextmenu, no menu (\(st["ctx"] ?? "nil"))")
                                        let path = st["drag"] as? [[Any]] ?? []
                                        let end = st["dragEnd"] as? [NSNumber]
                                        self.measure("drag_event_buttons", "\((st["dragButtons"] as? [Int] ?? []).prefix(3))")
                                        self.check(path.count >= 5 && end.map { abs($0[0].doubleValue - 700) < 3 && abs($0[1].doubleValue - 400) < 3 } == true,
                                                   "left_click_drag drags (\(path.count) moves, end \(end ?? []))")
                                        self.check(((st["innerScroll"] as? NSNumber)?.doubleValue ?? 0) > 0, "scroll scrolls the element under the point (\(st["innerScroll"] ?? "nil"))")
                                        self.check(((st["scrollY"] as? NSNumber)?.doubleValue ?? 0) > 0, "scroll scrolls the page (\(st["scrollY"] ?? "nil"))")
                                        self.measure("input_paths", (self.agentWindow?.driver.inputPaths ?? [:]).description)
                                        self.client.call("mouse_move", ["coordinate": [123, 456]]) { _, _ in
                                            self.client.call("cursor_position") { r, _ in
                                                self.check(SpikeMCPClient.text(r) == "X=123, Y=456", "cursor_position follows mouse_move (\(SpikeMCPClient.text(r)))")
                                                self.client.call("left_click", ["coordinate": [5000, 10]]) { r, _ in
                                                    self.check(SpikeMCPClient.isError(r), "a click outside the screenshot is refused")
                                                    // Back to the top for the reads.
                                                    self.client.call("scroll", ["coordinate": [100, 300], "scroll_direction": "up", "scroll_amount": 20]) { _, _ in
                                                        self.client.call("zoom", ["region": [0, 0, 200, 100]]) { r, _ in
                                                            let image = SpikeMCPClient.image(r)
                                                            let p = image.flatMap { AgentImages.pixel($0, x: $0.width / 2, y: $0.height / 2) }
                                                            self.check(image?.width == 1280 && image?.height == 640 && (p?.r ?? 0) > 220,
                                                                       "zoom returns the region at the screenshot's width (\(image.map { "\($0.width)x\($0.height)" } ?? "none"))")
                                                            self.safetyInput(done)
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

    /// Keys and dialogs that must never reach the person: ⌘W in an agent window leaves the person's window and tab alone;
    /// a page's alert() and confirm() neither block the agent nor show anything.
    func safetyInput(_ done: @escaping () -> Void) {
        let controllers = app.controllers.count
        let shown = runner.c?.shownTabID
        client.call("key", ["text": "super+w"]) { _, _ in
            self.client.call("key", ["text": "super+q"]) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.check(self.app.controllers.count == controllers && self.runner.c?.shownTabID == shown && self.agentWindow != nil,
                               "super+w and super+q in an agent window leave Airc's own windows and tabs alone")
                    self.client.call("left_click", ["coordinate": [930, 270]], timeout: 20) { r, ms in
                        self.pageState { st in
                            self.check(!SpikeMCPClient.isError(r) && st["alerted"] as? Int == 1 && ms < 5000,
                                       "a page's alert() and confirm() don't block the agent (\(Int(ms)) ms, alerted \(st["alerted"] ?? "nil"))")
                            self.check(self.agentWindow?.window.attachedSheet == nil, "no sheet on the agent window")
                            done()
                        }
                    }
                }
            }
        }
    }

    func readChecks(_ done: @escaping () -> Void) {
        client.call("read_page", ["mode": "text"]) { r, ms in
            let text = SpikeMCPClient.text(r)
            self.measure("read_page_text_ms", Int(ms))
            self.check(text.contains("Agentspike fixture") && text.contains("<untrusted-page-content"), "read_page text has the page's text, fenced as untrusted")
            self.check(!text.contains(self.secretPassword) && !text.contains(self.secretCookie), "read_page text has no password or cookie")
            self.client.call("read_page", ["mode": "outline"]) { r, ms in
                let out = SpikeMCPClient.text(r)
                self.measure("read_page_outline_ms", Int(ms))
                self.check(out.contains("\"name\":\"Press me\"") && out.contains("\"x\":380") && out.contains("\"y\":55"),
                           "read_page outline gives the button with its centre in screenshot pixels")
                self.check(!out.contains(self.secretPassword) && out.contains("(hidden)"), "the outline hides the password field's value")
                self.client.call("find_element", ["text": "press", "role": "button"]) { r, _ in
                    let found = SpikeMCPClient.text(r)
                    self.check(found.contains("Press me") && found.contains("\"x\":380"), "find_element finds the button by its name and role")
                    done()
                }
            }
        }
    }

    func navigationChecks(_ done: @escaping () -> Void) {
        client.call("left_click", ["coordinate": [720, 190]]) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.client.call("list_tabs") { r, _ in
                    let tabs = (SpikeMCPClient.json(r)["tabs"] as? [[String: Any]]) ?? []
                    self.check(tabs.count == 2, "a target=_blank link opens a second tab in the agent window (\(tabs.count))")
                    if let first = tabs.first?["tab"] as? Int { self.client.call("select_tab", ["tab": first]) { _, _ in } }
                    if let second = tabs.last?["tab"] as? Int, tabs.count == 2 { self.client.call("close_tab", ["tab": second]) { _, _ in } }
                    self.client.call("navigate", ["url": "\(self.base)/second.html"]) { r, ms in
                        let j = SpikeMCPClient.json(r)
                        self.measure("navigate_ms", Int(ms))
                        self.check(j["loaded"] as? Bool == true && j["title"] as? String == "Second", "navigate loads and waits (\(j["title"] ?? "nil"))")
                        self.client.call("navigate", ["url": "file:///etc/hosts"]) { r, _ in
                            self.check(SpikeMCPClient.isError(r), "navigate refuses file: addresses")
                            self.client.call("go_back") { r, _ in
                                self.check(SpikeMCPClient.json(r)["title"] as? String == "Agentspike", "go_back returns to the page (\(SpikeMCPClient.json(r)["title"] ?? "nil"))")
                                self.client.call("list_windows") { r, _ in
                                    let ws = (SpikeMCPClient.json(r)["windows"] as? [[String: Any]]) ?? []
                                    self.check(ws.count == 1 && ws.first?["key"] as? Bool == false, "list_windows lists this connection's one window")
                                    done()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The same page in a window the engine treats as hidden (no visible-capture hold): what still works.
    func hiddenComparison(_ done: @escaping () -> Void) {
        client.call("open_window", ["url": "\(base)/agent.html", "keepVisible": false, "width": 800, "height": 600]) { r, _ in
            let id = SpikeMCPClient.json(r)["window"] as? Int ?? 0
            guard let w = AgentCenter.shared.windows[id], let tab = w.activeTab else { self.check(false, "hidden-mode window opens"); return done() }
            let read = "(function(){var s={};try{s=JSON.parse(document.getElementById('state').textContent||'{}');}catch(e){}s.visibility=document.visibilityState;s.hasFocus=document.hasFocus();return JSON.stringify(s);})()"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                w.driver.evaluate(tab, read) { v in
                    let a = agentJSON(v) ?? [:]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        w.driver.evaluate(tab, read) { v in
                            let b = agentJSON(v) ?? [:]
                            self.measure("hidden_page_visibility", b["visibility"] ?? "?")
                            self.measure("hidden_page_raf_per_s", (b["raf"] as? Int ?? 0) - (a["raf"] as? Int ?? 0))
                            self.client.call("screenshot", ["window": id], timeout: 15) { r, ms in
                                let image = SpikeMCPClient.image(r)
                                let red = image.flatMap { AgentImages.pixel($0, x: 100, y: 50) }
                                self.measure("hidden_screenshot_ok", red.map { $0.r > 220 && $0.g < 40 } ?? false)
                                self.measure("hidden_screenshot_ms", Int(ms))
                                self.client.call("left_click", ["coordinate": [380, 55], "window": id]) { _, ms in
                                    w.driver.evaluate(tab, read) { v in
                                        self.measure("hidden_click_reached", (agentJSON(v)?["clicks"] as? Int ?? 0) == 1)
                                        self.measure("hidden_click_ms", Int(ms))
                                        self.client.call("close_window", ["window": id]) { _, _ in done() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Idle cost

    struct Proc { var pid: Int32; var ppid: Int32; var rssKB: Int; var cpuSeconds: Double; var name: String }

    func processes() -> [Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "pid=,ppid=,rss=,time=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), let rss = Int(f[2]) else { return nil }
            return Proc(pid: pid, ppid: ppid, rssKB: rss, cpuSeconds: Self.seconds(String(f[3])), name: String(f[4]))
        }
    }

    /// ps's cumulative CPU time, [[dd-]hh:]mm:ss.cc, in seconds.
    static func seconds(_ t: String) -> Double {
        var days = 0.0, rest = t
        if let dash = t.firstIndex(of: "-") { days = Double(t[..<dash]) ?? 0; rest = String(t[t.index(after: dash)...]) }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86400 + total
    }

    /// This app and its engine processes (Chromium's helpers are our children; WebKit's are launchd's, so its own
    /// WebContent processes count by name only when they're new since the baseline).
    func ours(_ all: [Proc], extra: Set<Int32>) -> [Proc] {
        let me = getpid()
        var set: Set<Int32> = [me]
        var grew = true
        while grew {
            grew = false
            for p in all where !set.contains(p.pid) && set.contains(p.ppid) { set.insert(p.pid); grew = true }
        }
        return all.filter { set.contains($0.pid) || extra.contains($0.pid) }
    }

    func idleCost(_ done: @escaping () -> Void) {
        // Baseline: the agent's page window closed, 10 s; then one idle agent window, settled, 10 s.
        client.call("close_window", ["window": windowID]) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let before = self.processes()
                let ownBefore = self.ours(before, extra: [])
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    let mid = self.processes()
                    let cpuBase = self.cpu(self.ours(mid, extra: []), since: ownBefore)
                    self.client.call("open_window", ["url": "\(self.base)/idle.html"]) { r, _ in
                        self.windowID = SpikeMCPClient.json(r)["window"] as? Int ?? 0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            let start = self.processes()
                            let newPIDs = Set(start.map(\.pid)).subtracting(before.map(\.pid))
                            let engineNew = start.filter { newPIDs.contains($0.pid) && ($0.name.contains("Helper") || $0.name.contains("WebKit") || $0.name.contains("WebContent")) }
                            let ownStart = self.ours(start, extra: Set(engineNew.map(\.pid)))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                                let end = self.processes()
                                let cpuWindow = self.cpu(self.ours(end, extra: Set(engineNew.map(\.pid))), since: ownStart)
                                self.measure("idle_cpu_percent_baseline", Self.r1(cpuBase / 10 * 100))
                                self.measure("idle_cpu_percent_with_window", Self.r1(cpuWindow / 10 * 100))
                                self.measure("idle_window_new_processes", engineNew.map { $0.name.split(separator: "/").last.map(String.init) ?? $0.name })
                                let enginePIDs = Set(engineNew.map(\.pid))
                                let engineRSS = end.filter { enginePIDs.contains($0.pid) }.reduce(0) { $0 + $1.rssKB }
                                self.measure("idle_window_new_processes_rss_mb", Self.r1(Double(engineRSS) / 1024))
                                // Each one: Chromium also makes its next spare renderer when the agent page takes the current one.
                                self.measure("idle_window_new_processes_each_mb", end.filter { enginePIDs.contains($0.pid) }
                                    .map { "\($0.name.split(separator: "/").last ?? "?") \(Self.r1(Double($0.rssKB) / 1024))" })
                                let rssBefore = ownBefore.reduce(0) { $0 + $1.rssKB }, rssAfter = self.ours(end, extra: Set(engineNew.map(\.pid))).reduce(0) { $0 + $1.rssKB }
                                self.measure("idle_window_rss_delta_mb", Self.r1(Double(rssAfter - rssBefore) / 1024))
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func cpu(_ now: [Proc], since then: [Proc]) -> Double {
        var t: [Int32: Double] = [:]
        for p in then { t[p.pid] = p.cpuSeconds }
        return now.reduce(0) { $0 + max(0, $1.cpuSeconds - (t[$1.pid] ?? $1.cpuSeconds)) }
    }

    // MARK: HTTP

    /// A raw HTTP request to the loopback transport (no URLSession: no ATS, no cookies, exact headers).
    func http(_ headers: [String: String], body: String, _ done: @escaping (Int, String) -> Void) {
        guard let info = try? Data(contentsOf: AgentCenter.shared.httpInfo),
              let j = try? JSONSerialization.jsonObject(with: info) as? [String: Any], let url = (j["url"] as? String).flatMap(URL.init(string:)),
              let p = url.port else { return done(0, "no info file") }
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(p).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard ok == 0 else { close(fd); return DispatchQueue.main.async { done(0, "connect") } }
            var h = "POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            for (k, v) in headers { h += "\(k): \(v)\r\n" }
            h += "\r\n" + body
            _ = h.withCString { write(fd, $0, strlen($0)) }
            var out = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true { let n = read(fd, &chunk, chunk.count); if n <= 0 { break }; out.append(contentsOf: chunk[0..<n]) }
            close(fd)
            let text = String(decoding: out, as: UTF8.self)
            let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
            DispatchQueue.main.async { done(status, text) }
        }
    }

    func httpChecks(_ done: @escaping () -> Void) {
        guard let info = try? Data(contentsOf: AgentCenter.shared.httpInfo),
              let j = try? JSONSerialization.jsonObject(with: info) as? [String: Any], let token = j["token"] as? String,
              let url = (j["url"] as? String).flatMap(URL.init(string:)), let p = url.port else {
            check(false, "the HTTP transport writes its info file"); return done()
        }
        var st = stat()
        check(stat(AgentCenter.shared.httpInfo.path, &st) == 0 && st.st_mode & 0o777 == 0o600, "the HTTP info file (token) is 0600")
        let host = "127.0.0.1:\(p)"
        let list = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_profiles\",\"arguments\":{},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}"
        http(["Host": host, "Authorization": "Bearer \(token)", "X-Airc-Profile": "Agent", "X-Airc-Client": "agentspike-http"], body: list) { s, text in
            self.check(s == 200 && text.contains("Agent"), "HTTP with the token: list_profiles answers (\(s))")
            self.http(["Host": host], body: list) { s, _ in
                self.check(s == 401, "HTTP without the token: 401 (\(s))")
                self.http(["Host": host, "Authorization": "Bearer \(token)", "Origin": "http://evil.example"], body: list) { s, _ in
                    self.check(s == 403, "HTTP with an Origin (a web page): 403 (\(s))")
                    self.http(["Host": "rebind.example:\(p)", "Authorization": "Bearer \(token)"], body: list) { s, _ in
                        self.check(s == 421, "HTTP with a foreign Host (DNS rebinding): 421 (\(s))")
                        done()
                    }
                }
            }
        }
    }

    // MARK: The log and Stop

    func logAndStop(_ done: @escaping () -> Void) {
        let file = AgentCenter.shared.logFile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var st = stat()
            self.check(stat(file.path, &st) == 0 && st.st_mode & 0o777 == 0o600, "AgentLog.jsonl is 0600")
            self.check(text.contains("\"tool\":\"left_click\"") && text.contains("\"tool\":\"screenshot\"") && text.contains("\"host\":\"127.0.0.1\""),
                       "the log has each call's tool and host")
            self.check(!text.contains(self.typed) && !text.contains("replaced") && !text.contains(self.secretPassword)
                       && !text.contains("quick brown fox") && !text.contains("/agent.html"),
                       "the log has no typed text, page text, password or path")
            self.measure("log_lines", text.split(separator: "\n").count)
            // Stop: the connection ends, agent windows close, the badge goes; a new connection works again.
            let windowsBefore = AgentCenter.shared.windows.count
            self.client.onExit = {
                self.check(AgentCenter.shared.windows.isEmpty && windowsBefore > 0, "Stop Agents closes the agent windows (\(windowsBefore) → 0)")
                self.check(!AgentCenter.shared.badgeShown, "the ✦ badge goes with them")
                self.startClient(profile: "Agent") { ok in
                    self.check(ok, "after Stop, a new connection works")
                    self.client.stop()
                    done()
                }
            }
            AgentCenter.shared.stopAgents(reason: "check")
        }
    }

    func finish() {
        check(!(runner.c?.window.isKeyWindow ?? false) || personWindowKeyAtStart, "the person's window kept its key state")
        check(activations == 0 && !airIsFront,
              "Airc never became the active app during the run (\(activations) activations; front at start \(frontAtStart ?? "none"), at end \(front))")
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
        measures["engine"] = engine
        if let data = try? JSONSerialization.data(withJSONObject: measures, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: runner.dir.appendingPathComponent("agentspike-\(engine).json"))
        }
        client?.stop()
        AgentCenter.shared.stopAgents(reason: "check-end", off: true)
    }
}
#endif
