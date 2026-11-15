// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only: public builds compile nothing in Debug/ (App/TestingGate.swift)
import AppKit
import AircKit

/// `--script parityremote` (Agent/AgentRemote.swift): Settings › Agents › Other devices with the build Mac's UI driver
/// (real clicks; `AIRC_UI_DEDICATED_SESSION=1 AIRC_REAL_KEYS=1 AIRC_LA_AS_OWNER=1`, else FAIL-ENV and posted):
/// - off by default: the line says so, and nothing of this app listens on the network (lsof);
/// - a real click on "Allow other devices on your Tailscale network": it listens only on this Mac's Tailscale addresses
///   (lsof: every listening socket on the port is a tailnet address, never * or loopback), and says where;
/// - a real click on Pair a Device: a one-time code and the command with it;
/// - through the listener's own request path (`simulate`, a tailnet peer): unpaired → 401 and no data; a wrong code,
///   then the right one (a token), then the same code again (refused); the device's first MCP request asks
///   "Allow ‘Claude Code on check-device’…" (its own app), answered with a real click on Allow; tools/list is the local tool set; open_window works and
///   its window is that app's; a wrong token → 401; AgentLog.jsonl holds neither token nor code;
/// - read_page (text and outline) on a headings fixture lists every heading as assistive technology has it (levels,
///   aria-level, landmarks, visually hidden marked, hidden ones left out), and example.com's markup has its h1;
/// - a real click on Revoke: the token gets 401, its window closes, its approval is forgotten;
/// - a real click on the switch again: nothing listens;
/// - with the Tailscale CLI here, the command uses the Mac's MagicDNS name (else the address);
/// - a partial bind (the check holds one address's port) is retried at the next 10 s refresh.
/// The real network path (another computer of the tailnet) is the end-to-end proof in artifacts/mcpremote/REPORT.md.
extension SnapshotRunner {
    func parityRemoteScenario() {
        let k = RemoteCheck(runner: self)
        step { done in k.setUp(done) }
        step { done in k.switchOn(done) }
        step { done in k.pairAndUse(done) }
        step { done in k.headings(done) }
        step { done in k.revoke(done) }
        step { done in k.switchOff(done) }
        step { done in k.partialBind(done) }
        run { k.finish() }
    }
}

final class RemoteCheck {
    unowned let runner: SnapshotRunner
    var app: AppDelegate { runner.app! }
    var engine = "?"
    var real = false
    var port: UInt16 = 0
    var token = ""
    var code = ""
    var sessionID = ""
    var center: AgentCenter { .shared }

    init(runner: SnapshotRunner) { self.runner = runner }

    func note(_ s: String) { runner.note(s) }
    func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + "parityremote \(engine): " + what) }
    func after(_ s: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    var settingsWindow: NSWindow? { app.settingsWindow?.window }

    func setUp(_ done: @escaping () -> Void) {
        engine = app.engine is WebKitEngine ? "webkit" : "chromium"
        let env = ProcessInfo.processInfo.environment
        real = UIDriverClient.available && env["AIRC_UI_DEDICATED_SESSION"] == "1" && env["AIRC_LA_AS_OWNER"] == "1"
        note("parityremote \(engine): input \(real ? "real (UI driver)" : "posted")")
        center.app = app
        // A port of this run's own, so a parallel run (or an Airc the account runs) can't collide.
        port = UInt16(47_900 + Int(getpid() % 500))
        center.runRemotePort = port
        center.enableForCheck(grants: [], http: false)
        center.approvals.automatic = nil   // the device's approval shows, and is read
        check(!center.settings.remoteEnabled && center.remote == nil, "off by default")
        check(center.remoteStatus == "Off. Nothing on this Mac listens on the network.", "the line says so (\(center.remoteStatus))")
        check(listening().isEmpty, "nothing of this app listens on TCP (lsof: \(listening()))")
        app.showSettings(page: .agents)
        reveal { done() }
    }

    func reveal(_ then: @escaping () -> Void) {
        guard let w = settingsWindow else { check(false, "Settings is open"); return then() }
        app.settingsWindow?.model.reveal("Other devices")
        after(0.6) { self.front(w) { _ in then() } }
    }

    func front(_ w: NSWindow, _ then: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        runner.waitUntil({ NSApp.isActive && w.isKeyWindow }, timeout: 5) { then(NSApp.isActive && w.isKeyWindow) }
    }

    /// A real click on a Settings anchor; `posted` when there's no driver or no frame (labelled FAIL-ENV).
    func press(_ anchor: String, in window: NSWindow? = nil, posted: @escaping () -> Void, _ then: @escaping (String) -> Void) {
        guard let w = window ?? settingsWindow, let content = w.contentView else { posted(); return then("posted") }
        content.layoutSubtreeIfNeeded()
        // Settings must be key; the approval card never is (a non-activating panel that takes the first click).
        guard real, w.isKeyWindow || w is AgentApprovalPanel, w.isVisible, let r = TestAnchors.frame(anchor, in: content), let primary = NSScreen.screens.first,
              content.bounds.contains(NSPoint(x: r.midX, y: r.midY)) else {
            note("FAIL-ENV parityremote \(engine): \(anchor) posted (\(real ? "no frame on screen" : "no UI driver"))")
            posted()
            return then("posted")
        }
        let p = NSPoint(x: r.midX, y: content.isFlipped ? r.midY : content.bounds.height - r.midY)
        let g = w.convertPoint(toScreen: content.convert(p, to: nil))
        UIDriverClient.run(["--click", String(Double(g.x.rounded())), String(Double((primary.frame.maxY - g.y).rounded()))]) { ok, out in
            if !ok {
                self.note("FAIL-ENV parityremote \(self.engine) [real click] \(anchor): \(out); posted")
                posted()
            }
            self.after(0.4) { then(ok ? "real click" : "posted") }
        }
    }

    /// This process's listening TCP sockets ("100.99.1.2:47930", "[fd7a:…]:47930", "*:47930"), from lsof.
    func listening() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-a", "-p", "\(getpid())", "-iTCP", "-sTCP:LISTEN", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return ["lsof failed"] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func host(of endpoint: String) -> String {
        var h = endpoint
        if let i = h.lastIndex(of: ":") { h = String(h[..<i]) }
        return h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    func switchOn(_ done: @escaping () -> Void) {
        press("agents-remote-switch", posted: { self.center.setRemoteEnabled(true) }) { how in
            self.runner.waitUntil({ self.center.remote != nil && self.center.remote?.state != .starting }, timeout: 6) {
                self.check(self.center.settings.remoteEnabled && self.center.remote != nil, "[\(how)] the switch turns it on")
                let tailnet = TailnetAddress.current().map(\.address)
                let mine = self.listening().filter { $0.hasSuffix(":\(self.port)") }
                guard !tailnet.isEmpty else {
                    self.note("FAIL-ENV parityremote \(self.engine): Tailscale isn't connected on this Mac")
                    self.check(self.center.remoteStatus.hasPrefix("Tailscale isn't connected") && mine.isEmpty,
                               "no Tailscale: it says so, and nothing listens (\(mine))")
                    return done()
                }
                self.check(Set(mine.map(Self.host)) == Set(tailnet),
                           "it listens on exactly this Mac's Tailscale addresses \(tailnet) (lsof: \(mine))")
                self.check(!mine.isEmpty && mine.allSatisfy { TailnetAddress.isTailnet(Self.host(of: $0)) },
                           "no listener on *, loopback or another network")
                let status = self.center.remoteStatus
                self.check(status.hasPrefix("On · listening only on your Tailscale network, at http://") && status.contains(":\(self.port)"),
                           "the line says where")
                self.magicName(done)
            }
        }
    }

    /// With the Tailscale CLI on this Mac (and MagicDNS on), the command uses the Mac's MagicDNS name, not its address.
    /// The name itself isn't logged (only its tailnet suffix).
    func magicName(_ done: @escaping () -> Void) {
        let cli = TailscaleName.cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        let addresses = TailnetAddress.current().map(\.address)
        guard let cli, let data = RemoteAgentListener.run(cli, TailscaleName.arguments, timeout: 3),
              let expected = TailscaleName.magicDNSName(statusJSON: data, addresses: addresses) else {
            note("FAIL-ENV parityremote \(engine): no Tailscale CLI answer with a MagicDNS name here; the command shows the address")
            check(center.remoteBaseURL.map { u in addresses.contains { u.contains($0) } } ?? false, "without a name, the command uses the address")
            return done()
        }
        runner.waitUntil({ self.center.remote?.hostName != nil }, timeout: 5) {
            let base = self.center.remoteBaseURL ?? ""
            let suffix = expected.split(separator: ".").suffix(2).joined(separator: ".")
            self.check(base == "http://\(expected):\(self.port)", "the command uses this Mac's MagicDNS name (…\(suffix)), from the Tailscale CLI")
            let command = AgentCenter.remoteCommand(base: base, code: "ABCD-EFGH")
            self.check(command.contains("http://\(expected):\(self.port)/pair") && command.contains("http://\(expected):\(self.port)/mcp"), "both URLs in the command use it")
            done()
        }
    }

    /// One request through the listener's own path, off the main thread (it waits for the main thread's answers).
    func request(_ method: String, _ path: String, _ headers: [String: String], _ body: [String: Any]? = nil,
                 _ then: @escaping (RemoteAgentListener.Response) -> Void) {
        guard let remote = center.remote else { return then(.init(status: 0)) }
        let data = body.map { AgentMCP.encode($0) } ?? Data()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = remote.simulate(method, path, headers: headers, body: data, peer: "100.100.7.9")
            DispatchQueue.main.async { then(r) }
        }
    }

    func json(_ r: RemoteAgentListener.Response) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
    }

    var mcpHeaders: [String: String] {
        var h = ["Authorization": "Bearer " + token, "Content-Type": "application/json", "User-Agent": "claude-code/2.1.322"]
        if !sessionID.isEmpty { h["Mcp-Session-Id"] = sessionID }
        return h
    }

    func pairAndUse(_ done: @escaping () -> Void) {
        guard center.remoteListening else { note("FAIL-ENV parityremote \(engine): not listening, pairing skipped"); return done() }
        reveal {
            self.press("agents-remote-pair", posted: { AgentsSettingsModel.shared.startPairing() }) { how in
                self.runner.waitUntil({ AgentsSettingsModel.shared.pairingCode != nil }, timeout: 3) {
                    self.code = AgentsSettingsModel.shared.pairingCode ?? ""
                    self.check(self.code.count == 9, "[\(how)] Pair a Device shows a one-time code")
                    let command = AgentCenter.remoteCommand(base: self.center.remoteBaseURL ?? "", code: self.code)
                    let shown = self.settingsWindow?.contentView.flatMap { TestAnchors.view("agents-remote-command", in: $0) } != nil
                    self.check(shown && command.contains("X-Airc-Pairing-Code: \(self.code)") && command.contains("claude mcp add --transport http --scope user airc http://")
                               && command.hasSuffix("--header \"Authorization: Bearer $t\""), "the command to paste shows, with the code")
                    self.unpaired(done)
                }
            }
        }
    }

    func unpaired(_ done: @escaping () -> Void) {
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"]]]
        request("POST", "/mcp", ["Content-Type": "application/json"], initialize) { r in
            let text = String(decoding: r.body, as: UTF8.self)
            self.check(r.status == 401 && !text.contains("jsonrpc") && !text.contains("airc\""), "unpaired: 401 and no data (\(r.status) \(text.prefix(60)))")
            self.request("POST", "/mcp", ["Authorization": "Bearer airc_notatoken"], initialize) { r in
                self.check(r.status == 401, "an unknown token: 401")
                self.request("POST", "/pair", ["X-Airc-Pairing-Code": "WRNG-WRNG", "X-Airc-Device": "check-device"]) { r in
                    self.check(r.status == 403, "a wrong pairing code is refused (\(r.status))")
                    self.request("POST", "/pair", ["X-Airc-Pairing-Code": self.code.lowercased(), "X-Airc-Device": "check-device"]) { r in
                        self.token = String(decoding: r.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        self.check(r.status == 200 && self.token.hasPrefix("airc_") && self.token.count == 48, "the right code gives the device its token")
                        self.check(AgentsSettingsModel.shared.pairingCode == nil, "the code is gone from Settings once used")
                        self.check(self.center.remoteDevices.map(\.name) == ["check-device"], "Settings lists the device (\(self.center.remoteDevices.map(\.name)))")
                        self.request("POST", "/pair", ["X-Airc-Pairing-Code": self.code, "X-Airc-Device": "again"]) { r in
                            self.check(r.status == 403 && self.center.remoteDevices.count == 1, "the same code doesn't work twice")
                            self.approval(initialize, done)
                        }
                    }
                }
            }
        }
    }

    func approval(_ initialize: [String: Any], _ done: @escaping () -> Void) {
        var answered: RemoteAgentListener.Response?
        request("POST", "/mcp", mcpHeaders, initialize) { answered = $0 }
        runner.waitUntil({ self.center.approvals.shown != nil }, timeout: 5) {
            guard let panel = self.center.approvals.shown else { self.check(false, "the device's first request asks"); return done() }
            self.check(panel.identity.displayName == "Claude Code on check-device" && panel.identity.kind == .remote
                       && panel.identity.detail.contains("Tailscale"), "it asks about “\(panel.identity.displayName)”, its own app (\(panel.identity.detail))")
            if let rep = panel.picture(), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: self.runner.dir.appendingPathComponent("remote-approval-\(self.engine).png"))
            }
            self.press("agent-approval-allow", in: panel, posted: { panel.answer(.allow) }) { how in
            self.runner.waitUntil({ answered != nil }, timeout: 5) {
                self.check(answered != nil && self.center.approvals.shown == nil, "[\(how)] Allow on the card answers it, in one click")
                let r = answered ?? .init(status: 0)
                let result = self.json(r)["result"] as? [String: Any]
                self.sessionID = r.headers["Mcp-Session-Id"] ?? ""
                self.check(r.status == 200 && (result?["serverInfo"] as? [String: Any])?["name"] as? String == "airc" && self.sessionID.count == 32,
                           "Allow: initialize answers, with a session (\(r.status))")
                self.useTools(done)
            }
            }
        }
    }

    func useTools(_ done: @escaping () -> Void) {
        request("POST", "/mcp", mcpHeaders, ["jsonrpc": "2.0", "method": "notifications/initialized"]) { r in
            self.check(r.status == 202, "a notification: 202")
            self.request("POST", "/mcp", self.mcpHeaders, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]) { r in
                let tools = ((self.json(r)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                self.check(tools == self.center.tools.map(\.name) && tools.contains("fill_saved_login"), "tools/list is the local tool set (\(tools.count))")
                self.request("POST", "/mcp", self.mcpHeaders, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                                 "params": ["name": "open_window", "arguments": ["url": "about:blank"]]]) { r in
                    let res = self.json(r)["result"] as? [String: Any]
                    let w = self.center.windows.values.first
                    self.check(res?["isError"] == nil && w?.clientName == "Claude Code on check-device", "open_window works, as that app (\(w?.clientName ?? "none"))")
                    self.check(self.center.settings.clients.contains { $0.key.hasPrefix("remote:") && $0.allowed && $0.name == "Claude Code on check-device" },
                               "Settings › Agents › Apps lists it")
                    var other = self.mcpHeaders
                    other["Mcp-Session-Id"] = "0123456789abcdef0123456789abcdef"
                    self.request("POST", "/mcp", other, ["jsonrpc": "2.0", "id": 4, "method": "tools/list"]) { r in
                        self.check(r.status == 404, "an unknown session: 404")
                        self.after(0.5) {
                            let log = (try? String(contentsOf: self.center.logFile, encoding: .utf8)) ?? ""
                            self.check(log.contains("remote-paired") && !log.contains(self.token) && !log.contains(self.code)
                                       && !log.contains(self.code.replacingOccurrences(of: "-", with: "")), "AgentLog.jsonl notes the pairing, never the token or code")
                            done()
                        }
                    }
                }
            }
        }
    }

    // MARK: Headings (read_page, through the device's session)

    /// h1–h3, headings in landmarks, role=heading with and without aria-level, an aria-level override, a heading
    /// turned off with role=presentation, a visually hidden one (kept, marked), and five hidden ones (left out).
    static let headingsPage = """
    <!doctype html><html><head><title>Headings fixture</title><style>body{font:15px -apple-system,sans-serif}
    .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}</style></head><body>
    <header><h1>Fixture Main Heading</h1></header>
    <nav aria-label="Site"><h2>Site menu</h2></nav>
    <main><h2>Section Two</h2><p>Some text.</p><h3>Sub Three</h3>
    <div role="heading" aria-level="4">Aria Four</div>
    <div role="heading">Aria Default</div>
    <h2 aria-level="5">Override Five</h2>
    <h2 role="presentation">Not A Heading</h2>
    <h2 class="sr">Screen Reader Only</h2>
    <h2 style="display:none">Hidden Display</h2>
    <div style="display:none"><h3>Hidden Parent</h3></div>
    <h2 style="visibility:hidden">Hidden Visibility</h2>
    <h2 hidden>Hidden Attr</h2>
    <div aria-hidden="true"><h3>Hidden Aria</h3></div>
    <section aria-label="Extras"><h3>In Region</h3></section>
    <article><header><h3>Article Header</h3></header></article>
    </main>
    <aside><h2>Side Note</h2></aside>
    <footer><h2>Footer Heading</h2></footer>
    </body></html>
    """
    static let expectedHeadings: [String] = [
        "1 Fixture Main Heading @banner", "2 Site menu @navigation", "2 Section Two @main", "3 Sub Three @main",
        "4 Aria Four @main", "2 Aria Default @main", "5 Override Five @main", "2 Screen Reader Only @main sr",
        "3 In Region @region", "3 Article Header @main", "2 Side Note @complementary", "2 Footer Heading @contentinfo",
    ]
    /// example.com's own markup (no landmarks: a div with the h1), where an agent read "no main heading".
    static let examplePage = """
    <!doctype html><html><head><title>Example Domain</title></head><body><div><h1>Example Domain</h1>
    <p>This domain is for use in documentation examples without needing permission.</p><p><a href="/more">Learn more</a></p></div></body></html>
    """
    var fixture: LocalPageServer?
    var fixturePort: UInt16 = 0

    func call(_ id: Int, _ tool: String, _ args: [String: Any], _ then: @escaping ([[String: Any]], Bool) -> Void) {
        request("POST", "/mcp", mcpHeaders, ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": args]]) { r in
            let res = self.json(r)["result"] as? [String: Any]
            then(res?["content"] as? [[String: Any]] ?? [], res?["isError"] as? Bool ?? (res == nil))
        }
    }

    /// The fenced JSON lists of a page answer, keyed by their first object's shape ("headings" if it has a level).
    static func fencedHeadings(_ content: [[String: Any]]) -> [[String: Any]]? {
        for item in content {
            guard let text = item["text"] as? String, text.hasPrefix("<untrusted-page-content"),
                  let a = text.firstIndex(of: "\n"), let b = text.lastIndex(of: "\n"), a < b,
                  let list = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: a)..<b].utf8)) as? [[String: Any]]
            else { continue }
            if list.isEmpty || list[0]["level"] != nil && list[0]["text"] != nil { return list }
        }
        return nil
    }

    static func line(_ h: [String: Any]) -> String {
        "\(h["level"] as? Int ?? 0) \(h["text"] as? String ?? "")" + ((h["landmark"] as? String).map { " @" + $0 } ?? "")
            + (h["screenReaderOnly"] as? Bool == true ? " sr" : "")
    }

    func headings(_ done: @escaping () -> Void) {
        guard !sessionID.isEmpty, let window = center.windows.keys.first else { note("FAIL-ENV parityremote \(engine): no session, headings skipped"); return done() }
        fixture = LocalPageServer(responses: ["/headings.html": LocalPageServer.Page(body: Self.headingsPage),
                                              "/example.html": LocalPageServer.Page(body: Self.examplePage)])
        fixture?.start { p in
            self.fixturePort = p ?? 0
            let base = "http://127.0.0.1:\(self.fixturePort)"
            self.call(10, "navigate", ["url": base + "/headings.html", "window": window]) { _, err in
                self.check(!err, "navigate to the headings fixture")
                self.call(11, "read_page", ["mode": "text", "window": window]) { content, _ in
                    let got = Self.fencedHeadings(content)?.map(Self.line) ?? ["none"]
                    self.check(got == Self.expectedHeadings, "read_page text lists the headings: levels, aria-level, landmarks, visually hidden marked, hidden left out (\(got))")
                    self.call(12, "read_page", ["mode": "outline", "window": window]) { content, _ in
                        let got = Self.fencedHeadings(content)?.map(Self.line) ?? ["none"]
                        self.check(got == Self.expectedHeadings, "read_page outline lists the same headings")
                        let elements = content.compactMap { $0["text"] as? String }.first { $0.contains("\"role\":\"heading\"") } ?? ""
                        self.check(elements.contains("\"level\":1") && elements.contains("Fixture Main Heading") && !elements.contains("Hidden Aria")
                                   && !elements.contains("Hidden Display"),
                                   "outline elements give headings their level and leave hidden ones out")
                        self.call(13, "navigate", ["url": base + "/example.html", "window": window]) { _, _ in
                            self.call(14, "read_page", ["mode": "text", "window": window]) { content, _ in
                                let got = Self.fencedHeadings(content)?.map(Self.line) ?? ["none"]
                                self.check(got == ["1 Example Domain"], "example.com's markup: its h1 is the main heading (\(got))")
                                self.fixture?.stop()
                                done()
                            }
                        }
                    }
                }
            }
        }
    }

    func revoke(_ done: @escaping () -> Void) {
        guard !token.isEmpty else { return done() }
        reveal {
            let id = self.center.remoteDevices.first?.id ?? ""
            self.press("agents-remote-revoke", posted: { self.center.revokeDevice(id) }) { how in
                self.runner.waitUntil({ self.center.remoteDevices.isEmpty }, timeout: 3) {
                    self.check(self.center.remoteDevices.isEmpty, "[\(how)] Revoke removes the device")
                    self.request("POST", "/mcp", self.mcpHeaders, ["jsonrpc": "2.0", "id": 5, "method": "tools/list"]) { r in
                        self.check(r.status == 401, "its token: 401 (\(r.status))")
                        self.runner.waitUntil({ self.center.windows.isEmpty }, timeout: 3) {
                            self.check(self.center.windows.isEmpty, "its window closed")
                            self.check(!self.center.settings.clients.contains { $0.key.hasPrefix("remote:") }, "its approval is forgotten")
                            done()
                        }
                    }
                }
            }
        }
    }

    func switchOff(_ done: @escaping () -> Void) {
        reveal {
            self.press("agents-remote-switch", posted: { self.center.setRemoteEnabled(false) }) { how in
                self.runner.waitUntil({ self.center.remote == nil }, timeout: 3) {
                    let mine = self.listening().filter { $0.hasSuffix(":\(self.port)") }
                    self.check(self.center.remote == nil && !self.center.settings.remoteEnabled && mine.isEmpty, "[\(how)] off: nothing listens (\(mine))")
                    self.check(self.center.remoteStatus == "Off. Nothing on this Mac listens on the network.", "the line says so")
                    done()
                }
            }
        }
    }

    /// A listening socket of the check's own on `address`:`port` (no SO_REUSEPORT, so the listener can't bind it too).
    static func occupy(_ address: String, port: UInt16) -> Int32? {
        let v6 = address.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var rc: Int32 = -1
        if v6 {
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6); a.sin6_port = port.bigEndian
            if inet_pton(AF_INET6, address, &a.sin6_addr) == 1 {
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
            if inet_pton(AF_INET, address, &a.sin_addr) == 1 {
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
        }
        guard rc == 0, Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// Only one of the two addresses binds (the check holds the other's port), then it's free: the listener takes it at
    /// its next 10 s refresh, with the addresses unchanged.
    func partialBind(_ done: @escaping () -> Void) {
        let tailnet = TailnetAddress.current().map(\.address)
        guard tailnet.count >= 2, let held = tailnet.last, let fd = Self.occupy(held, port: port) else {
            note("FAIL-ENV parityremote \(engine): partial bind needs two Tailscale addresses and a free port (\(tailnet.count))")
            return done()
        }
        let others = tailnet.filter { $0 != held }
        center.setRemoteEnabled(true)
        runner.waitUntil({ self.center.remote != nil && self.center.remoteListening }, timeout: 6) {
            let mine = self.listening().filter { $0.hasSuffix(":\(self.port)") }.map(Self.host)
            // lsof lists the check's own socket too (same process): the listener's are the rest.
            let listenerAddresses: [String] = { if case .listening(let a, _) = self.center.remote?.state { return a }; return [] }()
            self.check(Set(listenerAddresses) == Set(others) && mine.filter { $0 == held }.count == 1,
                       "with \(held) taken, it listens on the other address only (\(listenerAddresses))")
            let log0 = (try? String(contentsOf: self.center.logFile, encoding: .utf8)) ?? ""
            self.check(log0.contains("remote-partial"), "AgentLog notes the partial bind")
            Darwin.close(fd)
            let t0 = Date()
            self.runner.waitUntil({
                if case .listening(let a, _) = self.center.remote?.state { return Set(a) == Set(tailnet) }
                return false
            }, timeout: 15) {
                let s = Date().timeIntervalSince(t0)
                let now = self.listening().filter { $0.hasSuffix(":\(self.port)") }.map(Self.host)
                self.check(Set(now) == Set(tailnet) && now.count == tailnet.count,
                           "once free, the next refresh binds it too, addresses unchanged (after \(String(format: "%.1f", s)) s; lsof \(now))")
                self.center.setRemoteEnabled(false)
                self.runner.waitUntil({ self.center.remote == nil }, timeout: 3) {
                    self.check(self.listening().filter { $0.hasSuffix(":\(self.port)") }.isEmpty, "off again: nothing listens")
                    done()
                }
            }
        }
    }

    func finish() {
        settingsWindow?.close()
        center.setRemoteEnabled(false)
        center.stopAgents(reason: "check-end", off: true)
        runner.finish()
    }
}
#endif
